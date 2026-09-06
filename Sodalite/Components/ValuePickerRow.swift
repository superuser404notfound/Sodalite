import SwiftUI

// MARK: - Value Picker Row

/// How far a step through a `ValuePickerRow`'s options actually gets, kept out of the view so it is
/// testable. A two-option row is a TOGGLE and wraps in both directions; three or more are an ordered
/// list and clamp at their ends.
///
/// Sodalite#115: the select click is the only gesture that reaches every remote, and it only ever steps
/// forward. With a clamped step that gave any toggle already sitting on its last option a click that did
/// nothing, which is how "Stats for Nerds" could be switched on and never off again. Two states are peers,
/// so there is no end for them to clamp against. For a longer list there is, and the greyed chevron says so.
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
}

/// Full-width settings row: left/right cycles options directly (no dropdown), Select also advances forward, chevrons are cues not focus targets.
struct ValuePickerRow<Value: Hashable>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @FocusState private var focused: Bool

    /// iPhone compact stacks the picker control under the label (the one-line tvOS row overflows
    /// the narrow width, which collapses the label column and blows up the row height).
    private var isCompact: Bool { hSizeClass == .compact }

    var body: some View {
        layout
            .padding(.horizontal, isCompact ? 16 : 28)
            .padding(.vertical, isCompact ? 16 : 22)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(focused ? Color.Theme.focusFill : Color.Theme.restFillFaint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(focused ? 1 : 0)
            )
            .scaleEffect(focused ? 1.015 : 1.0)
            .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 6)
            .focusable(true)
            .focused($focused)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .animation(.easeInOut(duration: 0.15), value: selection)
            #if os(tvOS)
            .onMoveCommand { direction in
                switch direction {
                case .left:  advance(by: -1)
                case .right: advance(by: 1)
                default: break
                }
            }
            // tvOS: Select also advances forward (focus-gated). iOS uses the tappable chevrons (both
            // directions); on a list of three or more a forward-only tap still cannot reach a lower option,
            // which is what the chevrons are for. On a two-option row it wraps, so a click is a full toggle.
            .stableTap(isFocused: focused) {
                advance(by: 1)
            }
            #endif
    }

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
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
