import SwiftUI

// MARK: - Value Picker Row

/// How far a step through a `ValuePickerRow`'s options actually gets, kept out of the view so it is
/// testable. A two-option row is a TOGGLE and wraps in both directions; three or more are an ordered
/// list and clamp at their ends.
///
/// Sodalite#115: the select click is the only gesture that reaches every remote. On a toggle it steps,
/// and a clamped step gave any toggle already sitting on its last option a click that did nothing, which
/// is how "Stats for Nerds" could be switched on and never off again. Two states are peers, so there is
/// no end for them to clamp against. For a longer list there is, and the greyed chevron says so.
enum ValuePickerAdvance {

    /// The index a step lands on. `count` is the number of options.
    static func index(from current: Int, by step: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        guard count == 2 else { return max(0, min(count - 1, current + step)) }
        let wrapped = (current + step) % count
        return wrapped < 0 ? wrapped + count : wrapped
    }

    /// Whether that step changes anything, which is what greys a chevron out.
    static func canMove(from current: Int, by step: Int, count: Int) -> Bool {
        index(from: current, by: step, count: count) != current
    }

    /// Whether the select click opens the full list instead of stepping. A forward-only click on a
    /// clamped list stops dead at its end and can only get back with left, which the first-generation
    /// Siri Remote and a CEC TV remote do not reliably have; the list reaches every value in one pick.
    static func selectOpensList(count: Int) -> Bool {
        count > 2
    }
}

/// Full-width settings row: left/right steps through the options directly, Select flips a toggle or opens the list of a longer row, chevrons are cues not focus targets.
struct ValuePickerRow<Value: Hashable>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.settingsValueScope) private var valueScope
    @FocusState private var focused: Bool
    @State private var isListPresented = false

    /// iPhone compact stacks the picker control under the label (the one-line tvOS row overflows
    /// the narrow width, which collapses the label column and blows up the row height).
    private var isCompact: Bool { hSizeClass == .compact }

    #if os(tvOS)
    @State private var focusAcquiredAt: Date?
    #endif

    var body: some View {
        #if os(tvOS)
        // A Button, not `stableTap`: the system routes Select to the focused button's action, while
        // SwiftUI's long-press gesture only saw about one press in five on this row (measured on
        // Wohnzimmer, 2026-10-21: 11 of 11 presses reached the window, a handful the gesture).
        Button(action: selectPressed) { surface }
            .buttonStyle(ValuePickerRowButtonStyle())
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                focusAcquiredAt = isFocused ? Date() : nil
            }
            .onMoveCommand { direction in
                switch direction {
                case .left:  advance(by: -1)
                case .right: advance(by: 1)
                default: break
                }
            }
            .menuPresentation(isPresented: $isListPresented) {
                CatalogPickerSheet(
                    title: title,
                    options: options.indices.map { .init(id: String($0), label: label(options[$0])) },
                    selectedID: String(currentIndex),
                    onSelect: { id in
                        if let index = Int(id), options.indices.contains(index) {
                            selection = options[index]
                        }
                        isListPresented = false
                    },
                    onCancel: { isListPresented = false }
                )
            }
        #else
        // iOS uses the tappable chevrons, both directions.
        surface
            .focusableSurface(true)
            .focused($focused)
        #endif
    }

    private var surface: some View {
        layout
            .padding(.horizontal, isCompact ? 16 : 28)
            .padding(.vertical, isCompact ? 16 : 22)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(focused ? Color.Theme.focusFill : Color.Theme.restFillFaint)
            )
            .focusStroke(cornerRadius: 16, isFocused: focused)
            .focusResponse(.row, isFocused: focused)
            .animation(.easeInOut(duration: 0.15), value: selection)
    }

    #if os(tvOS)
    /// Select flips a two-option row and opens the list of a longer one. Dropped while focus is
    /// younger than `StableTapModifier.stableFocusWindow`, the same drift guard every other row has.
    private func selectPressed() {
        guard let acquired = focusAcquiredAt,
              Date().timeIntervalSince(acquired) >= StableTapModifier.stableFocusWindow
        else { return }
        if ValuePickerAdvance.selectOpensList(count: options.count) {
            isListPresented = true
        } else {
            advance(by: 1)
        }
    }
    #endif

    @ViewBuilder
    private var layout: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    iconView
                    labelView.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    pickerControl
                }
            }
        } else {
            HStack(alignment: .center, spacing: 36) {
                iconView
                labelView.frame(maxWidth: .infinity, alignment: .leading)
                pickerControl
            }
        }
    }

    private var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: isCompact ? 26 : 36))
            .frame(width: isCompact ? 40 : 64)
            .foregroundStyle(.tint)
    }

    private var labelView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Inside the card, so it cannot read as belonging to the next row (measured both ways on
            // 2026-09-17; a caption between two cards did).
            if valueScope == .device {
                DeviceScopeMark()
                    .padding(.top, 4)
            }
        }
    }

    private var pickerControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left")
                .font(.body)
                .foregroundStyle(focused ? .white : Color.secondary)
                .opacity(canMoveBackward ? 1 : 0.25)
                #if os(iOS)
                .padding(10)
                .contentShape(Rectangle())
                .onTapGesture { advance(by: -1) }
                #endif
            Text(label(selection))
                .font(.body)
                .fontWeight(.semibold)
                .foregroundStyle(focused ? .white : Color.white.opacity(0.85))
                .frame(minWidth: isCompact ? 72 : 110, alignment: .center)
                .contentTransition(.opacity)
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(focused ? .white : Color.secondary)
                .opacity(canMoveForward ? 1 : 0.25)
                #if os(iOS)
                .padding(10)
                .contentShape(Rectangle())
                .onTapGesture { advance(by: 1) }
                #endif
        }
    }

    private var currentIndex: Int {
        options.firstIndex(of: selection) ?? 0
    }

    private var canMoveBackward: Bool {
        ValuePickerAdvance.canMove(from: currentIndex, by: -1, count: options.count)
    }
    private var canMoveForward: Bool {
        ValuePickerAdvance.canMove(from: currentIndex, by: 1, count: options.count)
    }

    private func advance(by step: Int) {
        let newIdx = ValuePickerAdvance.index(from: currentIndex, by: step, count: options.count)
        if newIdx != currentIndex {
            selection = options[newIdx]
        }
    }
}

#if os(tvOS)
/// Draws the row as it is: the row carries its own fill, stroke and lift, and a custom style keeps
/// tvOS from adding its own focus effect on top.
private struct ValuePickerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif
