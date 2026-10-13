import SwiftUI

/// What Sodalite keeps on this device, and a way to drop it (Sodalite#117, DrHurt).
///
/// The point of the screen is not the numbers, it is the button. A cache that can only be cleared
/// by a factory reset is a cache you have to give up your servers and your settings to get rid of,
/// which is why the one suspicion nobody could act on was "maybe something cached is wrong". The
/// figures are here so the button is not a leap of faith: you can see there was something, and see
/// that it went.
///
/// Rows follow the Settings conventions (SettingsTileButtonStyle for the action, .alert to confirm).
/// The sizes are read off the main actor because the entry cache is counted by walking its files.
struct CachedDataView: View {
    @Environment(\.dependencies) private var dependencies

    @State private var footprint: CacheFootprint?
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                header

                sizeRow(
                    icon: "square.grid.2x2",
                    title: "settings.cachedData.rows.title",
                    subtitle: "settings.cachedData.rows.subtitle",
                    bytes: footprint?.feedAndLists
                )

                sizeRow(
                    icon: "arrow.down.circle",
                    title: "settings.cachedData.responses.title",
                    subtitle: "settings.cachedData.responses.subtitle",
                    bytes: footprint?.serverResponses
                )

                sizeRow(
                    icon: "photo",
                    title: "settings.cachedData.artwork.title",
                    subtitle: "settings.cachedData.artwork.subtitle",
                    bytes: footprint?.artwork
                )

                clearRow

                Text("settings.cachedData.footnote", bundle: .main)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            .screenContentInset()
        }
        .hidesNavigationBarChrome()
        .task { await refresh() }
        .alert(
            Text("settings.cachedData.clear.confirm.title", bundle: .main),
            isPresented: $confirmClear
        ) {
            Button("settings.cachedData.clear.confirm.action", role: .destructive) {
                dependencies.clearCachedData()
                Task { await refresh() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.cachedData.clear.confirm.message", bundle: .main)
        }
    }

    private var header: some View {
        Text("settings.cachedData.title", bundle: .main)
            .font(.largeTitle)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
    }

    /// Off the main actor: counting the entry cache means asking the filesystem for the size of
    /// every file in it, and this screen is opened while the rest of the app is still live.
    private func refresh() async {
        let dependencies = dependencies
        footprint = await Task.detached(priority: .userInitiated) {
            dependencies.cacheFootprint()
        }.value
    }

    private func sizeRow(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        bytes: Int?
    ) -> some View {
        HStack(spacing: 28) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 56, alignment: .center)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.size(bytes))
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    private var clearRow: some View {
        Button { confirmClear = true } label: {
            HStack(spacing: 28) {
                Image(systemName: "trash")
                    .font(.title2)
                    .frame(width: 56, alignment: .center)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.cachedData.clear.title", bundle: .main)
                        .font(.body)
                        .fontWeight(.medium)
                    Text("settings.cachedData.clear.subtitle", bundle: .main)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
        // Only once the walk has answered and answered zero. While it is still counting the button
        // stays live, because on tvOS a screen that arrives with nothing focusable has nowhere to
        // put focus, and clearing a cache that is already empty costs nothing anyway.
        .disabled(footprint?.isEmpty == true)
        .opacity(footprint?.isEmpty == true ? 0.4 : 1)
    }

    /// A dash until the walk has answered, so an empty cache and an unread one do not both read as
    /// "0 bytes" while the screen is still counting.
    private static func size(_ bytes: Int?) -> String {
        guard let bytes else { return "–" }
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// `allowsNonnumericFormatting` off, because the default renders zero as "Zero KB", and the one
    /// moment every figure on this screen is zero is the moment just after the button was pressed,
    /// which is when it has to read like an answer.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
