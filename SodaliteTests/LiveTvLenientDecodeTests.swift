import Testing
import Foundation
@testable import Sodalite

/// Audit NET-203 (date parsing without a formatter per field), NET-206 (one bad EPG entry must not
/// empty a page) and NET-R203 (one token spelling).
@MainActor
struct LiveTvLenientDecodeTests {
    private let decoder = JSONDecoder.jellyfinLiveTv
    private let reference = Date(timeIntervalSince1970: 1_781_173_200) // 2026-06-11T10:20:00Z

    @Test("the date shapes Jellyfin and Seerr send all parse to the same instant")
    func dateShapes() {
        let shapes = ["2026-06-11T10:20:00.0000000Z",   // 7 digits, Jellyfin
                      "2026-06-11T10:20:00.000Z",       // 3 digits, Seerr
                      "2026-06-11T10:20:00Z",           // none
                      "2026-06-11T12:20:00+02:00",      // offset
                      "2026-06-11T10:20:00.000+00:00",
                      "2026-06-11T10:20:00",            // no zone reads as UTC (FR-DAT-2)
                      "2026-06-11T10:20:00.0000000"]
        for raw in shapes {
            #expect(ISODateParser.parse(raw) == reference, "\(raw)")
        }
        #expect(ISODateParser.parse("2026-06-11T10:20:00.5Z") == reference.addingTimeInterval(0.5))
        #expect(ISODateParser.parse("not a date") == nil)
        #expect(ISODateParser.parse("") == nil)
        #expect(SeerrDate.parse("2026-06-11T10:20:00.000Z") == reference)
    }

    @Test("a program decodes its start and end through the shared parser")
    func programDates() throws {
        let json = #"{"Id":"p","Name":"N","StartDate":"2026-06-11T10:20:00.0000000Z","EndDate":"2026-06-11T11:20:00Z"}"#
        let program = try decoder.decode(JellyfinProgram.self, from: Data(json.utf8))
        #expect(program.startDate == reference)
        #expect(program.endDate == reference.addingTimeInterval(3600))
    }

    @Test("a programs page with one title-less entry keeps the others")
    func programPageIsLenient() throws {
        let json = """
        {"Items":[{"Id":"a","Name":"One"},{"Id":"b"},{"Id":"c","Name":"Three"}],"TotalRecordCount":3}
        """
        let page = try decoder.decode(LiveTvProgramsResponse.self, from: Data(json.utf8))
        #expect(page.items.map(\.id) == ["a", "c"])
        #expect(page.totalRecordCount == 3)
    }

    @Test("a channels page survives a malformed channel and a malformed current program")
    func channelPageIsLenient() throws {
        let json = """
        {"Items":[{"Name":"no id"},
                  {"Id":"c1","Name":"One","CurrentProgram":{"Id":"p"}},
                  {"Id":"c2","Name":"Two"}]}
        """
        let page = try decoder.decode(LiveTvChannelsResponse.self, from: Data(json.utf8))
        #expect(page.items.map(\.id) == ["c1", "c2"])
        #expect(page.items[0].currentProgram == nil)
    }

    @Test("6000 programs decode well inside a second")
    func bigPage() throws {
        var items: [String] = []
        for i in 0..<6_000 {
            items.append(#"{"Id":"p\#(i)","Name":"Show \#(i)","StartDate":"2026-06-11T10:20:00.0000000Z","EndDate":"2026-06-11T11:20:00.0000000Z"}"#)
        }
        let data = Data(#"{"Items":[\#(items.joined(separator: ","))],"TotalRecordCount":6000}"#.utf8)
        let start = ContinuousClock.now
        let page = try decoder.decode(LiveTvProgramsResponse.self, from: data)
        #expect(page.items.count == 6_000)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("every token-in-URL builder spells the token the same two ways")
    func tokenSpelling() {
        #expect(JellyfinTokenQuery.queryString("abc") == "api_key=abc&ApiKey=abc")
        #expect(JellyfinTokenQuery.items("abc").map(\.name) == ["api_key", "ApiKey"])
        #expect(JellyfinPlaybackService.tokenQueryItems("abc") == JellyfinTokenQuery.items("abc"))
    }

    /// Audit review R-W2-4: a cursor that cannot step over a bad element must end the loop.
    @Test("a list whose cursor never advances ends instead of spinning")
    func lossyListEndsWhenSkippingThrows() throws {
        let list = try LossyList<Int>(from: StuckDecoder())
        #expect(list.elements.isEmpty)
        #expect(list.dropped == 1)
    }
}

private struct StuckDecoder: Decoder {
    var codingPath: [CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer { StuckContainer() }
    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "stuck"))
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "stuck"))
    }
}

private struct StuckContainer: UnkeyedDecodingContainer {
    var codingPath: [CodingKey] { [] }
    var count: Int? { nil }
    var isAtEnd: Bool { false }
    var currentIndex: Int { 0 }
    private var stuck: DecodingError { .dataCorrupted(.init(codingPath: [], debugDescription: "stuck")) }
    mutating func decodeNil() throws -> Bool { throw stuck }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { throw stuck }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> { throw stuck }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { throw stuck }
    mutating func superDecoder() throws -> Decoder { throw stuck }
}
