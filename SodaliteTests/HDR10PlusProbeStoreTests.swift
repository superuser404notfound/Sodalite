import Testing
import Foundation
@testable import Sodalite

/// AE#579, host side: HDR10+ rides an in-band ITU-T T.35 SEI that no demuxer parses, so a Jellyfin
/// scan that stops at the container reports plain HDR10 for a file that carries it. The engine can
/// answer the question without playing anything, and this store decides when that is worth a
/// connection.
@MainActor
struct HDR10PlusProbeStoreTests {

    // MARK: - Fixtures

    private static func item(
        id: String = "m1",
        type: String = "Movie",
        range: String? = "HDR10",
        dvProfile: Int? = nil,
        container: String? = "mkv",
        sourceIDs: [String] = ["src1"]
    ) throws -> JellyfinItem {
        var stream = [#""Index":0"#, #""Type":"Video""#, #""Width":3840"#, #""Height":2160"#]
        if let range { stream.append(#""VideoRangeType":"\#(range)""#) }
        if let dvProfile { stream.append(#""DvProfile":\#(dvProfile)"#) }
        let streams = "[{\(stream.joined(separator: ","))}]"

        var fields = [#""Id":"\#(id)""#, #""Name":"\#(id)""#, #""Type":"\#(type)""#,
                      #""Width":3840"#, #""Height":2160"#, #""MediaStreams":\#(streams)"#]
        if !sourceIDs.isEmpty {
            let sources = sourceIDs.map { sourceID -> String in
                var source = [#""Id":"\#(sourceID)""#, #""MediaStreams":\#(streams)"#]
                if let container { source.append(#""Container":"\#(container)""#) }
                return "{\(source.joined(separator: ","))}"
            }
            fields.append(#""MediaSources":[\#(sources.joined(separator: ","))]"#)
        }
        return try JSONDecoder().decode(JellyfinItem.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }


    private static func store(answer: Result<Bool, Error> = .success(true),
                              enabled: Bool = true) -> (HDR10PlusProbeStore, ProbeSpy) {
        let spy = ProbeSpy(answer: answer)
        let store = HDR10PlusProbeStore(
            streamURL: { item, sourceID, container in
                URL(string: "https://jf.example/Videos/\(item.id)/stream.\(container ?? "mp4")?MediaSourceId=\(sourceID)&Static=true")
            },
            isEnabled: { enabled },
            probe: { url, _ in try spy.probe(url) }
        )
        return (store, spy)
    }

    // MARK: - What is worth a connection

    @Test("a movie the server calls HDR10 is the one case worth probing")
    func probesPlainHDR10() throws {
        let item = try Self.item()
        #expect(HDR10PlusProbeStore.shouldProbe(item: item, sourceID: "src1"))
    }

    @Test("a server that already said HDR10+ is not asked again")
    func skipsDeclaredHDR10Plus() throws {
        let item = try Self.item(range: "HDR10Plus")
        #expect(!HDR10PlusProbeStore.shouldProbe(item: item, sourceID: "src1"))
    }

    @Test("Dolby Vision keeps its badge, a probe could only muddle it")
    func skipsDolbyVision() throws {
        let item = try Self.item(range: "DOVIWithHDR10", dvProfile: 8)
        #expect(!HDR10PlusProbeStore.shouldProbe(item: item, sourceID: "src1"))
    }

    @Test("SDR and HLG carry no HDR10 base layer to upgrade")
    func skipsNonHDR10() throws {
        #expect(!HDR10PlusProbeStore.shouldProbe(item: try Self.item(range: "SDR"), sourceID: "src1"))
        #expect(!HDR10PlusProbeStore.shouldProbe(item: try Self.item(range: "HLG"), sourceID: "src1"))
        #expect(!HDR10PlusProbeStore.shouldProbe(item: try Self.item(range: nil), sourceID: "src1"))
    }

    @Test("a series root has no file of its own, so there is nothing to open")
    func skipsSeriesRoot() throws {
        let item = try Self.item(type: "Series")
        #expect(!HDR10PlusProbeStore.shouldProbe(item: item, sourceID: "src1"))
    }

    @Test("an episode answers for itself and is probed like a movie")
    func probesEpisode() throws {
        let item = try Self.item(type: "Episode")
        #expect(HDR10PlusProbeStore.shouldProbe(item: item, sourceID: "src1"))
    }

    @Test("an item with no media source cannot be addressed")
    func skipsWithoutSource() throws {
        let item = try Self.item(sourceIDs: [])
        #expect(!HDR10PlusProbeStore.shouldProbe(item: item, sourceID: nil))
    }

    // MARK: - Asking, and asking once

    @Test("a confirmed probe lifts the page's badge from HDR10 to HDR10+")
    func confirmedUpgradesBadge() async throws {
        let (store, _) = Self.store(answer: .success(true))
        let item = try Self.item()
        #expect(!store.carriesHDR10Plus(item: item, sourceID: "src1"))

        await store.probeIfNeeded(item: item, sourceID: "src1")

        #expect(store.carriesHDR10Plus(item: item, sourceID: "src1"))
    }

    /// The trap this caught: `VersionSelection.preferredSourceID` returns nil for a title with ONE
    /// source, which is most of them, so the page reads with nil while the probe wrote under the
    /// resolved source id. Both sides have to resolve the same way.
    @Test("a single-source title, where the page has no version id to pass, is still recognised")
    func singleSourceTitleIsRecognised() async throws {
        let (store, spy) = Self.store()
        let item = try Self.item()

        await store.probeIfNeeded(item: item, sourceID: nil)

        #expect(spy.count == 1)
        #expect(store.carriesHDR10Plus(item: item, sourceID: nil))
    }

    @Test("the probe reads the version the page is showing, not the first source")
    func probesTheShownVersion() async throws {
        let (store, spy) = Self.store()
        let item = try Self.item()

        await store.probeIfNeeded(item: item, sourceID: "src1")

        #expect(spy.count == 1)
        let url = try #require(spy.urls.first)
        #expect(url.absoluteString.contains("MediaSourceId=src1"))
        #expect(url.absoluteString.contains("Static=true"))
        #expect(url.absoluteString.contains("stream.mkv"))
    }

    @Test("a second visit to the page reads the answer instead of opening the file again")
    func asksOnlyOnce() async throws {
        let (store, spy) = Self.store()
        let item = try Self.item()

        await store.probeIfNeeded(item: item, sourceID: "src1")
        await store.probeIfNeeded(item: item, sourceID: "src1")

        #expect(spy.count == 1)
    }

    @Test("a negative is an answer too and is not retried")
    func negativeIsRemembered() async throws {
        let (store, spy) = Self.store(answer: .success(false))
        let item = try Self.item()

        await store.probeIfNeeded(item: item, sourceID: "src1")
        await store.probeIfNeeded(item: item, sourceID: "src1")

        #expect(spy.count == 1)
        #expect(!store.carriesHDR10Plus(item: item, sourceID: "src1"))
    }

    @Test("a probe that fails leaves the badge alone and does not loop on the next visit")
    func failureIsRemembered() async throws {
        let (store, spy) = Self.store(answer: .failure(ProbeFailure()))
        let item = try Self.item()

        await store.probeIfNeeded(item: item, sourceID: "src1")
        await store.probeIfNeeded(item: item, sourceID: "src1")

        #expect(spy.count == 1)
        #expect(!store.carriesHDR10Plus(item: item, sourceID: "src1"))
    }

    @Test("two versions of one title are two questions")
    func versionsAreSeparate() async throws {
        let (store, spy) = Self.store()
        let item = try Self.item(sourceIDs: ["src1", "src2"])

        await store.probeIfNeeded(item: item, sourceID: "src1")
        await store.probeIfNeeded(item: item, sourceID: "src2")

        #expect(spy.count == 2)
    }

    @Test("with the detail pills turned off nothing is opened")
    func disabledProbesNothing() async throws {
        let (store, spy) = Self.store(enabled: false)
        let item = try Self.item()

        await store.probeIfNeeded(item: item, sourceID: "src1")

        #expect(spy.count == 0)
    }

    // MARK: - What the row does with it

    @Test("the upgrade only ever touches an HDR10 badge")
    func upgradeIsOneDirectional() {
        let hdr10 = MediaBadges(resolution: .uhd, dynamicRange: .hdr10, audio: nil, audioCodec: nil)
        #expect(hdr10.upgradedToHDR10Plus().dynamicRange == .hdr10Plus)

        let dv = MediaBadges(resolution: .uhd, dynamicRange: .dolbyVision, audio: nil, audioCodec: nil)
        #expect(dv.upgradedToHDR10Plus().dynamicRange == .dolbyVision)

        let sdr = MediaBadges(resolution: .uhd, dynamicRange: nil, audio: nil, audioCodec: nil)
        #expect(sdr.upgradedToHDR10Plus().dynamicRange == nil)
    }

    @Test("a confirmed item prints HDR10+ in the detail row")
    func rowPrintsUpgradedPill() throws {
        let item = try Self.item()
        let plain = FormatBadgeRow.pills(for: item, sourceID: "src1", enabled: true, carriesHDR10Plus: false)
        let upgraded = FormatBadgeRow.pills(for: item, sourceID: "src1", enabled: true, carriesHDR10Plus: true)

        #expect(plain.contains("HDR10"))
        #expect(!plain.contains("HDR10+"))
        #expect(upgraded.contains("HDR10+"))
    }
}

/// Counts calls and answers whatever the test asked for, so nothing here opens a socket.
private nonisolated final class ProbeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    private let answer: Result<Bool, Error>

    init(answer: Result<Bool, Error>) { self.answer = answer }

    var urls: [URL] { lock.withLock { _urls } }
    var count: Int { urls.count }

    func probe(_ url: URL) throws -> Bool {
        lock.withLock { _urls.append(url) }
        return try answer.get()
    }
}

private struct ProbeFailure: Error {}
