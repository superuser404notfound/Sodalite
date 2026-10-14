#if os(iOS)
import SwiftUI

/// The iPhone and iPad shape of the sign-in screens, on Apple's own setup-screen pattern: a centred
/// mark, a large title and a line under it, the screen's content in cards, and its actions pinned
/// to the bottom where a thumb reaches them and the keyboard pushes them up instead of covering
/// them. tvOS keeps its focus-driven layout; this is only the touch one.
///
/// The screens used to share the tvOS stack verbatim, grey tiles floating in the middle of an
/// otherwise empty page with no primary action to it, which is the first thing a new user sees
/// (r/jellyfin feedback on 1.0, 2026-10).
struct OnboardingScaffold<Mark: View, Content: View, Actions: View>: View {
    let title: Text
    var subtitle: Text? = nil
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    /// The actions ride up on the keyboard, and with the mark and a large title above them a
    /// two-field form no longer fits between the two: the fields ran under the buttons (device,
    /// 2026-10-14). While the keyboard is up the mark steps aside and the title shrinks, the way
    /// the system's own setup screens make room.
    @State private var keyboardIsUp = false

    var body: some View {
        ScrollView {
            VStack(spacing: keyboardIsUp ? 20 : 28) {
                VStack(spacing: 16) {
                    if !keyboardIsUp {
                        mark()
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                    VStack(spacing: 8) {
                        title
                            .font(keyboardIsUp ? .title2.bold() : .largeTitle.bold())
                            .multilineTextAlignment(.center)
                        if let subtitle {
                            subtitle
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, keyboardIsUp ? 8 : 24)
            .padding(.bottom, 16)
            .frame(maxWidth: Self.columnWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                actions()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: Self.columnWidth)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardIsUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardIsUp = false }
        }
    }

    /// One column on an iPad too, the width of a form rather than of the screen.
    static var columnWidth: CGFloat { 520 }
}

extension OnboardingScaffold where Mark == OnboardingLogo {
    init(
        title: Text,
        subtitle: Text? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(title: title, subtitle: subtitle, mark: { OnboardingLogo() }, content: content, actions: actions)
    }
}

/// The app's mark. The artwork carries its own glow on a transparent ground, so it stands free
/// rather than in an icon tile.
struct OnboardingLogo: View {
    var size: CGFloat = 112

    var body: some View {
        Image("Logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A group of rows on one flat surface, the touch counterpart of the tvOS tiles.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity)
        .background(Color.Theme.restFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.Theme.panelEdge, lineWidth: 1)
        }
    }
}

/// Hairline between two rows of an `OnboardingCard`, inset like a system list's.
struct OnboardingCardDivider: View {
    var leadingInset: CGFloat = 16

    var body: some View {
        Rectangle()
            .fill(Color.Theme.panelEdge)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

/// The screen's one primary action: full width, on the accent, in the detail page's Play pill.
struct OnboardingPrimaryButton: View {
    let title: LocalizedStringKey
    var isLoading: Bool = false
    let action: () -> Void

    @Environment(\.appearanceTheme) private var appearanceTheme
    @Environment(\.isEnabled) private var isEnabled

    /// The accent's own foreground, as on every other accent fill (Sodalite#111).
    private var contentColor: Color { appearanceTheme.palette.foreground.color }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(contentColor)
                } else {
                    Text(title)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassButtonStyle(isProminent: true, contentColor: contentColor))
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(isLoading)
    }
}

/// A quieter way on beside the primary action: text on the accent, no fill.
struct OnboardingSecondaryButton: View {
    let title: LocalizedStringKey
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading { ProgressView() }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(isLoading)
    }
}

/// A small status or error line under a card.
struct OnboardingFootnote: View {
    let text: Text
    var isError: Bool = false

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(isError ? AnyShapeStyle(Color.Theme.destructive) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
#endif
