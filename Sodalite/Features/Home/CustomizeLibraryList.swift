import Foundation

/// The library list Home anpassen orders: every participant's My Media libraries, active first
/// (Sodalite#85). nil when the active server fails; `complete` false when a secondary did not
/// answer in time, which must never reach `HomeRowConfig.reconciled`.
enum CustomizeLibraryList {
    static func fetch(_ sources: [HomeSource], secondaryDeadline: Duration) async -> (libraries: [JellyfinLibrary], complete: Bool)? {
        var lists: [[JellyfinLibrary]?] = Array(repeating: nil, count: sources.count)
        await withTaskGroup(of: (Int, [JellyfinLibrary]?).self) { group in
            for (index, source) in sources.enumerated() {
                let service = source.libraryService
                let user = source.userID
                let isActive = source.isActive
                group.addTask {
                    let work: @Sendable () async -> [JellyfinLibrary]? = { try? await service.getLibraries(userID: user) }
                    return (index, isActive ? await work() : await Deadline.race(secondaryDeadline, work) ?? nil)
                }
            }
            for await (index, list) in group { lists[index] = list }
        }
        var combined: [JellyfinLibrary] = []
        var complete = true
        for (index, source) in sources.enumerated() {
            guard let list = lists[index] else {
                if source.isActive { return nil }
                complete = false
                continue
            }
            combined += list.map { library in
                var stamped = library
                if stamped.serverID == nil { stamped.serverID = source.serverID }
                return stamped
            }
        }
        return (combined, complete)
    }

    static func serverLabel(for library: JellyfinLibrary, in libraries: [JellyfinLibrary], sources: [HomeSource]) -> String? {
        guard sources.count > 1 else { return nil }
        let clashes = libraries.filter { $0.name.caseInsensitiveCompare(library.name) == .orderedSame }.count > 1
        guard clashes else { return nil }
        let owner = library.serverID ?? sources[0].serverID
        return sources.first { $0.serverID == owner }?.serverName
    }
}
