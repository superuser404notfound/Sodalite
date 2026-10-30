@preconcurrency import TVServices

private let log = ShelfLog(category: "ContentProvider")

/// Top Shelf provider; tvOS calls loadTopShelfContent on icon focus + background refresh. No session or a transient API error both return nil (shelf falls back to the static brand asset).
///
/// `@objc(SodaliteTopShelfContentProvider)` pins an explicit Obj-C name so PluginKit's NSClassFromString lookup against NSExtensionPrincipalClass survives Swift name-mangling. The target also needs `OTHER_LDFLAGS = -e _NSExtensionMain` (Xcode sets it automatically, hand-rolled pbxproj targets do not).
@objc(SodaliteTopShelfContentProvider)
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard TopShelfEnabled.read() else {
            log.notice("Top Shelf switched off in Settings; rendering empty.")
            return nil
        }
        guard let sessions = ShelfSessions.read() else {
            log.notice("No shared session in keychain; TopShelf will render empty.")
            return nil
        }
        let session = sessions.active

        // Shows hidden from Home's rows stay off the shelf too; the server knows nothing of them.
        // The cache is read on the failure path only, which keeps the extension's tight budget
        // clear of a read + decode a healthy load has no use for.
        let feed = await TopShelfFeed.load(sessions: sessions,
                                           hidden: TopShelfHiddenShows.read(),
                                           cache: { TopShelfCache.usable(for: session) })
        let resumeItems = feed.resume
        let nextUpItems = feed.nextUp
        log.info("Fetched resume=\(resumeItems.count) nextUp=\(nextUpItems.count) servers=\(sessions.all.count) usedCache=\(feed.usedCache)")

        // Writes the merged view, not just what came back, so a partial failure still leaves
        // both sections populated for the next total failure.
        if TopShelfCachePolicy.shouldWrite(resumeSucceeded: feed.resumeFetched,
                                           nextUpSucceeded: feed.nextUpFetched) {
            TopShelfCache(serverURL: session.baseURL.absoluteString,
                          userID: session.userID,
                          resume: resumeItems,
                          nextUp: nextUpItems).write()
        }

        // Every cell of both rows, bar or no bar, and only what the app has already rendered: either
        // every cell is a local file or the row keeps its remote artwork with the system bar, never a
        // mix (Sodalite#128). The extension does not render; see `ResumeBarArtwork.existing`.
        let artwork = TopShelfArtwork.read()
        let titleVeil = TopShelfTitleVeil.read()
        let bars = ResumeBarArtwork.existing(cells: (resumeItems + nextUpItems)
                                                 .compactMap { $0.artworkCell(session: sessions.session(for: $0), artwork: artwork) },
                                             accent: TopShelfAccent.read())
        log.info("shelf artwork local=\(bars.count)")

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        if !resumeItems.isEmpty {
            let collection = TVTopShelfItemCollection(items: resumeItems.map {
                makeItem(item: $0, session: sessions.session(for: $0), barURL: bars[$0.shelfKey], artwork: artwork, titleVeil: titleVeil)
            })
            collection.title = String(
                localized: "TopShelf.ContinueWatching",
                defaultValue: "Continue Watching"
            )
            sections.append(collection)
        }

        if !nextUpItems.isEmpty {
            let collection = TVTopShelfItemCollection(items: nextUpItems.map {
                makeItem(item: $0, session: sessions.session(for: $0), barURL: bars[$0.shelfKey], artwork: artwork, titleVeil: titleVeil)
            })
            collection.title = String(
                localized: "TopShelf.NextUp",
                defaultValue: "Next Up"
            )
            sections.append(collection)
        }

        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }


    /// `barURL` is artwork with the resume bar already drawn in. When it exists the system's own
    /// `playbackProgress` stays unset, otherwise the shelf stacks two bars on the same cell.
    private func makeItem(item: TopShelfItem,
                          session: SharedSession,
                          barURL: URL?,
                          artwork: TopShelfArtwork.Choice,
                          titleVeil: TopShelfTitleVeil) -> TVTopShelfSectionedItem {
        let cell = TVTopShelfSectionedItem(identifier: item.shelfKey)
        cell.title = item.topShelfTitle(veil: titleVeil)
        cell.imageShape = .hdtv
        // Both actions play. A shelf cell is an invitation to keep watching, not a link to a
        // page, and nobody guesses that the detail route hides behind Select while Play starts.
        let play = TVTopShelfAction(url: playLink(for: item))
        cell.displayAction = play
        cell.playAction = play
        if barURL == nil, let progress = item.topShelfProgress {
            cell.playbackProgress = progress
        }

        let remote = item.topShelfImageURL(baseURL: session.baseURL,
                                           token: session.accessToken,
                                           artwork: artwork)
        if let url = barURL ?? remote {
            // 2x is the only scale Apple TV renders; setting both 1x and 2x doubles the daemon's fetch work and trips memory pressure surfacing as "-17102 decompressing image" when cells race to decode.
            cell.setImageURL(url, for: .screenScale2x)
        } else {
            log.notice("cell \(item.id) has no image URL")
        }
        return cell
    }

    /// `sodalite://play/{id}`: the main app's `onOpenURL` opens the item's detail route and starts playback on arrival. The app still understands `sodalite://item/{id}` (detail without playing), the shelf just has no use for it.
    /// An item from another server of a combined shelf names it in `?server=` (Sodalite#218), so the app asks that server rather than the active one.
    private func playLink(for item: TopShelfItem) -> URL {
        let server = item.sourceServerID.map { "?server=\($0)" } ?? ""
        return URL(string: "sodalite://play/\(item.id)\(server)")!
    }
}
