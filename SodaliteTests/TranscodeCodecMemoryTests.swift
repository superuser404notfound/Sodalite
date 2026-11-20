import Foundation
import Testing
@testable import Sodalite

/// Whether a server may encode HEVC is an admin setting a client cannot read. The first transcode it
/// delivers answers it, so the answer is kept per server (Sodalite#87).
struct TranscodeCodecMemoryTests {
    private func memory() -> TranscodeCodecMemory {
        let suite = "transcodeCodec.\(UUID().uuidString)"
        return TranscodeCodecMemory(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test func anUnknownServerIsAssumedToEncodeH264() {
        #expect(!memory().encodesHEVC(server: "jf.local"))
        #expect(!memory().encodesHEVC(server: nil))
        #expect(memory().knownCodec(server: "jf.local") == nil)
    }

    @Test func aDeliveredHEVCTranscodeIsRemembered() {
        let memory = memory()
        memory.record(server: "jf.local", deliveredCodec: "hevc")
        #expect(memory.encodesHEVC(server: "jf.local"))
        #expect(!memory.encodesHEVC(server: "other.local"))
    }

    /// The admin can switch HEVC off again; the next delivered transcode says so.
    @Test func aLaterH264TranscodeOverwritesIt() {
        let memory = memory()
        memory.record(server: "jf.local", deliveredCodec: "hevc")
        memory.record(server: "jf.local", deliveredCodec: "h264")
        #expect(!memory.encodesHEVC(server: "jf.local"))
    }
}
