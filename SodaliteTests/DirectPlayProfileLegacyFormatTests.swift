import Testing
import Foundation
@testable import Sodalite

/// RealMedia, feature-phone 3GP and Theora, offered for direct play since FFmpegBuild 3.8.0.
///
/// The same rule as the WMV and Flash chains: an unlisted VIDEO codec costs a transcode, while a
/// container whose AUDIO codecs the engine's build cannot decode plays without sound. So every
/// RealAudio flavour ships with `rm`, and AMR with the H.263 that a 3GP carries.
@MainActor
struct DirectPlayProfileLegacyFormatTests {

    private func videoProfile() -> [String: Any] {
        let profiles = DirectPlayProfile.baseProfile()["DirectPlayProfiles"] as? [[String: Any]] ?? []
        return profiles.first { $0["Type"] as? String == "Video" } ?? [:]
    }

    private func list(_ key: String) -> Set<String> {
        Set((videoProfile()[key] as? String ?? "").components(separatedBy: ","))
    }

    @Test func theProfileOffersTheRealMediaContainer() {
        #expect(list("Container").isSuperset(of: ["rm", "rmvb"]))
    }

    /// ffprobe names the speech codecs `ra_144` / `ra_288`, which is what Jellyfin compares against;
    /// the decoders register as `real_144` / `real_288`, a name the server never reports.
    @Test func offeringRealMediaMeansOfferingAllOfItsCodecs() {
        guard list("Container").contains("rm") else { return }
        #expect(list("VideoCodec").isSuperset(of: ["rv10", "rv20", "rv30", "rv40"]))
        #expect(list("AudioCodec").isSuperset(of: ["cook", "atrac3", "sipr", "ralf", "ra_144", "ra_288"]))
    }

    @Test func aPhoneThreeGPHasItsVideoAndSpeechCodecs() {
        #expect(list("Container").contains("3gp"))
        #expect(list("VideoCodec").contains("h263"))
        #expect(list("AudioCodec").isSuperset(of: ["amr_nb", "amr_wb"]))
    }

    @Test func theoraAndDVDLPCMAreOffered() {
        #expect(list("VideoCodec").contains("theora"))
        #expect(list("AudioCodec").contains("pcm_dvd"))
    }
}
