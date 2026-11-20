import SwiftUI

/// Settings → "Open Source Licenses": one row per third-party component,
/// pushing the component's notice + license text. Mirrors the Changelog
/// screen's layout and focus idioms.
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(String(
                    localized: "settings.licenses.title",
                    defaultValue: "Open Source Licenses"
                ))
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.bottom, 32)

                LazyVStack(spacing: 4) {
                    ForEach(OpenSourceLicenses.components) { component in
                        ComponentRow(component: component)
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, hSizeClass == .compact ? 16 : 80)

                Text(String(
                    localized: "settings.licenses.footer",
                    defaultValue: "Sodalite is open source under the GPL-3.0 with an App Store exception. This app uses FFmpeg and the other components listed above."
                ))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
                .padding(.top, 40)
                .padding(.bottom, 80)
            }
            .frame(maxWidth: .infinity)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hidesNavigationBarChrome()
        .onExitCommandCompat { dismiss() }
    }
}

private struct ComponentRow: View {
    let component: OpenSourceComponent

    var body: some View {
        NavigationLink {
            LicenseDetailView(component: component)
                .hidesShellTabBar()
                .themedNavigationDestination()
        } label: {
            HStack(spacing: 28) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .frame(width: 56, alignment: .center)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: component.name)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(verbatim: component.licenseName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
    }
}

private struct LicenseDetailView: View {
    let component: OpenSourceComponent

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(verbatim: component.name)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(verbatim: component.licenseName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(verbatim: component.url)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 20) {
                    if let notice = component.notice {
                        Paragraph(text: notice, emphasized: true)
                    }
                    ForEach(paragraphs, id: \.self) { paragraph in
                        Paragraph(text: paragraph, emphasized: false)
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, hSizeClass == .compact ? 16 : 80)
                .padding(.bottom, 80)
            }
            .frame(maxWidth: .infinity)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hidesNavigationBarChrome()
        .onExitCommandCompat { dismiss() }
    }

    /// Split on blank lines so tvOS focus can step through (and thereby scroll) the text.
    private var paragraphs: [String] {
        guard let text = OpenSourceLicenses.text(for: component) else { return [] }
        return text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct Paragraph: View {
    let text: String
    let emphasized: Bool

    // @FocusState not @Environment(\.isFocused): latter doesn't propagate into a plain .focusable() View on tvOS.
    @FocusState private var isFocused: Bool

    var body: some View {
        Text(verbatim: text)
            .font(emphasized ? .callout.weight(.medium) : .caption)
            .foregroundStyle(emphasized ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isFocused ? Color.Theme.focusFill : .white.opacity(emphasized ? 0.06 : 0.03))
            )
            // Not a `FocusResponse` role: this is the focusable reading block tvOS needs to scroll a
            // long licence, not a tile. At 900pt wide, 1.01 is 4.5pt per side, the same displacement
            // a 180pt profile card gets from 1.05. A tile's 1.03 would move it by 13.5pt (#130).
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(FocusResponse.settle, value: isFocused)
            .focusableSurface()
            .focused($isFocused)
    }
}
