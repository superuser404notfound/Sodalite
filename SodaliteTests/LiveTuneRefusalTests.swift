import Testing
import Foundation
import AetherEngine
@testable import Sodalite

struct LiveTuneRefusalTests {
    @Test("a provider refusing the playlist is a provider limit", arguments: [403, 429, 458, 503, 509])
    func providerStatuses(status: Int) {
        #expect(LiveTuneRefusal.classify(tunerOpenError: nil, ingestError: .playlistUnreachable(status: status))
                == .providerLimit(status: status))
    }

    @Test("a transport error or a 404 is not a provider limit")
    func otherIngestErrors() {
        #expect(LiveTuneRefusal.classify(tunerOpenError: nil, ingestError: .playlistUnreachable(status: -1)) == nil)
        #expect(LiveTuneRefusal.classify(tunerOpenError: nil, ingestError: .playlistUnreachable(status: 404)) == nil)
        #expect(LiveTuneRefusal.classify(tunerOpenError: nil, ingestError: .ingestStalled) == nil)
    }

    @Test("PlaybackInfo failing with an HTTP error reads as no free tuner")
    func tunerOpenHTTPError() {
        let error = APIError.httpError(statusCode: 500, data: nil)
        #expect(LiveTuneRefusal.classify(tunerOpenError: error, ingestError: nil) == .tunerUnavailable)
    }

    @Test("an unreachable server is not a tuner verdict")
    func unreachableIsNotTuner() {
        #expect(LiveTuneRefusal.classify(tunerOpenError: APIError.serverUnreachable, ingestError: nil) == nil)
    }

    @Test("the provider verdict wins when both are present")
    func providerWins() {
        let error = APIError.httpError(statusCode: 500, data: nil)
        #expect(LiveTuneRefusal.classify(tunerOpenError: error, ingestError: .playlistUnreachable(status: 403))
                == .providerLimit(status: 403))
    }
}
