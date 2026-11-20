import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

/// One buffered line. The buffer is a ring of plain strings and duplicate lines are normal in a
/// log, so the index has to carry the identity.
private struct LogLine: Identifiable {
    let id: Int
    let text: String
}

/// The lines as they stood when Export was pressed. The `item:` presentation needs an identity and an
/// array of strings has none; the snapshot also keeps the panel from reading a buffer that has moved on
/// while the cover was going up.
private struct LogSnapshot: Identifiable {
    let id = UUID()
    let lines: [String]
}

/// Settings > "Diagnostic Log": the lines `LogTap` collected this session.
///
/// Deliberately not gated by `LogTap.isDiagnosticBuild`: it is read-only, and until it existed the
/// only way to see a host line like `[CloudSync] …` was a console capture from a Mac, which put every
/// log-based question out of reach for the people actually hitting the bug. Sodalite#45 was diagnosed
/// twice without it. Engine lines are in here on every build including App Store, because `SodaliteApp`
/// wires `EngineLog.handler` unconditionally.
struct DiagnosticLogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @ObservedObject private var tap = LogTap.shared

    /// Non-nil while the export panel is up, and the snapshot it is serving. Carried in the binding
    /// rather than read inside the panel so the page shows the lines that were on screen when the
    /// button was pressed, not the ones that arrived while it was opening.
    @State private var exportedLines: LogSnapshot?

    /// AE#597: mirrors `LogTap.fileSinkEnabled`, which is a plain flag rather than observable
    /// state because it is read on the emitting thread for every line.
    @State private var persistsLog = LogTap.fileSinkEnabled

    #if os(iOS)
    /// Whether the file sink has left anything on disk, including from an earlier launch with the
    /// switch since turned off. Checked on appear and on every flip, which is when it can change in a
    /// way the reader would notice.
    @State private var hasPersistedLog = PersistedLogShare.isAvailable
    #endif

    /// tvOS groups the lines into focusable blocks (see LogBlock). 12 keeps a block roughly one
    /// screenful, so one swipe of the remote is one page.
    private static let blockSize = 12

    /// Wider than the 900 the rest of Settings reads at, because this is a table and not prose. At tvOS
    /// caption size the monospaced advance is 15.45pt, so 900 held 56 characters per row: a 24-character
    /// UTC stamp plus its two spaces left 30 for the message, and every line wrapped. 1600 holds 101, so
    /// the stamp costs a quarter of a row instead of half of it. It is also the ceiling: 1920 less the
    /// 80pt padding on each side and the overscan safe area leaves about 1640, and `maxWidth` shrinks to
    /// what is there rather than overflowing if a future tvOS insets more.
    private static let contentWidth: CGFloat = {
        #if os(tvOS)
        1600
        #else
        900
        #endif
    }()

    /// Stable per-line id derived from `sequenceNumber`, not the array offset (Audit 2026-09-25
    /// DIAG-8): once the 300-line ring starts evicting from the front, an offset-based id shifts by
    /// one on every new line, and `lines.count` itself stops changing, so a view keyed on either one
    /// stops noticing new lines arrive at all. `sequenceNumber` keeps climbing regardless, and a
    /// line's distance from the newest end of the buffer is unaffected by eviction at the other end,
    /// so the id stays fixed for a given line both while the buffer is still growing and once
    /// eviction starts. Internal (not private) so it can be pinned directly in tests.
    static func lineID(sequenceNumber: Int, lineCount: Int, offset: Int) -> Int {
        sequenceNumber - lineCount + offset + 1
    }

    private var lines: [LogLine] {
        tap.lines.enumerated().map {
            LogLine(
                id: Self.lineID(sequenceNumber: tap.sequenceNumber, lineCount: tap.lines.count, offset: $0.offset),
                text: $0.element
            )
        }
    }

    private var blocks: [[LogLine]] {
        stride(from: 0, to: lines.count, by: Self.blockSize).map {
            Array(lines[$0 ..< min($0 + Self.blockSize, lines.count)])
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if lines.isEmpty {
                        Text("settings.log.empty", bundle: .main)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    } else {
                        content
                    }
                }
                .frame(maxWidth: Self.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, hSizeClass == .compact ? 16 : 80)
                .padding(.bottom, 60)
            }
            // A log is read from its end. Landing at the top would mean scrolling past a full
            // session to reach the line that prompted the visit.
            .onAppear {
                // The app can be in front while tvOS reloads the shelf, so activation alone can miss
                // what the extension just wrote.
                tap.importShelfLines()
                #if os(iOS)
                hasPersistedLog = PersistedLogShare.isAvailable
                #endif
                scrollToEnd(proxy)
            }
            // sequenceNumber, not lines.count: the count pins at 300 once the ring starts evicting,
            // so this stopped firing for every line after the first full session (DIAG-8).
            .onChange(of: tap.sequenceNumber) { _, _ in scrollToEnd(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hidesNavigationBarChrome()
        .onExitCommandCompat { dismiss() }
        #if os(tvOS)
        // Presented from here rather than from Settings: this view is already a cover, and the panel
        // is a modal of ITS host, which is the one arrangement UIKit allows (see the log view's own
        // presenter in DiagnosticLogLink).
        .menuPresentation(item: $exportedLines, panel: .plain) { snapshot in
            LogExportPanel(lines: snapshot.lines) { exportedLines = nil }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(blocks, id: \.first?.id) { block in
                LogBlock(lines: block)
                    .id(block.last?.id)
            }
        }
        #else
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(line.id)
            }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.log.title", bundle: .main)
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)

            Text("settings.log.hint", bundle: .main)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // Not localised on purpose: two product names and three numbers, and it is quoted back
            // verbatim in an issue. It leads the copied and exported text for the same reason.
            Text(LogTap.environmentLine)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            actions
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 60)
        .padding(.bottom, 24)
    }

    /// One row where it fits (iPad, and always on tvOS). On a phone four labels do not, and an HStack
    /// that cannot fit squeezes every label to a column one letter wide, so there they stack at one
    /// shared width instead. Measured on the iPhone 17e simulator, the narrowest current phone.
    @ViewBuilder
    private var actions: some View {
        #if os(tvOS)
        HStack(spacing: 16) { actionButtons(fillsWidth: false) }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { actionButtons(fillsWidth: false) }
            VStack(spacing: 12) { actionButtons(fillsWidth: true) }
                .fixedSize(horizontal: true, vertical: false)
        }
        #endif
    }

    @ViewBuilder
    private func actionButtons(fillsWidth: Bool) -> some View {
        #if os(iOS)
        LogActionButton(
            titleKey: "settings.log.copy",
            systemImage: "doc.on.doc",
            isEnabled: !tap.lines.isEmpty,
            fillsWidth: fillsWidth
        ) {
            UIPasteboard.general.string = ([LogTap.environmentLine] + tap.lines).joined(separator: "\n")
        }

        // AE#597: the buffer is this launch only, the file reaches back across restarts. Copy
        // cannot carry 32 MB, a share sheet can (Mail, Files, AirDrop to a Mac).
        if hasPersistedLog {
            ShareLink(
                item: PersistedLogShare(),
                preview: SharePreview(LogExportSession.persistedLogName)
            ) {
                LogActionLabel(
                    titleKey: "settings.log.share",
                    systemImage: "square.and.arrow.up",
                    isFocused: false,
                    fillsWidth: fillsWidth
                )
            }
            .buttonStyle(.plain)
        }
        #endif

        #if os(tvOS)
        // Sodalite#148. An Apple TV has no clipboard and no keyboard worth the name, so the way off
        // it is a page a phone can open. iOS keeps Copy above and needs none of this.
        LogActionButton(
            titleKey: "settings.log.export",
            systemImage: "qrcode",
            isEnabled: !tap.lines.isEmpty
        ) {
            exportedLines = LogSnapshot(lines: [LogTap.environmentLine] + tap.lines)
        }
        #endif

        LogActionButton(
            titleKey: "settings.log.clear",
            systemImage: "trash",
            isEnabled: !tap.lines.isEmpty,
            fillsWidth: fillsWidth
        ) {
            tap.clear()
        }

        // AE#597: the buffer above is this launch only, which is the wrong shape for anything
        // with an hour between its cause and its symptom. Always enabled: it is most worth
        // turning on when there is nothing on screen yet. The state is in the title, not only in the
        // icon: Sodalite#164 came with a file holding nine "armed" lines from 32 seconds of pressing
        // this, from someone who could not tell whether it was on.
        LogActionButton(
            titleKey: persistsLog ? "settings.log.persist.on" : "settings.log.persist.off",
            systemImage: persistsLog ? "externaldrive.fill.badge.checkmark" : "externaldrive",
            isEnabled: true,
            fillsWidth: fillsWidth
        ) {
            persistsLog.toggle()
            LogTap.setFileSinkEnabled(persistsLog)
            #if os(iOS)
            hasPersistedLog = PersistedLogShare.isAvailable
            #endif
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = lines.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }
}

/// Compact action chip. Not a `Button` with a system style: on tvOS `.bordered` draws a filled
/// pill in the accent colour whether or not it holds focus, which reads as permanently focused and
/// swallows its own label. Mirrors `SettingsTileButtonStyle`'s fills and tinted focus border
/// instead, so it looks like the rest of Settings on both platforms.
///
/// Not private: the export panel (Sodalite#148) is a second face of this same screen and its buttons
/// have to be the same ones.
struct LogActionButton: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let isEnabled: Bool
    var fillsWidth = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        LogActionLabel(titleKey: titleKey, systemImage: systemImage, isFocused: isFocused, fillsWidth: fillsWidth)
            .focusStroke(cornerRadius: 14, isFocused: isFocused)
            .focusResponse(.tile.flat, isFocused: isFocused)
            .opacity(isEnabled ? 1 : 0.4)
            .focusableSurface(isEnabled)
            .focused($isFocused)
            .stableTap(isFocused: isFocused) {
                guard isEnabled else { return }
                action()
            }
    }
}

/// The face of `LogActionButton`, split out so the iOS share link can wear it: a `ShareLink` has to
/// own its tap, so it cannot be one of the buttons.
struct LogActionLabel: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    let isFocused: Bool
    var fillsWidth = false

    var body: some View {
        Label(titleKey, systemImage: systemImage)
            .font(.callout)
            .fontWeight(.medium)
            // One line, always: a label that may wrap is one a tight row turns into a column of letters.
            .lineLimit(1)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.Theme.focusFill : Color.white.opacity(0.05))
            )
    }
}

#if os(iOS)
/// The file sink's file as a share-sheet item (AE#597). Built lazily, when a target is picked, so
/// opening the sheet copies nothing, and built as a copy with the provenance header on top so the
/// file that lands in Mail says which build wrote it and does not keep growing while it is sent.
nonisolated struct PersistedLogShare: Transferable {
    static var isAvailable: Bool {
        PersistedLogFile(urls: LogTap.persistedLogURLs) != nil
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try snapshot())
        }
    }

    /// One fixed folder, emptied first, so repeated shares do not pile copies up in tmp.
    static func snapshot() throws -> URL {
        guard let file = PersistedLogFile(urls: LogTap.persistedLogURLs) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("log-share", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(LogExportSession.persistedLogName)
        let header = LogTap.environmentLine
            + "\nPersistent log, \(file.length) bytes, captured \(LogTimestamp.stamp(Date()))"
        try file.writeCopy(to: destination, header: header)
        return destination
    }
}
#endif

#if os(tvOS)
/// A tvOS scroll view only scrolls when the focus engine has somewhere to move, and a `Text` is
/// not focusable: with only Copy and Clear focusable, the log stood still. Blocks rather than
/// single lines because 300 focusable rows would mean 300 swipes to reach the end of the buffer,
/// while a block is one page per swipe.
private struct LogBlock: View {
    let lines: [LogLine]
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isFocused ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(Color.clear))
        )
        .focusStroke(cornerRadius: 12, isFocused: isFocused)
        .focusableSurface(true)
        .focused($isFocused)
    }
}
#endif
