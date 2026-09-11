import SwiftUI

enum AccentPickerLayout {
    /// Every category ships at most five presets, so a fixed column count keeps
    /// the tiles at one size across category switches and gives the titles the
    /// full row width instead of the 219pt an adaptive grid settles on.
    static let tvOSColumnCount = 5

    /// Room for the focus lift of a category chip, INSIDE the strip's scroll view and taken back
    /// outside it, so it buys clip room without moving the strip. A ScrollView clips its content,
    /// and `FocusResponse.chip` scales by 5%: without this the first chip loses its left edge and
    /// every chip its top and bottom. Measured on the tvOS simulator: a 58.6pt chip grows 1.5pt per
    /// side, and the widest chip any locale can produce (Russian "Кинематографические" plus the
    /// crown, 382pt) 9.6pt. iOS carries no lift on these chips, so it reserves nothing.
    #if os(tvOS)
    static let chipLiftMargin: CGFloat = 14
    #else
    static let chipLiftMargin: CGFloat = 0
    #endif

    #if os(tvOS)
    static let columnSpacing: CGFloat = 24
    static let swatchSize: CGFloat = 80
    static let contentSpacing: CGFloat = 12
    /// Two lines of tvOS headline (38pt) plus leading. Long names in Ukrainian,
    /// Finnish and Polish need the second line, so the row reserves it even
    /// though most names fit on one. Both rows centre their content, otherwise
    /// the reserve reads as a hole under the name.
    static let titleHeight: CGFloat = 96
    /// One line of tvOS caption (25pt).
    static let statusHeight: CGFloat = 32
    #else
    static let columnSpacing: CGFloat = 18
    static let swatchSize: CGFloat = 64
    static let contentSpacing: CGFloat = 10
    static let titleHeight: CGFloat = 46
    static let statusHeight: CGFloat = 20
    #endif
}

struct AccentColorPickerView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var category: AccentCategory
    @State private var showSupport = false

    init(initialCategory: AccentCategory) {
        _category = State(initialValue: initialCategory)
    }

    private var preferences: AppearancePreferences {
        dependencies.appearancePreferences
    }

    private var isSupporter: Bool {
        dependencies.storeKitService.isSupporter
    }

    private var columns: [GridItem] {
        #if os(tvOS)
        Array(
            repeating: GridItem(
                .flexible(),
                spacing: AccentPickerLayout.columnSpacing,
                alignment: .top
            ),
            count: AccentPickerLayout.tvOSColumnCount
        )
        #else
        [GridItem(
            .adaptive(
                minimum: horizontalSizeClass == .compact ? 130 : 190,
                maximum: 260
            ),
            spacing: AccentPickerLayout.columnSpacing,
            alignment: .top
        )]
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text(String(
                    localized: "appearance.accentPicker.title",
                    defaultValue: "Accent Color"
                ))
                .font(.largeTitle.bold())

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(AccentCategory.allCases) { candidate in
                                AccentCategoryButton(
                                    category: candidate,
                                    selected: category == candidate
                                ) {
                                    category = candidate
                                }
                                .id(candidate)
                            }
                        }
                        .padding(AccentPickerLayout.chipLiftMargin)
                    }
                    .padding(-AccentPickerLayout.chipLiftMargin)
                    .focusSectionCompat()
                    #if os(iOS)
                    // The strip scrolls off screen on a phone, so an active
                    // category further right would be marked but invisible.
                    .onAppear { proxy.scrollTo(category, anchor: .center) }
                    #endif
                }

                LazyVGrid(
                    columns: columns,
                    spacing: AccentPickerLayout.columnSpacing
                ) {
                    ForEach(category.presets) { preset in
                        FocusableCard(
                            action: {
                                if preset.tier == .supporter && !isSupporter {
                                    requestSupportAccess()
                                } else {
                                    preferences.accentChoice = preset
                                }
                            },
                            exposesButtonSemantics: true
                        ) { focused in
                            AccentPresetTile(
                                preset: preset,
                                selected: preferences.accentChoice == preset,
                                locked: preset.tier == .supporter && !isSupporter,
                                focused: focused
                            )
                        }
                    }
                }
            }
            .screenContentInset()
        }
        .hidesNavigationBarChrome()
        .navigationDestination(isPresented: $showSupport) {
            SupportDevelopmentView()
                .hidesShellTabBar()
                .themedNavigationDestination()
        }
    }

    private func requestSupportAccess() {
        guard dependencies.parentalGateRequiredForSessionAction() else {
            showSupport = true
            return
        }

        Task {
            guard await dependencies.parentalGate.challenge(
                reason: .openParentalSettings
            ) else { return }
            showSupport = true
        }
    }
}

/// The active category and the focused/pressed one are separate axes: fill and
/// text colour carry "this is the category you are looking at", the border and
/// the scale carry "this is what the remote is on". Encoding both as a border
/// would leave the active category invisible the moment focus moves into the
/// grid, which is what shipped before.
private enum AccentCategoryChip {
    static let cornerRadius: CGFloat = 16

    static func foreground(selected: Bool, active: Bool) -> AnyShapeStyle {
        if selected { return active ? AnyShapeStyle(.white) : AnyShapeStyle(.tint) }
        return active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
    }

    static func background(selected: Bool, active: Bool) -> AnyShapeStyle {
        if selected {
            return AnyShapeStyle(TintShapeStyle.tint.opacity(active ? 0.4 : 0.2))
        }
        return AnyShapeStyle(Color.white.opacity(active ? 0.18 : 0.06))
    }
}

#if os(iOS)
private struct AccentCategoryChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AccentCategoryChip.foreground(
                selected: selected,
                active: configuration.isPressed
            ))
            .background(
                RoundedRectangle(cornerRadius: AccentCategoryChip.cornerRadius)
                    .fill(AccentCategoryChip.background(
                        selected: selected,
                        active: configuration.isPressed
                    ))
            )
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.15), value: selected)
    }
}
#endif

private struct AccentCategoryButton: View {
    let category: AccentCategory
    let selected: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        label
            .foregroundStyle(AccentCategoryChip.foreground(
                selected: selected,
                active: focused
            ))
            .background(
                RoundedRectangle(cornerRadius: AccentCategoryChip.cornerRadius)
                    .fill(AccentCategoryChip.background(
                        selected: selected,
                        active: focused
                    ))
            )
            .focusStroke(cornerRadius: AccentCategoryChip.cornerRadius, isFocused: focused)
            .focusResponse(.chip, isFocused: focused)
            .focusable(true)
            .focused($focused)
            .stableTap(isFocused: focused, perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction { action() }
            .animation(.easeInOut(duration: 0.2), value: selected)
        #else
        Button(action: action) {
            label
        }
        .buttonStyle(AccentCategoryChipStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        #endif
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text(category.title)
                .fontWeight(selected ? .semibold : .regular)
            if category != .basic {
                Image(systemName: "crown.fill")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct AccentPresetTile: View {
    let preset: AccentPreset
    let selected: Bool
    let locked: Bool
    let focused: Bool

    var body: some View {
        VStack(spacing: AccentPickerLayout.contentSpacing) {
            Circle()
                .fill(preset.palette.control.color)
                .frame(
                    width: AccentPickerLayout.swatchSize,
                    height: AccentPickerLayout.swatchSize
                )
                .overlay(Circle().stroke(Color.Theme.hairline, lineWidth: 1))
            Text(preset.title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .frame(height: AccentPickerLayout.titleHeight)
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark")
                    Text(selectedLabel)
                }
                if locked {
                    Image(systemName: "crown.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(height: AccentPickerLayout.statusHeight)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(focused ? 0.12 : 0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    selected ? preset.palette.control.color : .clear,
                    lineWidth: 3
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(Text(accessibilityValue))
    }

    private var selectedLabel: String {
        String(localized: "appearance.selected", defaultValue: "Selected")
    }

    private var lockedLabel: String {
        String(
            localized: "settings.appearance.locked.title",
            defaultValue: "Part of the Supporter Pack"
        )
    }

    private var accessibilityValue: String {
        [selected ? selectedLabel : nil, locked ? lockedLabel : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
