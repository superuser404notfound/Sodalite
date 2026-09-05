import SwiftUI
import AetherEngine

/// Playback preferences UI; each row is a focusable left/right value cycler (no click), like native tvOS Settings.
struct PlaybackSettingsView: View {
    @Environment(\.dependencies) private var dependencies

    /// Read once per appearance, not per body pass: the DV row is inert on a display that has Dolby
    /// Vision of its own, and the capability read walks the screen's HDR modes.
    @State private var displayHasDolbyVision = false

    private var prefs: PlaybackPreferences { dependencies.playbackPreferences }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.bottom, 24)

                sectionHeader("settings.playback.section.episodes")

                boolRow(
                    icon: "play.square.stack",
                    title: "settings.playback.autoplayNextEp",
                    subtitle: "settings.playback.autoplayNextEp.subtitle",
                    value: Binding(
                        get: { prefs.autoplayNextEpisode },
                        set: { prefs.autoplayNextEpisode = $0 }
                    )
                )

                // Off plays the episode out (credits, post-credit scenes) and switches at its real end
                // instead of counting down over the outro (Sodalite#67). Inert without autoplay, so it
                // greys out with it rather than offering a switch that cannot do anything.
                boolRow(
                    icon: "timer",
                    title: "settings.playback.autoplayCountdown",
                    subtitle: "settings.playback.autoplayCountdown.subtitle",
                    value: Binding(
                        get: { prefs.autoplayCountdown },
                        set: { prefs.autoplayCountdown = $0 }
                    )
                )
                .disabled(!prefs.autoplayNextEpisode)
                .opacity(prefs.autoplayNextEpisode ? 1 : 0.4)

                boolRow(
                    icon: "forward.end.fill",
                    title: "settings.playback.autoSkipIntro",
                    subtitle: "settings.playback.autoSkipIntro.subtitle",
                    value: Binding(
                        get: { prefs.autoSkipIntro },
                        set: { prefs.autoSkipIntro = $0 }
                    )
                )

                boolRow(
                    icon: "forward.frame.fill",
                    title: "settings.playback.autoSkipRecap",
                    subtitle: "settings.playback.autoSkipRecap.subtitle",
                    value: Binding(
                        get: { prefs.autoSkipRecap },
                        set: { prefs.autoSkipRecap = $0 }
                    )
                )

                boolRow(
                    icon: "forward.end.alt.fill",
                    title: "settings.playback.autoSkipOutro",
                    subtitle: "settings.playback.autoSkipOutro.subtitle",
                    value: Binding(
                        get: { prefs.autoSkipOutro },
                        set: { prefs.autoSkipOutro = $0 }
                    )
                )

                // Countdown LENGTH stays out of settings: Netflix/Prime hardcode 8-12 s. The knobs are
                // autoplay itself and, since Sodalite#67, the countdown on/off row above it.

                sectionHeader("settings.playback.section.controls")

                ValuePickerRow(
                    icon: "goforward",
                    title: "settings.playback.skipInterval",
                    subtitle: "settings.playback.skipInterval.subtitle",
                    options: PlaybackPreferences.skipIntervalChoices,
                    selection: Binding(
                        get: { prefs.skipIntervalSeconds },
                        set: { prefs.skipIntervalSeconds = $0 }
                    ),
                    label: { seconds in "\(seconds) s" }
                )

                #if os(tvOS)
                boolRow(
                    icon: "hand.draw",
                    title: "settings.playback.touchpadScrubbing",
                    subtitle: "settings.playback.touchpadScrubbing.subtitle",
                    value: Binding(
                        get: { prefs.touchpadScrubbing },
                        set: { prefs.touchpadScrubbing = $0 }
                    )
                )
                #endif

                boolRow(
                    icon: "rectangle.center.inset.filled.badge.plus",
                    title: "settings.playback.scrubPreview",
                    subtitle: "settings.playback.scrubPreview.subtitle",
                    value: Binding(
                        get: { prefs.showScrubPreview },
                        set: { prefs.showScrubPreview = $0 }
                    )
                )

                if prefs.showScrubPreview {
                    boolRow(
                        icon: "square.grid.3x3.fill",
                        title: "settings.playback.serverTrickplay",
                        subtitle: "settings.playback.serverTrickplay.subtitle",
                        value: Binding(
                            get: { prefs.preferServerTrickplay },
                            set: { prefs.preferServerTrickplay = $0 }
                        )
                    )
                }

                sectionHeader("settings.playback.section.streaming")

                ValuePickerRow(
                    icon: "arrow.down.circle",
                    title: "settings.playback.buffer",
                    subtitle: "settings.playback.buffer.subtitle",
                    options: PlaybackPreferences.NetworkBufferDepth.allCases,
                    selection: Binding(
                        get: { prefs.networkBufferDepth },
                        set: { prefs.networkBufferDepth = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                sectionHeader("settings.playback.section.languages")

                languageRow(
                    icon: "speaker.wave.2",
                    title: "settings.playback.preferredAudio",
                    subtitle: "settings.playback.preferredAudio.subtitle",
                    choices: PlaybackPreferences.audioLanguageChoices,
                    selection: Binding(
                        get: { prefs.preferredAudioLanguage },
                        set: { prefs.preferredAudioLanguage = $0 }
                    )
                )

                languageRow(
                    icon: "captions.bubble",
                    title: "settings.playback.preferredSubtitle",
                    subtitle: "settings.playback.preferredSubtitle.subtitle",
                    choices: PlaybackPreferences.subtitleLanguageChoices,
                    selection: Binding(
                        get: { prefs.preferredSubtitleLanguage },
                        set: { prefs.preferredSubtitleLanguage = $0 }
                    )
                )

                boolRow(
                    icon: "captions.bubble.fill",
                    title: "settings.playback.autoSubtitleForeign",
                    subtitle: "settings.playback.autoSubtitleForeign.subtitle",
                    value: Binding(
                        get: { prefs.autoSubtitleForForeignAudio },
                        set: { prefs.autoSubtitleForForeignAudio = $0 }
                    )
                )

                boolRow(
                    icon: "text.bubble.fill",
                    title: "settings.playback.autoForcedSubtitles",
                    subtitle: "settings.playback.autoForcedSubtitles.subtitle",
                    value: Binding(
                        get: { prefs.autoForcedSubtitles },
                        set: { prefs.autoForcedSubtitles = $0 }
                    )
                )

                boolRow(
                    icon: "gobackward",
                    title: "settings.playback.subtitlesOnSkipBack",
                    subtitle: "settings.playback.subtitlesOnSkipBack.subtitle",
                    value: Binding(
                        get: { prefs.subtitlesOnSkipBack },
                        set: { prefs.subtitlesOnSkipBack = $0 }
                    )
                )

                boolRow(
                    icon: "bookmark",
                    title: "settings.playback.rememberTracks",
                    subtitle: "settings.playback.rememberTracks.subtitle",
                    value: Binding(
                        get: { prefs.rememberTrackSelections },
                        set: { prefs.rememberTrackSelections = $0 }
                    )
                )

                sectionHeader("settings.playback.section.subtitleStyle")

                boolRow(
                    icon: "wand.and.stars",
                    title: "settings.playback.subtitle.styledASS",
                    subtitle: "settings.playback.subtitle.styledASS.subtitle",
                    value: Binding(
                        get: { prefs.styledASSSubtitles },
                        set: { prefs.styledASSSubtitles = $0 }
                    )
                )

                ValuePickerRow(
                    icon: "textformat.size",
                    title: "settings.playback.subtitle.size",
                    subtitle: "settings.playback.subtitle.size.subtitle",
                    options: PlaybackPreferences.SubtitleFontSize.allCases,
                    selection: Binding(
                        get: { prefs.subtitleFontSize },
                        set: { prefs.subtitleFontSize = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                ValuePickerRow(
                    icon: "paintpalette",
                    title: "settings.playback.subtitle.color",
                    subtitle: "settings.playback.subtitle.color.subtitle",
                    options: PlaybackPreferences.SubtitleColor.allCases,
                    selection: Binding(
                        get: { prefs.subtitleColor },
                        set: { prefs.subtitleColor = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                ValuePickerRow(
                    icon: "number.square",
                    title: "settings.playback.teletext.title",
                    subtitle: "settings.playback.teletext.subtitle",
                    options: PlaybackPreferences.LiveTeletextPage.allCases,
                    selection: Binding(
                        get: { prefs.liveTeletextPage },
                        set: { prefs.liveTeletextPage = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                ValuePickerRow(
                    icon: "rectangle.fill",
                    title: "settings.playback.subtitle.background",
                    subtitle: "settings.playback.subtitle.background.subtitle",
                    options: PlaybackPreferences.SubtitleBackground.allCases,
                    selection: Binding(
                        get: { prefs.subtitleBackground },
                        set: { prefs.subtitleBackground = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                ValuePickerRow(
                    icon: "metronome",
                    title: "settings.playback.subtitle.delay",
                    subtitle: "settings.playback.subtitle.delay.subtitle",
                    options: PlaybackPreferences.subtitleDelayChoices,
                    selection: Binding(
                        get: {
                            // Snap persisted value to nearest option so a stale value doesn't render as a no-op picker.
                            let stored = prefs.subtitleDelaySeconds
                            return PlaybackPreferences.subtitleDelayChoices
                                .min(by: { abs($0 - stored) < abs($1 - stored) })
                                ?? 0
                        },
                        set: { prefs.subtitleDelaySeconds = $0 }
                    ),
                    label: PlaybackSettingsView.formatSubtitleDelay
                )

                ValuePickerRow(
                    icon: "arrow.up.and.down",
                    title: "settings.playback.subtitle.position",
                    subtitle: "settings.playback.subtitle.position.subtitle",
                    options: PlaybackPreferences.SubtitleVerticalPosition.allCases,
                    selection: Binding(
                        get: { prefs.subtitleVerticalPosition },
                        set: { prefs.subtitleVerticalPosition = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                ValuePickerRow(
                    icon: "textformat",
                    title: "settings.playback.subtitle.font",
                    subtitle: "settings.playback.subtitle.font.subtitle",
                    options: PlaybackPreferences.SubtitleFont.allCases,
                    selection: Binding(
                        get: { prefs.subtitleFont },
                        set: { prefs.subtitleFont = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                ValuePickerRow(
                    icon: "bold",
                    title: "settings.playback.subtitle.weight",
                    subtitle: "settings.playback.subtitle.weight.subtitle",
                    options: PlaybackPreferences.SubtitleWeight.allCases,
                    selection: Binding(
                        get: { prefs.subtitleWeight },
                        set: { prefs.subtitleWeight = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                sectionHeader("settings.playback.section.picture")

                ValuePickerRow(
                    icon: "rectangle.expand.vertical",
                    title: "settings.playback.picture",
                    subtitle: "settings.playback.picture.subtitle",
                    options: PlaybackPreferences.PictureMode.allCases,
                    selection: Binding(
                        get: { prefs.pictureMode },
                        set: { prefs.pictureMode = $0 }
                    ),
                    label: { String(localized: String.LocalizationValue($0.titleKey)) }
                )

                // AetherEngine#455: only a display without Dolby Vision of its own has anything to gain
                // here, so on one that has it the row greys out rather than offering a dead switch.
                boolRow(
                    icon: "sparkles.tv",
                    title: "settings.playback.forceDolbyVision",
                    subtitle: "settings.playback.forceDolbyVision.subtitle",
                    value: Binding(
                        get: { prefs.forceDolbyVisionOnNonDVDisplay },
                        set: { prefs.forceDolbyVisionOnNonDVDisplay = $0 }
                    )
                )
                .disabled(displayHasDolbyVision)
                .opacity(displayHasDolbyVision ? 0.4 : 1)

                sectionHeader("settings.playback.section.audio")

                boolRow(
                    icon: "hifispeaker",
                    title: "settings.playback.preferLossless",
                    subtitle: "settings.playback.preferLossless.subtitle",
                    value: Binding(
                        get: { prefs.preferLosslessAudioBridge },
                        set: { prefs.preferLosslessAudioBridge = $0 }
                    )
                )

                sectionHeader("settings.playback.section.advanced")

                boolRow(
                    icon: "info.circle",
                    title: "settings.playback.statsForNerds",
                    subtitle: "settings.playback.statsForNerds.subtitle",
                    value: Binding(
                        get: { prefs.showStatsForNerds },
                        set: { prefs.showStatsForNerds = $0 }
                    )
                )

                if prefs.showStatsForNerds {
                    boolRow(
                        icon: "waveform.path.ecg",
                        title: "settings.playback.engineDiagnostics.title",
                        subtitle: "settings.playback.engineDiagnostics.subtitle",
                        value: Binding(
                            get: { prefs.showEngineDiagnostics },
                            set: { prefs.showEngineDiagnostics = $0 }
                        )
                    )
                }
            }
            .screenContentInset()
            .task { displayHasDolbyVision = AetherEngine.displayCapabilities.supportsDolbyVision }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .hidesShellTabBar()
        // Suppress floating tvOS nav-title; we show our own inline header (default sits behind scrolling content).
        .hidesNavigationBarChrome()
    }

    // MARK: - Header

    private var header: some View {
        Text("settings.playback.title")
            .font(.largeTitle)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 24)
            .padding(.bottom, 4)
    }

    // MARK: - Rows

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

    /// Uses U+2212 minus (not hyphen) for parity with "+", and trims trailing zeroes.
    static func formatSubtitleDelay(_ seconds: Double) -> String {
        if seconds == 0 {
            return "0 s"
        }
        let abs = Swift.abs(seconds)
        let formatted: String
        if abs == abs.rounded() {
            formatted = "\(Int(abs))"
        } else {
            formatted = String(format: "%.2f", abs)
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        }
        let sign = seconds < 0 ? "\u{2212}" : "+"
        return "\(sign)\(formatted) s"
    }

    private func languageRow(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        choices: [PlaybackPreferences.LanguageChoice],
        selection: Binding<String?>
    ) -> some View {
        let choiceBinding = Binding<PlaybackPreferences.LanguageChoice>(
            get: { choices.first(where: { $0.code == selection.wrappedValue }) ?? choices[0] },
            set: { selection.wrappedValue = $0.code }
        )
        let labelFn: (PlaybackPreferences.LanguageChoice) -> String = { choice in
            String(localized: String.LocalizationValue(choice.titleKey))
        }
        return ValuePickerRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            options: choices,
            selection: choiceBinding,
            label: labelFn
        )
    }
}
