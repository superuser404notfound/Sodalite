import Foundation
import os.log

private let log = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: "ResumeBar")

/// Produces cell artwork with the resume bar already drawn into it, cached as files in the shared
/// container.
///
/// All or nothing: either every progress-bearing cell on the shelf gets burned-in artwork, or none
/// does and the caller keeps the system's own `playbackProgress` throughout. A pass that covered
/// only the cells it had budget for left the accent capsule standing beside the white system bar
/// inside one row, at two different resolutions, with the seam moving on every refresh
/// (Sodalite#128). The shelf can still never come out worse than before: the fallback is what it
/// rendered before any of this existed.
enum ResumeBarArtwork {

    /// Decode cap. Below what `JellyfinItem.imageURL` downloads because the bitmap is what costs
    /// memory here: decoding at 640 handed the shelf an image it had to upscale, which is what made
    /// a burned-in cell visibly softer than its remote neighbour, while the full-size decode is
    /// ~3.7MB a bitmap and trips "-17102 decompressing image" when several cells decode at once.
    /// 1024 covers the zoomed cell at roughly 2.4MB.
    private static let maxPixelSize = ImageWidth.topShelfDecode

    /// Both queries ask for ten items, so this is the shelf at its fullest. Past it a pass cannot
    /// promise a uniform shelf inside its budget, so it does not start one.
    private static let maxCells = 20

    /// Whole-pass budget. Downloads overlap, so this is a backstop against a stalled server rather
    /// than the thing that decides how many cells get a bar.
    private static let deadline: TimeInterval = 6

    private static let requestTimeout: TimeInterval = 4

    /// Enough overlap to finish a full shelf well inside the budget without asking a small server
    /// to resize ten stills at once.
    private static let maxConcurrentDownloads = 4

    /// Maps item id to a burned-in artwork file, or nothing at all. A partial map is never
    /// returned; see the type's note.
    static func prepare(items: [JellyfinItem],
                        session: SharedSession,
                        accent: UInt32,
                        artwork: TopShelfArtwork.Choice) async -> [String: URL] {
        guard let directory = containerDirectory() else {
            log.notice("no shared container; resume bars disabled")
            return [:]
        }

        let candidates = items.compactMap { item -> Candidate? in
            guard let fraction = item.topShelfProgress,
                  let remote = item.topShelfImageURL(baseURL: session.baseURL,
                                                     token: session.accessToken,
                                                     artwork: artwork)
            else { return nil }
            let name = ResumeBarFile.name(itemID: item.id, remote: remote, fraction: fraction, accent: accent)
            return Candidate(itemID: item.id,
                             remote: remote,
                             fraction: fraction,
                             destination: directory.appendingPathComponent(name))
        }

        // The full set is named before a single byte moves. Collected as the pass goes, it would
        // omit the cells the pass never reached and the sweep would then delete exactly the
        // artwork an earlier pass rendered for them, which is the work that lets this one finish.
        let live = Set(candidates.map { $0.destination.lastPathComponent })
        defer { sweep(directory: directory, keeping: live) }

        guard !candidates.isEmpty else { return [:] }
        guard candidates.count <= maxCells else {
            log.notice("\(candidates.count) resume cells is past the cap; shelf keeps the system bar")
            return [:]
        }

        var covered: [String: URL] = [:]
        var pending: [Candidate] = []
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.destination.path) {
                covered[candidate.itemID] = candidate.destination
            } else {
                pending.append(candidate)
            }
        }

        if !pending.isEmpty {
            covered.merge(await render(pending, accent: accent)) { current, _ in current }
        }

        guard covered.count == candidates.count else {
            log.notice("resume bars covered \(covered.count) of \(candidates.count) cells; shelf keeps the system bar")
            return [:]
        }
        return covered
    }

    // MARK: - Rendering

    private struct Candidate: Sendable {
        let itemID: String
        let remote: URL
        let fraction: Double
        let destination: URL
    }

    private struct Download: Sendable {
        let candidate: Candidate
        let data: Data?
    }

    /// Downloads overlap, compositing stays serial: the network is what makes a pass slow, and
    /// CoreGraphics is what the extension's memory ceiling cares about.
    private static func render(_ pending: [Candidate], accent: UInt32) async -> [String: URL] {
        let started = Date()
        var done: [String: URL] = [:]

        await withTaskGroup(of: Download.self) { group in
            var next = 0
            while next < pending.count, next < maxConcurrentDownloads {
                let candidate = pending[next]
                group.addTask { Download(candidate: candidate, data: await download(candidate.remote)) }
                next += 1
            }

            while let outcome = await group.next() {
                guard Date().timeIntervalSince(started) < deadline else {
                    log.notice("resume bar pass hit its deadline with \(pending.count - done.count) cells left")
                    group.cancelAll()
                    continue
                }
                if next < pending.count {
                    let candidate = pending[next]
                    group.addTask { Download(candidate: candidate, data: await download(candidate.remote)) }
                    next += 1
                }
                guard let data = outcome.data else { continue }
                if persist(data, for: outcome.candidate, accent: accent) {
                    done[outcome.candidate.itemID] = outcome.candidate.destination
                }
            }
        }
        return done
    }

    private static func persist(_ source: Data, for candidate: Candidate, accent: UInt32) -> Bool {
        guard let rendered = ResumeBarRenderer.render(source: source,
                                                      fraction: candidate.fraction,
                                                      accent: accent,
                                                      maxPixelSize: maxPixelSize)
        else {
            log.error("render failed for \(candidate.destination.lastPathComponent, privacy: .public)")
            return false
        }
        do {
            try rendered.write(to: candidate.destination, options: .atomic)
            // The Top Shelf is drawn by the home screen, not by us. Group-container files are not
            // world-readable by default, so widen the mode; if the sandbox still refuses, the
            // caller's fallback covers it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: candidate.destination.path)
            return true
        } catch {
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            log.notice("artwork download failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Files

    private static func containerDirectory() -> URL? {
        guard let base = TopShelfCachePolicy.directory() else { return nil }
        let directory = base.appendingPathComponent("ResumeBars", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Every pass names the full set it needs, so anything else is a stale progress value, a stale
    /// accent, a stale render version, or an item that left the shelf. Without this the directory
    /// only grows.
    private static func sweep(directory: URL, keeping live: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where !live.contains(entry) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }
}
