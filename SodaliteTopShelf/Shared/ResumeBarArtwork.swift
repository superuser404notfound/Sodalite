import Foundation
import os

nonisolated private let log = ShelfLog(category: "ResumeBar")

/// Renders the shelf's cell artwork into the shared container: cropped to the cell's 16:9, decoded
/// at the width the cell draws, and with the resume bar burned in where there is one.
///
/// Every cell, not just the ones with a bar. A Next Up cell has nothing to resume, but rendering it
/// too means the home screen never fetches anything itself: one resolution across the row, no
/// system-process download that can quietly fail and leave a cell empty, and no second copy of the
/// artwork on the wire.
///
/// All or nothing: either every cell is a local file or none is and the caller falls back to remote
/// URLs with the system's own `playbackProgress` throughout. A pass that covered only what it had
/// budget for left the accent capsule standing beside the white system bar inside one row, at two
/// different resolutions, with the seam moving on every refresh (Sodalite#128).
///
/// It lives in `Shared/` because the app runs it too: doing this work when the app has a reason to
/// (a setting changed, a title finished) is what keeps it off the path of someone looking at the
/// shelf, where it used to hold the row back until it finished.
enum ResumeBarArtwork {

    /// One cell's input. Neutral on purpose: the extension and the app each have their own
    /// `TopShelfItem`, and neither type can cross into the other's module.
    nonisolated struct Cell: Sendable, Equatable {
        let itemID: String
        let remote: URL
        /// nil draws no bar. `TopShelfProgress` already returns nil for an untouched item, so this
        /// is the same thing as "nothing to resume".
        let fraction: Double?

        nonisolated init(itemID: String, remote: URL, fraction: Double?) {
            self.itemID = itemID
            self.remote = remote
            self.fraction = fraction
        }
    }

    /// Decode cap, below the width the artwork was downloaded at but exactly the width the cell
    /// draws: anything under it hands the shelf an image to upscale, which is what made a burned-in
    /// cell visibly softer than its remote neighbour (Sodalite#128). ImageIO downsamples during the
    /// decode, so a larger source never becomes a full bitmap here. The bitmap is what costs memory,
    /// 5.8MB at this width with two alive during a composite, which is why compositing stays serial.
    nonisolated private static let maxPixelSize = ImageWidth.topShelfCell

    /// Both queries ask for ten items, so twenty is the shelf at its fullest. Past it a pass cannot
    /// promise a uniform shelf inside its budget, so it does not start one.
    nonisolated private static let maxCells = 20

    /// Whole-pass budget. Downloads overlap, so this is a backstop against a stalled server rather
    /// than the thing that decides how many cells get rendered.
    nonisolated private static let deadline: TimeInterval = 6

    nonisolated private static let requestTimeout: TimeInterval = 4

    /// Enough overlap to finish a full shelf well inside the budget without asking a small server
    /// for twenty pictures at once.
    nonisolated private static let maxConcurrentDownloads = 4

    /// Maps item id to a rendered artwork file, or nothing at all. A partial map is never returned;
    /// see the type's note.
    nonisolated static func prepare(cells: [Cell], accent: UInt32) async -> [String: URL] {
        guard let directory = containerDirectory() else {
            log.notice("no shared container; shelf artwork disabled")
            return [:]
        }

        // One file per item. A repeated id would leave `covered` short of `candidates` for good,
        // and the all-or-nothing check below would then drop the artwork on every pass.
        var seen = Set<String>()
        let candidates = cells.filter { seen.insert($0.itemID).inserted }.map { cell in
            Candidate(cell: cell,
                      destination: directory.appendingPathComponent(name(for: cell, accent: accent)))
        }

        // The full set is named before a single byte moves. Collected as the pass goes, it would
        // omit the cells the pass never reached and the sweep would then delete exactly the
        // artwork an earlier pass rendered for them, which is the work that lets this one finish.
        let live = Set(candidates.map { $0.destination.lastPathComponent })
        defer { sweep(directory: directory, keeping: live) }

        guard !candidates.isEmpty else { return [:] }
        guard candidates.count <= maxCells else {
            log.notice("\(candidates.count) cells is past the cap; shelf keeps the remote artwork")
            return [:]
        }

        var covered: [String: URL] = [:]
        var pending: [Candidate] = []
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.destination.path) {
                covered[candidate.cell.itemID] = candidate.destination
            } else {
                pending.append(candidate)
            }
        }

        if !pending.isEmpty {
            covered.merge(await render(pending, accent: accent)) { current, _ in current }
        }

        guard covered.count == candidates.count else {
            log.notice("covered \(covered.count) of \(candidates.count) cells; shelf keeps the remote artwork")
            return [:]
        }
        return covered
    }

    /// The accent rides in the name only for a cell that draws a bar. Without this an accent change
    /// would re-render every Next Up cell as well, for artwork that carries no accent at all.
    nonisolated static func name(for cell: Cell, accent: UInt32) -> String {
        ResumeBarFile.name(itemID: cell.itemID,
                           remote: cell.remote,
                           fraction: cell.fraction ?? 0,
                           accent: cell.fraction == nil ? UInt32(0) : accent)
    }

    // MARK: - Rendering

    nonisolated private struct Candidate: Sendable {
        let cell: Cell
        let destination: URL
    }

    nonisolated private enum Event: Sendable {
        case downloaded(URL, Data?)
        case deadline
    }

    /// Downloads overlap, compositing stays serial: the network is what makes a pass slow, and
    /// CoreGraphics is what the memory ceiling cares about.
    ///
    /// One download per PICTURE, not per cell. Under the Thumb and Backdrop options every episode
    /// of a show points at the same show-level artwork, so a shelf with four episodes of one series
    /// asked for the same file four times; the cells still differ, because each burns in its own
    /// resume bar.
    ///
    /// The deadline is a timer in the group, not a clock check between results. A check only runs
    /// when a download returns, so a stalled request held the pass (and with it the extension's
    /// answer) for its full timeout on top of the budget, per stalled slot.
    nonisolated private static func render(_ pending: [Candidate], accent: UInt32) async -> [String: URL] {
        var done: [String: URL] = [:]
        let sources = Dictionary(grouping: pending, by: { $0.cell.remote })
        let urls = Array(sources.keys)

        await withTaskGroup(of: Event.self) { group in
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                return .deadline
            }
            var next = 0
            var inFlight = 0
            while next < urls.count, inFlight < maxConcurrentDownloads {
                let url = urls[next]
                group.addTask { .downloaded(url, await download(url)) }
                next += 1
                inFlight += 1
            }

            while inFlight > 0, let event = await group.next() {
                switch event {
                case .deadline:
                    log.notice("artwork pass hit its deadline with \(pending.count - done.count) cells left")
                    group.cancelAll()
                    return
                case let .downloaded(url, data):
                    inFlight -= 1
                    if next < urls.count {
                        let url = urls[next]
                        group.addTask { .downloaded(url, await download(url)) }
                        next += 1
                        inFlight += 1
                    }
                    guard let data else { continue }
                    for candidate in sources[url] ?? [] where persist(data, for: candidate, accent: accent) {
                        done[candidate.cell.itemID] = candidate.destination
                    }
                }
            }
            // Wakes the timer, which the group would otherwise wait out.
            group.cancelAll()
        }
        // The one number a pass cannot reason about from here. A composite holds two bitmaps of
        // `maxPixelSize`, so that width trades sharpness against a hard ceiling, and the headroom
        // left at the end is what says whether there is room to go on.
        log.info("composited \(done.count) cells, \(os_proc_available_memory() / 1_048_576)MB left")
        return done
    }

    nonisolated private static func persist(_ source: Data, for candidate: Candidate, accent: UInt32) -> Bool {
        guard let rendered = ResumeBarRenderer.render(source: source,
                                                      fraction: candidate.cell.fraction,
                                                      accent: accent,
                                                      maxPixelSize: maxPixelSize)
        else {
            log.error("render failed for \(candidate.destination.lastPathComponent)")
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
            log.error("write failed: \(error.localizedDescription)")
            return false
        }
    }

    nonisolated private static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            log.notice("artwork download failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Files

    nonisolated private static func containerDirectory() -> URL? {
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
    nonisolated private static func sweep(directory: URL, keeping live: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where !live.contains(entry) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
        }
    }
}
