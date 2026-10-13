import SwiftUI

/// The top of Home: the profile's HomeHeroMode titles as a full-width banner that pages by itself,
/// the way the TV app opens. The art runs to the window's top edge under the toolbar; the title, a
/// line of facts, the overview and Play sit over a scrim at the bottom leading corner. An upright
/// iPhone gets its own shape: the poster standing up, the text centred under it.
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

    @State private var index = 0
    /// The pointer is over the banner, or on tvOS focus is on its buttons; either way it holds still.
    @State private var isHovering = false
    #if os(tvOS)
    @FocusState private var buttonsFocused: Bool
    #endif
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
    @State private var readyKeys: Set<String> = []
    @State private var palettes: [String: ArtworkPalette] = [:]
    /// The page being left, kept fully opaque underneath while the new one fades in over it, so the
    /// change never uncovers what lies behind the banner.
    @State private var outgoing: JellyfinItem?

    private var isCompact: Bool { hSizeClass == .compact }

    /// An iPhone held upright. A backdrop cropped to that width is a sliver of a face, so this shape
    /// trades it for the poster. Landscape iPhones and compact iPad windows keep the wide banner.
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
                        ForEach([outgoing, current].compactMap { $0 }, id: \.originKey) { item in
                            artworkLayer(for: item)
                                // One picture per page before it fades: without it the opacity lands on
                                // the artwork, the colour strip and both dissolves separately, and half
                                // a dissolve over half a poster let the art show through both seams.
                                .compositingGroup()
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                        }
                    }
                    .padding(.top, -topExtension)
                    .overlay(alignment: .bottom) {
                        if isPortrait { portraitTail(near: palette(for: current).near) }
                    }
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
                                .padding(.bottom, 52)
                        }
                    }
                    .id(current.originKey)
                    .transition(.opacity)
                }
                .overlay(alignment: .bottom) {
                    pager.padding(.bottom, isPortrait ? 12 : 20)
                }
                .overlay { if !isPortrait { arrows } }
                #if os(tvOS)
                // Focus stands in for the pointer: a page change rebuilds the buttons, which would
                // throw focus off the one the viewer is on.
                .onChange(of: buttonsFocused) { _, focused in isHovering = focused }
                #else
                .contentShape(Rectangle())
                .onTapGesture { onOpen(current) }
                .mediaContextMenu(for: current) { onOpen(current) }
                .onHover { isHovering = $0 }
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
                // Restarted by every page change, so a click on an arrow gets a full dwell before the
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
                .onChange(of: items.map(\.originKey)) { _, _ in show(0) }
                // Every page is made ready as soon as the banner knows its titles, the one on screen
                // first, so paging never waits on the network or on a colour still being read.
                .task(id: "\(items.map(\.originKey))|\(isPortrait)") {
                    readyKeys = []
                    palettes = [:]
                    await prepare(current)
                    let rest = items.dropFirst(index + 1) + items.prefix(index)
                    await ImageCache.prefetch(rest.compactMap(artworkURL(for:)), auth: imageAuth)
                    for item in rest {
                        guard !Task.isCancelled else { return }
                        await prepare(item)
                    }
                }
        }
    }

    // MARK: - Layers

    /// A placeholder sized off the window, or upright off the width on an iPhone held that way.
    @ViewBuilder
    private var bannerBox: some View {
        if isPortrait {
            // 4:5 holds a 2:3 poster with little lost at the sides and leaves the first row in view.
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
        isPortrait ? (posterURL(item) ?? backdropURL(item)) : backdropURL(item)
    }

    private var imageAuth: ImageAuth { ImageAuth.snapshot(dependencies.sessionRegistry) }

    /// Decodes a page's art into `ImageCache` (or finds it there) and reads its colour, then marks it
    /// ready. Both land together, so the art and the colour it dissolves into appear in one step.
    private func prepare(_ item: JellyfinItem) async {
        let key = item.originKey
        guard let url = artworkURL(for: item) else { return }
        if readyKeys.contains(key), ImageCache.shared.image(for: url) != nil { return }
        if ImageCache.shared.image(for: url) == nil {
            await ImageCache.prefetch([url], auth: imageAuth)
        }
        guard let image = ImageCache.shared.image(for: url) else { return }
        let palette = await Task.detached(priority: .userInitiated) {
            ArtworkTint.bottomEdgePalette(of: image)
        }.value
        withAnimation(.easeIn(duration: 0.3)) {
            if let palette { palettes[key] = palette }
            readyKeys.insert(key)
        }
    }

    @ViewBuilder
    private func artworkLayer(for item: JellyfinItem) -> some View {
        if isPortrait {
            portraitArtwork(for: item)
        } else {
            ZStack {
                backdrop(for: item)
                scrim
            }
        }
    }

    private func backdrop(for item: JellyfinItem, alignment: Alignment = .center) -> some View {
        let image = readyKeys.contains(item.originKey)
            ? artworkURL(for: item).flatMap { ImageCache.shared.image(for: $0) }
            : nil
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

    private var scrim: some View {
        ZStack {
            LinearGradient(
                stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            LinearGradient(
                stops: [.init(color: .black.opacity(0.6), location: 0), .init(color: .clear, location: 0.55)],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
    }

    /// The upright iPhone's text: logo, facts and the two buttons, centred. No overview, the poster
    /// already says what the title is and two lines of it would push Play off the art.
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
            }

            heroButtons(for: item)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .environment(\.serverSession, item.serverID.map { dependencies.sessionRegistry.session(forServerID: $0) })
    }

    private func details(for item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ContentLogoTitle(
                itemID: item.id,
                logo: .from(imageTags: item.imageTags, hasFullDetail: true)
            ) {
                Text(item.name)
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(2)
            }
            .frame(maxWidth: 420, maxHeight: 130, alignment: .bottomLeading)

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

            #if os(tvOS)
            // The system styles, because they carry the focus lift a remote needs to see where it is.
            HStack(spacing: 24) {
                Button { onPlay(item) } label: {
                    Label("detail.play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button { onOpen(item) } label: {
                    Image(systemName: "info")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text(verbatim: item.name))
            }
            .focused($buttonsFocused)
            .focusSection()
            .padding(.top, 8)
            #else
            heroButtons(for: item)
                .padding(.top, 4)
            #endif
        }
        .foregroundStyle(.white)
        // The serverSession a combined Home's secondary title needs for its logo request.
        .environment(\.serverSession, item.serverID.map { dependencies.sessionRegistry.session(forServerID: $0) })
    }

    #if !os(tvOS)
    private func heroButtons(for item: JellyfinItem) -> some View {
        HStack(spacing: 12) {
            Button {
                onPlay(item)
            } label: {
                Label("detail.play", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .foregroundStyle(.black)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                onOpen(item)
            } label: {
                Image(systemName: "info")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.name))
        }
    }
    #else
    private func heroButtons(for item: JellyfinItem) -> some View { EmptyView() }
    #endif

    @ViewBuilder
    private var pager: some View {
        if items.count > 1 {
            HStack(spacing: 8) {
                ForEach(items.indices, id: \.self) { page in
                    pagerMark(isCurrent: page == index)
                        .contentShape(Rectangle().inset(by: -4))
                        #if !os(tvOS)
                        .onTapGesture { show(page) }
                        #endif
                }
            }
        }
    }

    /// A dot, or for the page on screen a short track that fills until the banner moves on.
    private func pagerMark(isCurrent: Bool) -> some View {
        Capsule()
            .fill(.white.opacity(0.4))
            .frame(width: isCurrent ? 26 : 7, height: 7)
            .overlay(alignment: .leading) {
                if isCurrent {
                    TimelineView(.animation(paused: dwellRunningSince == nil)) { context in
                        Capsule()
                            .fill(.white)
                            .frame(width: max(7, 26 * dwellProgress(at: context.date)))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isCurrent)
    }

    private func dwellProgress(at date: Date) -> CGFloat {
        let running = dwellRunningSince.map { date.timeIntervalSince($0) } ?? 0
        return CGFloat(min(1, (dwellSpent + running) / Self.dwell))
    }

    /// The upright iPhone's artwork. The poster hangs from just under the Dynamic Island, top edge
    /// first, so its top (where most posters carry their title) is never behind the island or the
    /// corner buttons; the overflow is cropped at the bottom, under the dissolve. Behind the island
    /// sits a heavily blurred copy of the same art, and the poster emerges out of it. The bottom follows the detail page's recipe (DetailBackdrop's heroBand, tuned on
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

    private static let portraitTail: CGFloat = 160

    /// The colour handing over to the page's own background below the banner, behind the first row.
    /// One for the banner rather than one per page: it is the only part of a page that is see-through,
    /// so two pages' tails stacked during a change read darker, and the old one vanishing when its
    /// page was removed made the hand-over jump. A single one changes its colour instead.
    private func portraitTail(near: Color) -> some View {
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
        .frame(height: Self.portraitTail)
        .offset(y: Self.portraitTail)
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
        palettes[item.originKey] ?? .base
    }

    @ViewBuilder
    private var arrows: some View {
        #if !os(tvOS)
        if items.count > 1 {
            HStack {
                arrow("chevron.left") { step(-1) }
                Spacer()
                arrow("chevron.right") { step(1) }
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isHovering)
        }
        #endif
    }

    private func arrow(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 88)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        show((index + delta + items.count) % items.count)
    }

    /// Every page change goes through here, so each page starts its dwell from zero. The page being
    /// left stays underneath, opaque, until the new one has faded in over it.
    private func show(_ page: Int) {
        dwellSpent = 0
        dwellRunningSince = nil
        guard page != index, items.indices.contains(page), let leaving = current else {
            index = page
            return
        }
        let target = items[page]
        // Evicted from the cache since it was read: fetch it again, it fades in over its colour.
        if let url = artworkURL(for: target), ImageCache.shared.image(for: url) == nil {
            readyKeys.remove(target.originKey)
            Task { await prepare(target) }
        }
        outgoing = leaving
        withAnimation(.easeInOut(duration: 0.6)) {
            index = page
        } completion: {
            if outgoing?.originKey == leaving.originKey { outgoing = nil }
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
