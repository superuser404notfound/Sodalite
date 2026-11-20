#if os(tvOS)
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Hands the diagnostic log to a phone on the same network (Sodalite#148).
///
/// tvOS only. iOS has a Copy button and a keyboard behind it; an Apple TV has neither, and the reporter
/// who asked for this was photographing the screen and running OCR over roughly 300 lines per report.
///
/// This half owns the server's lifetime: it starts on appear, stops on disappear, and the link dies with
/// the deadline whether or not anyone is looking. A log is a live document about someone's server, so an
/// export that outlives the screen it was started from would be a thing left switched on by accident.
/// What the panel LOOKS like is `LogExportPanelContent`, which has no side effects and can therefore be
/// hosted and measured (`LogExportPanelBudgetTests`).
struct LogExportPanel: View {
    /// The lines the reporter was looking at when they pressed the button. Frozen here rather than read
    /// inside the server, so the page and the screen show the same session.
    let lines: [String]
    let dismiss: () -> Void

    @State private var server = LogExportServer()
    @State private var endpoint: LogExportServer.Endpoint?
    @State private var failure: LogExportServer.StartError?
    @State private var hasExpired = false

    var body: some View {
        VStack(spacing: LogExportPanelContent.blockSpacing) {
            content

            LogActionButton(
                titleKey: hasExpired ? "home.retry" : "common.done",
                systemImage: hasExpired ? "arrow.clockwise" : "xmark",
                isEnabled: true,
                action: hasExpired ? start : dismiss
            )
        }
        .padding(LogExportPanelContent.padding)
        .frame(width: LogExportPanelContent.width)
        // A page of its own rather than a card over the log. The card let the log show through at the
        // edges, and the reporter read that as clutter around the one thing on screen that matters.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedPresentationBackground()
        .task { start() }
        .onDisappear { server.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if hasExpired {
            LogExportPanelContent.message(
                "settings.log.export.expired.title",
                detail: "settings.log.export.expired.message",
                isError: false
            )
        } else if failure != nil {
            LogExportPanelContent.message(
                "settings.log.export.failed.title",
                detail: "settings.log.export.failed.message",
                isError: true
            )
        } else if let endpoint {
            LogExportPanelContent(url: endpoint.url, expiresAt: endpoint.expiresAt)
                // Not a timer on the view: the deadline is one instant, and a task that sleeps to it
                // costs nothing in between and cancels itself when the panel goes away.
                .task(id: endpoint.expiresAt) {
                    let remaining = endpoint.expiresAt.timeIntervalSinceNow
                    guard remaining > 0 else { hasExpired = true; return }
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                    hasExpired = true
                }
        } else {
            ProgressView()
                .frame(height: LogExportPanelContent.codeSide)
        }
    }

    private func start() {
        hasExpired = false
        failure = nil
        do {
            endpoint = try server.start(lines: lines, persistedLog: LogTap.persistedLogURLs)
        } catch let error as LogExportServer.StartError {
            endpoint = nil
            failure = error
            LogTap.shared.note("[LogExport] start failed: \(error)")
        } catch {
            endpoint = nil
            failure = .noNetwork
        }
    }
}

/// The face of the export panel, with no server behind it.
///
/// Split out so its height can be measured rather than guessed. The first device round overran the
/// title-safe band and SwiftUI paid for it the way it always does, with a text line: the hint came back
/// as one truncated line and the address lost its tail, both of them at a distance from the cause. The
/// sizes below are budgeted against the 960 pt title-safe band, and `LogExportPanelBudgetTests` holds the
/// total there.
struct LogExportPanelContent: View {
    let url: URL
    let expiresAt: Date

    /// Wide rather than tall. The screen is 16:9 and the constraint is height, so the panel spends the
    /// axis it has: 1500 of the 1760 inside the overscan inset.
    ///
    /// The width is set by the address, which is the widest thing here and must not shrink. The longest
    /// one this can produce is 45 characters (`http://255.255.255.255:65535/` plus 16 hex), measured at
    /// 1335.2 pt in title3 monospaced, so the 1412 pt inside the padding carries it at full size with
    /// 77 pt to spare. At 1300 it did not: that left 1212, and even a short address on a 10.x network
    /// came to 1216.5 and was already being scaled, which would have made the type size depend on which
    /// address the router handed out. `LogExportPanelBudgetTests` pins the worst case at scale 1.
    static let width: CGFloat = 1500
    static let padding: CGFloat = 44
    static let blockSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 16
    /// 280 on a 55 inch panel is about 16 cm of printed code, which a phone reads from across a room.
    /// It was 340 in the first round, and the 60 pt are the cheapest ones in the column.
    static let codeSide: CGFloat = 280

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            Text("settings.log.export.title", bundle: .main)
                .font(.title2)
                .fontWeight(.semibold)

            qrCode

            // The address is spelled out under the code as well: a camera will not always focus on a
            // television, and the fallback has to be typeable rather than a second attempt at scanning.
            // The panel is sized so this never actually scales; the floor is only there so an address
            // nobody anticipated comes out small rather than cut in half.
            Text(url.absoluteString)
                .font(.system(.title3, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            HStack(spacing: 8) {
                Text("settings.log.export.expires", bundle: .main)
                Text(timerInterval: Date() ... expiresAt, countsDown: true)
                    .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text("settings.log.export.hint", bundle: .main)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
                // Makes the hint honest about its height. Without it a stack under a height offer
                // squeezes its own text and reports back the offered height, which is exactly how this
                // sentence came back as one line with an ellipsis instead of wrapping.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Black on white with a quiet zone of its own, never on the panel material: the generator's
    /// background is not guaranteed opaque, and dark modules on dark material scan as nothing.
    @ViewBuilder
    private var qrCode: some View {
        if let image = Self.qrImage(for: url) {
            Image(platformImage: image)
                // Nearest neighbour: a QR module is a hard square, and smoothing its edges is what
                // makes a code fail to scan from across a room.
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: Self.codeSide, height: Self.codeSide)
                .padding(20)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        } else {
            Self.message(
                "settings.log.export.failed.title",
                detail: "settings.log.export.failed.message",
                isError: true
            )
        }
    }

    /// Shared by the expired and the failed state, which are the panel's two other faces.
    @ViewBuilder
    static func message(
        _ titleKey: LocalizedStringKey,
        detail: LocalizedStringKey,
        isError: Bool
    ) -> some View {
        VStack(spacing: 12) {
            Text(titleKey)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(isError ? Color.Theme.destructive : .primary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 160)
    }

    private static func qrImage(for url: URL) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        // M corrects a quarter of the code. The next level up grows the module count, which on a
        // television means smaller squares for the same frame, and the code is read off a clean screen
        // rather than a creased label.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return PlatformImage.wrapping(cgImage, size: scaled.extent.size)
    }
}
#endif
