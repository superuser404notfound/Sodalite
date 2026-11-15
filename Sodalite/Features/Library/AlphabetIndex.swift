import Foundation

/// Letter logic behind the alphabet rail (Sodalite#86). Fixed `#` + A to Z, because the rail jumps
/// into the server's SortName order, which does not follow the device locale.
enum AlphabetIndex {
    static let letters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)

    static func railLetters(descending: Bool) -> [String] {
        descending ? letters.reversed() : letters
    }

    static func letter(for sortName: String) -> String {
        let folded = sortName.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard let first = folded.unicodeScalars.first, ("a"..."z").contains(first) else { return "#" }
        return String(first).uppercased()
    }

    /// The query whose `TotalRecordCount` is the first slot of `letter`; nil when that slot is 0.
    /// Jellyfin 12 compares against the lowercased, diacritic-folded SortName, case-insensitively.
    static func countQuery(for letter: String, base: ItemQuery, descending: Bool) -> ItemQuery? {
        var query = base
        query.limit = 0
        query.startIndex = nil
        query.fields = ""
        if descending {
            query.nameStartsWithOrGreater = queryValue(after: letter)
        } else {
            guard letter != "#" else { return nil }
            query.nameLessThan = letter.lowercased()
        }
        return query
    }

    /// Every library sorted by title gets the rail, small or combined (Sodalite#240). It used to
    /// need 60 titles and a single server, so the same kind of library had a rail on one server
    /// and none on the other.
    static func showsRail(sortKey: LibrarySortKey, total: Int) -> Bool {
        sortKey == .title && total > 0
    }

    /// The first loaded title at or past `letter` in rail order, for grids that hold their items
    /// in memory (combined servers, smart providers). Those cannot ask the server for a count:
    /// a combined grid drops a film the second server also has, so a server's count is not a
    /// position in it.
    static func firstPosition(of letter: String, in sortNames: [String], descending: Bool) -> Int? {
        guard let target = letters.firstIndex(of: letter) else { return nil }
        return sortNames.firstIndex { name in
            let rank = letters.firstIndex(of: self.letter(for: name)) ?? 0
            return descending ? rank <= target : rank >= target
        }
    }

    /// Descending puts a letter after every title at or past the NEXT letter; `{` follows `z`, and
    /// `#` (digits, symbols) sorts below `a`.
    private static func queryValue(after letter: String) -> String {
        guard letter != "#" else { return "a" }
        guard letter != "Z", let scalar = letter.lowercased().unicodeScalars.first,
              let next = Unicode.Scalar(scalar.value + 1) else { return "{" }
        return String(Character(next))
    }
}

/// Runs and remembers the count queries; the cache lives until the grid's filter or sort changes.
@MainActor
final class AlphabetJumpResolver {
    typealias Count = @MainActor @Sendable (ItemQuery) async throws -> Int

    private let count: Count
    private var cache: [String: Int] = [:]

    init(count: @escaping Count) {
        self.count = count
    }

    func reset() {
        cache = [:]
    }

    private static func key(_ letter: String, _ descending: Bool) -> String {
        "\(descending ? "d" : "a")\(letter)"
    }

    /// A slot known without a request, so a commit can act before the focus engine's own move.
    func cachedSlot(for letter: String, descending: Bool) -> Int? {
        if !descending, letter == "#" { return 0 }
        return cache[Self.key(letter, descending)]
    }

    func slot(for letter: String, base: ItemQuery, descending: Bool) async -> Int? {
        let key = Self.key(letter, descending)
        if let cached = cache[key] { return cached }
        guard let query = AlphabetIndex.countQuery(for: letter, base: base, descending: descending) else {
            return 0
        }
        guard !Task.isCancelled, let result = try? await count(query), !Task.isCancelled else { return nil }
        cache[key] = result
        return result
    }
}
