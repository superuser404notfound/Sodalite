import Testing
import UIKit
import AetherEngine
@testable import Sodalite

/// Mapping from the engine's typed `PlaybackErrorInfo` (AetherEngine#376/#377/#378) onto the host's
/// error faces. Split from the copy on purpose: the classification is testable without a locale, the
/// sentences are not.
struct PlayerEngineErrorFaceTests {

    private func info(_ kind: PlaybackErrorKind, status: Int? = nil) -> PlaybackErrorInfo {
        PlaybackErrorInfo(kind: kind, message: "Failed to load: whatever", underlyingCode: status)
    }

    // MARK: A refusal, split by what the status actually says

    @Test func forbiddenAndUnauthorizedReadAsARefusal() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 403)) == .streamRefused(status: 403))
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 401)) == .streamRefused(status: 401))
    }

    @Test func goneAndNotFoundReadAsAMissingItem() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 404)) == .streamNotFound)
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 410)) == .streamNotFound)
    }

    @Test func serverSideStatusReadsAsAServerError() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 500)) == .streamServerError(status: 500))
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused, status: 502)) == .streamServerError(status: 502))
    }

    /// The copy for a refusal names its status, so a refusal without one has nothing to say that the
    /// engine's own sentence does not say better.
    @Test func aRefusalWithoutAStatusKeepsTheEngineSentence() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRefused)) == .engineMessage)
    }

    // MARK: The metered origin, which is a different recovery

    @Test func rateLimitedReadsAsAConnectionLimitWhicheverStatusCarriedIt() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRateLimited, status: 429)) == .rateLimited)
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRateLimited, status: 509)) == .rateLimited)
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceRateLimited)) == .rateLimited)
    }

    // MARK: Device-bound failures

    @Test func dolbyVisionWithoutHardwareNamesTheDevice() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.dolbyVisionRequiresHardware)) == .dolbyVisionUnsupported)
    }

    /// A full segment volume used to arrive as a source that cannot be muxed or as a silent audio
    /// bridge, which pointed the viewer at the file or the track. It is the device (AetherEngine#720).
    @Test func aFullSegmentVolumeNamesTheDeviceStorage() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.storageExhausted, status: -28)) == .storageFull)
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.storageExhausted)) == .storageFull)
    }

    @Test func aLiveProbeThatBurnedItsBudgetReadsAsAnUnavailableChannel() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.liveSourceUnavailable)) == .liveChannelUnavailable)
    }

    // MARK: Everything the host has no better sentence for

    /// AVFoundation already rendered its `localizedDescription` in the device's language, so replacing it
    /// with our own generic line would lose detail rather than gain a translation.
    @Test func aNativeItemFailureKeepsItsAlreadyLocalizedSentence() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.nativeItemFailed, status: -11800)) == .engineMessage)
    }

    /// A classified failure the host has no sentence for keeps the TOKEN, not the engine's English. Only
    /// a failure with no classification at all falls back to whatever sentence reached us, because there
    /// is nothing else to say.
    @Test func aClassifiedFailureWithoutAHostSentenceKeepsItsToken() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.sourceOpenFailed))
                == .engineClassified(identifier: "sourceOpenFailed"))
        #expect(PlayerEngineErrorPresentation.face(for: nil) == .engineMessage)
    }

    /// `PlaybackErrorKind` is a string-backed struct precisely so the engine can add kinds in a minor
    /// release. A kind this build has never heard of must land on the token, not onto whichever face
    /// happens to sit last in the switch.
    @Test func aKindFromALaterEngineLandsOnItsTokenNotOnANeighbouringFace() {
        let future = PlaybackErrorKind(rawValue: "somethingThisBuildHasNeverHeardOf")
        #expect(PlayerEngineErrorPresentation.face(for: info(future, status: 403))
                == .engineClassified(identifier: "somethingThisBuildHasNeverHeardOf · 403"))
    }

    // MARK: The live variant, where "unavailable" is the fallback rather than the verdict

    @Test func aLiveFailureWithNothingTypedStaysTheUnavailableChannel() {
        #expect(PlayerEngineErrorPresentation.liveFace(for: nil) == .liveChannelUnavailable)
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.sourceOpenFailed)) == .liveChannelUnavailable)
    }

    /// The case worth having: a one-slot panel behind Live TV is out of connections, which the viewer can
    /// act on, and which "the channel's source may be offline" would have mis-stated.
    @Test func aTypedLiveFailureBeatsTheUnavailableCopy() {
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.sourceRateLimited, status: 429)) == .rateLimited)
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.sourceRefused, status: 403)) == .streamRefused(status: 403))
    }

    // MARK: Every face has copy behind it

    @Test func everyFaceResolvesToANonEmptyTrio() {
        let faces: [PlayerEngineErrorPresentation.Face] = [
            .streamRefused(status: 403),
            .streamNotFound,
            .streamServerError(status: 503),
            .rateLimited,
            .dolbyVisionUnsupported,
            .liveChannelUnavailable,
            .engineMessage
        ]
        for face in faces {
            let trio = PlayerEngineErrorPresentation.trio(for: face, engineMessage: "raw engine sentence")
            #expect(!trio.icon.isEmpty)
            #expect(!trio.title.isEmpty)
            #expect(!trio.message.isEmpty)
        }
    }

    /// A symbol name with a typo in it renders as nothing at all rather than failing, so the error screen
    /// would simply lose its icon and no build step would say a word.
    @Test func everyIconIsARealSystemSymbol() {
        let faces: [PlayerEngineErrorPresentation.Face] = [
            .streamRefused(status: 403),
            .streamNotFound,
            .streamServerError(status: 503),
            .rateLimited,
            .dolbyVisionUnsupported,
            .liveChannelUnavailable,
            .engineMessage
        ]
        for face in faces {
            let icon = PlayerEngineErrorPresentation.trio(for: face, engineMessage: "").icon
            #expect(UIImage(systemName: icon) != nil, "\(icon) is not a system symbol on this platform")
        }
    }

    /// The raw sentence is diagnostic, not copy: it reaches the log, and the screen only when the host has
    /// nothing better.
    @Test func onlyTheFallbackFaceShowsTheEngineSentence() {
        let refused = PlayerEngineErrorPresentation.trio(for: .streamRefused(status: 403),
                                                         engineMessage: "Failed to load: HTTP 403")
        #expect(!refused.message.contains("Failed to load"))

        let fallback = PlayerEngineErrorPresentation.trio(for: .engineMessage,
                                                          engineMessage: "Failed to load: HTTP 403")
        #expect(fallback.message == "Failed to load: HTTP 403")
    }

    /// The status is the one number worth reporting back, so the two faces that carry one must render it.
    @Test func theStatusReachesTheCopyWhereTheFaceCarriesOne() {
        let refused = PlayerEngineErrorPresentation.trio(for: .streamRefused(status: 403), engineMessage: "")
        #expect(refused.message.contains("403"))

        let serverError = PlayerEngineErrorPresentation.trio(for: .streamServerError(status: 502), engineMessage: "")
        #expect(serverError.message.contains("502"))
    }

    /// Every kind without a host sentence carries an engine-authored ENGLISH one, which is the one thing
    /// a 26-language app must not paint. Those trade it for a translated line plus the stable token.
    @Test func aClassifiedKindWithNoHostSentenceKeepsTheTokenNotTheEnglish() {
        let face = PlayerEngineErrorPresentation.face(for: info(.softwarePipelineFailed))
        #expect(face == .engineClassified(identifier: "softwarePipelineFailed"))
    }

    /// The token is what a bug report can be searched on, so it carries whatever named the failure
    /// underneath as well.
    @Test func theTokenCarriesTheDomainAndCodeUnderneath() {
        let carried = PlaybackErrorInfo(
            kind: .vodSourceFailed, message: "x",
            underlyingDomain: "NSURLErrorDomain", underlyingCode: -1001)
        #expect(PlayerEngineErrorPresentation.identifier(for: carried) == "vodSourceFailed · NSURLErrorDomain -1001")
    }

    /// `.nativeItemFailed` is the exception and stays the engine's sentence: it IS AVFoundation's
    /// localizedDescription, already in the device's language and more specific than a generic line.
    @Test func aNativeItemFailureKeepsAVFoundationsOwnLocalizedSentence() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.nativeItemFailed)) == .engineMessage)
    }

    /// Live already decided that "channel unavailable" beats a generic line, and splitting the
    /// no-sentence case in two must not quietly regress that.
    @Test func liveStillReadsAnUnnamedFailureAsTheChannelNotComingUp() {
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.softwarePipelineFailed)) == .liveChannelUnavailable)
        #expect(PlayerEngineErrorPresentation.liveFace(for: nil) == .liveChannelUnavailable)
    }

    /// The same classification reads differently before the first frame and after it.
    @Test func theHeadlineFollowsWhetherPlaybackHadStarted() {
        let face = PlayerEngineErrorPresentation.face(for: info(.softwarePipelineFailed))
        let start = PlayerEngineErrorPresentation.trio(for: face, engineMessage: "raw", context: .start)
        let session = PlayerEngineErrorPresentation.trio(for: face, engineMessage: "raw", context: .session)
        #expect(start.title != session.title)
        #expect(start.message == session.message)
        // Whatever the engine said in English is not what either of them paints.
        #expect(!start.message.contains("raw"))
        #expect(start.message.contains("softwarePipelineFailed"))
    }

    // MARK: The one advice that is not "try again"

    /// A track the bridge produced nothing for and a switch that failed both leave the viewer with the
    /// same next move, and it is not the generic line's "try again": pick a different track. That is the
    /// whole test for whether a kind earns its own sentence.
    @Test func anAudioTrackThatCannotBeCarriedGetsItsOwnAdvice() {
        #expect(PlayerEngineErrorPresentation.face(for: info(.audioBridgeProducedNoOutput)) == .audioTrackUnavailable)
        #expect(PlayerEngineErrorPresentation.face(for: info(.audioTrackSwitchFailed)) == .audioTrackUnavailable)
    }

    /// Live can switch tracks too, so this one must NOT be swallowed by "channel unavailable" the way an
    /// unnamed failure is.
    @Test func liveKeepsTheAudioAdviceRatherThanCallingTheChannelDead() {
        #expect(PlayerEngineErrorPresentation.liveFace(for: info(.audioTrackSwitchFailed)) == .audioTrackUnavailable)
    }

    // MARK: The token live would otherwise swallow

    /// Live trades the token for the better sentence. A report that says only "channel unavailable" names
    /// nothing, so the classification comes back as a line underneath.
    @Test func aSwallowedClassificationComesBackAsAReportCode() {
        let message = PlayerEngineErrorPresentation.appendingReportCode(
            to: "Channel unavailable", from: info(.softwarePipelineFailed))
        #expect(message.contains("Channel unavailable"))
        #expect(message.contains("softwarePipelineFailed"))
    }

    /// Nothing was swallowed here, so nothing is appended: the sentence already names the failure, and a
    /// token under it would be noise on every refused stream.
    @Test func aNamedFailureGetsNoCodeAppended() {
        let named = PlayerEngineErrorPresentation.appendingReportCode(
            to: "Stream refused", from: info(.sourceRefused, status: 403))
        #expect(named == "Stream refused")
        #expect(PlayerEngineErrorPresentation.appendingReportCode(to: "x", from: nil) == "x")
    }
    @Test("A stream refused for its certificate says that, not something generic")
    func certificateRefusalHasItsOwnFace() {
        // Without a face this lands on .engineClassified, which shows a translated generic line plus
        // "sourceCertificateRejected · NSURLErrorDomain -1202". That token is right and useless to
        // the one person who can fix it, because what they need to be told is where the answer is.
        let info = PlaybackErrorInfo(
            kind: .sourceCertificateRejected,
            message: "The system does not trust the origin's certificate",
            underlyingDomain: NSURLErrorDomain,
            underlyingCode: NSURLErrorServerCertificateUntrusted
        )
        #expect(PlayerEngineErrorPresentation.face(for: info) == .certificateRejected)
    }

}
