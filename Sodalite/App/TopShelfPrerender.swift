import Foundation

/// Renders the Top Shelf's cell artwork from inside the app, the only process that can: the
/// extension answers from what is on disk and shows remote artwork for a row this has not covered
/// yet, because a composite at the cell's width does not fit its 25 MB ceiling
/// (`ResumeBarArtwork.existing`). So every change to what the shelf shows has to reach a pass here.
///
/// It goes through the extension's own client and model (`TopShelfAPI`, `TopShelfItem`), not the
/// app's: the two have to select the same items and the same pictures, or the files this writes are
/// named differently from the ones the extension looks for, and the pre-render silently buys
/// nothing.
enum TopShelfPrerender {

    /// Runs one pass, coalescing anything asked for while one is in flight into a single repeat.
    /// Several of the triggers fire together (a title finishes, the mirror is rewritten, a row is
    /// marked played), and a pass per trigger would re-read a directory that the first pass has
    /// already filled.
    static func run() async {
        #if os(tvOS)
        guard await gate.enter() else { return }
        repeat {
            await pass()
        } while await gate.leave()
        #endif
    }

    #if os(tvOS)
    private static let gate = Gate()

    private static func pass() async {
        guard TopShelfEnabled.read(), let session = SharedSession.read() else { return }
        let api = TopShelfAPI(session: session)
        async let resume = try? api.resumeItems()
        async let nextUp = try? api.nextUp()
        // Both rows or no pass. `prepare` sweeps every file outside the set it is handed, so a pass
        // built from one row deleted the other row's artwork, and the extension then had to
        // download and composite it again while tvOS waited for the shelf.
        guard let fetchedResume = await resume, let fetchedNextUp = await nextUp else { return }
        let rows = TopShelfItem.shelfRows(resume: fetchedResume, nextUp: fetchedNextUp)
        let items = rows.resume + rows.nextUp
        guard !items.isEmpty else { return }

        let artwork = TopShelfArtwork.read()
        let cells = items.compactMap { $0.artworkCell(session: session, artwork: artwork) }
        _ = await ResumeBarArtwork.prepare(cells: cells, accent: TopShelfAccent.read())
    }

    private actor Gate {
        private var running = false
        private var again = false

        func enter() -> Bool {
            if running {
                again = true
                return false
            }
            running = true
            return true
        }

        /// True asks the caller for one more pass: something changed while this one was running, so
        /// its own result may already be stale.
        func leave() -> Bool {
            let repeated = again
            again = false
            running = repeated
            return repeated
        }
    }
    #endif
}
