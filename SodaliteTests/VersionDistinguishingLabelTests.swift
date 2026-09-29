import Testing
import Foundation
@testable import Sodalite

/// Sodalite#172: the version pill names the version in force, and Jellyfin names merged versions
/// after their files. Those share their start, so the part that tells them apart is the part a tail
/// truncation cuts. The pill now carries only the words that differ.
struct VersionDistinguishingLabelTests {

    private func sources(_ entries: [(name: String?, width: Int?, codec: String?, size: Int64?)]) throws -> [MediaSource] {
        let json = entries.enumerated().map { i, e -> String in
            var fields = [#""Id":"s\#(i)""#]
            if let name = e.name {
                fields.append(#""Name":\#(String(decoding: try! JSONEncoder().encode(name), as: UTF8.self))"#)
            }
            if let size = e.size { fields.append(#""Size":\#(size)"#) }
            if let width = e.width, let codec = e.codec {
                fields.append(#""MediaStreams":[{"Index":0,"Type":"Video","Codec":"\#(codec)","Width":\#(width),"Height":\#(width * 9 / 16)}]"#)
            }
            return "{" + fields.joined(separator: ",") + "}"
        }
        return try JSONDecoder().decode([MediaSource].self, from: Data("[\(json.joined(separator: ","))]".utf8))
    }

    private func labels(_ names: [String?]) throws -> [String] {
        let all = try sources(names.map { ($0, 1920, "h264", nil) })
        return all.map { all.distinguishingLabel(for: $0) }
    }

    /// The issue's own example, the Merge Versions naming.
    @Test func dropsTheSharedTitleAndYear() throws {
        #expect(try labels([
            "Captain America The Winter Soldier (2014) - 2160p Remux",
            "Captain America The Winter Soldier (2014) - 1080p",
        ]) == ["2160p Remux", "1080p"])
    }

    /// Scene names share their tail too (the release group). A channel layout is one word, or the
    /// shared "1" of "7.1" and "5.1" would be dropped as tail and leave "TrueHD.7".
    @Test func dropsASharedTailAndKeepsTheNameAsWritten() throws {
        #expect(try labels([
            "Movie.2014.2160p.UHD.BluRay.TrueHD.7.1-GRP",
            "Movie.2014.1080p.BluRay.DD.5.1-GRP",
        ]) == ["2160p.UHD.BluRay.TrueHD.7.1", "1080p.BluRay.DD.5.1"])
    }

    /// Whole words only: "1080p" and "2160p" share no word, so neither loses its "p" or its "0".
    @Test func neverCutsInsideAWord() throws {
        #expect(try labels(["Film 1080p", "Film 2160p"]) == ["1080p", "2160p"])
    }

    /// A bracket whose partner was dropped with the shared words goes as well.
    @Test func dropsBracketsThatLostTheirPartner() throws {
        #expect(try labels(["Movie [4K] (HDR)", "Movie [1080p]"]) == ["4K HDR", "1080p"])
    }

    /// Three versions: what all of them share goes, what only two share stays.
    @Test func onlyWhatEveryVersionSharesIsDropped() throws {
        #expect(try labels(["Movie - 4K HDR", "Movie - 4K SDR", "Movie - 1080p"])
                == ["4K HDR", "4K SDR", "1080p"])
    }

    /// The item's own file often carries just the title; its alternate adds the variant. The one
    /// with nothing of its own left falls back to what sets it apart in the specs.
    @Test func aNameThatIsAllSharedWordsFallsBackToTheSpecs() throws {
        let all = try sources([
            ("Movie", 1920, "h264", nil),
            ("Movie - 4K", 3840, "hevc", nil),
        ])
        #expect(all.map { all.distinguishingLabel(for: $0) } == ["1080p · H264", "4K"])
    }

    /// Missing or identical names say nothing, so the specs that differ speak instead, and only
    /// those: a codec both versions share is not what tells them apart.
    @Test func missingOrIdenticalNamesFallBackToTheDifferingSpecs() throws {
        let missing = try sources([(nil, 3840, "hevc", 50_000_000_000), (nil, 1920, "hevc", 10_000_000_000)])
        let labels = missing.map { missing.distinguishingLabel(for: $0) }
        #expect(labels[0].hasPrefix("4K · ") && labels[1].hasPrefix("1080p · "))
        #expect(!labels[0].contains("HEVC"))

        let identical = try sources([("Movie", 3840, "hevc", nil), ("movie", 1920, "hevc", nil)])
        #expect(identical.map { identical.distinguishingLabel(for: $0) } == ["4K", "1080p"])
    }

    /// Two of three names identical: those two have no words of their own, whatever the third has.
    @Test func aNameSharedWithAnotherVersionIsNoLabel() throws {
        let all = try sources([
            ("Movie - Cut", 3840, "hevc", nil),
            ("Movie - Cut", 1920, "hevc", nil),
            ("Movie - Extended", 1920, "hevc", nil),
        ])
        #expect(all.map { all.distinguishingLabel(for: $0) } == ["4K", "1080p", "Extended"])
    }

    /// Nothing differs anywhere: the full label, which the button's ceiling still caps.
    @Test func nothingDifferingFallsBackToTheFullLabel() throws {
        let all = try sources([("Movie", 1920, "h264", nil), ("Movie", 1920, "h264", nil)])
        #expect(all.distinguishingLabel(for: all[0]) == all[0].versionLabel)
    }
}
