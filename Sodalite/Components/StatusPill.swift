import SwiftUI

/// The capsule that marks a row's state: active, default, already added.
///
/// One shape everywhere. `fixedSize` keeps the label on a single line, so a
/// long neighbour (a server name) is what wraps or truncates, never the status
/// itself: the German "Bereits hinzugefügt" measures 229pt at tvOS caption1,
/// which a broken capsule renders as if it were cut off.
struct StatusPill: View {
    enum Tone {
        /// Carries the accent colour. For the state a row is in.
        case accent
        /// Muted. For a detail that qualifies the accent pill next to it.
        case neutral
    }

    private let title: LocalizedStringKey
    private let tone: Tone
    @Environment(\.appearanceTheme) private var appearanceTheme

    init(_ title: LocalizedStringKey, tone: Tone = .accent) {
        self.title = title
        self.tone = tone
    }

    var body: some View {
        Text(title, bundle: .main)
            .font(.caption.bold())
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(background, in: Capsule())
            .fixedSize()
    }

    /// The accent pill is the accent itself, solid, labelled in its paired foreground like every
    /// other accent-filled shape (Sodalite#166). A tint wash under fixed white read as a muddied
    /// accent, and white is only legible on the darker presets.
    private var foreground: AnyShapeStyle {
        switch tone {
        case .accent: AnyShapeStyle(appearanceTheme.palette.foreground.color)
        case .neutral: AnyShapeStyle(.secondary)
        }
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .accent: AnyShapeStyle(appearanceTheme.palette.control.color)
        case .neutral: AnyShapeStyle(.secondary.opacity(0.15))
        }
    }
}
