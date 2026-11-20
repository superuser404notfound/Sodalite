import Foundation

extension Array where Element == MediaSource {
    /// The part of `source`'s name that tells it apart from the other versions (Sodalite#172).
    ///
    /// Jellyfin names merged versions after their files, and files of one film share their start
    /// (title, year) and often their end (release group). The part that differs sits in between,
    /// which is exactly the part a tail truncation cuts, so the version pill showed the same text for
    /// every version. Whole words, never characters, so a label cannot read "080p".
    ///
    /// Falls back to the specs that differ between the versions when the names say nothing (missing
    /// or identical), and to the full `versionLabel` when those do not differ either.
    func distinguishingLabel(for source: MediaSource) -> String {
        let named = map { VersionNameWords($0.name) }
        let own = VersionNameWords(source.name)
        let sharesItsName = zip(self, named).contains { other, words in
            other.id != source.id && words.matches(own)
        }
        if !sharesItsName, let tail = own.slice(
            droppingLeading: VersionNameWords.commonPrefixLength(named),
            trailing: VersionNameWords.commonSuffixLength(named)
        ) {
            return tail
        }

        let specs: [(MediaSource) -> String?] = [\.resolutionLabel, \.codecLabel, \.sizeLabel]
        let differing = specs.compactMap { spec -> String? in
            guard Set(map(spec)).count > 1 else { return nil }
            return spec(source)
        }
        return differing.isEmpty ? source.versionLabel : differing.joined(separator: " · ")
    }
}

/// A source name as the words it is made of, each kept as its range in the original string so the
/// label can be cut from the name as written (a "7.1" stays "7.1").
private struct VersionNameWords {
    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".-_()[]{}"))
    private static let brackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    let text: String
    let ranges: [Range<String.Index>]

    init(_ name: String?) {
        text = name ?? ""
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            let isSeparator = text[index].unicodeScalars.allSatisfy { Self.separators.contains($0) }
                && !Self.isDecimalPoint(at: index, in: text)
            if isSeparator {
                if let s = start { ranges.append(s..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        self.ranges = ranges
    }

    /// A dot between two single digits is a channel layout, not a word break: "7.1" against "5.1"
    /// is one difference, where splitting it would keep the shared "1" and leave "TrueHD.7" behind.
    /// Single digits only, so a scene name's "2014.2160p" still splits into year and resolution.
    private static func isDecimalPoint(at index: String.Index, in text: String) -> Bool {
        guard text[index] == ".", index > text.startIndex else { return false }
        let before = text[..<index].reversed().prefix { $0.isNumber }.count
        let after = text[text.index(after: index)...].prefix { $0.isNumber }.count
        return before == 1 && after == 1
    }

    private func word(_ i: Int) -> Substring { text[ranges[i]] }

    private static func same(_ a: Substring, _ b: Substring) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    func matches(_ other: VersionNameWords) -> Bool {
        ranges.count == other.ranges.count
            && ranges.indices.allSatisfy { Self.same(word($0), other.word($0)) }
    }

    static func commonPrefixLength(_ all: [VersionNameWords]) -> Int {
        guard let first = all.first else { return 0 }
        let limit = all.map(\.ranges.count).min() ?? 0
        var n = 0
        while n < limit, all.allSatisfy({ same($0.word(n), first.word(n)) }) { n += 1 }
        return n
    }

    /// Stops where it would reach into a name's shared prefix, so a name that is all shared words
    /// (the item's own "Movie" beside "Movie - 4K") is not counted twice.
    static func commonSuffixLength(_ all: [VersionNameWords]) -> Int {
        guard let first = all.first else { return 0 }
        let prefix = commonPrefixLength(all)
        let limit = all.map { $0.ranges.count - prefix }.min() ?? 0
        var n = 0
        while n < limit, all.allSatisfy({
            same($0.word($0.ranges.count - 1 - n), first.word(first.ranges.count - 1 - n))
        }) { n += 1 }
        return n
    }

    /// The name between the dropped words, as written. Brackets whose partner was dropped go too,
    /// so "Movie [4K] (HDR)" against "Movie [1080p]" reads "4K HDR", not "4K] (HDR".
    func slice(droppingLeading leading: Int, trailing: Int) -> String? {
        let last = ranges.count - 1 - trailing
        guard leading <= last else { return nil }
        let cut = text[ranges[leading].lowerBound..<ranges[last].upperBound]

        var unmatched = Set<Int>()
        var open: [(Character, Int)] = []
        for (offset, char) in cut.enumerated() {
            if "([{".contains(char) {
                open.append((char, offset))
            } else if let opener = Self.brackets[char] {
                if open.last?.0 == opener { open.removeLast() } else { unmatched.insert(offset) }
            }
        }
        unmatched.formUnion(open.map(\.1))

        let kept = String(cut.enumerated().filter { !unmatched.contains($0.offset) }.map(\.element))
        let label = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return label.isEmpty ? nil : label
    }
}
