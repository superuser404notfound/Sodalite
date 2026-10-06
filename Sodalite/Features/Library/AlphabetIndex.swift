import Foundation

/// Letter logic behind the alphabet rail (Sodalite#86). Fixed `#` + A to Z, because the rail jumps
/// into the server's SortName order, which does not follow the device locale.
enum AlphabetIndex {
    static let letters: [String] = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)

    static let minimumTitles = 60

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

    static func showsRail(sortKey: LibrarySortKey, usesSparseGrid: Bool, total: Int) -> Bool {
        sortKey == .title && usesSparseGrid && total >= minimumTitles
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
