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
        return CacheIdentity(serverID: "combined-" + String(hash, radix: 16), userID: userID)
    }

    private enum SourceOutcome: Sendable {
        case row(HomeRowData?)
        case failed(unauthorized: Bool)
        case timedOut
    }

    /// One row from every source, in source order, leaving out the ones that failed or missed the
    /// deadline. The active source has no deadline: its row is the one Home waited for before.
    func fetchAcrossSources(_ config: HomeRowConfig) async -> [HomeRowData] {
        let candidates = config.type == .libraryLatest ? await owningSources(for: config) : sources
        if candidates.count == 1, let only = candidates.first, only.isActive {
            return (try? await loadRow(config: config, source: only)).flatMap { $0 }.map { [$0] } ?? []
        }
        let deadline = secondaryDeadline
        let outcomes = await withTaskGroup(of: (Int, SourceOutcome).self, returning: [Int: SourceOutcome].self) { group in
            for (index, source) in candidates.enumerated() {
                group.addTask(priority: source.isActive ? nil : .utility) { [weak self] in
                    guard let self else { return (index, .timedOut) }
                    return (index, await self.outcome(config: config, source: source, deadline: source.isActive ? nil : deadline))
                }
            }
            var collected: [Int: SourceOutcome] = [:]
            for await (index, outcome) in group { collected[index] = outcome }
            return collected
        }
        var rows: [HomeRowData] = []
        for (index, source) in candidates.enumerated() {
            switch outcomes[index] {
            case .row(let row?):
                rows.append(row)
            case .row(nil):
                break
            case .failed(unauthorized: true) where !source.isActive:
                onUnauthorized?(source.serverID)
            case .failed, .timedOut, .none:
                if !source.isActive, !pendingUnreachable.contains(source.serverName) {
                    pendingUnreachable.append(source.serverName)
                }
            }
        }
        return rows
    }

    private func outcome(config: HomeRowConfig, source: HomeSource, deadline: Duration?) async -> SourceOutcome {
        let work: @MainActor () async -> SourceOutcome = { [weak self] in
            guard let self else { return .timedOut }
            do {
                return .row(try await self.loadRow(config: config, source: source))
            } catch let error as APIError {
                if case .unauthorized = error { return .failed(unauthorized: true) }
                return .failed(unauthorized: false)
            } catch {
                return .failed(unauthorized: false)
            }
        }
        guard let deadline else { return await work() }
        return await withTaskGroup(of: SourceOutcome.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// A per-library row is fetched from the server that owns the library, nobody else.
    private func owningSources(for config: HomeRowConfig) async -> [HomeSource] {
        guard let libraryID = config.libraryID else { return [sources[0]] }
        for source in sources {
            let task = librariesTasks[source.serverID]
            let libraries = source.isActive
                ? await task?.value ?? nil
                : await withDeadline(secondaryDeadline) { await task?.value ?? nil } ?? nil
            if libraries?.contains(where: { $0.id == libraryID }) == true { return [source] }
        }
        if let owner = myMediaLibraries.first(where: { $0.id == libraryID })?.serverID,
           let source = sources.first(where: { $0.serverID == owner }) {
            return [source]
        }
        return [sources[0]]
    }

    /// Every source's libraries, active first, each stamped with its server. nil when the active
    /// server's own list failed, which keeps today's "stored config stands" fallback.
    func combinedLibraries() async -> [JellyfinLibrary]? {
        var combined: [JellyfinLibrary] = []
        for source in sources {
            let task = librariesTasks[source.serverID]
            let fetched: [JellyfinLibrary]?
            if source.isActive {
                fetched = await task?.value ?? nil
                guard fetched != nil else { return nil }
            } else {
                fetched = await withDeadline(secondaryDeadline) { await task?.value ?? nil } ?? nil
            }
            combined += (fetched ?? []).map { library in
                var stamped = library
                if stamped.serverID == nil { stamped.serverID = source.serverID }
                return stamped
            }
        }
        return combined
    }

    private func withDeadline<T: Sendable>(_ deadline: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
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
        guard sources.count > 1 else { return nil }
        let clashes = myMediaLibraries.filter { $0.name.caseInsensitiveCompare(library.name) == .orderedSame }.count > 1
        guard clashes else { return nil }
        let owner = library.serverID ?? sources[0].serverID
        return sources.first { $0.serverID == owner }?.serverName
    }

    func serverLabel(forRow row: HomeRowData) -> String? {
        guard let libraryID = row.libraryID,
              let library = myMediaLibraries.first(where: { $0.id == libraryID }) else { return nil }
        return serverLabel(forLibrary: library)
    }
}
