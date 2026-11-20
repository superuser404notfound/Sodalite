import Foundation
import Observation
import SwiftUI

/// Why the Guardian-PIN is being requested. Drives the prompt copy, and names the door: only
/// `enterProfile` stands at a profile's own lock, everything else stands at the Guardian's.
enum PINReason: Equatable {
    case switchProfile              // activate an open profile out of a leave-locked one
    case enterProfile(ProfileRef)   // activate a profile that is locked to enter
    case logout
    case serverManagement
    case openParentalSettings
}

/// Presentation coordinator: challenge(reason:) suspends until PINEntryView resolves it; AppRouter drives the fullScreenCover. Decision logic lives on DependencyContainer; this holds no container ref so no retain cycle.
@Observable
@MainActor
final class ParentalGate {

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let reason: PINReason
    }

    private(set) var activeRequest: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Hosts that can put the PIN cover on screen, innermost last; empty means the AppRouter's own
    /// cover is the one to use.
    ///
    /// A cover cannot stack on a sheet presented from the same hosting controller, and on iOS the
    /// Settings sheet is exactly that: presented from inside the router. Left to the router alone,
    /// every challenge raised from Settings (Log Out, Reset, the PIN-gated sub-screens) was
    /// swallowed, the continuation never resolved, and the button read as dead until the sheet was
    /// closed, at which point the prompt finally appeared over the wrong screen.
    /// Ids are caller-supplied and stable, not per-instance: whoever puts the surface up can then
    /// clear the claim from its own presentation state, which no view lifecycle can be trusted for.
    /// A host stranded in this stack would leave every later challenge with nothing on screen.
    private(set) var presenterStack: [String] = []

    /// Registered by `parentalGateHost(_:)` while a surface above the router is on screen.
    func pushPresenter(_ id: String) {
        guard !presenterStack.contains(id) else { return }
        presenterStack.append(id)
    }

    func popPresenter(_ id: String) {
        presenterStack.removeAll { $0 == id }
    }

    /// Awaits outcome (true = unlocked, false = cancelled). Caller must have already decided a PIN is required.
    func challenge(reason: PINReason) async -> Bool {
        // Defensive: if a prior challenge somehow never resolved, fail it.
        continuation?.resume(returning: false)
        continuation = nil
        return await withCheckedContinuation { cont in
            continuation = cont
            activeRequest = Request(reason: reason)
        }
    }

    /// Called by PINEntryView on success (true) or cancel (false).
    func resolve(_ unlocked: Bool) {
        activeRequest = nil
        continuation?.resume(returning: unlocked)
        continuation = nil
    }
}

// MARK: - Host

/// Puts the Guardian-PIN cover on screen while this view is, and claims the presentation from the
/// AppRouter for as long as it is up. Belongs on any surface presented ABOVE the router (the iOS
/// Settings sheet); the router keeps its own cover for everything else.
private struct ParentalGateHost: ViewModifier {
    @Environment(\.dependencies) private var dependencies
    let hostID: String

    func body(content: Content) -> some View {
        content
            .fullScreenCoverCompat(item: Binding(
                get: {
                    dependencies.parentalGate.presenterStack.last == hostID
                        ? dependencies.parentalGate.activeRequest
                        : nil
                },
                set: { if $0 == nil { dependencies.parentalGate.resolve(false) } }
            )) { request in
                PINEntryView(mode: .unlock(reason: request.reason)) { unlocked in
                    dependencies.parentalGate.resolve(unlocked)
                }
                .pausesAppBackgroundMotion()
            }
            // Registered on appear rather than in init: the stack has to follow what is on screen,
            // and a host that never appeared must not swallow a challenge it cannot show.
            .onAppear { dependencies.parentalGate.pushPresenter(hostID) }
            .onDisappear {
                // A fullScreenCover takes its presenter off screen, so this fires for the very
                // cover put up above. Popping there would hand the presentation back to the router
                // mid-challenge and dismiss that cover again. A host with nothing pending is the
                // only one that is actually gone; onAppear re-registers when the cover closes.
                guard dependencies.parentalGate.activeRequest == nil else { return }
                dependencies.parentalGate.popPresenter(hostID)
            }
    }
}

extension View {
    /// `id` must match whatever the presenting side passes to `ParentalGate.popPresenter` when the
    /// surface goes away, so a claim never outlives what it was claimed for.
    func parentalGateHost(_ id: String) -> some View {
        modifier(ParentalGateHost(hostID: id))
    }
}
