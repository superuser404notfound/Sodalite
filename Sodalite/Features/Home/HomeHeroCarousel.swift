import SwiftUI

/// The top of Home: the profile's HomeHeroMode titles as a full-width banner that pages by itself,
/// the way the TV app opens. The art runs to the window's top edge under the toolbar; the title, a
/// line of facts, the overview (not on tvOS) and Play sit at the bottom leading corner. An upright
/// iPhone gets its own shape: a tall crop of the backdrop, the text centred over its foot.
struct HomeHeroCarousel: View {
    let items: [JellyfinItem]
    let backdropURL: (JellyfinItem) -> URL?
    let posterURL: (JellyfinItem) -> URL?
    let onOpen: (JellyfinItem) -> Void
    let onPlay: (JellyfinItem) -> Void

    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var vSizeClass
    #endif

    @State private var index: Int

    init(
        items: [JellyfinItem],
        backdropURL: @escaping (JellyfinItem) -> URL?,
        posterURL: @escaping (JellyfinItem) -> URL?,
        onOpen: @escaping (JellyfinItem) -> Void,
        onPlay: @escaping (JellyfinItem) -> Void
    ) {
        self.items = items
        self.backdropURL = backdropURL
        self.posterURL = posterURL
        self.onOpen = onOpen
        self.onPlay = onPlay
        // A rebuilt banner (a return to the Home tab) picks up on the page it was showing.
        let remembered = Self.rememberedPage[Self.pageMemoryKey(items)] ?? 0
        _index = State(initialValue: items.indices.contains(remembered) ? remembered : 0)
    }

    /// The page each set of titles was last on, and each artwork's colour, for this run of the app,
    /// so a rebuilt banner shows the same page in the same colour on its first frame.
    private static var rememberedPage: [String: Int] = [:]
    private static var rememberedPalettes: [URL: ArtworkPalette] = [:]

    private static func pageMemoryKey(_ items: [JellyfinItem]) -> String {
        items.map(\.originKey).joined(separator: ",")
    }

    /// The pointer is over the banner, or on tvOS focus is on its buttons; either way it holds still.
    @State private var isHovering = false
    #if os(tvOS)
    private enum HeroFocus: Hashable { case play, info, page(Int) }
    @FocusState private var focus: HeroFocus?
    @State private var claimedOpeningFocus = false
    #endif
    /// The sidebar shell's rail slot, which the art reaches back under so it fills the screen.
    @Environment(\.shellLeadingSlot) private var leadingSlot
    /// How far below the window's top edge the banner starts: the toolbar's inset plus the stack
    /// spacing above it, and more while the page is pulled past its top. The art grows upward by
    /// exactly that. Measured in window space because every scroll-relative reading falls short:
    /// the top safe area is zero inside the scroll view, the content inset misses the spacing, and
    /// the `.scrollView` space starts below the inset, so it saw only the 8pt of spacing.
    @State private var topExtension: CGFloat = 0

    /// Long enough to read an overview, short enough that the banner visibly moves.
    private static let dwell: TimeInterval = 8
    /// The dwell already spent on this page before a pause, so a pause holds the timing line where it
    /// is instead of starting it over.
    @State private var dwellSpent: TimeInterval = 0
    /// When the running stretch of the dwell began; nil while paused or with a single page.
    @State private var dwellRunningSince: Date?

    /// Pages whose artwork is decoded in `ImageCache` and whose colour has been read. A page is drawn
    /// from here, never through `AsyncCachedImage`: that view starts every new URL empty and fades the
    /// image in, so a page change showed the placeholder, then the art, then the colour, each on its
    /// own clock, and the seams of the top and bottom transitions flickered black in between.
    /// Decoded art held for the pages around the one on screen (see `trimHeld`). Held here, not only
    /// in `ImageCache`: that cache may drop an image under memory pressure, and a page read from it on
    /// every redraw then fell back to its placeholder until the banner was rebuilt by scrolling away.
    @State private var held: [String: PlatformImage] = [:]
    @State private var palettes: [String: ArtworkPalette] = [:]
    /// One drawn page. Every change adds a new one with an identity of its own, even when it shows a
    /// title that is already underneath: keyed by the title, paging back and forth quickly brought a
    /// half faded-in layer forward instead of fading a fresh one in, and two see-through layers with
    /// nothing opaque under them made the dissolves look cut off.
    private struct HeroLayer: Identifiable {
        var id = UUID()
        let item: JellyfinItem
    }
    /// Oldest first, the newest fading in on top. The oldest is always a finished, opaque page, since
    /// layers are only cleared once the latest change has completed. Empty at rest: then the page on
    /// screen is drawn as the one `baseLayerID` layer.
    @State private var layers: [HeroLayer] = []
    @State private var baseLayerID = UUID()
    /// Which change is the latest, so only its completion clears the layers beneath it.
    @State private var changeGeneration = 0

    private var isCompact: Bool { hSizeClass == .compact }

    /// An iPhone held upright, which crops the backdrop to a tall box. Landscape iPhones and compact
    /// iPad windows keep the wide banner.
    private var isPortrait: Bool {
        #if os(iOS)
        isCompact && vSizeClass == .regular
        #else
        false
        #endif
    }

    private var titleSize: CGFloat {
        #if os(tvOS)
        64
        #else
        isCompact ? 28 : 40
        #endif
    }

    private var current: JellyfinItem? {
        items.indices.contains(index) ? items[index] : items.first
    }

    var body: some View {
        // A ZStack rather than a bare `if`, so the modifier below exists while there is no banner yet.
        ZStack {
            banner
        }
        #if os(tvOS)
        // A cold start paints the rows from their feed cache before the banner has titles (its
        // memory lasts one run of the app), so tvOS put the opening focus on the first card. When the
        // titles arrive into a banner that started empty, focus goes to Play once; a banner rebuilt
        // on a tab return already has them and leaves focus where the system puts it.
        .onChange(of: items.isEmpty) { _, isEmpty in
            guard !isEmpty, !claimedOpeningFocus else { return }
            claimedOpeningFocus = true
            Task { @MainActor in focus = .play }
        }
        #endif
    }

    @ViewBuilder
    private var banner: some View {
        if let current {
            // The box is a placeholder sized off the window, and everything else is laid onto it, so
            // the art, the text and the pager all agree on one height. Built the other way round, the
            // filled backdrop picked the size and the clip cut the buttons and the dots off the bottom.
            bannerBox
                // Up under the transparent toolbar, the way the TV app's banner reaches the window's
                // top edge. Pinned to the bottom: `ignoresSafeArea` inside a scroll view let the art
                // hang below the banner as well.
                .background(alignment: .bottom) {
                    ZStack {
                        ForEach(layers.isEmpty ? [HeroLayer(id: baseLayerID, item: current)] : layers) { layer in
                            // The top layer always draws the page on screen, the one whose text and
                            // buttons sit over it; only the layers beneath it draw what they were
                            // made with. Stored for the top as well, a reshuffled title list could
                            // leave one title's art under another's name.
                            artworkLayer(for: layer.id == layers.last?.id ? current : layer.item)
                                // One picture per page before it fades: without it the opacity lands on
                                // the artwork, the colour strip and both dissolves separately, and half
                                // a dissolve over half a poster let the art show through both seams.
                                .compositingGroup()
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        }
                    }
                    .padding(.top, -(topExtension + artShift))
                    .overlay(alignment: .bottom) {
                        tail(near: palette(for: current).near)
                    }
                    // The wide banner's whole composition, art, dissolve and tail unchanged, sits this
                    // much lower, toward the first row, so more of the picture shows above the
                    // dissolve. Drawn taller at the top by the same amount, so it still meets the
                    // screen's edge. Moved as one, because stretching only the art pulled the dissolve
                    // and the tail apart and cut both.
                    .offset(y: artShift)
                    // Edge to edge: the rows keep the overscan margin on tvOS, the art does not, and
                    // with the sidebar it runs on under the rail.
                    .padding(.leading, -leadingSlot)
                    .ignoresSafeArea(edges: .horizontal)
                }
                .onGeometryChange(for: CGFloat.self) { max(0, $0.frame(in: .global).minY) } action: {
                    topExtension = $0
                }
                .overlay(alignment: isPortrait ? .bottom : .bottomLeading) {
                    Group {
                        if isPortrait {
                            portraitDetails(for: current)
                                .padding(.horizontal, LayoutMetrics.current(hSizeClass).rowInset)
                                .padding(.bottom, 36)
                        } else {
                            details(for: current)
                                // Lined up with the rows' titles below it.
                                .padding(.leading, LayoutMetrics.current(hSizeClass).rowInset)
                                .padding(.trailing, isCompact ? LayoutMetrics.current(hSizeClass).rowInset : 160)
                                // Lower by part of the art's shift, so the text keeps its place
                                // on the picture rather than floating up into it.
                                .padding(.bottom, 52 - artShift * 0.375)
                        }
                    }
                    #if !os(tvOS)
                    .id(current.originKey)
                    .transition(.opacity)
                    #endif
                }
                .overlay(alignment: .bottom) {
                    // Upright iPhone only: in the wide banner the dots sit under the buttons (see
                    // `details`), where the floating tab bar of an iPad cannot cover them.
                    // Below the box's edge, in the dissolve: the glass pill made the row tall enough
                    // to touch Play from where the bare dots used to sit.
                    if isPortrait { pager.padding(.bottom, -12) }
                }
                #if os(tvOS)
                // Focus stands in for the pointer: a page change rebuilds the buttons, which would
                // throw focus off the one the viewer is on.
                .onChange(of: focus) { old, new in handleFocusChange(from: old, to: new) }
                // The whole banner width is one section, so Up from any card in the first row lands on
                // the buttons; with only the buttons' own frame to aim at, the focus engine found
                // nothing above a card to their right and Up did nothing until the row was scrolled
                // back to its start.
                .focusSection()
                // The remote's Play starts the page on screen from anywhere in the banner, the way it
                // does on a focused card (Sodalite#196); without it the press went to the music toggle
                // at the tab root (Sodalite#205).
                .onPlayPauseCommandCompat {
                    let music = dependencies.musicPlaybackCoordinator
                    if music.currentItem != nil {
                        music.togglePlayPause()
                    } else {
                        onPlay(current)
                    }
                }
                #else
                .contentShape(Rectangle())
                .onTapGesture { onOpen(current) }
                .mediaContextMenu(for: current) { onOpen($0) }
                // The buttons are gone on touch, so the two actions they carried stay reachable here.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpen(current) }
                .accessibilityAction(named: Text("detail.play")) { onPlay(current) }
                .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
                #endif
                #if os(iOS)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24).onEnded { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height),
                              abs(drag.translation.width) > 40 else { return }
                        step(drag.translation.width < 0 ? 1 : -1)
                    }
                )
                #endif
                .animation(.easeInOut(duration: 0.6), value: index)
                // Restarted by every page change, so a click on a dot gets a full dwell before the
                // banner moves on by itself. Paused while the pointer is over it, so nothing slides
                // away from under someone reading it, and resumed with what was left.
                .task(id: "\(index)|\(isHovering)|\(items.count)") {
                    guard !isHovering, items.count > 1 else {
                        dwellRunningSince = nil
                        return
                    }
                    dwellRunningSince = .now
                    try? await Task.sleep(for: .seconds(max(0, Self.dwell - dwellSpent)))
                    guard !Task.isCancelled else { return }
                    // A page whose art is still on its way would fade in as a dark slab first.
                    await prepare(items[(index + 1) % items.count])
                    guard !Task.isCancelled else { return }
                    step(1)
                }
                .onChange(of: isHovering) { _, paused in
                    guard paused, let since = dwellRunningSince else { return }
                    dwellSpent += Date.now.timeIntervalSince(since)
                    dwellRunningSince = nil
                }
                .onChange(of: items.map(\.originKey)) { _, _ in
                    layers = []
                    show(0)
                }
                // Every page is made ready as soon as the banner knows its titles, the one on screen
                // first, so paging never waits on the network or on a colour still being read.
                .task(id: "\(items.map(\.originKey))|\(isPortrait)") {
                    held = [:]
                    palettes = [:]
                    await prepare(current)
                    let rest = Array(items.dropFirst(index + 1) + items.prefix(index))
                    if let next = rest.first { await prepare(next) }
                    // The others only into the cache and for their colour; they are held once they
                    // come next to the page on screen.
                    for item in rest.dropFirst() {
                        guard !Task.isCancelled else { return }
                        _ = await loadArt(for: item)
                    }
                }
        }
    }

    // MARK: - Layers

    /// A placeholder sized off the window, or upright off the width on an iPhone held that way.
    @ViewBuilder
    private var bannerBox: some View {
        if isPortrait {
            // 4:5 leaves the first row in view and still holds a 2:3 poster, the fallback, with little lost.
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            Color.clear
                .containerRelativeFrame(.vertical) { height, _ in
                    isCompact ? max(320, height * 0.5) : max(440, height * 0.66)
                }
                .frame(maxWidth: .infinity)
        }
    }

    private func artworkURL(for item: JellyfinItem) -> URL? {
        // The poster only where there is no backdrop: most carry the title printed at the foot, right
        // where the logo and the facts go, and the two titles stacked (Blexbi).
        isPortrait ? (backdropURL(item) ?? posterURL(item)) : backdropURL(item)
    }

    private var imageAuth: ImageAuth { ImageAuth.snapshot(dependencies.sessionRegistry) }

    /// Holds a page's art and its colour, so both appear in one step.
    private func prepare(_ item: JellyfinItem) async {
        let key = item.originKey
        guard held[key] == nil, let image = await loadArt(for: item) else { return }
        withAnimation(.easeIn(duration: 0.3)) {
            held[key] = image
        }
    }

    /// The page's art from `ImageCache`, fetched (three tries, the way `AsyncCachedImage` retries)
    /// when the cache does not have it, with its colour read once. Nil only when every try failed;
    /// the next page change or auto-advance asks again.
    private func loadArt(for item: JellyfinItem) async -> PlatformImage? {
        guard let url = artworkURL(for: item) else { return nil }
        var image = ImageCache.shared.image(for: url)
        for delay in [0, 1, 3] where image == nil {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return nil }
            await ImageCache.prefetch([url], auth: imageAuth)
            image = ImageCache.shared.image(for: url)
        }
        guard let image else { return nil }
        let key = item.originKey
        if palettes[key] == nil {
            let palette = await Task.detached(priority: .userInitiated) {
                ArtworkTint.bottomEdgePalette(of: image)
            }.value
            if let palette {
                Self.rememberedPalettes[url] = palette
                withAnimation(.easeIn(duration: 0.3)) { palettes[key] = palette }
            }
        }
        return image
    }

    /// Keeps the page on screen, its neighbours and the page fading out, and lets the rest go back
    /// to living in `ImageCache` alone: eight held 1920 px backdrops are some 66 MB on an Apple TV.
    private func trimHeld() {
        guard !items.isEmpty else { return }
        var keep: Set<String> = [items[index].originKey]
        keep.insert(items[(index + 1) % items.count].originKey)
        keep.insert(items[(index - 1 + items.count) % items.count].originKey)
        keep.formUnion(layers.map(\.item.originKey))
        held = held.filter { keep.contains($0.key) }
    }

    @ViewBuilder
    private func artworkLayer(for item: JellyfinItem) -> some View {
        if isPortrait {
            portraitArtwork(for: item)
        } else {
            wideArtwork(for: item)
        }
    }

    private func backdrop(for item: JellyfinItem, alignment: Alignment = .center) -> some View {
        // Held first; on a rebuilt banner's first frames, before `prepare` has held anything, the
        // cache's copy, so the page is there at once instead of fading in over its placeholder.
        let image = held[item.originKey] ?? artworkURL(for: item).flatMap { ImageCache.shared.image(for: $0) }
        // The art lies over a surface that takes exactly the space it is offered. Framed directly, a
        // filled image grows its frame to the overflow, the page outgrew the banner, and centring it
        // pushed the strip and the art up under the island by however far that poster's shape ran over.
        return Color.clear
            .overlay(alignment: alignment) {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    isPortrait ? palette(for: item).near : Color.black
                }
            }
            .clipped()
    }

    /// The wide banner (iPad, Apple TV, Mac, a landscape iPhone), on the upright iPhone's recipe: the
    /// backdrop dissolves at the bottom into its own colour, which the shared tail hands over to the
    /// page. The text needs no shade on the art, it sits in a glass panel (see `detailsText`).
    private func wideArtwork(for item: JellyfinItem) -> some View {
        let near = palette(for: item).near
        return backdrop(for: item)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: near.opacity(0), location: 0),
                        .init(color: near.opacity(0.12), location: 0.30),
                        .init(color: near.opacity(0.45), location: 0.58),
                        .init(color: near.opacity(0.85), location: 0.82),
                        .init(color: near, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Self.wideBottomDissolve)
            }
            .animation(.easeInOut(duration: 0.4), value: near)
            .allowsHitTesting(false)
    }

    private static var wideBottomDissolve: CGFloat {
        #if os(tvOS)
        360
        #else
        240
        #endif
    }

    private var artShift: CGFloat {
        guard !isPortrait else { return 0 }
        #if os(tvOS)
        return 160
        #else
        return 80
        #endif
    }

    /// The upright iPhone's text: logo, facts and two lines of the overview, centred. No buttons on
    /// touch (Blexbi): the banner itself opens the title, and its hold menu carries Play.
    private func portraitDetails(for item: JellyfinItem) -> some View {
        VStack(spacing: 12) {
            ContentLogoTitle(
                itemID: item.id,
                logo: .from(imageTags: item.imageTags, hasFullDetail: true)
            ) {
                Text(item.name)
                    .font(.system(size: titleSize, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: 260, maxHeight: 90, alignment: .bottom)

            if let facts = facts(for: item) {
                Text(verbatim: facts)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    // The same glass the wide banner's panel and the detail page carry.
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
            }

            if let overview = item.overview, !overview.isEmpty {
                Text(verbatim: overview)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .environment(\.serverSession, item.serverID.map { dependencies.sessionRegistry.session(forServerID: $0) })
    }

    private func details(for item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            detailsText(for: item)
                #if os(tvOS)
                // Only the text changes with the page: the buttons stay the same views, so focus
                // stays on the one the viewer is on while Left and Right page through the banner.
                .id(item.originKey)
                .transition(.opacity)
                #endif
            #if os(tvOS)
            tvButtons(for: item)
                .padding(.top, 8)
            #else
            pager
                .padding(.leading, 8)
                .padding(.top, 4)
            #endif
        }
        .foregroundStyle(.white)
        // The serverSession a combined Home's secondary title needs for its logo request.
        .environment(\.serverSession, item.serverID.map { dependencies.sessionRegistry.session(forServerID: $0) })
    }

    private func detailsText(for item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The component sizes the mark off this column (42% of it on tvOS) and lends it the detail
            // page's glow and drop shadow. On tvOS the column is wider than elsewhere: at 420 pt the
            // marks came out some 176 pt wide, small from a sofa, while the detail page's full column
            // would make the banner's mark as big as the page's own.
            ContentLogoTitle(
                itemID: item.id,
                logo: .from(imageTags: item.imageTags, hasFullDetail: true)
            ) {
                Text(item.name)
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(2)
            }
            .frame(maxWidth: Self.logoColumn.width, maxHeight: Self.logoColumn.height, alignment: .bottomLeading)

            #if os(tvOS)
            // The facts alone on tvOS (Sodalite#205): two lines of overview were cut off on almost
            // every title, and the detail page is one click away.
            if let facts = facts(for: item) {
                Text(verbatim: facts)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
            }
            #else
            // The detail page's glass panel (MovieDetailView.glassPanel): the facts and the overview
            // carry their own material, so the art needs no shade of its own to keep them legible.
            VStack(alignment: .leading, spacing: 10) {
                if let facts = facts(for: item) {
                    Text(verbatim: facts)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let overview = item.overview, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
            .padding(isCompact ? 16 : 30)
            .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
            #endif
        }
    }

    #if os(tvOS)
    /// The detail page's own buttons (GlassActionButton), so the banner's Play reads like every other
    /// Play in the app, and under them the page dots, which take focus: Left and Right on them page
    /// through the banner. They sit under the buttons rather than centred at the bottom, or Down from
    /// Play would aim past them into the rows.
    private func tvButtons(for item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 20) {
                GlassActionButton(title: "detail.play", systemImage: "play.fill", isProminent: true) {
                    onPlay(item)
                }
                .focused($focus, equals: .play)
                GlassActionButton(title: "detail.episode.showDetails", systemImage: "info") {
                    onOpen(item)
                }
                .focused($focus, equals: .info)
                // The detail page's trick (Sodalite#53): out of reach until focus is in the banner, so
                // coming in from outside the engine lands on Play (from below on the dots), rather than on the
                // nearer info button and being corrected afterwards, which twitched.
                .focusSuppressed(focus == nil)
            }
            .collapsesActionButtonLabel(true)
            pager
                .padding(.leading, 8)
                // The one reachable dot moves right with every page, and with few titles the pill
                // ends left of the info button, so Down from it fell into the rows (Sodalite#205).
                // A section the banner's width is under every button and over every card.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
    }

    /// Moving along the dots shows the page under focus. Where focus lands in the first place is
    /// decided by what is reachable (see the focusSuppressed calls), not corrected here.
    private func handleFocusChange(from old: HeroFocus?, to new: HeroFocus?) {
        // Only the dots hold the banner: the viewer is choosing there. On Play it keeps moving, as
        // the TV app's does, and since Home opens with focus on Play it never moved at all otherwise.
        isHovering = isOnDots
        if case .page(let page)? = new, page != index { show(page) }
    }

    private var isOnDots: Bool {
        if case .page? = focus { return true }
        return false
    }
    #endif


    @ViewBuilder
    private var pager: some View {
        if items.count > 1 {
            HStack(spacing: Self.dot * 8 / 7) {
                ForEach(items.indices, id: \.self) { page in
                    #if os(tvOS)
                    pagerMark(isCurrent: page == index)
                        .focusable()
                        .focused($focus, equals: .page(page))
                        // From outside the dots only the page on screen is reachable, so Up from the
                        // rows and Down from the buttons land on it; once there, every dot is.
                        .focusSuppressed(!isOnDots && page != index)
                    #else
                    pagerMark(isCurrent: page == index)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { show(page) }
                    #endif
                }
            }
            // The glass the text panel carries, so the dots read on bright art too. With the remote on
            // the dots the whole pill lifts, brighter and a little larger: the dot under focus is
            // always the page on screen, so a ring around that one dot only collided with its
            // neighbours.
            .padding(.horizontal, Self.dot * 1.4)
            .padding(.vertical, Self.dot)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.Theme.focusFill).opacity(pagerFocused ? 1 : 0))
            )
            // An accent ring round the whole pill while it has focus, the way the focused buttons
            // above it wear the accent, so it reads as selected from across the room.
            .overlay(Capsule().strokeBorder(.tint, lineWidth: 3).opacity(pagerFocused ? 1 : 0))
            .scaleEffect(pagerFocused ? 1.15 : 1)
            #if !os(tvOS)
            // Only the dots hold the banner for the pointer, as they do for the remote. Held for the
            // pointer anywhere over it, a banner filling most of a Mac window never moved, and even
            // the text and buttons were too much of it.
            .onHover { isHovering = $0 }
            #endif
            .animation(.easeInOut(duration: 0.2), value: pagerFocused)
        }
    }

    private var pagerFocused: Bool {
        #if os(tvOS)
        isOnDots
        #else
        false
        #endif
    }

    /// A dot's size; the line and the gaps scale with it. Larger on tvOS, read from across the room.
    private static var dot: CGFloat {
        #if os(tvOS)
        12
        #else
        7
        #endif
    }

    /// A dot, or for the page on screen a short track that fills until the banner moves on.
    private func pagerMark(isCurrent: Bool) -> some View {
        Capsule()
            .fill(.white.opacity(0.4))
            .frame(width: isCurrent ? Self.dot * 26 / 7 : Self.dot, height: Self.dot)
            .overlay(alignment: .leading) {
                if isCurrent {
                    TimelineView(.animation(paused: dwellRunningSince == nil)) { context in
                        Capsule()
                            .fill(.white)
                            .frame(width: max(Self.dot, Self.dot * 26 / 7 * dwellProgress(at: context.date)))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isCurrent)
    }

    private func dwellProgress(at date: Date) -> CGFloat {
        let running = dwellRunningSince.map { date.timeIntervalSince($0) } ?? 0
        return CGFloat(min(1, (dwellSpent + running) / Self.dwell))
    }

    /// The upright iPhone's artwork. The backdrop, cropped to the box's middle, hangs from just under
    /// the Dynamic Island, so nothing of it is behind the island or the corner buttons; a poster (the
    /// fallback) runs over at the bottom, cropped under the dissolve. Behind the island sits a heavily
    /// blurred copy of the same art, and the art emerges out of it. The bottom follows the detail page's recipe (DetailBackdrop's heroBand, tuned on
    /// the device): it dissolves into the artwork's colour, which then lets go into the page below.
    /// Every stop is that colour at some opacity, never `.clear`, which is transparent black and drags
    /// the art through a grey band on the way.
    private func portraitArtwork(for item: JellyfinItem) -> some View {
        let near = palette(for: item).near
        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                backdrop(for: item)
                    .blur(radius: 30, opaque: true)
                    // Keeps the clock legible on a bright poster.
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: safeTop)
                    }
                backdrop(for: item, alignment: .top)
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 28)
                            Color.black
                        }
                    }
                    .padding(.top, safeTop)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: near.opacity(0), location: 0),
                        .init(color: near.opacity(0.12), location: 0.30),
                        .init(color: near.opacity(0.45), location: 0.58),
                        .init(color: near.opacity(0.85), location: 0.82),
                        .init(color: near, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 220)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: near)
        .allowsHitTesting(false)
    }

    private static var logoColumn: CGSize {
        #if os(tvOS)
        CGSize(width: 680, height: 170)
        #else
        CGSize(width: 420, height: 130)
        #endif
    }

    private static var tailHeight: CGFloat {
        #if os(tvOS)
        240
        #else
        160
        #endif
    }

    /// The colour handing over to the page's own background below the banner, behind the first row.
    /// One for the banner rather than one per page: it is the only part of a page that is see-through,
    /// so two pages' tails stacked during a change read darker, and the old one vanishing when its
    /// page was removed made the hand-over jump. A single one changes its colour instead.
    private func tail(near: Color) -> some View {
        LinearGradient(
            stops: [
                .init(color: near, location: 0),
                .init(color: near.opacity(0.6), location: 0.30),
                .init(color: near.opacity(0.2), location: 0.65),
                .init(color: near.opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Self.tailHeight)
        .offset(y: Self.tailHeight)
        .animation(.easeInOut(duration: 0.6), value: near)
        .allowsHitTesting(false)
    }

    /// The status bar and Dynamic Island. Read from the key window: inside the scroll view the
    /// environment's top inset is already spent.
    private var safeTop: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 0
        #else
        0
        #endif
    }

    /// The artwork's colour once it has been read, black until then, so a page that has not been read
    /// yet is a dark banner rather than a seam.
    private func palette(for item: JellyfinItem) -> ArtworkPalette {
        palettes[item.originKey]
            ?? artworkURL(for: item).flatMap { Self.rememberedPalettes[$0] }
            ?? .base
    }

    // MARK: - Helpers

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        show((index + delta + items.count) % items.count)
    }

    /// Every page change goes through here, so each page starts its dwell from zero. The pages being
    /// left stay underneath until the latest change has faded in over them.
    private func show(_ page: Int) {
        dwellSpent = 0
        dwellRunningSince = nil
        #if !os(tvOS)
        // The details block is rebuilt for the new page, and a view removed under the pointer never
        // reports the pointer leaving it, which would hold the banner for good.
        isHovering = false
        #endif
        Self.rememberedPage[Self.pageMemoryKey(items)] = page
        guard page != index, items.indices.contains(page), let leaving = current else {
            index = page
            return
        }
        // The page at rest becomes the bottom layer under its own identity, so it does not redraw.
        if layers.isEmpty { layers = [HeroLayer(id: baseLayerID, item: leaving)] }
        changeGeneration += 1
        let generation = changeGeneration
        withAnimation(.easeInOut(duration: 0.6)) {
            index = page
            layers.append(HeroLayer(item: items[page]))
        } completion: {
            guard generation == changeGeneration, let top = layers.last else { return }
            layers = [top]
            trimHeld()
        }
        // The page shown (if it was not held yet, it fades in over its colour) and its neighbours.
        let around = [page, (page + 1) % items.count, (page - 1 + items.count) % items.count].map { items[$0] }
        Task {
            for item in around { await prepare(item) }
        }
    }

    /// "Movie · 2025 · Drama · Thriller · PG-13", with whatever the server knows.
    private func facts(for item: JellyfinItem) -> String? {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        parts += (item.genres ?? []).prefix(2)
        if let rating = item.officialRating, !rating.isEmpty { parts.append(rating) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
