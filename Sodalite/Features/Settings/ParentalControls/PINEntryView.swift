import Combine
import SwiftUI

/// Whose PIN is being collected.
enum PINTarget: Equatable, Identifiable {
    case guardian
    case profile(ProfileRef)

    var id: String {
        switch self {
        case .guardian: "guardian"
        case .profile(let ref): ref.compositeID
        }
    }
}

/// What the PIN pad is being used for.
enum PINEntryMode: Equatable {
    /// Set a new PIN for `target`: enter, then confirm. Persists via the container.
    case setup(PINTarget)
    /// Verify the existing PIN for `reason`.
    case unlock(reason: PINReason)
}

/// 4-digit PIN pad. .unlock verifies through dependencies.verifyPIN(_:for:), which resolves the reason to its door; .setup collects+confirms and persists to the target, refusing a PIN that already opens another door. "Forgot PIN?" opens recovery, which either clears this profile's own PIN or flips the pad into collecting a new Guardian PIN.
struct PINEntryView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.verticalSizeClass) private var vSizeClass

    private var isPhoneLandscape: Bool {
        #if os(iOS)
        vSizeClass == .compact
        #else
        false
        #endif
    }

    let mode: PINEntryMode
    /// Called with true (unlocked / set) or false (cancelled).
    let onComplete: (Bool) -> Void

    private static let pinLength = 4

    /// True = collecting a new PIN (setup, or post-recovery); false = verifying existing (unlock).
    @State private var collectingNewPIN: Bool
    @State private var entered = ""
    @State private var firstEntry: String?      // collection: holds the first pass
    @State private var message: LocalizedStringKey?
    @State private var isError = false
    @State private var lockoutUntil: Date?
    @State private var showRecovery = false

    // Re-evaluated every second so the lockout countdown ticks.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(mode: PINEntryMode, onComplete: @escaping (Bool) -> Void) {
        self.mode = mode
        self.onComplete = onComplete
        if case .setup = mode {
            _collectingNewPIN = State(initialValue: true)
        } else {
            _collectingNewPIN = State(initialValue: false)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()

            // Phone landscape is ~440 pt tall and the stacked layout needs ~560, so the pad moves
            // beside the title and the actions there instead of below them.
            if isPhoneLandscape {
                HStack(spacing: 64) {
                    VStack(spacing: 28) {
                        header
                        actions
                    }
                    pad
                }
                .screenContentInset()
            } else {
                VStack(spacing: 40) {
                    header
                    pad
                    actions
                }
                .screenContentInset()
            }
        }
        .onAppear { lockoutUntil = currentDoorLockout }
        // Only advance `now` (and re-render) while a lockout countdown is actually running;
        // during normal PIN entry the 1 Hz tick would otherwise invalidate the whole view for nothing.
        .onReceive(ticker) { if lockoutUntil != nil { now = $0 } }
        .fullScreenCoverCompat(isPresented: $showRecovery) {
            PINRecoveryView(
                onRecovered: {
                    showRecovery = false
                    switch recoveryOutcome {
                    case .clearOwnPIN(let ref):
                        // The door in front of the user was this profile's own PIN, so that is what
                        // recovery repairs. It now takes the Guardian PIN, which is the stricter key.
                        dependencies.clearOwnPIN(for: ref)
                        onComplete(true)
                    case .collectNewGuardianPIN:
                        collectingNewPIN = true
                        firstEntry = nil
                        entered = ""
                        message = "parental.pin.recovery.setNew"
                        isError = false
                        lockoutUntil = nil
                    }
                },
                onCancel: { showRecovery = false }
            )
        }
    }

    // MARK: Title

    private var title: LocalizedStringKey {
        if collectingNewPIN {
            if firstEntry != nil { return "parental.pin.setup.confirm" }
            if case .profile = collectTarget { return "parental.pin.setup.profile.title" }
            return "parental.pin.setup.title"
        }
        switch mode {
        case .setup:
            return "parental.pin.setup.title"
        case .unlock(let reason):
            switch reason {
            case .switchProfile: return "parental.pin.unlock.switchProfile"
            case .enterProfile: return "parental.pin.unlock.enterProfile"
            case .logout: return "parental.pin.unlock.logout"
            case .serverManagement: return "parental.pin.unlock.serverManagement"
            case .openParentalSettings: return "parental.pin.unlock.settings"
            }
        }
    }

    // MARK: Dots

    private var dots: some View {
        HStack(spacing: 28) {
            ForEach(0..<Self.pinLength, id: \.self) { i in
                Circle()
                    .strokeBorder(.white.opacity(0.6), lineWidth: 2)
                    .background(Circle().fill(i < entered.count ? Color.white : .clear))
                    .frame(width: 24, height: 24)
            }
        }
    }

    // MARK: Digit pad

    @ViewBuilder private var header: some View {
        Text(title)
            .font(.title2).fontWeight(.semibold)

        dots

        if let message {
            Text(message)
                .font(.callout)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
        }

        if let remaining = lockoutRemaining {
            Text("parental.pin.lockedOut \(remaining)")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var pad: some View {
        digitPad
            .disabled(lockoutRemaining != nil)
            .opacity(lockoutRemaining != nil ? 0.4 : 1)
    }

    private var actions: some View {
        HStack(spacing: 24) {
            actionButton("common.cancel", systemImage: "xmark") {
                onComplete(false)
            }
            if case .unlock = mode, !collectingNewPIN {
                actionButton("parental.pin.forgot", systemImage: "questionmark.circle") {
                    showRecovery = true
                }
            }
        }
        .focusSectionCompat()
    }

    private var digitPad: some View {
        VStack(spacing: 20) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 20) {
                    ForEach(1...3, id: \.self) { col in
                        let digit = row * 3 + col
                        DigitKey(label: "\(digit)") { append("\(digit)") }
                    }
                }
            }
            HStack(spacing: 20) {
                DigitKey(label: "0") { append("0") }
                DigitKey(systemImage: "delete.left") { deleteLast() }
            }
        }
        .focusSectionCompat()
    }

    // MARK: Action button (matches app focus convention)

    private func actionButton(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(titleKey, systemImage: systemImage)
                .font(.body)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
        }
        .buttonStyle(SettingsTileButtonStyle())
    }

    // MARK: Logic

    /// Post-recovery collection always replaces the Guardian PIN: recovery's profile branch clears
    /// an own PIN and never reaches the pad.
    private var collectTarget: PINTarget {
        if case .setup(let target) = mode { return target }
        return .guardian
    }

    private var recoveryOutcome: PINRecoveryOutcome {
        guard case .unlock(let reason) = mode else { return .collectNewGuardianPIN }
        return PINRecoveryOutcome.forDoor(reason: reason) { dependencies.hasOwnPIN($0) }
    }

    /// The pad shows the lockout of the door it is standing at. Collecting a PIN verifies nothing,
    /// so a setup pad reads the Guardian door and simply has nothing to report.
    private var currentDoorLockout: Date? {
        guard case .unlock(let reason) = mode else { return dependencies.guardianPINLockout() }
        return dependencies.pinLockout(for: reason)
    }

    private var lockoutRemaining: Int? {
        guard let until = lockoutUntil, until > now else { return nil }
        return Int(until.timeIntervalSince(now).rounded(.up))
    }

    private func append(_ d: String) {
        guard entered.count < Self.pinLength, lockoutRemaining == nil else { return }
        entered += d
        if entered.count == Self.pinLength {
            submit()
        }
    }

    private func deleteLast() {
        if !entered.isEmpty { entered.removeLast() }
    }

    private func submit() {
        let pin = entered
        entered = ""
        if collectingNewPIN {
            handleCollect(pin)
        } else {
            handleUnlock(pin)
        }
    }

    private func handleCollect(_ pin: String) {
        guard let first = firstEntry else {
            firstEntry = pin
            message = "parental.pin.setup.confirm"
            isError = false
            return
        }
        guard first == pin else {
            firstEntry = nil
            message = "parental.pin.setup.mismatch"
            isError = true
            return
        }
        switch collectTarget {
        case .guardian:
            // A Guardian PIN that repeats a profile's own PIN hands that profile's occupant the
            // master key, which is the same leak from the other side.
            guard !dependencies.pinCollides(pin, excluding: nil) else { return reject() }
            try? dependencies.saveGuardianPIN(pin)
        case .profile(let ref):
            guard !dependencies.pinCollides(pin, excluding: ref) else { return reject() }
            try? dependencies.saveOwnPIN(pin, for: ref)
        }
        onComplete(true)
    }

    private func reject() {
        firstEntry = nil
        message = "parental.pin.duplicate"
        isError = true
    }

    private func handleUnlock(_ pin: String) {
        guard case .unlock(let reason) = mode else { return }
        switch dependencies.verifyPIN(pin, for: reason) {
        case .success:
            onComplete(true)
        case .wrong(let remaining):
            message = "parental.pin.wrong \(remaining)"
            isError = true
        case .lockedOut(let until):
            lockoutUntil = until
            message = nil
            isError = true
        }
    }
}

/// Digit / delete tile. tvOS: tinted fill on focus, activated via stableTap. iOS:
/// a Button with a pressed-state style (the focus highlight is dead on iOS, and a
/// 0-distance drag for press feedback would swallow the tap).
private struct DigitKey: View {
    var label: String? = nil
    var systemImage: String? = nil
    let action: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    private var keyWidth: CGFloat { hSizeClass == .compact ? 72 : 110 }
    private var keyHeight: CGFloat { hSizeClass == .compact ? 64 : 90 }

    private var content: some View {
        ZStack {
            if let label { Text(label).font(.system(size: hSizeClass == .compact ? 28 : 40, weight: .medium, design: .rounded)) }
            else if let systemImage { Image(systemName: systemImage).font(.system(size: hSizeClass == .compact ? 24 : 32)) }
        }
        .frame(width: keyWidth, height: keyHeight)
        .foregroundStyle(.white)
    }

    var body: some View {
        #if os(tvOS)
        content
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(focused ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
            )
            .focusStroke(cornerRadius: 16, isFocused: focused)
            .focusResponse(.chip, isFocused: focused)
            .focusableSurface(true)
            .focused($focused)
            .stableTap(isFocused: focused, perform: action)
        #else
        Button(action: action) { content }
            .buttonStyle(DigitKeyButtonStyle())
        #endif
    }
}

#if !os(tvOS)
/// iOS pressed-state fill for a PIN digit key (canonical isPressed, no gesture conflict).
private struct DigitKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(configuration.isPressed ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
