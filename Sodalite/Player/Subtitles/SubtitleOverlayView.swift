import SwiftUI
import Combine
import AetherEngine
import SwiftAssRenderer

/// Renders subtitle cues at the current playback time. Text cues draw as
/// a styled box; image cues (PGS/DVB/HDMV) draw as bitmaps at normalised
/// positions (multiple can overlap). When `assRenderer` is non-nil the cue
/// pipeline is bypassed entirely: swift-ass-renderer draws the frame with
/// authored fonts/colors/positioning, so user styling/offset prefs don't apply.
struct SubtitleOverlayView: View {
    let cues: [SubtitleCue]
    let currentTime: Double
    /// Walk-back bound for active-cue lookup: longest cue duration in `cues`.
    let maxCueDuration: Double
    /// Secondary companion track cues (issue #47), text-only, rendered ABOVE primary.
    let secondaryCues: [SubtitleCue]
    let secondaryMaxCueDuration: Double
    let fontSize: PlaybackPreferences.SubtitleFontSize
    /// Foreground colour for text cues; bitmap cues bake colour from source and ignore it.
    let textColor: PlaybackPreferences.SubtitleColor
    let background: PlaybackPreferences.SubtitleBackground
    /// Timing offset in seconds applied to both text and image cues. Positive = subs later.
    let delaySeconds: Double
    /// Vertical position. `default` preserves historical text baseline (height − 100) and
    /// source-baked bitmap position; other cases anchor to a fraction of overlay height
    /// from the bottom and shift bitmap cues by the same delta, so one dial works for both.
    let verticalPosition: PlaybackPreferences.SubtitleVerticalPosition
    /// Subtitle font; only affects text cues (bitmap cues are pre-rendered by source decoder).
    let font: PlaybackPreferences.SubtitleFont
    let weight: PlaybackPreferences.SubtitleWeight
    /// While player chrome is visible, text cues snap to a fixed clearance above the UI
    /// (user vertical position is overridden); bitmap cues keep source-baked layout.
    let controlsVisible: Bool
    /// Non-nil exactly while an embedded ASS/SSA track is active AND swift-ass-renderer initialized.
    let assRenderer: AssSubtitlesRenderer?
    /// Reload pre-announcements from the ASS coordinator (see `ASSFrameHostView`'s nil suppression).
    let assReloadSignal: PassthroughSubject<Void, Never>
    /// Lowercased active subtitle codec ("ass"/"ssa"/"subrip"/...); drives the raw-event-line
    /// stripper for the fallback where an ASS track is active but the styled renderer bailed.
    let activeSubtitleCodec: String?

    /// While a secondary track is selected, the primary renders through the plain-text overlay
    /// (not libass) so both lines stack without overlap; libass positions ASS primaries opaquely
    /// so the secondary cannot reliably go above it (issue #47). Full ASS styling returns when off.
    let hasSecondaryTrack: Bool
    /// Coded video dims for bitmap-canvas mapping; .zero falls back to full-bounds layout.
    var videoSize: CGSize = .zero
    /// Which rectangle the picture actually occupies. `.fill` draws the video `.resizeAspectFill`,
    /// so the picture covers the surface and overflows it; cues placed against the picture have to
    /// follow it there instead of staying on the aspect-fit band the video would occupy in
    /// `.original` (#120).
    var pictureMode: PlaybackPreferences.PictureMode = .original

    /// Fixed bottom inset for text cues while controls are visible, above the 300 pt gradient band.
    private static let controlsVisibleBottomInset: CGFloat = 280

    /// A primary text line to render: plain (user-pref colour) or coloured runs (#107 teletext).
    private enum RenderLine: Identifiable {
        case plain(id: Int, text: String)
        case rich(id: Int, runs: [SubtitleTextRun])
        var id: Int { switch self { case .plain(let id, _): return id; case .rich(let id, _): return id } }
    }

    private func color(_ c: SubtitleColor) -> Color {
        Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }

    var body: some View {
        // libass styling used ONLY without a secondary track; with one the primary
        // falls back to the plain-text overlay so both share one stack (issue #47).
        if let assRenderer, !hasSecondaryTrack {
            ASSRenderedSubtitles(
                renderer: assRenderer,
                reloadSignal: assReloadSignal,
                currentOffset: currentTime
            )
            .allowsHitTesting(false)
        } else {
            cueOverlay
        }
    }

    private var cueOverlay: some View {
        ZStack {
            // Bitmap cues MUST lay out against a stable full-screen rect, not the
            // safe-area-inset rect: an audio-track switch reloads AVKit and transiently
            // grows safe-area insets, collapsing the GeometryReader height and squishing
            // the cue. `.ignoresSafeArea()` pins this layer to full screen; engine
            // normalized positions are plane-relative and map onto it correctly.
            GeometryReader { geo in
                Color.clear
                    .overlay(alignment: .topLeading) {
                        ForEach(activeCues(in: cues, maxDuration: maxCueDuration), id: \.id) { cue in
                            if case .image(let image) = cue.body {
                                imageOverlay(image, in: geo.size)
                            }
                        }
                    }
            }
            .ignoresSafeArea()

            // Text cues share ONE bottom-anchored stack so secondary sits above primary
            // regardless of wrap count (a fixed offset fails on a 2-line primary). Stays
            // safe-area-aware.
            GeometryReader { geo in
                Color.clear
                    .overlay(alignment: .topLeading) {
                        let activePrimary = activeCues(in: cues, maxDuration: maxCueDuration)
                        // A cue that asks for its own spot (AetherEngine #233: teletext pages,
                        // WebVTT cue settings, ASS `\an`/`\pos`) leaves the shared stack and is
                        // drawn where it asked. That also keeps it clear of the secondary track
                        // by construction, which is what the stack exists to guarantee (#47).
                        let placedCues = activePrimary.filter { $0.placement != nil && renderLine(for: $0) != nil }
                        let primaryRenderLines: [RenderLine] = activePrimary.compactMap { cue in
                            cue.placement == nil ? renderLine(for: cue) : nil
                        }
                        let secondaryLines: [String] = activeCues(in: secondaryCues, maxDuration: secondaryMaxCueDuration).compactMap { cue in
                            guard case .text(let raw) = cue.body, !raw.isEmpty else { return nil }
                            return raw
                        }
                        if !primaryRenderLines.isEmpty || !secondaryLines.isEmpty {
                            stackedText(
                                primary: primaryRenderLines,
                                secondary: secondaryLines,
                                in: geo.size,
                                safeAreaInsets: geo.safeAreaInsets
                            )
                        }
                        ForEach(placedCues, id: \.id) { cue in
                            placedText(cue, in: geo.size)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }

    /// True while the selected stream is ASS/SSA. In the cue path (styled renderer nil) the
    /// cue text bodies are still RAW event lines (`ReadOrder,Layer,...,Text`), stripped before display.
    private var isASSTrackActive: Bool {
        activeSubtitleCodec == "ass" || activeSubtitleCodec == "ssa"
    }

    /// Fallback when the styled renderer is unavailable: raw event lines
    /// must never reach the screen. Mirrors the engine's cleanASSBody.
    private func strippedASSText(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.split(separator: "\n") {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            // Integer ReadOrder gate so clean sidecar text with 8+ commas isn't truncated.
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, Int(fields[0]) != nil else { lines.append(String(line)); continue }
            var text = String(fields[8])
            text = text.replacingOccurrences(of: "\\N", with: "\n")
            text = text.replacingOccurrences(of: "\\n", with: "\n")
            text = text.replacingOccurrences(of: "\\h", with: " ")
            text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Text branch

    /// Point size and wrap width for text cues, shared by the stack and by placed cues so a cue
    /// does not change size depending on whether it carries a placement.
    private func textMetrics(in size: CGSize) -> (pointSize: CGFloat, maxWidth: CGFloat) {
        #if os(iOS)
        // 28pt is tuned for the ~1920pt-wide 10-foot tvOS screen; at iPhone/iPad sizes it reads far too
        // large (issue #14). /68 keeps the tvOS proportion (28/1920) at every width, so a wired external
        // display still lands on the cap and matches tvOS exactly, while phone/iPad shrink accordingly.
        // Floor is a hand-held legibility bound (portrait is far below the proportional size).
        let maxWidth = max(0, size.width - 120)
        let basePoints = min(28, max(12, size.width / 68))
        #else
        let maxWidth = max(0, size.width - 240)
        let basePoints: CGFloat = 28
        #endif
        return (basePoints * fontSize.scale, maxWidth)
    }

    /// Cue to renderable line, or nil when there is nothing to draw (empty body, bitmap cue).
    private func renderLine(for cue: SubtitleCue) -> RenderLine? {
        switch cue.body {
        case .richText(let runs):
            return runs.isEmpty ? nil : .rich(id: cue.id, runs: runs)
        case .text(let raw):
            let display = isASSTrackActive ? strippedASSText(raw) : raw
            return display.isEmpty ? nil : .plain(id: cue.id, text: display)
        case .image:
            return nil
        }
    }

    /// Render text cues as one bottom-anchored stack (secondary on top, primary below) so the
    /// secondary never overlaps a multi-line primary (the old fixed `pointSize * 2.4` lift did).
    private func stackedText(
        primary: [RenderLine],
        secondary: [String],
        in size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let (pointSize, maxWidth) = textMetrics(in: size)
        let placement = textBottomPlacement(in: size, safeAreaInsets: safeAreaInsets)
        return VStack(spacing: 10) {
            ForEach(Array(secondary.enumerated()), id: \.offset) { _, line in
                styledText(line, pointSize: pointSize)
            }
            ForEach(primary) { line in
                switch line {
                case .plain(_, let text): styledText(text, pointSize: pointSize)
                case .rich(_, let runs): styledRuns(runs, pointSize: pointSize)
                }
            }
        }
        .frame(maxWidth: maxWidth)
        .padding(.bottom, placement.padding)
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .offset(y: placement.offsetBelowSafeArea)
        .transition(.opacity)
    }

    /// Bottom-of-text-block distance from screen bottom as `(padding, offsetBelowSafeArea)`.
    /// `size` is safe-area-reduced (~60 pt vertically), so positions near the screen bottom
    /// bleed past the safe area into the letterbox via `.offset(y:)`; higher ones use padding.
    /// Fractions are taken against FULL screen height (not `size.height`, which put "Bottom
    /// Edge" ~70 pt up, above the letterbox); default keeps the historical ~80 pt gap.
    private func textBottomPlacement(in size: CGSize, safeAreaInsets: EdgeInsets) -> (padding: CGFloat, offsetBelowSafeArea: CGFloat) {
        if controlsVisible {
            return (Self.controlsVisibleBottomInset, 0)
        }
        if let fraction = verticalPosition.fractionFromBottom {
            let fullScreenHeight = size.height + safeAreaInsets.top + safeAreaInsets.bottom
            let desiredAboveScreenBottom = fullScreenHeight * CGFloat(fraction)
            let safeBottom = safeAreaInsets.bottom
            if desiredAboveScreenBottom >= safeBottom {
                return (desiredAboveScreenBottom - safeBottom, 0)
            }
            return (0, safeBottom - desiredAboveScreenBottom)
        }
        return (80, 0)
    }

    /// A cue drawn where it asked to be (AetherEngine #233), instead of in the shared bottom
    /// stack. Positioned like a bitmap cue: against the aspect-fit video band rather than the
    /// screen, and carrying the same vertical-position delta the user's dial gives bitmaps. The
    /// styling is identical to the stack's, since placement is geometry and not appearance.
    @ViewBuilder
    private func placedText(_ cue: SubtitleCue, in size: CGSize) -> some View {
        if let placement = cue.placement, let line = renderLine(for: cue) {
            let (pointSize, maxWidth) = textMetrics(in: size)
            let offset = Self.placedOffset(
                placement: placement,
                in: Self.videoRect(videoSize: videoSize, in: size,
                                   fillsSurface: pictureMode == .fill),
                container: size,
                margin: Self.placedMargin,
                verticalShift: bitmapVerticalShift(in: size),
                // Unlike a bitmap cue, a placed text cue still gets out of the chrome's way: on
                // teletext every cue carries a placement, so leaving them put would hide the
                // whole track behind the transport bar. Absent the chrome the limit is still the
                // bottom edge, since under `.fill` the picture runs past it (#120).
                bottomLimit: controlsVisible ? size.height - Self.controlsVisibleBottomInset : size.height,
                topLimit: 0)
            Group {
                switch line {
                case .plain(_, let text): styledText(text, pointSize: pointSize)
                case .rich(_, let runs): styledRuns(runs, pointSize: pointSize)
                }
            }
            .frame(maxWidth: maxWidth)
            .frame(width: size.width, height: size.height,
                   alignment: Self.placedAlignment(placement.alignment))
            .offset(x: offset.width, y: offset.height)
            .transition(.opacity)
        }
    }

    /// Edge inset for a placed cue with no `\pos`. Matches the stack's default bottom gap, so an
    /// `\an2` cue sits exactly where an unplaced one would.
    private static let placedMargin: CGFloat = 80

    /// Top-left origin for a text cue that carries its own placement (AetherEngine #233), in the
    /// coordinate space of `frame`. Mirrors `SubtitleFrameCompositor.blockOrigin` in the engine,
    /// translated to SwiftUI's top-down y axis, so the engine's compositor and this overlay put
    /// the same cue in the same spot.
    ///
    /// ASS numpad alignment: 1 to 3 bottom, 4 to 6 middle, 7 to 9 top, left to right within each
    /// row. With a `\pos` the point is the anchor and the alignment says which part of the block
    /// sits on it; without one the alignment picks a corner inset by `margin`. A missing or
    /// out-of-range alignment takes the ASS default of 2, which is exactly where unplaced cues
    /// sit, so a track carrying `\an` on only some of its cues does not make the text jump.
    ///
    /// An anchor outside the picture is ignored and the cue falls back to alignment-only, see
    /// `isDrawableAnchor`.
    ///
    /// `verticalShift` is the user's vertical-position dial, the same delta bitmap cues get.
    /// `bottomLimit` is the lowest the block may end, which lifts a low cue clear of the player
    /// chrome and leaves everything above it untouched. `topLimit` is the highest it may start,
    /// which holds a cue on screen when `.fill` pushes the picture past the top edge (#120); it
    /// wins over `bottomLimit`, since a block too tall for the gap is read from its first line.
    ///
    /// `placedOffset` calls this with a zero block size, because SwiftUI sizes the block itself
    /// there, so both limits act on the anchor rather than on the block's own edges.
    nonisolated static func placedOrigin(placement: SubtitleTextPlacement,
                                         blockSize: CGSize,
                                         in frame: CGRect,
                                         margin: CGFloat,
                                         verticalShift: CGFloat,
                                         bottomLimit: CGFloat,
                                         topLimit: CGFloat = -.infinity) -> CGPoint {
        let requested = placement.alignment ?? 2
        let an = (1...9).contains(requested) ? requested : 2
        let column = (an - 1) % 3     // 0 left, 1 centre, 2 right
        let row = (an - 1) / 3        // 0 bottom, 1 middle, 2 top

        let x: CGFloat
        let y: CGFloat
        if let position = placement.position, isDrawableAnchor(position) {
            let anchorX = frame.minX + position.x * frame.width
            let anchorY = frame.minY + position.y * frame.height
            x = column == 0 ? anchorX
                : column == 1 ? anchorX - blockSize.width / 2
                : anchorX - blockSize.width
            y = row == 0 ? anchorY - blockSize.height
                : row == 1 ? anchorY - blockSize.height / 2
                : anchorY
        } else {
            x = column == 0 ? frame.minX + margin
                : column == 1 ? frame.midX - blockSize.width / 2
                : frame.maxX - blockSize.width - margin
            y = row == 0 ? frame.maxY - blockSize.height - margin
                : row == 1 ? frame.midY - blockSize.height / 2
                : frame.minY + margin
        }
        return CGPoint(x: x, y: max(min(y + verticalShift, bottomLimit - blockSize.height), topLimit))
    }

    /// Whether an anchor is inside the picture and can therefore be drawn. `SubtitleTextPlacement`
    /// stopped promising a [0, 1] range in AetherEngine #261: a script may anchor outside the frame
    /// on purpose, so the engine passes the value through instead of clamping it, which also keeps
    /// a wrong normalization basis visible rather than absorbed. This overlay cannot draw
    /// off-picture, so it makes that call here and drops the anchor, leaving the cue in the corner
    /// its alignment asks for. A cue in the wrong corner is a visible defect; a cue drawn
    /// off-picture is indistinguishable from one that never arrived.
    ///
    /// Both axes go together: a wrong basis is wrong on both, so an in-range axis next to an
    /// out-of-range one is not evidence of anything and honouring it would only place the cue
    /// confidently wrong.
    nonisolated static func isDrawableAnchor(_ position: CGPoint) -> Bool {
        (0...1).contains(position.x) && (0...1).contains(position.y)
    }

    /// Which corner of the block the placement is measured from, as the SwiftUI alignment that
    /// puts that corner where the container's matching corner is. Same numpad reading and the
    /// same fallback to 2 as `placedOrigin`.
    nonisolated static func placedAlignment(_ alignment: Int?) -> Alignment {
        let requested = alignment ?? 2
        let an = (1...9).contains(requested) ? requested : 2
        switch ((an - 1) % 3, (an - 1) / 3) {
        case (0, 0): return .bottomLeading
        case (1, 0): return .bottom
        case (2, 0): return .bottomTrailing
        case (0, 1): return .leading
        case (1, 1): return .center
        case (2, 1): return .trailing
        case (0, 2): return .topLeading
        case (1, 2): return .top
        default:     return .topTrailing
        }
    }

    /// How far to move a block that SwiftUI has already aligned by `placedAlignment`, so that its
    /// reference corner lands on the placement's target.
    ///
    /// The block's size is unknown until it lays out, and this never needs it: aligning first
    /// makes the block's own corner the reference, so only the two container-space points have to
    /// be subtracted. `placedOrigin` evaluated with a zero block IS the target point, which keeps
    /// this and the engine's compositor on one formula.
    nonisolated static func placedOffset(placement: SubtitleTextPlacement,
                                         in frame: CGRect,
                                         container: CGSize,
                                         margin: CGFloat,
                                         verticalShift: CGFloat,
                                         bottomLimit: CGFloat,
                                         topLimit: CGFloat = -.infinity) -> CGSize {
        let target = placedOrigin(placement: placement, blockSize: .zero, in: frame,
                                  margin: margin, verticalShift: verticalShift,
                                  bottomLimit: bottomLimit, topLimit: topLimit)
        let requested = placement.alignment ?? 2
        let an = (1...9).contains(requested) ? requested : 2
        let column = (an - 1) % 3
        let row = (an - 1) / 3
        let anchorX: CGFloat = column == 0 ? 0 : column == 1 ? container.width / 2 : container.width
        let anchorY: CGFloat = row == 2 ? 0 : row == 1 ? container.height / 2 : container.height
        return CGSize(width: target.x - anchorX, height: target.y - anchorY)
    }

    /// Compose the text view: font + colour + background style. Outline stacks eight nudged
    /// black copies behind the text since tvOS has no per-character stroke modifier.
    @ViewBuilder
    private func styledText(_ text: String, pointSize: CGFloat) -> some View {
        let foreground = foregroundColor
        let baseFont = subtitleBaseFont(pointSize: pointSize)

        switch background {
        case .box:
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .outline:
            ZStack {
                ForEach(Self.outlineOffsets, id: \.self) { offset in
                    Text(text)
                        .font(baseFont)
                        .foregroundStyle(.black)
                        .multilineTextAlignment(.center)
                        .offset(x: offset.x, y: offset.y)
                }
                Text(text)
                    .font(baseFont)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        case .shadow:
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        case .none:
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        }
    }

    /// richText variant of styledText: per-run colour and emphasis (the source wins per run;
    /// nil-colour runs use the user foreground pref). Outline draws the same attributed string in
    /// black for the eight copies, so emphasis cannot shift the outline off the glyphs.
    ///
    /// AetherEngine 5.26.0 also surfaces `fontName` and `fontSize` per run. Both are deliberately
    /// ignored here: the subtitle font and size are user preferences, and High Legibility is an
    /// accessibility choice, so a track is not allowed to override either.
    @ViewBuilder
    private func styledRuns(_ runs: [SubtitleTextRun], pointSize: CGFloat) -> some View {
        let attributed = attributedRuns(runs, pointSize: pointSize)
        let colored = Text(attributed)
        switch background {
        case .box:
            colored.multilineTextAlignment(.center)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .outline:
            ZStack {
                ForEach(Self.outlineOffsets, id: \.self) { offset in
                    Text(attributedRuns(runs, pointSize: pointSize, forcedColor: .black))
                        .multilineTextAlignment(.center).offset(x: offset.x, y: offset.y)
                }
                colored.multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
        case .shadow:
            colored.multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 20).padding(.vertical, 6)
        case .none:
            colored.multilineTextAlignment(.center)
                .padding(.horizontal, 20).padding(.vertical, 6)
        }
    }

    /// One attributed string from a run sequence: the user's font as the base, the source's
    /// emphasis on top. `forcedColor` paints every run in one colour for the outline copies, which
    /// have to match the coloured layer glyph for glyph.
    private func attributedRuns(_ runs: [SubtitleTextRun], pointSize: CGFloat,
                                forcedColor: Color? = nil) -> AttributedString {
        let baseFont = subtitleBaseFont(pointSize: pointSize)
        return runs.reduce(into: AttributedString()) { acc, run in
            var piece = AttributedString(run.text)
            var runFont = baseFont
            if run.isBold { runFont = runFont.bold() }
            if run.isItalic { runFont = runFont.italic() }
            piece.font = runFont
            piece.foregroundColor = forcedColor ?? run.color.map(color) ?? foregroundColor
            if run.isUnderlined { piece.underlineStyle = .single }
            if run.isStruckThrough { piece.strikethroughStyle = .single }
            acc.append(piece)
        }
    }

    private var foregroundColor: Color {
        switch textColor {
        case .white: return .white
        case .yellow: return Color(red: 1.0, green: 0.86, blue: 0.0)
        case .gray: return Color(white: 0.85)
        }
    }

    /// Base font for the active font/weight prefs. SF Pro's heavy cut is `.semibold` not
    /// `.bold` (true bold reads as caption-pasted-on at player sizes); Atkinson Hyperlegible
    /// uses its bundled Regular/Bold PostScript faces (matching `UIAppFonts`).
    private func subtitleBaseFont(pointSize: CGFloat) -> Font {
        switch font {
        case .system:
            let systemWeight: Font.Weight = (weight == .bold) ? .semibold : .regular
            return Font.system(size: pointSize, weight: systemWeight)
        case .highLegibility:
            let postScriptName = (weight == .bold)
                ? "AtkinsonHyperlegible-Bold"
                : "AtkinsonHyperlegible-Regular"
            return Font.custom(postScriptName, size: pointSize)
        }
    }

    /// Eight-direction offsets for the outline background; 2 px reads as a solid edge at TV distance.
    private static let outlineOffsets: [CGPoint] = [
        CGPoint(x: -2, y: -2), CGPoint(x: 0, y: -2), CGPoint(x: 2, y: -2),
        CGPoint(x: -2, y:  0),                       CGPoint(x: 2, y:  0),
        CGPoint(x: -2, y:  2), CGPoint(x: 0, y:  2), CGPoint(x: 2, y:  2),
    ]

    // MARK: - Image branch

    private func imageOverlay(_ image: SubtitleImage, in size: CGSize) -> some View {
        let frame = Self.bitmapCueFrame(position: image.position,
                                        canvas: image.canvasSize,
                                        videoSize: videoSize,
                                        in: size,
                                        verticalShift: bitmapVerticalShift(in: size),
                                        fillsSurface: pictureMode == .fill)
        return Image(decorative: image.cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    /// Screen frame for one bitmap cue. Positions are normalized to the subtitle CANVAS (the
    /// PGS/DVB composition plane, often 16:9 even when the video is cropped to scope), so the
    /// canvas maps onto the aspect-fit video rect, center-anchored, and the cue rides along.
    /// Cues land where the disc authored them, including the lower letterbox bar.
    nonisolated static func bitmapCueFrame(position: CGRect,
                                           canvas: CGSize,
                                           videoSize: CGSize,
                                           in bounds: CGSize,
                                           verticalShift: CGFloat = 0,
                                           fillsSurface: Bool = false) -> CGRect {
        let videoRect = videoRect(videoSize: videoSize, in: bounds, fillsSurface: fillsSurface)
        let canvasRect: CGRect
        if videoRect.width > 0, canvas.width > 0, canvas.height > 0, videoSize.width > 0 {
            // Scale the canvas so it COVERS the video rect: the video is a crop of the plane
            // (scope cropped out of a 16:9 canvas) or a rescale of it, and either way its picture
            // fills the canvas. Scaling by coded video pixels instead assumed canvas and video
            // share a pixel grid, which a downscaled encode breaks: a 720p rip carrying the disc's
            // 1920x1080 PGS plane blew the canvas up 1.5x, so lines rendered 1.5x too wide and ran
            // off the bottom edge of the screen.
            let scale = max(videoRect.width / canvas.width, videoRect.height / canvas.height)
            let w = canvas.width * scale
            let h = canvas.height * scale
            canvasRect = CGRect(x: videoRect.midX - w / 2, y: videoRect.midY - h / 2,
                                width: w, height: h)
        } else {
            // Unknown dims (pre-load or an older engine cue): the historical full-bounds layout.
            canvasRect = CGRect(origin: .zero, size: bounds)
        }
        let frame = CGRect(x: canvasRect.minX + position.minX * canvasRect.width,
                           y: canvasRect.minY + position.minY * canvasRect.height + verticalShift,
                           width: position.width * canvasRect.width,
                           height: position.height * canvasRect.height)
        return frame.offsetBy(dx: 0, dy: verticalClamp(frame, in: bounds))
    }

    /// Vertical delta that pulls `frame` back inside `bounds`, 0 when it already fits. Two
    /// situations push a cue off screen and neither is the cue being wrong:
    ///
    /// - The canvas legitimately overhangs the bounds. `bitmapCueFrame` scales the subtitle plane
    ///   to COVER the video rect so a scope line authored into the 16:9 letterbox bar stays in the
    ///   bar. On a 16:9 display that canvas is about screen-tall and the authored position lands.
    ///   On a display narrower than the plane it does not: 3840x1600 inside a 2318x1206 overlay
    ///   scales a 1920x1080 plane to 1304 pt, overhanging by 98 pt, and a line authored at 0.89 of
    ///   plane height ends 23 pt past the bottom edge (measured on an iPhone 16 Pro, #120).
    /// - `.fill` crops the picture, and a cue riding on the cropped part goes with it. On a 4:3
    ///   title that is most of the lower eighth, so the whole subtitle track would disappear.
    ///
    /// Clamping trades authored position for legibility, which is the right way round: a
    /// subtitle a few points off is readable, one off screen is indistinguishable from missing.
    /// Top wins when the cue is taller than the bounds, since text is read from the top.
    nonisolated static func verticalClamp(_ frame: CGRect, in bounds: CGSize) -> CGFloat {
        guard bounds.height > 0 else { return 0 }
        var dy: CGFloat = 0
        if frame.maxY > bounds.height { dy = bounds.height - frame.maxY }
        if frame.minY + dy < 0 { dy = -frame.minY }
        return dy
    }

    /// Rect the picture occupies under the gravity currently on screen: aspect-fit for
    /// `.original`, aspect-fill for `.fill`, where the picture covers the bounds and overflows
    /// them on one axis. Cue geometry has to use this rather than the fit rect unconditionally,
    /// or every cue placed against the picture stays on a band the picture left (#120).
    nonisolated static func videoRect(videoSize: CGSize, in bounds: CGSize,
                                      fillsSurface: Bool) -> CGRect {
        guard fillsSurface else { return aspectFitRect(videoSize: videoSize, in: bounds) }
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * scale
        let h = videoSize.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Aspect-fit rect of the video plane within the overlay bounds. Full bounds when the
    /// video dims are unknown (pre-load or older engine cues).
    nonisolated private static func aspectFitRect(videoSize: CGSize, in bounds: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let videoAspect = videoSize.width / videoSize.height
        let boundsAspect = bounds.width / bounds.height
        if boundsAspect > videoAspect {
            let w = bounds.height * videoAspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        } else {
            let h = bounds.width / videoAspect
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        }
    }

    /// Vertical shift so the active vertical-position step also moves bitmap cues. `default`
    /// returns 0 (source layout preserved); non-default applies a uniform `-fraction * height`,
    /// matching the text branch's Y for that step (top-of-frame cues can clip; user opted in).
    private func bitmapVerticalShift(in size: CGSize) -> CGFloat {
        guard let fraction = verticalPosition.fractionFromBottom else { return 0 }
        return -CGFloat(fraction) * size.height
    }

    // MARK: - Active-cue lookup

    /// Every cue in `source` whose range contains `currentTime`. Cues are sorted by `startTime`,
    /// so binary-search the first cue starting after now and walk back collecting unexpired ones.
    private func activeCues(in source: [SubtitleCue], maxDuration: Double) -> [SubtitleCue] {
        guard !source.isEmpty else { return [] }
        // delay > 0 means subs appear LATER, so look up at (currentTime - delay).
        let lookupTime = currentTime - delaySeconds
        var lo = 0, hi = source.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if source[mid].startTime > lookupTime {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1
        // Bound the walk-back by `maxDuration` (data-derived: longest cue in track): every cue
        // before `lo` starts <= lookupTime, so without it the scan is O(n) per tick on a full
        // sidecar SRT. A fixed constant would silently hide cues longer than it.
        while i >= 0, source[i].startTime >= lookupTime - maxDuration {
            if source[i].endTime >= lookupTime {
                result.append(source[i])
            }
            i -= 1
        }
        return result.reversed()
    }
}

// MARK: - Styled ASS host

/// Hosts the styled ASS frame stream. A clone of swift-ass-renderer's `AssSubtitlesView`
/// (canvas sized in layoutSubviews, frames drawn at `ProcessedImage.imageRect`) with ONE
/// difference: nil frames from the coordinator's `reloadTrack` are suppressed. The renderer
/// publishes a transient nil before the identical re-render lands, which blinked every visible
/// sub; the coordinator pre-announces reloads via `reloadSignal` so suppression is deterministic.
/// A nil with no announced reload is a real cue end and hides instantly.
private struct ASSRenderedSubtitles: UIViewRepresentable {
    let renderer: AssSubtitlesRenderer
    let reloadSignal: PassthroughSubject<Void, Never>
    /// Playback offset (overlay's `currentTime`, a sourceTime mirror); frame view needs it for
    /// track-data queries since the renderer's own offset is not public.
    let currentOffset: Double

    func makeUIView(context: Context) -> ASSFrameHostView {
        ASSFrameHostView(renderer: renderer, reloadSignal: reloadSignal)
    }

    func updateUIView(_ view: ASSFrameHostView, context: Context) {
        view.currentOffset = currentOffset
    }
}

final class ASSFrameHostView: UIView {
    /// Playback offset fed by the representable on every SwiftUI update (~10 Hz).
    var currentOffset: Double = 0
    private let renderer: AssSubtitlesRenderer
    private let canvasScale: CGFloat
    private let imageView = UIImageView()
    private var lastRenderBounds = CGRect.zero
    private var cancellables = Set<AnyCancellable>()
    /// Suppress nil frames until this deadline (armed per reload signal). `.distantPast` = off.
    private var suppressNilDeadline = Date.distantPast
    /// Deferred hide scheduled during suppression so a swallowed real cue end still hides.
    private var hideWorkItem: DispatchWorkItem?
    /// Generous upper bound for one reload round-trip (parse + font matching + render).
    private static let reloadSuppressWindow: TimeInterval = 0.5

    init(renderer: AssSubtitlesRenderer, reloadSignal: PassthroughSubject<Void, Never>) {
        self.renderer = renderer
        self.canvasScale = UITraitCollection.current.displayScale
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(imageView)
        // No receive(on:): synchronous main-actor delivery arms suppression before the
        // renderer's transient nil can arrive (coordinator sends right before reloadTrack).
        reloadSignal
            .sink { [weak self] in
                self?.suppressNilDeadline = Date().addingTimeInterval(Self.reloadSuppressWindow)
            }
            .store(in: &cancellables)
        renderer
            .framesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleFrameChanged($0) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A zero-bounds pass must never reach the renderer: a 0x0 canvas renders every
        // event as nil, hiding the visible subtitle with no reload announced.
        guard !bounds.isEmpty else {
            return
        }
        if !lastRenderBounds.isEmpty, imageView.image != nil, lastRenderBounds != bounds {
            let ratioX = bounds.width / lastRenderBounds.width
            let ratioY = bounds.height / lastRenderBounds.height
            let f = imageView.frame
            imageView.frame = CGRect(
                x: f.origin.x * ratioX, y: f.origin.y * ratioY,
                width: f.width * ratioX, height: f.height * ratioY
            ).integral
        }
        renderer.setCanvasSize(bounds.size, scale: canvasScale)
    }

    private func handleFrameChanged(_ image: ProcessedImage?) {
        if let image {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            suppressNilDeadline = .distantPast
            lastRenderBounds = bounds
            imageView.frame = image.imageRect
            imageView.image = UIImage(cgImage: image.image)
            imageView.isHidden = false
        } else {
            let remaining = suppressNilDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                // Real cue end (no reload announced): hide instantly.
                hideWorkItem?.cancel()
                hideWorkItem = nil
                hideNow()
                return
            }
            // Reload in flight: keep the last image; arm a safety hide at the deadline
            // in case no frame follows (reload coinciding with a real cue end).
            guard hideWorkItem == nil else { return }
            scheduleSafetyHide(after: remaining)
        }
    }

    /// Resolve a suppression window that ended without a new frame (re-arms if a newer reload
    /// extended the deadline). libass skips the publish when a reload's re-render is visually
    /// identical (parked on the transient nil), so at the deadline query track data directly: an
    /// active event means keep the image and end suppression; none means hide (reload hit a cue end).
    private func scheduleSafetyHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil
            let remaining = self.suppressNilDeadline.timeIntervalSinceNow
            if remaining > 0 {
                self.scheduleSafetyHide(after: remaining)
                return
            }
            let stillActive = !self.renderer.dialogues(at: self.currentOffset).isEmpty
            if stillActive {
                self.suppressNilDeadline = .distantPast
                // Frame subject is parked on nil, so the real cue end's nil-after-nil is
                // swallowed by the duplicate filter and the frame would linger forever.
                // Watch track data for the end ourselves until the next published frame.
                self.scheduleEndWatch()
            } else {
                self.hideNow()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Poll track data while holding a manually-kept frame; hide once no event is active.
    /// Cancelled by any freshly published frame (handleFrameChanged cancels `hideWorkItem`).
    private func scheduleEndWatch() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil
            if self.renderer.dialogues(at: self.currentOffset).isEmpty {
                self.hideNow()
            } else {
                self.scheduleEndWatch()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func hideNow() {
        imageView.isHidden = true
        imageView.image = nil
        suppressNilDeadline = .distantPast
    }
}
