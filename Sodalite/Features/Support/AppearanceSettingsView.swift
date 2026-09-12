import SwiftUI

struct AppearanceSettingsView: View {

    @Environment(\.dependencies) private var dependencies

    private var appearance: AppearancePreferences { dependencies.appearancePreferences }
    private var isSupporter: Bool { dependencies.storeKitService.isSupporter }
    private var effectiveTheme: ResolvedAppearanceTheme {
        appearance.resolvedTheme(isSupporter: isSupporter)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Text(String(
                    localized: "settings.appearance.title",
                    defaultValue: "Appearance"
                ))
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)

                header
                togglesSection
                personalizationSection
            }
            .screenContentInset()
        }
        // Inline largeTitle only; floating nav-title otherwise sits behind scroll content. Matches PlaybackSettingsView.
        .hidesNavigationBarChrome()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text(String(
                localized: "settings.appearance.subtitle",
                defaultValue: "Customize content, accent color, and background."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Options (free for everyone)

    /// Free rows above the supporter-gated accent picker; same ValuePickerRow as Playback for consistency.
    private var togglesSection: some View {
        VStack(spacing: 4) {
            boolRow(
                icon: "photo.on.rectangle",
                title: "settings.appearance.showLogos",
                subtitle: "settings.appearance.showLogos.subtitle",
                value: Binding(get: { appearance.showContentLogos },
                               set: { appearance.showContentLogos = $0 })
            )

            ValuePickerRow(
                icon: "rectangle.on.rectangle.angled",
                title: "settings.appearance.cwImage",
                subtitle: "settings.appearance.cwImage.subtitle",
                options: AppearancePreferences.ContinueWatchingImage.allCases,
                selection: Binding(get: { appearance.continueWatchingImage },
                                   set: { appearance.continueWatchingImage = $0 }),
                label: { $0.title }
            )

            boolRow(
                icon: "rectangle.expand.vertical",
                title: "settings.appearance.largeCards",
                subtitle: "settings.appearance.largeCards.subtitle",
                value: Binding(get: { appearance.largeCards },
                               set: { appearance.largeCards = $0 })
            )

            // Sodalite#136. Off by default: a poster is a title rather than the thing being
            // watched, and on a Favourites row, where most series are partly watched, a capsule
            // under every one of them is noise with nothing to resume. The episode card is not
            // affected, it always draws progress.
            boolRow(
                icon: "rectangle.bottomthird.inset.filled",
                title: "settings.appearance.posterProgress",
                subtitle: "settings.appearance.posterProgress.subtitle",
                value: Binding(get: { appearance.showPosterProgress },
                               set: { appearance.showPosterProgress = $0 })
            )

            // Sodalite#79. Off by default: the resolution pill is free, but filling in the picture
            // and sound pills costs a MediaStreams round trip per row.
            boolRow(
                icon: "4k.tv",
                title: "settings.appearance.posterBadges",
                subtitle: "settings.appearance.posterBadges.subtitle",
                value: Binding(get: { appearance.showPosterBadges },
                               set: { appearance.showPosterBadges = $0 })
            )

            // Sodalite#84. Off by default: most library images have the library's name burnt in,
            // and ours on top makes two captions. On for viewers whose images carry no text.
            boolRow(
                icon: "textformat",
                title: "settings.appearance.libraryNames",
                subtitle: "settings.appearance.libraryNames.subtitle",
                value: Binding(get: { appearance.showLibraryNames },
                               set: { appearance.showLibraryNames = $0 })
            )

            #if os(tvOS)
            // The row can show another household member's Continue Watching, because the shelf
            // extension is stuck on the Default user (Apple bug, see TopShelfEnabled).
            boolRow(
                icon: "menubar.dock.rectangle",
                title: "settings.appearance.topShelf",
                subtitle: "settings.appearance.topShelf.subtitle",
                value: Binding(get: { appearance.showTopShelfRow },
                               set: { appearance.showTopShelfRow = $0 })
            )

            // Its own choice rather than a reader of the Continue Watching row above: a shelf cell
            // is around 800pt wide against a 360pt card, and an episode still is capped at the
            // server's image-extraction width, so the two surfaces do not want the same answer.
            ValuePickerRow(
                icon: "photo.on.rectangle",
                title: "settings.appearance.topShelfImage",
                subtitle: "settings.appearance.topShelfImage.subtitle",
                options: AppearancePreferences.ContinueWatchingImage.allCases,
                selection: Binding(get: { appearance.topShelfImage },
                                   set: { appearance.topShelfImage = $0 }),
                label: { $0.title }
            )
            #endif

            boolRow(
                icon: "music.note.tv",
                title: "settings.appearance.nowPlayingPoster",
                subtitle: "settings.appearance.nowPlayingPoster.subtitle",
                value: Binding(get: { appearance.nowPlayingUsesSeriesPoster },
                               set: { appearance.nowPlayingUsesSeriesPoster = $0 })
            )

            // Sodalite#127. On by default, one row per source: the star is a community average,
            // the percentage is the tomatometer, and a viewer can object to either alone.
            boolRow(
                icon: "star",
                title: "settings.appearance.communityRating",
                subtitle: "settings.appearance.communityRating.subtitle",
                value: Binding(get: { appearance.showCommunityRating },
                               set: { appearance.showCommunityRating = $0 })
            )

            boolRow(
                icon: "percent",
                title: "settings.appearance.criticRating",
                subtitle: "settings.appearance.criticRating.subtitle",
                value: Binding(get: { appearance.showCriticRating },
                               set: { appearance.showCriticRating = $0 })
            )

            // Sodalite#50. The two sub-rows stay visible while protection is off: this screen has
            // no conditional rows, and rows appearing under the focused one is a tvOS focus hazard.
            boolRow(
                icon: "eye.slash",
                title: "settings.appearance.spoiler",
                subtitle: "settings.appearance.spoiler.subtitle",
                value: Binding(get: { appearance.spoilerProtectionEnabled },
                               set: { appearance.spoilerProtectionEnabled = $0 })
            )

            boolRow(
                icon: "tv",
                title: "settings.appearance.spoilerEpisodes",
                subtitle: "settings.appearance.spoilerEpisodes.subtitle",
                value: Binding(get: { appearance.spoilerHideEpisodes },
                               set: { appearance.spoilerHideEpisodes = $0 })
            )

            boolRow(
                icon: "film",
                title: "settings.appearance.spoilerMovies",
                subtitle: "settings.appearance.spoilerMovies.subtitle",
                value: Binding(get: { appearance.spoilerHideMovies },
                               set: { appearance.spoilerHideMovies = $0 })
            )
        }
    }

    private func boolRow(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        value: Binding<Bool>
    ) -> some View {
        ValuePickerRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            options: [false, true],
            selection: value,
            label: { on in
                on
                    ? String(localized: "settings.playback.on", defaultValue: "On")
                    : String(localized: "settings.playback.off", defaultValue: "Off")
            }
        )
    }

    private var personalizationSection: some View {
        VStack(spacing: 4) {
            NavigationLink {
                AccentColorPickerView(initialCategory: appearance.accentChoice.category)
                    .themedNavigationDestination()
            } label: {
                AppearanceNavigationRow(
                    icon: "paintpalette.fill",
                    title: String(localized: "appearance.accentPicker.title",
                                  defaultValue: "Accent Color"),
                    value: accentSummary
                ) {
                    Circle()
                        .fill(effectiveTheme.palette.control.color)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(Color.Theme.hairline, lineWidth: 1))
                }
            }
            .buttonStyle(SettingsTileButtonStyle())

            NavigationLink {
                BackgroundPickerView()
                    .themedNavigationDestination()
            } label: {
                AppearanceNavigationRow(
                    icon: "rectangle.inset.filled",
                    title: String(localized: "appearance.backgroundPicker.title",
                                  defaultValue: "Background"),
                    value: backgroundSummary
                ) {
                    AppBackgroundView(
                        theme: effectiveTheme,
                        mode: .static
                    )
                    .frame(width: 52, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.Theme.hairline, lineWidth: 1)
                    }
                }
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
    }

    private var accentSummary: String {
        "\(effectiveTheme.accent.category.title) · \(effectiveTheme.accent.title)"
    }

    private var backgroundSummary: String {
        let motionState: String
        switch effectiveTheme.background {
        case .graphiteGlass, .oledBlack:
            motionState = String(
                localized: "appearance.motion.static",
                defaultValue: "Static"
            )
        case .accentAurora, .cinemaNoir:
            motionState = String(
                localized: "appearance.motion.animated",
                defaultValue: "Animated"
            )
        }
        return "\(motionState) · \(effectiveTheme.background.title)"
    }
}

private struct AppearanceNavigationRow<Preview: View>: View {
    let icon: String
    let title: String
    let value: String
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 34)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            preview()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .contentShape(Rectangle())
    }
}
