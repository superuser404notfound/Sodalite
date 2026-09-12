import Foundation

/// Renders the Top Shelf's cell artwork from inside the app, so the extension's own pass finds
/// everything on disk and answers with a directory listing.
///
/// The work is the same either way, the difference is who waits for it. In the extension it sits
/// between tvOS asking for the shelf and the row appearing, which is what made switching the
/// artwork setting feel slow: up to twenty downloads and composites with the row held back until
/// the last one. Here it runs while the app is open and nobody is looking at the shelf.
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
        let items = (await resume ?? []) + (await nextUp ?? [])
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
