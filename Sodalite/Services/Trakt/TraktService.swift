import Foundation
import Observation

/// Reads and writes the per-profile Trakt session. The container implements it, so the keychain
/// logic stays in one place.
@MainActor
protocol TraktSessionStoring: AnyObject {
    func loadTraktSession(for profile: ProfileKey) -> TraktSession?
    func saveTraktSession(_ session: TraktSession, for profile: ProfileKey)
    func deleteTraktSession(for profile: ProfileKey)
}

/// The Trakt connection of the active Jellyfin profile: sign-in, the two-way watched sync, ratings,
/// the watchlist and lists behind the Home rows, and scrobbling for the player.
///
/// It follows the active profile (`activate`) and keeps nothing about any other profile in memory.
@Observable
@MainActor
final class TraktService {
    private(set) var profile: ProfileKey?
    private(set) var session: TraktSession?
    private(set) var lists = TraktListsSnapshot()
    private(set) var isSyncing = false
    private(set) var lastSyncError: String?

    var isAvailable: Bool { client != nil }
    var isConnected: Bool { session != nil }

    @ObservationIgnored private let client: TraktClient?
    @ObservationIgnored private weak var store: TraktSessionStoring?
    @ObservationIgnored private let libraryService: JellyfinLibraryServiceProtocol
    @ObservationIgnored private let itemService: JellyfinItemServiceProtocol
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// Bumped whenever a sync starts or the profile changes, so a cancelled sync unwinding late does
    /// not clear the state of the one that replaced it.
    @ObservationIgnored private var syncGeneration = 0
    @ObservationIgnored private var cachedIndex: (profile: ProfileKey, built: Date, index: TraktLibrary.Index)?
    /// Series ids for episodes the player scrobbles, so a binge looks each show up once.
    @ObservationIgnored private var seriesIDsCache: [String: TraktIDs] = [:]

    /// A sync runs at most this often on its own; "Sync now" and a fresh connection skip the wait.
    static let syncInterval: TimeInterval = 5 * 60

    init(clientID: String?, store: TraktSessionStoring,
         libraryService: JellyfinLibraryServiceProtocol, itemService: JellyfinItemServiceProtocol) {
        self.client = clientID.map { TraktClient(clientID: $0) }
        self.store = store
        self.libraryService = libraryService
        self.itemService = itemService
        client?.onTokensChanged = { [weak self] tokens in self?.tokensChanged(tokens) }
    }

    // MARK: - Profile

    /// Loads the given profile's connection. Called whenever the active profile changes.
    func activate(profile: ProfileKey?) {
        guard profile != self.profile else { return }
        syncGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
        lastSyncError = nil
        cachedIndex = nil
        seriesIDsCache = [:]
        self.profile = profile
        session = profile.flatMap { store?.loadTraktSession(for: $0) }
        client?.setTokens(session?.tokens)
        lists = profile.flatMap { TraktCacheStore.load(TraktListsSnapshot.self, name: TraktCacheStore.lists, profile: $0) }
            ?? TraktListsSnapshot()
        NotificationCenter.default.post(name: .traktListsDidChange, object: nil)
    }

    private func tokensChanged(_ tokens: TraktTokens?) {
        guard let profile, var session else { return }
        guard let tokens else {
            // The refresh token was refused: the connection is gone and only a new sign-in helps.
            LogTap.shared.note("[Trakt] session ended by Trakt, disconnecting \(profile.fingerprint)")
            disconnectLocally()
            return
        }
        session.tokens = tokens
        self.session = session
        store?.saveTraktSession(session, for: profile)
    }

    // MARK: - Connect

    func requestDeviceCode() async throws -> TraktDeviceCode {
        guard let client else { throw TraktError.notConfigured }
        return try await client.requestDeviceCode()
    }

    /// Polls until the user approved the code on their phone, then stores the connection.
    func completeDeviceSignIn(_ code: TraktDeviceCode) async throws {
        guard let client, let profile else { throw TraktError.notConfigured }
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        let interval = max(code.interval, 1)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            guard profile == self.profile else { throw CancellationError() }
            if let tokens = try await client.pollDeviceToken(code) {
                let settings = try? await client.get(.userSettings, as: TraktUserSettings.self)
                let session = TraktSession(tokens: tokens, username: settings?.user.username ?? "Trakt",
                                           isVIP: settings?.user.vip ?? false)
                self.session = session
                store?.saveTraktSession(session, for: profile)
                LogTap.shared.note("[Trakt] connected \(profile.fingerprint)")
                sync(force: true)
                return
            }
        }
        throw TraktError.deviceCodeExpired
    }

    func disconnect() async {
        await client?.revoke()
        disconnectLocally()
    }

    private func disconnectLocally() {
        syncGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        isSyncing = false
        if let profile {
            store?.deleteTraktSession(for: profile)
            TraktCacheStore.removeAll(profile)
        }
        session = nil
        client?.setTokens(nil)
        lists = TraktListsSnapshot()
        NotificationCenter.default.post(name: .traktListsDidChange, object: nil)
    }

    func updateOptions(_ change: (inout TraktOptions) -> Void) {
        guard let profile, var session else { return }
        change(&session.options)
        self.session = session
        store?.saveTraktSession(session, for: profile)
    }

    // MARK: - Sync

    /// Starts a sync unless one ran within `syncInterval` or one is running.
    func sync(force: Bool = false, ignoringInterval: Bool = false) {
        guard client != nil, let session, syncTask == nil else { return }
        if !force, !ignoringInterval, let last = session.cursors.lastSyncAt,
           Date().timeIntervalSince(last) < Self.syncInterval { return }
        syncGeneration += 1
        let generation = syncGeneration
        isSyncing = true
        syncTask = Task { [weak self] in
            await self?.performSync(readFullHistory: force)
            guard let self, self.syncGeneration == generation else { return }
            self.syncTask = nil
            self.isSyncing = false
        }
    }

    /// `readFullHistory` (Sync now, a fresh connection) re-reads Trakt's watched history even when
    /// its stamps did not move, so a sync can always be made to look at everything again.
    private func performSync(readFullHistory: Bool = false) async {
        guard let client, let profile, let start = session else { return }
        do {
            let activities = try await client.get(.lastActivities, as: TraktLastActivities.self)
            var cursors = start.cursors
            var markedPlayed = 0
            var pushedAny = false

            var full = try await syncWatchedIfEnabled(
                client: client, profile: profile, activities: activities, readFullHistory: readFullHistory,
                cursors: &cursors, markedPlayed: &markedPlayed, pushedAny: &pushedAny)
            // The rating and position passes need every item, played or not; read it once per sync.
            let libraryService = self.libraryService
            func fullLibrary() async throws -> TraktLibrary {
                if let full { return full }
                let loaded = try await TraktLibrary.load(service: libraryService, userID: profile.userID, playedOnly: false).0
                full = loaded
                return loaded
            }

            let ratedStamp = Self.latest(activities.movies?.ratedAt, activities.shows?.ratedAt, activities.episodes?.ratedAt)
            if session?.options.syncRatings == true, cursors.ratedAt == nil || ratedStamp != cursors.ratedAt {
                try await syncRatings(client: client, profile: profile, library: try await fullLibrary())
                cursors.ratedAt = ratedStamp
            }

            let pausedStamp = Self.latest(activities.movies?.pausedAt, activities.episodes?.pausedAt)
            var resumed = 0
            if session?.options.syncWatched == true, pausedStamp != nil, pausedStamp != cursors.playbackAt {
                resumed = try await syncPlayback(client: client, profile: profile, library: try await fullLibrary())
                cursors.playbackAt = pausedStamp
            }

            let listsStamp = Self.latest(activities.watchlist?.updatedAt, activities.movies?.watchlistedAt,
                                         activities.shows?.watchlistedAt, activities.lists?.updatedAt)
            if listsStamp == nil || listsStamp != cursors.listsAt
                || TraktCacheStore.load(TraktListsSnapshot.self, name: TraktCacheStore.lists, profile: profile) == nil {
                try await refreshLists(client: client, profile: profile)
                cursors.listsAt = listsStamp
            }

            // Our own push moves Trakt's watched stamps past the cursors stored here, so the next
            // sync reads the history once more. Re-reading the stamps now would save that, but it
            // would also swallow a watch another device scrobbled in between, which nothing pulls.
            cursors.lastSyncAt = Date()
            guard profile == self.profile, var session else { return }
            session.cursors = cursors
            self.session = session
            store?.saveTraktSession(session, for: profile)
            lastSyncError = nil
            if markedPlayed > 0 || resumed > 0 {
                NotificationCenter.default.post(name: .homePlayedDidChange, object: nil)
                TopShelfRefresher.invalidate()
            }
            LogTap.shared.note("[Trakt] sync done: \(markedPlayed) marked played, \(resumed) resume positions, pushed=\(pushedAny)")
        } catch is CancellationError {
        } catch {
            guard profile == self.profile else { return }
            lastSyncError = ErrorText.user(for: error)
            LogTap.shared.note("[Trakt] sync failed: \(error)")
        }
    }

    /// Returns the full library when this pass read it, so the rating pass can reuse it.
    private func syncWatchedIfEnabled(
        client: TraktClient, profile: ProfileKey, activities: TraktLastActivities, readFullHistory: Bool,
        cursors: inout TraktSyncCursors, markedPlayed: inout Int, pushedAny: inout Bool
    ) async throws -> TraktLibrary? {
        guard session?.options.syncWatched == true else { return nil }
        let cached = TraktCacheStore.load(TraktWatchedSnapshot.self, name: TraktCacheStore.watched, profile: profile)
        let isFirst = cached == nil || cursors.lastSyncAt == nil
        let traktMoved = isFirst || readFullHistory
            || activities.movies?.watchedAt != cursors.moviesWatchedAt
            || activities.episodes?.watchedAt != cursors.episodesWatchedAt

        var snapshot = cached ?? TraktWatchedSnapshot()
        var pull: TraktWatchedSnapshot?
        var showsTrustworthy = true
        if traktMoved {
            async let movies = client.get(.watchedMovies, as: [TraktWatchedMovie].self)
            async let shows = client.get(.watchedShows, as: [TraktWatchedShow].self)
            let (watchedMovies, showHeads) = try await (movies, shows)
            let (watchedShows, episodesComplete) = try await withEpisodes(showHeads, client: client, profile: profile)
            showsTrustworthy = episodesComplete
            let watchedEpisodes = watchedShows.reduce(0) { $0 + ($1.seasons ?? []).reduce(0) { $0 + $1.episodes.count } }
            LogTap.shared.note("[Trakt] watched on Trakt: \(watchedMovies.count) movies, \(watchedShows.count) shows, \(watchedEpisodes) episodes")
            snapshot = TraktWatchedSnapshot(movies: watchedMovies, shows: watchedShows)
            snapshot.pushed = cached?.pushed ?? []
            // First sync: everything. After that: what was watched on Trakt since the last one, with
            // a day of slack for clocks and late scrobbles.
            let since = isFirst ? nil : cursors.lastSyncAt?.addingTimeInterval(-24 * 60 * 60)
            pull = TraktWatchedSnapshot(movies: watchedMovies, shows: watchedShows, since: since)
        }

        let (library, index) = try await TraktLibrary.load(service: libraryService, userID: profile.userID,
                                                           playedOnly: !traktMoved)
        if traktMoved { cachedIndex = (profile, Date(), index) }
        let pushSince = isFirst ? nil : cursors.lastSyncAt?.addingTimeInterval(-7 * 24 * 60 * 60)
        var plan = TraktSyncPlan.watched(movies: library.movies, series: library.series,
                                         episodes: library.episodes, trakt: snapshot, pull: pull,
                                         pushSince: pushSince)
        if !showsTrustworthy {
            // A show Trakt counts plays for came back without episodes. Pushing now would send its
            // whole history as new plays, the exact duplication this guard exists for.
            LogTap.shared.note("[Trakt] episode push skipped: Trakt's episode list is incomplete")
            plan.push.shows = []
        }

        markedPlayed = await markPlayed(plan.markPlayed, userID: profile.userID, profile: profile)
        for batch in TraktSyncPlan.batches(plan.push) {
            guard profile == self.profile else { throw CancellationError() }
            let data = try await client.send(.addHistory(batch))
            snapshot.record(batch)
            pushedAny = true
            Self.logHistoryResult(data, sent: batch)
        }
        TraktCacheStore.save(snapshot, name: TraktCacheStore.watched, profile: profile)
        cursors.moviesWatchedAt = activities.movies?.watchedAt
        cursors.episodesWatchedAt = activities.episodes?.watchedAt
        return traktMoved ? library : nil
    }

    /// Fills each watched show's seasons from its progress. A show whose last watch did not move
    /// since the previous sync reuses the stored answer, so a long history costs one call per show
    /// once, and one per show that changed after that. Throws rather than return a show without
    /// its episodes: an empty show reads as "nothing watched" and every episode would be pushed.
    private func withEpisodes(_ heads: [TraktWatchedShow], client: TraktClient,
                              profile: ProfileKey) async throws -> ([TraktWatchedShow], complete: Bool) {
        struct Stored: Codable { let stamp: Date?; let seasons: [TraktWatchedShow.Season] }
        let stored = TraktCacheStore.load([String: Stored].self, name: TraktCacheStore.showProgress, profile: profile) ?? [:]
        var next: [String: Stored] = [:]
        var result: [TraktWatchedShow] = []
        var toFetch: [(Int, TraktWatchedShow)] = []
        for head in heads {
            if let seasons = head.seasons, !seasons.isEmpty {
                result.append(head)
            } else if let id = head.show.ids.trakt {
                if let hit = stored[String(id)], hit.stamp == head.lastWatchedAt {
                    var show = head
                    show.seasons = hit.seasons
                    result.append(show)
                    next[String(id)] = hit
                } else {
                    toFetch.append((id, head))
                }
            }
        }
        var fetched = 0
        var complete = true
        for (id, head) in toFetch {
            guard profile == self.profile else { throw CancellationError() }
            let progress = try await client.get(.showProgress(traktID: id), as: TraktShowProgress.self)
            var show = head
            show.seasons = progress.watchedSeasons
            if (head.plays ?? 0) > 0, show.seasons?.isEmpty != false {
                LogTap.shared.note("[Trakt] \(head.show.title ?? "?") has \(head.plays ?? 0) plays but no watched episode in its progress")
                complete = false
            }
            result.append(show)
            next[String(id)] = Stored(stamp: head.lastWatchedAt, seasons: show.seasons ?? [])
            fetched += 1
        }
        TraktCacheStore.save(next, name: TraktCacheStore.showProgress, profile: profile)
        LogTap.shared.note("[Trakt] show progress: \(fetched) read, \(result.count - fetched) reused")
        return (result, complete)
    }

    private func markPlayed(_ itemIDs: [String], userID: String, profile: ProfileKey) async -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        let service = itemService
        return await withTaskGroup(of: Bool.self) { group in
            var pending = itemIDs.makeIterator()
            var done = 0
            for _ in 0..<4 {
                guard let id = pending.next() else { break }
                group.addTask { (try? await service.setPlayed(userID: userID, itemID: id, isPlayed: true)) != nil }
            }
            for await ok in group {
                if ok { done += 1 }
                guard profile == self.profile else { group.cancelAll(); break }
                if let id = pending.next() {
                    group.addTask { (try? await service.setPlayed(userID: userID, itemID: id, isPlayed: true)) != nil }
                }
            }
            return done
        }
    }

    private func syncRatings(client: TraktClient, profile: ProfileKey, library local: TraktLibrary) async throws {
        async let movies = client.get(.ratings(type: "movies"), as: [TraktRatedItem].self)
        async let shows = client.get(.ratings(type: "shows"), as: [TraktRatedItem].self)
        async let episodes = client.get(.ratings(type: "episodes"), as: [TraktRatedItem].self)
        let rated = try await movies + shows + episodes
        let plan = TraktSyncPlan.ratings(movies: local.movies, series: local.series, episodes: local.episodes,
                                         traktRatings: rated)
        LogTap.shared.note("[Trakt] ratings: \(rated.count) on Trakt, \(plan.setLocal.count) filled in, "
            + "\(plan.push.movies.count + plan.push.shows.count) sent")
        for (itemID, rating) in plan.setLocal {
            guard profile == self.profile else { throw CancellationError() }
            try? await itemService.setRating(userID: profile.userID, itemID: itemID, rating: rating)
        }
        for batch in TraktSyncPlan.batches(plan.push) {
            try await client.send(.addRatings(batch))
        }
    }

    /// Brings positions paused in other apps into Continue Watching. Returns how many moved.
    private func syncPlayback(client: TraktClient, profile: ProfileKey, library: TraktLibrary) async throws -> Int {
        guard let writer = itemService as? UserItemDataServing else { return 0 }
        let paused = try await client.get(.playback, as: [TraktPlaybackItem].self)
        let positions = TraktSyncPlan.playback(movies: library.movies, series: library.series,
                                               episodes: library.episodes, trakt: paused)
        var moved = 0
        for (itemID, position) in positions {
            guard profile == self.profile else { throw CancellationError() }
            if (try? await writer.updateUserData(itemID: itemID, userID: profile.userID, positionTicks: position.ticks,
                                                 played: false, lastPlayed: position.at)) != nil {
                moved += 1
            }
        }
        LogTap.shared.note("[Trakt] playback: \(paused.count) paused on Trakt, \(moved) positions taken over")
        return moved
    }

    /// After a playback ends: Trakt has just been told, so a sync a few seconds later picks up what
    /// the scrobble changed there without waiting for the interval.
    func syncAfterPlayback() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.sync(ignoringInterval: true)
        }
    }

    private func refreshLists(client: TraktClient, profile: ProfileKey) async throws {
        let watchlist = try await client.get(.watchlist, as: [TraktListEntry].self)
        let lists = (try? await client.get(.lists, as: [TraktList].self)) ?? []
        var snapshot = TraktListsSnapshot(watchlist: watchlist.compactMap(TraktListItem.init))
        for list in lists {
            guard let id = list.ids.trakt else { continue }
            let entries = (try? await client.get(.listItems(listID: id), as: [TraktListEntry].self)) ?? []
            snapshot.lists.append(.init(id: id, name: list.name, items: entries.compactMap(TraktListItem.init)))
        }
        guard profile == self.profile else { return }
        self.lists = snapshot
        TraktCacheStore.save(snapshot, name: TraktCacheStore.lists, profile: profile)
        NotificationCenter.default.post(name: .traktListsDidChange, object: nil)
    }

    private static func logHistoryResult(_ data: Data, sent: TraktSyncBody) {
        let sentEpisodes = sent.shows.reduce(0) { $0 + ($1.seasons ?? []).reduce(0) { $0 + ($1.episodes?.count ?? 0) } }
        guard let result = try? TraktClient.makeDecoder().decode(TraktHistoryResult.self, from: data) else {
            LogTap.shared.note("[Trakt] history push: sent \(sent.movies.count) movies, \(sentEpisodes) episodes, answer unreadable")
            return
        }
        let missingShows = (result.notFound?.shows ?? []).map { show in
            [show.title, TraktKey.keys(show.ids).joined(separator: ",")].compactMap { $0 }.joined(separator: " ")
        }
        LogTap.shared.note(
            "[Trakt] history push: sent \(sent.movies.count) movies, \(sentEpisodes) episodes; "
            + "added \(result.added?.movies ?? 0) movies, \(result.added?.episodes ?? 0) episodes; "
            + "not found \(result.notFound?.movies?.count ?? 0) movies, \(missingShows.count) shows "
            + "\(missingShows.prefix(5)), \(result.notFound?.episodes?.count ?? 0) episodes"
        )
    }

    nonisolated private static func latest(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }

    // MARK: - Library index for the rows

    /// Movies and series by external id. Reused for ten minutes; a sync that read the whole library
    /// refreshes it for free.
    func libraryIndex() async throws -> TraktLibrary.Index {
        guard let profile else { return TraktLibrary.Index(items: []) }
        if let cachedIndex, cachedIndex.profile == profile, Date().timeIntervalSince(cachedIndex.built) < 600 {
            return cachedIndex.index
        }
        let index = try await TraktLibrary.index(service: libraryService, userID: profile.userID)
        if profile == self.profile { cachedIndex = (profile, Date(), index) }
        return index
    }

    // MARK: - Live writes from the UI

    /// The viewer rated a title in Sodalite. nil or 0 removes the rating on Trakt.
    func ratingChanged(for item: JellyfinItem, rating: Double?) {
        guard let client, session?.options.syncRatings == true else { return }
        let traktRating = TraktRating.trakt(fromJellyfin: rating)
        Task {
            guard let body = await ratingBody(for: item, rating: traktRating) else { return }
            do {
                try await client.send(traktRating == nil ? .removeRatings(body) : .addRatings(body))
            } catch {
                LogTap.shared.note("[Trakt] rating write failed: \(error)")
            }
        }
    }

    private func ratingBody(for item: JellyfinItem, rating: Int?) async -> TraktSyncBody? {
        var body = TraktSyncBody()
        switch item.type {
        case .movie:
            guard let ids = TraktIDs(item: item) else { return nil }
            body.movies = [.init(ids: ids.external, rating: rating)]
        case .series:
            guard let ids = TraktIDs(item: item) else { return nil }
            body.shows = [.init(ids: ids.external, rating: rating)]
        case .episode:
            guard let ids = TraktIDs(item: item) else { return nil }
            body.episodes = [.init(ids: ids.external, rating: rating)]
        default:
            return nil
        }
        return body
    }

    /// The viewer marked something watched or unwatched in Sodalite. Watched goes to Trakt now
    /// rather than at the next sync; unwatched has to, or the sync would pull it back in.
    func playedChanged(for item: JellyfinItem, played: Bool, seasonNumber: Int? = nil) {
        guard let client, session?.options.syncWatched == true else { return }
        Task {
            guard let body = await historyBody(for: item, seasonNumber: seasonNumber, watchedAt: played ? Date() : nil)
            else { return }
            do {
                try await client.send(played ? .addHistory(body) : .removeHistory(body))
                if let profile, var snapshot = TraktCacheStore.load(TraktWatchedSnapshot.self,
                                                                    name: TraktCacheStore.watched, profile: profile) {
                    if played { snapshot.record(body) } else { snapshot.forget(body) }
                    TraktCacheStore.save(snapshot, name: TraktCacheStore.watched, profile: profile)
                }
            } catch {
                LogTap.shared.note("[Trakt] history write failed: \(error)")
            }
        }
    }

    private func historyBody(for item: JellyfinItem, seasonNumber: Int?, watchedAt: Date?) async -> TraktSyncBody? {
        var body = TraktSyncBody()
        switch item.type {
        case .movie:
            guard let ids = TraktIDs(item: item) else { return nil }
            body.movies = [.init(ids: ids.external, watchedAt: watchedAt.map(TraktDate.wire))]
        case .series:
            guard let ids = TraktIDs(item: item) else { return nil }
            let seasons = seasonNumber.map { [TraktSyncBody.Show.Season(number: $0, episodes: nil)] }
            body.shows = [.init(ids: ids.external, seasons: seasons)]
        case .episode:
            guard let season = item.parentIndexNumber, let number = item.indexNumber,
                  let showIDs = await seriesIDs(for: item) else { return nil }
            body.shows = [.init(ids: showIDs.external, seasons: [
                .init(number: season, episodes: [.init(number: number, watchedAt: watchedAt.map(TraktDate.wire))])
            ])]
        default:
            return nil
        }
        return body
    }

    // MARK: - Watchlist

    func isOnWatchlist(_ item: JellyfinItem) -> Bool {
        guard let ids = TraktIDs(item: item) else { return false }
        return lists.isOnWatchlist(ids)
    }

    /// Adds or removes the title. The local snapshot changes first so the button answers at once;
    /// a failure puts it back.
    func setOnWatchlist(_ item: JellyfinItem, _ onList: Bool) async throws {
        guard let client, let profile, let ids = TraktIDs(item: item) else { throw TraktError.notConnected }
        var body = TraktSyncBody()
        let kind: TraktListItem.Kind
        switch item.type {
        case .movie:
            body.movies = [.init(ids: ids.external)]
            kind = .movie
        case .series:
            body.shows = [.init(ids: ids.external)]
            kind = .show
        default:
            throw TraktError.notConnected
        }
        let before = lists
        let keys = Set(TraktKey.keys(ids))
        if onList {
            let entry = TraktListItem(kind: kind, ids: ids, title: item.name, year: item.productionYear, posterURL: nil)
            lists.watchlist.insert(entry, at: 0)
        } else {
            lists.watchlist.removeAll { !keys.isDisjoint(with: TraktKey.keys($0.ids)) }
        }
        NotificationCenter.default.post(name: .traktListsDidChange, object: nil)
        do {
            try await client.send(onList ? .addToWatchlist(body) : .removeFromWatchlist(body))
            TraktCacheStore.save(lists, name: TraktCacheStore.lists, profile: profile)
        } catch {
            lists = before
            NotificationCenter.default.post(name: .traktListsDidChange, object: nil)
            throw error
        }
    }

    // MARK: - Scrobble

    /// One playback event. Live TV and items Trakt cannot identify are skipped. Failures only log:
    /// a scrobble that did not land must never disturb playback.
    func scrobble(_ action: TraktEndpoint.ScrobbleAction, item: JellyfinItem, positionTicks: Int64) {
        guard let client, session?.options.scrobble == true,
              let runtime = item.runTimeTicks, runtime > 0 else { return }
        let progress = min(100, max(0, Double(positionTicks) / Double(runtime) * 100))
        Task {
            guard let body = await scrobbleBody(for: item, progress: progress) else { return }
            do {
                try await client.send(.scrobble(action: action, body: body))
            } catch APIError.httpError(let status, _) where status == 409 || status == 422 {
                // 409: already scrobbled moments ago. 422: under 1 %. Both are Trakt saying "no-op".
            } catch {
                LogTap.shared.note("[Trakt] scrobble \(action.rawValue) failed: \(error)")
            }
        }
    }

    private func scrobbleBody(for item: JellyfinItem, progress: Double) async -> TraktScrobbleBody? {
        switch item.type {
        case .movie:
            guard let ids = TraktIDs(item: item) else { return nil }
            return TraktScrobbleBody(movie: TraktMovie(title: item.name, year: item.productionYear, ids: ids.external),
                                     progress: progress)
        case .episode:
            if let showIDs = await seriesIDs(for: item), let season = item.parentIndexNumber,
               let number = item.indexNumber {
                return TraktScrobbleBody(show: TraktShow(title: item.seriesName, ids: showIDs.external),
                                         episode: .init(season: season, number: number), progress: progress)
            }
            guard let ids = TraktIDs(item: item) else { return nil }
            return TraktScrobbleBody(episode: .init(ids: ids.external), progress: progress)
        default:
            return nil
        }
    }

    private func seriesIDs(for episode: JellyfinItem) async -> TraktIDs? {
        guard let seriesID = episode.seriesId, let profile else { return nil }
        if let cached = seriesIDsCache[seriesID] { return cached }
        guard let series = try? await itemService.getItemDetail(userID: profile.userID, itemID: seriesID),
              let ids = TraktIDs(item: series) else { return nil }
        seriesIDsCache[seriesID] = ids
        return ids
    }
}
