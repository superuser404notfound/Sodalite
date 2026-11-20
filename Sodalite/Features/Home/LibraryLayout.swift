import Foundation

/// The profile's order and hidden flags for the My Media tiles, one entry per library on each
/// server (Sodalite#85). Libraries without an entry follow the known ones, visible, in server order.
nonisolated struct LibraryLayout: Codable, Equatable {
    struct Entry: Codable, Equatable, Hashable {
        let serverID: String
        let libraryID: String
        var isHidden: Bool
    }

    var entries: [Entry]

    private static func owner(_ library: JellyfinLibrary, _ fallback: String) -> String {
        library.serverID ?? fallback
    }

    private func index(of library: JellyfinLibrary, _ fallback: String) -> Int? {
        let server = Self.owner(library, fallback)
        return entries.firstIndex { $0.serverID == server && $0.libraryID == library.id }
    }

    func ordered(_ libraries: [JellyfinLibrary], fallbackServerID: String) -> [JellyfinLibrary] {
        let known = libraries.enumerated().compactMap { offset, library in
            index(of: library, fallbackServerID).map { (position: $0, library: library) }
        }.sorted { $0.position < $1.position }.map(\.library)
        let unknown = libraries.filter { index(of: $0, fallbackServerID) == nil }
        return known + unknown
    }

    func isHidden(_ library: JellyfinLibrary, fallbackServerID: String) -> Bool {
        index(of: library, fallbackServerID).map { entries[$0].isHidden } ?? false
    }

    func visible(_ libraries: [JellyfinLibrary], fallbackServerID: String) -> [JellyfinLibrary] {
        ordered(libraries, fallbackServerID: fallbackServerID).filter { !isHidden($0, fallbackServerID: fallbackServerID) }
    }

    /// Writes every listed library into the layout in its current order, keeping entries of
    /// libraries that are not listed right now (a server that did not answer in time).
    private func materialized(_ libraries: [JellyfinLibrary], _ fallback: String) -> LibraryLayout {
        var result = self
        for library in ordered(libraries, fallbackServerID: fallback) where result.index(of: library, fallback) == nil {
            result.entries.append(Entry(serverID: Self.owner(library, fallback), libraryID: library.id, isHidden: false))
        }
        return result
    }

    func toggling(_ library: JellyfinLibrary, in libraries: [JellyfinLibrary], fallbackServerID: String) -> LibraryLayout {
        var result = materialized(libraries, fallbackServerID)
        if let i = result.index(of: library, fallbackServerID) { result.entries[i].isHidden.toggle() }
        return result
    }

    func moving(
        _ library: JellyfinLibrary, toIndexAmongVisible target: Int, in libraries: [JellyfinLibrary], fallbackServerID: String
    ) -> LibraryLayout {
        var result = materialized(libraries, fallbackServerID)
        guard let from = result.index(of: library, fallbackServerID) else { return result }
        let moved = result.entries.remove(at: from)
        let visibleNow = result.visible(libraries, fallbackServerID: fallbackServerID)
        if target < visibleNow.count, let anchor = result.index(of: visibleNow[target], fallbackServerID) {
            result.entries.insert(moved, at: anchor)
        } else if let last = visibleNow.last, let anchor = result.index(of: last, fallbackServerID) {
            result.entries.insert(moved, at: anchor + 1)
        } else {
            result.entries.append(moved)
        }
        return result
    }

    /// A "Latest in X" row goes only while every copy of its library is hidden: one id on two
    /// servers is one merged row.
    /// The servers whose copy of a shared library still feeds its row: a hidden copy does not.
    func contributingServers(_ serverIDs: [String], libraryID: String) -> [String] {
        serverIDs.filter { id in !entries.contains { $0.serverID == id && $0.libraryID == libraryID && $0.isHidden } }
    }

    func hidesLatestRow(libraryID: String) -> Bool {
        let copies = entries.filter { $0.libraryID == libraryID }
        return !copies.isEmpty && copies.allSatisfy(\.isHidden)
    }
}

extension LibraryLayout {
    private static func key(_ scope: String) -> String { "homeLibraryLayout.\(scope)" }

    static func load(scope: String, defaults: UserDefaults = .standard) -> LibraryLayout {
        guard let data = rawData(scope: scope, defaults: defaults),
              let layout = try? JSONDecoder().decode(LibraryLayout.self, from: data) else { return LibraryLayout(entries: []) }
        return layout
    }

    func save(scope: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.setRawData(data, scope: scope, defaults: defaults)
    }

    static func rawData(scope: String, defaults: UserDefaults = .standard) -> Data? { defaults.data(forKey: key(scope)) }

    static func setRawData(_ data: Data, scope: String, defaults: UserDefaults = .standard) {
        defaults.set(data, forKey: key(scope))
    }

    static func clear(scope: String, defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key(scope)) }

    /// Back to server order with nothing hidden. Stored as an empty layout rather than removed, so the
    /// profile's home record carries the reset to its other devices instead of reading as "no layout".
    static func reset(scope: String, defaults: UserDefaults = .standard) {
        LibraryLayout(entries: []).save(scope: scope, defaults: defaults)
    }
}

enum ServerLabels {
    /// Items whose name another server in the same list also uses; those carry their server's name.
    static func clashingItems(_ items: [JellyfinItem]) -> Set<String> {
        let groups = Dictionary(grouping: items) { $0.name.lowercased() }
        return Set(groups.values.filter { Set($0.map { $0.serverID ?? "" }).count > 1 }.flatMap { $0.map(\.originKey) })
    }
}
