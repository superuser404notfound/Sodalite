import SwiftUI
import AetherEngine

/// Right-anchored read-only "stats for nerds" panel; visible when `PlaybackPreferences.showStatsForNerds`
/// is on and the transport's info chip is pressed.
///
/// Data is split for honesty, and the split runs the other way from what a media app usually does. The
/// ENGINE is asked first for everything it observes (codec, dimensions, frame rate, dynamic range, decoders,
/// audio tracks, telemetry): it describes the stream that actually arrived, and it answers on a live channel
/// and on a slim episode payload alike. JELLYFIN answers only the three things the engine structurally
/// cannot know, because it is handed `/Videos/{id}/stream.mkv?api_key=...` and never sees them: the
/// server-side filename, the file size, and the subtitle titles of tracks the server delivers separately.
///
/// The media description arrives as `PlaybackSourceFacts`, resolved once in the view model so this panel and
/// the section cursor that pages through it cannot disagree about which sections exist.
struct StatsOverlayView: View {
    @ObservedObject var player: AetherEngine
    /// Timer-sampled telemetry observed separately since the engine.diagnostics split (engine's objectWillChange no longer fires on 1 Hz samples). Mounted only while the panel is open, scoping the 1 Hz re-render to this view.
    @ObservedObject var diagnostics: EngineDiagnostics
    /// Container metadata for the version actually playing, session source first, launch item second.
    let facts: PlaybackSourceFacts
    /// Active subtitle stream's container index (matches `MediaStream.index`), or `nil` when off.
    let activeSubtitleIndex: Int?
    /// Cursor into `PlayerViewModel.statsSectionAnchors`, written by PlayerView's press handlers to drive the ScrollViewReader to the Up/Down-navigated section.
    let scrollSectionIndex: Int
    /// The sections that have something to say, from `PlayerViewModel.statsSectionAvailability`. Rendering
    /// and cursor paging read the same set, so Up/Down can never land on an anchor that was not drawn.
    let availableSections: Set<Int>
    /// Live session: the channel section takes the file section's place, because a tuner has no file.
    let isLiveSession: Bool
    let liveChannel: JellyfinChannel?
    let liveRoute: PlayerViewModel.LiveRoute?
    /// Jellyfin's handle for the open tuner, which is what a server-side log is correlated against.
    let liveStreamID: String?
    /// How Jellyfin is delivering a VOD session (direct play, direct stream, transcode). Live says the same
    /// thing with its route instead.
    let playMethod: PlayMethod?
    /// iOS touch close (X in the header); tvOS leaves it nil (dismissed via the info chip / Menu).
    var onClose: (() -> Void)? = nil

    private var panelWidth: CGFloat {
        #if os(iOS)
        return 380
        #else
        return 560
        #endif
    }

    private var videoStream: MediaStream? {
        facts.stream(ofType: .video)
    }

    /// Jellyfin's video stream where it describes what plays, nil under a transcode (Sodalite#87).
    private var fileVideoStream: MediaStream? {
        Self.fileFactsDescribePlayback(playMethod: playMethod) ? videoStream : nil
    }

    /// Whether the library file's own facts describe the video on screen. Under a transcode they describe
    /// the file the server re-encodes, not the stream that arrives.
    static func fileFactsDescribePlayback(playMethod: PlayMethod?) -> Bool {
        playMethod != .transcode
    }

    private var activeAudioStream: MediaStream? {
        facts.stream(ofType: .audio, index: player.activeAudioTrackIndex)
    }

    private var activeSubtitleStream: MediaStream? {
        facts.stream(ofType: .subtitle, index: activeSubtitleIndex)
    }

    var body: some View {
        // Absolute screen-pinned mount, the same wrapper the controls overlay uses. The panel is sized
        // `maxHeight: .infinity`, so it is exactly as tall as the host's safe area, and AVKit's alpha=0
        // chrome (kept for the CC +10s handler) shows ITSELF on pause and widens that inset: the panel
        // shortened on pause and grew back when the chrome auto-hid. The allotted region is measured in
        // global space and a screen-sized frame pinned back over it, so the panel reads the window's own
        // insets as plain padding instead (on iOS the insets AVKit serves in portrait go negative, so
        // `.ignoresSafeArea()` is not an option here). This also takes the panel out of the parent-frame
        // collapse an in-place reload (audio switch, next episode) puts AVKit through.
        GeometryReader { geo in
            let allotted = geo.frame(in: .global)
            let (screen, insets) = Self.hostGeometry(fallback: geo.size)
            HStack(spacing: 0) {
                Spacer()
                panel
                    #if os(iOS)
                    .padding(.trailing, 16)
                    .padding(.vertical, 16)
                    #else
                    .padding(.trailing, 40)
                    .padding(.vertical, 40)
                    #endif
            }
            .padding(insets)
            .frame(width: screen.width, height: screen.height)
            .position(x: screen.width / 2 - allotted.minX, y: screen.height / 2 - allotted.minY)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        // Hit testing left on so the focus engine treats the overlay as a gesture-consuming layer; Up/Down routing is in PlayerHostController's @objc handlers gated on viewModel.showStatsOverlay.
    }

    /// Screen bounds + the insets that are actually true, sourced away from the SwiftUI safe area AVKit
    /// churns. iOS reads the key window (shared with `PlayerOverlayView`), tvOS the scene's screen, where
    /// the title-safe margin is this panel's own 40pt padding and the window carries no insets.
    private static func hostGeometry(fallback: CGSize) -> (CGSize, EdgeInsets) {
        #if os(iOS)
        let (bounds, insets) = PlayerOverlayView.windowGeometry(fallback: fallback)
        return (
            bounds.size,
            EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
        )
        #else
        let size = UIApplication.shared.connectedScenes
            .lazy.compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.size ?? CGSize(width: 1920, height: 1080)
        return (size, EdgeInsets())
        #endif
    }

    /// Latches once the slide-in settles, gating scrollTo so the mount-time `statsSectionIndex = 0` reset (fires the same render cycle) doesn't run a 0.2s scrollTo that fights the panel's 0.25s `.move(edge: .trailing)` transition (stuck-halfway-in for ~1s).
    @State private var didFinishAppearTransition = false

    private var panel: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    #if os(iOS)
                    HStack {
                        Text("player.stats.title")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                        Spacer()
                        if let onClose {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    #else
                    Text("player.stats.title")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                    #endif

                    anchored(StatsSection.live) { liveSection }
                    anchored(StatsSection.playback) { playbackSection }
                    anchored(StatsSection.video) { videoSection }
                    anchored(StatsSection.audio) { audioSection }
                    anchored(StatsSection.subtitle) { subtitleSection }
                    // One index, two contents: a live session has a channel where a file would be.
                    anchored(StatsSection.source) {
                        if isLiveSession { channelSection } else { fileSection }
                    }
                    anchored(StatsSection.engine) { engineSection }
                    anchored(StatsSection.buffer) { bufferSection }
                    anchored(StatsSection.network) { networkSection }
                }
                .padding(28)
                .frame(width: panelWidth, alignment: .topLeading)
            }
            .onChange(of: scrollSectionIndex) { _, newIndex in
                // Skip auto-scroll while sliding in (the mount-time index-0 reset fires here and the two animations conflict); content starts at top anyway.
                guard didFinishAppearTransition else { return }
                let anchors = PlayerViewModel.statsSectionAnchors
                guard anchors.indices.contains(newIndex) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    // `.top` keeps the active section header at the top edge, mirroring transport-bar dropdowns.
                    proxy.scrollTo(anchors[newIndex], anchor: .top)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .frame(width: panelWidth)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        .task {
            // Wait past the 0.25s entrance transition (+ buffer) before unlatching the scrollTo gate.
            try? await Task.sleep(for: .milliseconds(300))
            didFinishAppearTransition = true
        }
    }

    /// Draws a section only when the shared availability set lists it, under the anchor and highlight the
    /// cursor uses. Going through one helper is what keeps "rendered" and "reachable by Up/Down" the same
    /// list; they were two lists, computed in two files, and they had already drifted.
    @ViewBuilder
    private func anchored<C: View>(_ index: Int, @ViewBuilder _ content: () -> C) -> some View {
        if availableSections.contains(index) {
            content()
                .id(PlayerViewModel.statsSectionAnchors[index])
                .modifier(StatsSectionHighlight(isCurrent: scrollSectionIndex == index))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var liveSection: some View {
        section("player.stats.section.live") {
            let telemetry = diagnostics.liveTelemetry
            row(
                "player.stats.bitrate",
                value: Self.formatBitratePair(
                    instant: telemetry?.instantBitrateMbps,
                    average: telemetry?.averageBitrateMbps
                )
            )
            // Both halves are native-only, so on the software path the row would read "— · — cached".
            // The two rows below carry what that path holds instead (AetherEngine#306).
            if telemetry?.forwardBufferSeconds != nil || telemetry?.cachedBytes != nil {
                row(
                    "player.stats.buffer",
                    value: Self.formatBufferPair(
                        seconds: telemetry?.forwardBufferSeconds,
                        cachedBytes: telemetry?.cachedBytes
                    )
                )
            }
            // Decoded video queued past the clock. Sub-second on a healthy software session: the
            // demux loop reads on renderer back-pressure, so this is a cushion, not a buffer.
            if let cushion = telemetry?.displayCushionSeconds {
                row("player.stats.decodeCushion", value: String(format: "%.2f s", cushion))
            }
            // Fetched but not yet demuxed: the runway that does exist ahead of the read cursor.
            if let ahead = telemetry?.readerWindowAheadBytes {
                row("player.stats.readerAhead", value: Self.formatByteCount(Int64(ahead)))
            }
            row(
                "player.stats.network",
                value: Self.formatNetworkPair(
                    mbps: telemetry?.networkThroughputMbps,
                    transferred: telemetry?.networkTransferredBytes
                )
            )
            if let dropped = telemetry?.droppedFrameCount {
                row("player.stats.droppedFrames", value: "\(dropped)")
            }
            if let delay = telemetry?.accumulatedFrameDelaySeconds {
                row("player.stats.frameDelay", value: String(format: "%.2f s", delay))
            }
            if let fps = telemetry?.observedFps {
                row("player.stats.fpsObserved", value: String(format: "%.2f fps", fps))
            }
            if let gap = telemetry?.avSyncGapMs {
                row(
                    "player.stats.avGap",
                    value: Self.formatAVGap(gap),
                    valueColor: Self.avGapColor(gap)
                )
            }
        }
    }

    private var playbackSection: some View {
        section("player.stats.section.playback") {
            row("player.stats.backend", value: backendLabel)
            if let decoder = player.activeVideoDecoder {
                row("player.stats.videoDecoder", value: decoder)
            }
            if let decoder = player.activeAudioDecoder {
                row("player.stats.audioDecoder", value: decoder)
            }
            // Jellyfin's own vocabulary, untranslated on purpose: this is the value a server log and a
            // Jellyfin dashboard session both spell "DirectPlay", and a translated one cannot be matched
            // against either. Live omits it, its route says the same thing more precisely.
            if !isLiveSession, let playMethod {
                row("player.stats.playMethod", value: playMethod.rawValue)
            }
            // What libavformat OPENED, which under a transcode is not what the library holds. The file
            // section below still names the library's container, and the two differing is the point.
            if let container = player.sourceContainerFormat {
                row("player.stats.container", value: container)
            }
        }
    }

    /// Engine first on every row. It reads the stream that arrived, so it answers for a live channel and for
    /// an episode whose Jellyfin payload carries no streams at all; the container stream fills in the codec
    /// profile, which the engine does not publish, and stands in before the probe lands.
    private var videoSection: some View {
        section("detail.tech.video") {
            if let codec = videoCodecLabel {
                row("detail.tech.codec", value: codec)
            }
            if let resolution = resolutionLabel {
                row("detail.tech.resolution", value: resolution)
            }
            if let fps = player.sourceVideoFrameRate
                ?? fileVideoStream?.realFrameRate ?? fileVideoStream?.averageFrameRate {
                row("detail.tech.framerate", value: String(format: "%.3g fps", fps))
            }
            if let bps = videoBitrate {
                row("detail.tech.bitrate", value: Self.formatBitrate(bps))
            }
            row("player.stats.dynamicRange", value: videoRangeLabel)
            if let format = videoStreamFormat {
                if let pixelFormat = format.pixelFormat {
                    row("player.stats.pixelFormat", value: pixelFormat)
                }
                if let depth = format.bitDepth {
                    row("player.stats.bitDepth", value: "\(depth)-bit")
                }
                if let primaries = format.colorPrimariesLabel {
                    row("player.stats.colorPrimaries", value: primaries)
                }
                if let transfer = format.transferLabel {
                    row("player.stats.colorTransfer", value: transfer)
                }
                if let matrix = format.matrixLabel {
                    row("player.stats.colorMatrix", value: matrix)
                }
                if let range = format.rangeLabel {
                    row("player.stats.colorRange", value: range)
                }
            }
            if let decoded = player.decodedVideoFormat {
                row("player.stats.displayBuffer", value: decoded.pixelBufferLabel)
            }
        }
    }

    /// AE#658: what the engine's own decoder produced where it decodes (software path), the source's
    /// declaration otherwise. On the native path AVPlayer decodes and the frames never reach the engine.
    private var videoStreamFormat: VideoStreamFormat? {
        player.decodedVideoFormat?.frame ?? player.sourceVideoStreamFormat
    }

    /// Prefer the engine's TrackInfo (live Atmos flag + channel count); the Jellyfin MediaStream fills the
    /// bitrate and the friendlier language title, and stands in during the session-start window before the
    /// engine has resolved a track.
    private var audioSection: some View {
        let engineTrack = player.audioTracks.first(where: { $0.id == player.activeAudioTrackIndex })
        return section("detail.tech.audio") {
            if let codec = engineTrack?.codec.uppercased()
                ?? activeAudioStream?.codec?.uppercased() {
                row("detail.tech.codec", value: engineTrack?.profile.map { "\(codec) · \($0)" } ?? codec)
            }
            let channels = engineTrack?.channels ?? activeAudioStream?.channels ?? 0
            let isAtmos = engineTrack?.isAtmos ?? false
            if channels > 0 {
                row(
                    "detail.tech.channels",
                    value: isAtmos
                        ? "\(Self.channelLayoutLabel(channels)) · Atmos"
                        : Self.channelLayoutLabel(channels)
                )
            }
            if let rate = engineTrack?.sampleRate, rate > 0 {
                row("player.stats.sampleRate", value: Self.formatSampleRate(rate))
            }
            if let bits = engineTrack?.bitsPerSample, bits > 0 {
                row("player.stats.bitDepth", value: "\(bits)-bit")
            }
            if let sampleFormat = engineTrack?.sampleFormat {
                row("player.stats.sampleFormat", value: sampleFormat)
            }
            let bitrate = activeAudioStream?.bitRate.map(Int64.init)
                ?? engineTrack.map(\.bitrate)
            if let bitrate, bitrate > 0 {
                row("detail.tech.bitrate", value: Self.formatBitrate(Int(bitrate)))
            }
            if let lang = activeAudioStream?.displayTitle
                ?? engineTrack?.language
                ?? activeAudioStream?.language {
                row("detail.tech.language", value: lang)
            }
        }
    }

    /// The engine's track stands in where Jellyfin has no stream to name: a live channel carries its
    /// subtitles inside the transport stream, and the item that launched it is a channel, not a file.
    private var subtitleSection: some View {
        let engineTrack = player.subtitleTracks.first { $0.id == activeSubtitleIndex }
        return section("detail.tech.subtitles") {
            if let codec = activeSubtitleStream?.codec?.uppercased()
                ?? engineTrack?.codec.uppercased() {
                row("detail.tech.codec", value: codec)
            }
            if let lang = activeSubtitleStream?.displayTitle
                ?? activeSubtitleStream?.language
                ?? engineTrack?.language
                ?? engineTrack?.name {
                row("detail.tech.language", value: lang)
            }
            if activeSubtitleStream?.isForced == true || engineTrack?.isForced == true {
                row("player.stats.forced", value: "✓")
            }
        }
    }

    /// The one section Jellyfin owns outright. The engine is handed `/Videos/{id}/stream.mkv?api_key=...`
    /// and never learns the library path behind it, so filename and size can come from nowhere else.
    private var fileSection: some View {
        section("detail.tech.file") {
            if let container = facts.container?.uppercased() {
                row("detail.tech.format", value: container)
            }
            if let size = facts.sizeBytes {
                row("detail.tech.size", value: Self.formatFileSize(size))
            }
            if let filename = facts.fileName {
                row("detail.tech.filename", value: filename)
            }
        }
    }

    /// Live's answer to the file section. The route is the row that earns it: it decides whether Jellyfin is
    /// in the data path at all, it is the difference between one ffmpeg and two on the server, and until now
    /// it existed only as a `LogTap` line inside a diagnostic build's HUD, which is somewhere a reporter
    /// cannot reach. Here it is part of a screenshot (Sodalite#70, where the route was the missing witness).
    private var channelSection: some View {
        section("player.stats.section.channel") {
            if let name = liveChannel?.name, !name.isEmpty {
                row("player.stats.channelName", value: name)
            }
            if let number = liveChannel?.channelNumber, !number.isEmpty {
                row("player.stats.channelNumber", value: number)
            }
            if let liveRoute {
                // Untranslated, like the play method: the value's whole job is to match the `route=` token
                // in the log a report is correlated against.
                row("player.stats.route", value: liveRoute.rawValue)
            }
            if let liveStreamID, !liveStreamID.isEmpty {
                row("player.stats.tuner", value: liveStreamID)
            }
        }
    }

    @ViewBuilder
    private var engineSection: some View {
        if let telemetry = diagnostics.liveTelemetry {
            section("player.stats.section.engine") {
                row("player.stats.producerRestarts", value: "\(telemetry.producerRestartCount)")
                row("player.stats.rss", value: "\(telemetry.rssMb) MB")
            }
        }
    }

    @ViewBuilder
    private var bufferSection: some View {
        if let telemetry = diagnostics.liveTelemetry {
            section("player.stats.section.buffer") {
                row(
                    "player.stats.demuxerBytes",
                    value: Self.formatByteCount(telemetry.demuxerBytesFetched)
                )
                row(
                    "player.stats.muxedBytes",
                    value: Self.formatByteCount(telemetry.muxedBytesLifetime)
                )
                row(
                    "player.stats.audioBridge",
                    value: Self.formatByteCount(Int64(telemetry.audioBridgeLiveBytes))
                )
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        if let telemetry = diagnostics.liveTelemetry {
            section("player.stats.section.network") {
                row(
                    "player.stats.serverSent",
                    value: Self.formatByteCount(telemetry.serverBytesSentLifetime)
                )
                row(
                    "player.stats.serverRequests",
                    value: "\(telemetry.serverRequestCount)"
                )
            }
        }
    }

    // MARK: - Row + Section primitives

    private func section<C: View>(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder _ content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleKey)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .padding(.bottom, 2)
            content()
        }
    }

    private func row(_ labelKey: LocalizedStringKey, value: String) -> some View {
        row(labelKey, value: value, valueColor: .white)
    }

    /// `row(_:value:)` with a caller-tinted value column (used by the live A/V-gap row for green/yellow/red); label column stays uncoloured for cross-locale legibility.
    private func row(
        _ labelKey: LocalizedStringKey,
        value: String,
        valueColor: Color
    ) -> some View {
        // 180pt label column fits the longer German/Romance terms ("Dynamikbereich", "Décodeur vidéo") on one line, trading slight English looseness for no mid-word truncation in the other 25 locales.
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(labelKey)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 180, alignment: .leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.caption)
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Derived video labels

    private var videoCodecLabel: String? {
        Self.videoCodecLabel(engineName: player.sourceVideoCodecName,
                             engineProfile: player.sourceVideoStreamFormat?.profile,
                             file: fileVideoStream)
    }

    /// Engine spelling ("HEVC") with the profile appended when one is known, the engine's first. The file's
    /// codec and profile stand in only until the engine has probed, and never under a transcode.
    static func videoCodecLabel(engineName: String?, engineProfile: String?, file: MediaStream?) -> String? {
        guard let name = engineName?.uppercased() ?? file?.codec?.uppercased() else { return nil }
        let profile = engineProfile ?? file?.profile ?? ""
        return profile.isEmpty ? name : "\(name) \(profile)"
    }

    private var resolutionLabel: String? {
        Self.resolutionLabel(engineWidth: Int(player.sourceVideoWidth),
                             engineHeight: Int(player.sourceVideoHeight),
                             file: fileVideoStream)
    }

    static func resolutionLabel(engineWidth: Int, engineHeight: Int, file: MediaStream?) -> String? {
        if engineWidth > 0, engineHeight > 0 {
            return "\(engineWidth)×\(engineHeight)"
        }
        if let w = file?.width, let h = file?.height {
            return "\(w)×\(h)"
        }
        return nil
    }

    /// The engine's declared VIDEO bitrate when the container carries one; the source-wide figure from
    /// Jellyfin otherwise, which is what this row showed before and is close enough to be worth keeping.
    private var videoBitrate: Int? {
        if player.sourceVideoBitrate > 0 { return Int(player.sourceVideoBitrate) }
        // Under a transcode the file's figure is not the stream's; the live section carries what arrives.
        return Self.fileFactsDescribePlayback(playMethod: playMethod) ? facts.bitrate : nil
    }

    /// Source video range refined with the DV profile. When the engine clamps `videoFormat` to `.sdr`
    /// (DV/HDR10 source on an SDR panel, or Match Content off), render "Source → Target". The profile comes
    /// from the engine's dvcC read first; Jellyfin's copy is the fallback.
    private var videoRangeLabel: String {
        Self.videoRangeLabel(
            source: player.sourceVideoFormat,
            presented: player.videoFormat,
            dvProfile: player.sourceDVProfile ?? fileVideoStream?.dvProfile,
            conversion: player.dolbyVisionConversion)
    }

    /// A Profile 7 presented as Dolby Vision is served as Profile 8.1, so the target names that profile
    /// rather than repeating the source's (AE#459).
    static func videoRangeLabel(
        source sourceFormat: VideoFormat,
        presented: VideoFormat,
        dvProfile: Int?,
        conversion: DolbyVisionConversion?
    ) -> String {
        let source = formatLabel(sourceFormat, dvProfile: dvProfile)
        if presented == .dolbyVision, conversion == .profile7ToProfile81 {
            return "\(source) → P8.1"
        }
        let effective = formatLabel(presented, dvProfile: dvProfile)
        if source == effective {
            return source
        }
        return "\(source) → \(effective)"
    }

    // MARK: - Labels

    private var backendLabel: String {
        switch player.playbackBackend {
        case .native:
            return String(localized: "player.stats.backend.native", defaultValue: "Native (AVPlayer)")
        case .software:
            return String(localized: "player.stats.backend.software", defaultValue: "Software (dav1d / FFmpeg)")
        case .aether, .none, .audio:
            // .aether is legacy (no longer dispatched to); .audio drives its own music UI, not this video overlay. Neither can surface here, so collapse to the placeholder.
            return "—"
        }
    }

    private static func formatLabel(_ format: VideoFormat, dvProfile: Int?) -> String {
        let base: String
        switch format {
        case .sdr:         base = "SDR"
        case .hdr10:       base = "HDR10"
        case .hdr10Plus:   base = "HDR10+"
        case .dolbyVision: base = "Dolby Vision"
        case .hlg:         base = "HLG"
        }
        if format == .dolbyVision, let p = dvProfile {
            return "\(base) P\(p)"
        }
        return base
    }

    // MARK: - Formatters

    private static func channelLayoutLabel(_ channels: Int) -> String {
        switch channels {
        case 1: return String(localized: "tech.channels.mono", defaultValue: "Mono")
        case 2: return String(localized: "tech.channels.stereo", defaultValue: "Stereo")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    static func formatSampleRate(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000)
    }

    private static func formatBitrate(_ bps: Int) -> String {
        let mbps = Double(bps) / 1_000_000
        if mbps >= 1 { return String(format: "%.1f Mbps", mbps) }
        return "\(bps / 1000) Kbps"
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    private static func formatBitratePair(instant: Double?, average: Double?) -> String {
        let inst = instant.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let avg = average.map { String(format: "%.1f", $0) } ?? "—"
        return "\(inst)  ·  avg \(avg) Mbps"
    }

    /// The cache half only where the engine keeps one: the remote-HLS bypass has AVPlayer's buffer and no
    /// engine cache, and a half that can never fill reads as broken (Sodalite#87).
    static func formatBufferPair(seconds: Double?, cachedBytes: Int64?) -> String {
        let sec = seconds.map { String(format: "+%.1f s", $0) } ?? "—"
        guard let cachedBytes else { return sec }
        return "\(sec)  ·  \(String(format: "%d MB", cachedBytes / 1_048_576)) cached"
    }

    private static func formatNetworkPair(mbps: Double?, transferred: Int64?) -> String {
        let m = mbps.map { String(format: "%.1f Mbps", $0) } ?? "—"
        let t = transferred.map { Self.formatByteCount($0) } ?? "—"
        return "\(m)  ·  \(t)"
    }

    private static func formatAVGap(_ ms: Double) -> String {
        return String(format: "%.0f ms", ms)
    }

    /// Tints the A/V-gap value by magnitude; thresholds mirror the engine's `abs(gapMs) > 50` warn-log site.
    private static func avGapColor(_ ms: Double) -> Color {
        let abs = Swift.abs(ms)
        if abs < 50 { return .green }
        if abs < 150 { return .yellow }
        return .red
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

/// Visual-only highlight (fill + accent stroke) for the up/down cursor's section; not focusable (AVKit-host gesture recognizers eat arrow presses before the focus engine), so the cursor is driven by the same @objc handlers that drive scrollTo.
private struct StatsSectionHighlight: ViewModifier {
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isCurrent ? Color.Theme.focusFill : .clear)
            )
            .focusStroke(cornerRadius: 12, isFocused: isCurrent)
            .animation(.easeInOut(duration: 0.18), value: isCurrent)
    }
}
