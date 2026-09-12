import os.log
@preconcurrency import TVServices

private let log = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: "ContentProvider")

/// Top Shelf provider; tvOS calls loadTopShelfContent on icon focus + background refresh. No session or a transient API error both return nil (shelf falls back to the static brand asset).
///
/// `@objc(SodaliteTopShelfContentProvider)` pins an explicit Obj-C name so PluginKit's NSClassFromString lookup against NSExtensionPrincipalClass survives Swift name-mangling. The target also needs `OTHER_LDFLAGS = -e _NSExtensionMain` (Xcode sets it automatically, hand-rolled pbxproj targets do not).
@objc(SodaliteTopShelfContentProvider)
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard TopShelfEnabled.read() else {
            log.notice("Top Shelf switched off in Settings; rendering empty.")
            return nil
        }
        guard let session = SharedSession.read() else {
            log.notice("No shared session in keychain; TopShelf will render empty.")
            return nil
        }
        let api = TopShelfAPI(session: session)

        async let resume = Self.fetch("resume") { try await api.resumeItems() }
        async let nextUp = Self.fetch("nextUp") { try await api.nextUp() }

        let fetchedResume = await resume
        let fetchedNextUp = await nextUp

        // Failure path only: a healthy load never touches the container, which keeps the
        // extension's tight budget clear of a read + decode it has no use for.
        let cached = (fetchedResume == nil || fetchedNextUp == nil)
            ? Self.usableCache(session: session)
            : nil

        let resumeItems = fetchedResume ?? cached?.resume ?? []
        let nextUpItems = fetchedNextUp ?? cached?.nextUp ?? []
        log.info("Fetched resume=\(resumeItems.count) nextUp=\(nextUpItems.count) usedCache=\(cached != nil)")

        // Writes the merged view, not just what came back, so a partial failure still leaves
        // both sections populated for the next total failure.
        if TopShelfCachePolicy.shouldWrite(resumeSucceeded: fetchedResume != nil,
                                           nextUpSucceeded: fetchedNextUp != nil) {
            TopShelfCache(serverURL: session.baseURL.absoluteString,
                          userID: session.userID,
                          resume: resumeItems,
                          nextUp: nextUpItems).write()
        }

        // Every cell of both rows, bar or no bar. The pass answers for the whole shelf or for none
        // of it, so `bars` is either empty or covers every cell; a partial map is what put two bar
        // styles and two resolutions in one row (Sodalite#128).
        //
        // Warm in the normal case: the app renders these when it has a reason to, so what happens
        // here is a directory listing. The pass stays as the fallback for a shelf whose items
        // changed while the app was closed, and it is the reason this can still cost seconds.
        let artwork = TopShelfArtwork.read()
        let bars = await ResumeBarArtwork.prepare(cells: (resumeItems + nextUpItems)
                                                      .compactMap { $0.artworkCell(session: session, artwork: artwork) },
                                                  accent: TopShelfAccent.read())
        log.info("shelf artwork rendered=\(bars.count)")

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        if !resumeItems.isEmpty {
            let collection = TVTopShelfItemCollection(items: resumeItems.map {
                makeItem(item: $0, session: session, barURL: bars[$0.id], artwork: artwork)
            })
            collection.title = String(
                localized: "TopShelf.ContinueWatching",
                defaultValue: "Continue Watching"
            )
            sections.append(collection)
        }

        if !nextUpItems.isEmpty {
            let collection = TVTopShelfItemCollection(items: nextUpItems.map {
                makeItem(item: $0, session: session, barURL: bars[$0.id], artwork: artwork)
            })
            collection.title = String(
                localized: "TopShelf.NextUp",
                defaultValue: "Next Up"
            )
            sections.append(collection)
        }

        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }


    /// `barURL` is artwork with the resume bar already drawn in. When it exists the system's own
    /// `playbackProgress` stays unset, otherwise the shelf stacks two bars on the same cell.
    private func makeItem(item: TopShelfItem,
                          session: SharedSession,
                          barURL: URL?,
                          artwork: TopShelfArtwork.Choice) -> TVTopShelfSectionedItem {
        let cell = TVTopShelfSectionedItem(identifier: item.id)
        cell.title = item.topShelfTitle
        cell.imageShape = .hdtv
        // Both actions play. A shelf cell is an invitation to keep watching, not a link to a
        // page, and nobody guesses that the detail route hides behind Select while Play starts.
        let play = TVTopShelfAction(url: playLink(for: item))
        cell.displayAction = play
        cell.playAction = play
        if barURL == nil, let progress = item.topShelfProgress {
            cell.playbackProgress = progress
        }

        let remote = item.topShelfImageURL(baseURL: session.baseURL,
                                           token: session.accessToken,
                                           artwork: artwork)
        if let url = barURL ?? remote {
            // 2x is the only scale Apple TV renders; setting both 1x and 2x doubles the daemon's fetch work and trips memory pressure surfacing as "-17102 decompressing image" when cells race to decode.
            cell.setImageURL(url, for: .screenScale2x)
        } else {
            log.notice("cell \(item.id, privacy: .public) has no image URL")
        }
        return cell
    }

    /// `sodalite://play/{id}`: the main app's `onOpenURL` opens the item's detail route and starts playback on arrival. The app still understands `sodalite://item/{id}` (detail without playing), the shelf just has no use for it.
    private func playLink(for item: TopShelfItem) -> URL {
        URL(string: "sodalite://play/\(item.id)")!
    }

    /// Last good content, but only when it belongs to the session just read from the keychain.
    /// A cache from another server or profile is deleted rather than carried forward.
    private static func usableCache(session: SharedSession) -> TopShelfCache? {
        guard let stored = TopShelfCache.read() else { return nil }
        guard TopShelfCachePolicy.matches(cachedServerURL: stored.serverURL,
                                          cachedUserID: stored.userID,
                                          sessionServerURL: session.baseURL.absoluteString,
                                          sessionUserID: session.userID)
        else {
            TopShelfCachePolicy.delete()
            return nil
        }
        return stored
    }

    /// nil is a failed fetch, [] is a genuinely empty section; the cache fallback needs to tell them apart.
    private static func fetch(_ label: String, _ work: () async throws -> [TopShelfItem]) async -> [TopShelfItem]? {
        do {
            return try await work()
        } catch {
            log.error("\(label, privacy: .public) fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
