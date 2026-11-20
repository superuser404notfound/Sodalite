import Foundation

extension HomeViewModel {
    /// The cache slot of a combined Home: one per set of (server, user) pairs, so the same set
    /// paints at once whichever server is active, and a different set never sees it (Sodalite#85).
    static func combinedIdentity(for sources: [HomeSource], userID: String) -> CacheIdentity {
        let members = sources.map { "\($0.serverID):\($0.userID)" }.sorted().joined(separator: ",")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in members.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // The pairs already name every user, so the slot does not depend on which one is active.
        return CacheIdentity(serverID: "combined-" + String(hash, radix: 16), userID: "combined")
    }

    /// One row from every source, in source order, leaving out the ones that failed or missed the
    /// deadline. The active source has no deadline: its row is the one Home waited for before.
    func fetchAcrossSources(_ config: HomeRowConfig) async -> [HomeRowData] {
        let candidates = config.type == .libraryLatest ? await owningSources(for: config) : sources
        if candidates.count == 1, let only = candidates.first, only.isActive {
            return (try? await loadRow(config: config, source: only)).flatMap { $0 }.map { [$0] } ?? []
        }
        let generation = loadGeneration
        let outcomes = await SourceFanOut.collect(candidates, deadline: secondaryDeadline) { @MainActor [weak self] source in
            guard let self else { throw CancellationError() }
            return try await self.loadRow(config: config, source: source)
        }
        // A superseded load's timeouts belong to nobody (BRW-205).
        let current = !Task.isCancelled && loadGeneration == generation
        var rows: [HomeRowData] = []
        for (source, outcome) in zip(candidates, outcomes) {
            switch outcome {
            case .value(let row?):
                rows.append(row)
            case .value(nil):
                break
            case .failed(unauthorized: true) where !source.isActive:
                if current { onUnauthorized?(source.serverID) }
            case .failed, .timedOut:
                if current, !source.isActive, !pendingUnreachable.contains(source.serverName) {
                    pendingUnreachable.append(source.serverName)
                }
            }
        }
        return rows
    }

    /// A per-library row is fetched from the servers that hold the library, nobody else. Jellyfin
    /// derives a folder id from its path, so two servers with the same layout can share one; their
    /// row then merges like any other.
    private func owningSources(for config: HomeRowConfig) async -> [HomeSource] {
        guard sources.count > 1, let libraryID = config.libraryID else { return sources }
        let deadline = secondaryDeadline
        var owners: [HomeSource] = []
        for source in sources {
            guard let task = librariesTasks[source.serverID] else { continue }
            let libraries = source.isActive
                ? await task.value
                : await Deadline.race(deadline) { await task.value } ?? nil
            if libraries?.contains(where: { $0.id == libraryID }) == true { owners.append(source) }
        }
        if owners.isEmpty {
            let known = Set(myMediaLibraries.filter { $0.id == libraryID }.compactMap(\.serverID))
            owners = sources.filter { known.contains($0.serverID) }
        }
        let contributing = libraryLayout.contributingServers(owners.map(\.serverID), libraryID: libraryID)
        owners = owners.filter { contributing.contains($0.serverID) }
        return owners.isEmpty ? [sources[0]] : owners
    }

    /// Every source's libraries, active first, each stamped with its server. nil when the active
    /// server's own list failed, which keeps today's "stored config stands" fallback. `complete`
    /// is false when a secondary did not answer in time, and an incomplete list must not be used
    /// to retire that server's per-library rows.
    func combinedLibraries() async -> (libraries: [JellyfinLibrary], complete: Bool)? {
        let generation = loadGeneration
        let tasks = librariesTasks
        let listing = await CustomizeLibraryList.fetch(sources, secondaryDeadline: secondaryDeadline) { source in
            guard let task = tasks[source.serverID] else { return nil }
            return await task.value
        }
        guard let listing else { return nil }
        if !Task.isCancelled, loadGeneration == generation {
            for name in listing.unreachable where !pendingUnreachable.contains(name) { pendingUnreachable.append(name) }
        }
        return (listing.libraries, listing.complete)
    }

    /// The participant set changed: repaint from that set's own cached feed, then fetch.
    func updateSources(_ newSources: [HomeSource]) async {
        guard !newSources.isEmpty else { return }
        sources = newSources
        await reloadAfterServerSwitch()
    }
}

extension HomeViewModel {
    /// The server name a library tile or row carries when another participating server has a
    /// library of the same name; nil otherwise, so a single server never shows one.
    func serverLabel(forLibrary library: JellyfinLibrary) -> String? {
        CustomizeLibraryList.serverLabel(for: library, in: myMediaLibraries, sources: sources)
    }

    /// Collections and playlists are not deduped, so a same-name pair from two servers needs telling apart.
    func serverLabel(forItem item: JellyfinItem, in row: HomeRowData) -> String? {
        guard sources.count > 1, row.type == .collections || row.type == .playlists,
              ServerLabels.clashingItems(row.items).contains(item.originKey) else { return nil }
        return sources.first { $0.serverID == (item.serverID ?? sources[0].serverID) }?.serverName
    }

    func serverLabel(forRow row: HomeRowData) -> String? {
        guard let libraryID = row.libraryID else { return nil }
        let matches = myMediaLibraries.filter { $0.id == libraryID }
        // One id on two servers is one merged row, which belongs to neither.
        guard matches.count == 1, let library = matches.first else { return nil }
        return serverLabel(forLibrary: library)
    }
}

extension HomeViewModel {
    /// Only sources for the identity this view model was built for. A registry revision fires
    /// before AppState follows a switch, and the outgoing Home must not fetch the incoming
    /// session into its own cache slot.
    func acceptsSources(_ newSources: [HomeSource]) -> Bool {
        guard let active = newSources.first else { return false }
        return active.serverID == serverID && active.userID == userID
    }

    /// The cache slot of a library grid opened from My Media: the library's own server and the
    /// user who reads it there.
    func gridIdentity(forLibrary library: JellyfinLibrary) -> CacheIdentity {
        guard let owner = library.serverID,
              let source = sources.first(where: { $0.serverID == owner }), !source.isActive
        else { return cacheIdentity }
        return CacheIdentity(serverID: source.serverID, userID: source.userID)
    }
}

