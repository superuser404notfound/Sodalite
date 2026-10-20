import Foundation
import Testing
import AetherEngine
@testable import Sodalite

/// The transport-bar chip label. A live channel is the case that pushed on this: broadcasters
/// routinely leave the audio stream untagged, and the container's own name for such a track reads
/// "Track 0 (aac)", which says nothing a viewer wants on a chip.
@Suite("Track chip label")
struct TrackDisplayFormatterTests {
    private func audio(language: String?, codec: String = "aac", channels: Int = 2,
                       name: String = "Track 0 (aac)", isAtmos: Bool = false) -> TrackInfo {
        TrackInfo(id: 0, name: name, codec: codec, language: language,
                  channels: channels, isDefault: true, isAtmos: isAtmos)
    }

    @Test("a tagged track shows its language, which is what the viewer picks by")
    func languageWins() {
        // Derived, not spelled: the label is the viewer's language name for the code, so a literal
        // here would only assert the locale the test happened to run in.
        let expected = Locale.current.localizedString(forLanguageCode: "de").map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        }
        #expect(TrackDisplayFormatter.shortName(for: audio(language: "de")) == expected)
    }

    @Test("an untagged track falls back to the format, not to the container's track name")
    func untaggedFallsBackToFormat() {
        let label = TrackDisplayFormatter.shortName(for: audio(language: nil))
        #expect(label != "Track 0 (aac)")
        #expect(label.contains("AAC"))
    }

    @Test("an empty language string counts as untagged")
    func emptyLanguageIsUntagged() {
        #expect(TrackDisplayFormatter.shortName(for: audio(language: "")).contains("AAC"))
    }

    @Test("und is the container saying it does not know, not a language to name")
    func undeterminedIsUntagged() {
        // Locale renders "und" as "Unknown language", which reads like a language on the chip and
        // is what a live channel would have shown, since broadcasters tag their streams that way.
        for code in ["und", "UND", "unknown"] {
            #expect(TrackDisplayFormatter.shortName(for: audio(language: code)).contains("AAC"),
                    "\(code) must not resolve to a language name")
        }
    }

    @Test("und drops out of the menu row too, leaving the format alone")
    func undeterminedInMenuRow() {
        let name = TrackDisplayFormatter.audioDisplayName(for: audio(language: "und"))
        #expect(name.contains("AAC"))
        #expect(name.contains("·") == false)
    }

    @Test("Atmos names itself rather than its bed layout")
    func atmosOverridesLayout() {
        let track = audio(language: nil, codec: "eac3", channels: 6, isAtmos: true)
        #expect(TrackDisplayFormatter.shortName(for: track) == "Dolby Atmos")
    }

    /// AetherEngine#731: TrueHD Atmos is the track that keeps its heights, so the menu has to say which
    /// of a film's TrueHD tracks it is. `isAtmos` answers for E-AC-3 JOC only; the profile tells TrueHD.
    @Test("TrueHD Atmos names itself, plain TrueHD keeps its layout")
    func trueHDAtmosNamesItself() {
        let atmos = TrackInfo(id: 1, name: "Track 1 (truehd)", codec: "truehd", language: nil, channels: 8,
                              isDefault: true, profile: "Dolby TrueHD + Dolby Atmos")
        #expect(TrackDisplayFormatter.shortName(for: atmos) == "Dolby TrueHD Atmos")
        #expect(TrackDisplayFormatter.audioDisplayName(for: atmos) == "Dolby TrueHD Atmos")
        let plain = TrackInfo(id: 2, name: "Track 2 (truehd)", codec: "truehd", language: nil, channels: 8,
                              isDefault: false, profile: nil)
        #expect(!TrackDisplayFormatter.isTrueHDAtmos(plain))
        #expect(TrackDisplayFormatter.audioDisplayName(for: plain) != "Dolby TrueHD Atmos")
    }

    /// AetherEngine#744: DTS:X keeps its heights like TrueHD Atmos. libavcodec's decoder is `dca`,
    /// which the menu used to print as "DCA 7.1".
    @Test("DTS:X names itself, the rest of the DTS family names its member")
    func dtsFamily() {
        func dts(_ profile: String?) -> TrackInfo {
            TrackInfo(id: 3, name: "Track 3 (dca)", codec: "dca", language: nil, channels: 8,
                      isDefault: true, profile: profile)
        }
        for profile in ["DTS-HD MA + DTS:X", "DTS-HD MA + DTS:X IMAX"] {
            #expect(TrackDisplayFormatter.isDTSX(dts(profile)))
            #expect(TrackDisplayFormatter.shortName(for: dts(profile)) == "DTS:X")
            #expect(TrackDisplayFormatter.audioDisplayName(for: dts(profile)) == "DTS:X")
        }
        #expect(TrackDisplayFormatter.audioDisplayName(for: dts("DTS-HD MA")) == "DTS-HD MA 7.1")
        #expect(TrackDisplayFormatter.audioDisplayName(for: dts("DTS-HD HRA")) == "DTS-HD HRA 7.1")
        #expect(TrackDisplayFormatter.audioDisplayName(for: dts("DTS-ES")) == "DTS 7.1")
        #expect(TrackDisplayFormatter.audioDisplayName(for: dts(nil)) == "DTS 7.1")
        // A track the engine confirmed as DTS:X under a plain "DTS-HD MA" label is named by the engine's flag.
        let confirmed = TrackInfo(id: 4, name: "Track 4 (dca)", codec: "dca", language: nil, channels: 8,
                                  isDefault: false, profile: "DTS-HD MA", isDTSX: true)
        #expect(TrackDisplayFormatter.audioDisplayName(for: confirmed) == "DTS:X")
    }

    @Test("a track with neither language nor a describable format keeps its name")
    func lastResortIsTheName() {
        let track = audio(language: nil, codec: "", channels: 0, name: "Commentary")
        #expect(TrackDisplayFormatter.shortName(for: track) == "Commentary")
    }
}
