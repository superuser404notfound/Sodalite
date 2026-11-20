import Foundation

/// The library list Home Customize orders and Home reconciles its rows against: every
/// participant's My Media libraries, active first (Sodalite#85). nil when the active server
/// fails; `complete` false when a secondary did not answer in time, which must never reach
/// `HomeRowConfig.reconciled`. Both screens go through `fetch`, so they cannot disagree (BRW-R201).
enum CustomizeLibraryList {
    typealias Listing = (libraries: [JellyfinLibrary], complete: Bool, unreachable: [String])

    static func fetch(
        _ sources: [HomeSource],
        secondaryDeadline: Duration,
        load: @escaping @MainActor @Sendable (HomeSource) async -> [JellyfinLibrary]? = { source in
            try? await source.libraryService.getLibraries(userID: source.userID)
        }
    ) async -> Listing? {
        let outcomes = await SourceFanOut.collect(sources, deadline: secondaryDeadline) { await load($0) }
        var combined: [JellyfinLibrary] = []
        var unreachable: [String] = []
        for (source, outcome) in zip(sources, outcomes) {
            guard case .value(let list?) = outcome else {
                if source.isActive { return nil }
                unreachable.append(source.serverName)
                continue
            }
            combined += list.map { library in
                var stamped = library
                if stamped.serverID == nil { stamped.serverID = source.serverID }
                return stamped
            }
        }
        return (combined, unreachable.isEmpty, unreachable)
    }

    static func serverLabel(for library: JellyfinLibrary, in libraries: [JellyfinLibrary], sources: [HomeSource]) -> String? {
        guard sources.count > 1 else { return nil }
        let clashes = libraries.filter { $0.name.caseInsensitiveCompare(library.name) == .orderedSame }.count > 1
        guard clashes else { return nil }
        let owner = library.serverID ?? sources[0].serverID
        return sources.first { $0.serverID == owner }?.serverName
    }
}
