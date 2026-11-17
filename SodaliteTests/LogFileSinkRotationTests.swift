import Foundation
import Testing
@testable import Sodalite

/// The sink used to stop writing at its cap, which kept the oldest lines and dropped the newest: the
/// ones next to the symptom a reporter turned it on for. It now rotates into two halves. Driven through
/// `LogTap.append` against a temporary folder and a tiny segment, so no test fills 16 MB.
struct LogFileSinkRotationTests {

    private struct Files {
        let folder: URL
        var live: URL { folder.appendingPathComponent("sodalite-log.txt") }
        var rotated: URL { folder.appendingPathComponent("sodalite-log.1.txt") }

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("sink-rotation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("sodalite-log.txt").path, contents: nil)
        }

        func append(_ line: String, segment: Int = 100) {
            LogTap.append(line, to: live, rotatingTo: rotated, segmentBytes: segment)
        }

        func read(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        func size(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test("below the segment size lines just append")
    func appendsBelowSegment() throws {
        let files = try Files()
        defer { files.remove() }

        files.append("one")
        files.append("two")

        #expect(files.read(files.live) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: files.rotated.path))
    }

    @Test("a full file rotates, and the line that found it full is kept")
    func fullFileRotates() throws {
        let files = try Files()
        defer { files.remove() }
        let old = String(repeating: "o", count: 99)

        files.append(old)
        files.append("newest")

        #expect(files.read(files.rotated) == old + "\n")
        let live = files.read(files.live)
        #expect(live.contains("[LogTap] file sink rotated, earlier lines are in sodalite-log.1.txt"))
        #expect(live.hasSuffix("newest\n"))
    }

    /// The failure this replaces: at the cap, the newest line was the one thrown away.
    @Test("the newest line always lands, however long the session runs")
    func newestLineAlwaysLands() throws {
        let files = try Files()
        defer { files.remove() }

        for index in 0 ..< 500 {
            files.append("line \(index)")
            #expect(files.read(files.live).hasSuffix("line \(index)\n"))
        }
    }

    @Test("two halves bound the total, the oldest half is what goes")
    func totalStaysBounded() throws {
        let files = try Files()
        defer { files.remove() }

        for index in 0 ..< 500 {
            files.append("line \(index)")
        }

        // A segment may overshoot by the one line that found it just under, plus the marker.
        let slack = 120
        #expect(files.size(files.live) <= 100 + slack)
        #expect(files.size(files.rotated) <= 100 + slack)
        #expect(!files.read(files.rotated).contains("line 0\n"), "the oldest half survived a later rotation")
    }

    @Test("the export hands both halves over as one, oldest first")
    func exportConcatenatesHalves() throws {
        let files = try Files()
        defer { files.remove() }
        let old = String(repeating: "o", count: 99)
        files.append(old)
        files.append("newest")

        let file = try #require(PersistedLogFile(urls: [files.rotated, files.live]))
        var read = Data()
        #expect(file.stream(chunkSize: 16) { read.append(contentsOf: $0); return true })
        let text = String(decoding: read, as: UTF8.self)

        #expect(file.length == files.size(files.rotated) + files.size(files.live))
        #expect(text.hasPrefix(old + "\n"))
        #expect(text.hasSuffix("newest\n"))
    }

    @Test("a missing rotated half is skipped, not an error")
    func missingHalfIsSkipped() throws {
        let files = try Files()
        defer { files.remove() }
        files.append("only")

        let file = try #require(PersistedLogFile(urls: [files.rotated, files.live]))
        #expect(file.length == files.size(files.live))
    }
}

/// Audit PTD-207: the sink keeps one handle open and its queue is bounded.
struct LogFileSinkBacklogTests {

    @Test("a batch past the limit is refused and counted, then reported once")
    func dropsAndCounts() {
        let backlog = FileSinkBacklog(limit: 10)
        #expect(backlog.admit(6))
        #expect(!backlog.admit(6))
        #expect(backlog.takeDropped() == 6)
        #expect(backlog.takeDropped() == 0)
        backlog.finish(6)
        #expect(backlog.admit(6))
    }

    @Test("lines written one after another through the kept handle all land, and rotation still works")
    func keptHandleWrites() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sink-handle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let live = folder.appendingPathComponent("l.txt")
        let rotated = folder.appendingPathComponent("l.1.txt")
        FileManager.default.createFile(atPath: live.path, contents: nil)

        for index in 0 ..< 20 {
            LogTap.append("line \(index)", to: live, rotatingTo: rotated, segmentBytes: 60)
        }
        let all = ((try? String(contentsOf: rotated, encoding: .utf8)) ?? "")
            + ((try? String(contentsOf: live, encoding: .utf8)) ?? "")
        #expect(all.contains("line 19\n"))
        #expect(FileManager.default.fileExists(atPath: rotated.path))
    }
}
