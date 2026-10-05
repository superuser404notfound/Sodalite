import SwiftUI
import UIKit

enum MyRequestsPresentationPolicy {
    static func shouldPresent(unseen: Int, authenticated: Bool, loading: Bool, modalActive: Bool) -> Bool {
        unseen > 0 && authenticated && !loading && !modalActive
    }

    /// Anything already presented (player, What's New, profile picker): a second cover would fail
    /// silently, and the panel must never land on top of playback.
    @MainActor
    static var isModalActive: Bool {
        if PlayerModalPresence.isPlayerActive { return true }
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }?
            .rootViewController
        return root?.presentedViewController != nil
    }
}

private struct MyRequestsTickKey: Equatable {
    let scope: String?
    let connected: Bool
    let active: Bool
}

/// Drives the my-requests watcher from AppRouter: foreground, Seerr connect, profile switch, a
/// 10-minute tick while in front, request edits, and shows the hint panel once nothing else is up.
private struct MyRequestsPresentation: ViewModifier {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPresented = false
    @State private var retryPending = false

    private var watcher: MyRequestsWatcher { dependencies.myRequestsWatcher }

    func body(content: Content) -> some View {
        content
            .task(id: MyRequestsTickKey(
                scope: dependencies.myRequestsScope,
                connected: appState.isSeerrConnected,
                active: scenePhase == .active
            )) {
                watcher.reloadForActiveProfile()
                await dependencies.syncAppIconBadge()
                guard scenePhase == .active, appState.isSeerrConnected else { return }
                while !Task.isCancelled {
                    await watcher.refresh()
                    evaluate()
                    try? await Task.sleep(for: .seconds(10 * 60))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .seerrRequestsDidChange)) { _ in
                Task {
                    await watcher.refresh()
                    if watcher.isEnabled, watcher.hasOwnRequests {
                        await MyRequestsNotifier.requestAuthorizationIfUndetermined()
                        await dependencies.syncAppIconBadge()
                    }
                    evaluate()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playerModalPresenceDidChange)) { _ in
                evaluate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .myRequestNotificationOpened)) { note in
                guard let itemID = note.userInfo?["itemID"] as? String else { return }
                clear()
                appState.pendingDeepLinkItemID = itemID
            }
            .onChange(of: watcher.unseenEvents.count) { _, _ in evaluate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, watcher.isEnabled { MyRequestsBackgroundRefresh.schedule() }
            }
            .menuPresentation(isPresented: $isPresented, onDismiss: {
                if !watcher.unseenEvents.isEmpty { clear() }
            }) {
                MyRequestsHintView(
                    events: watcher.unseenEvents,
                    onWatch: { itemID in
                        isPresented = false
                        clear()
                        appState.pendingDeepLinkItemID = itemID
                    },
                    onDone: {
                        isPresented = false
                        clear()
                    }
                )
            }
    }

    private func evaluate() {
        guard !isPresented, !watcher.unseenEvents.isEmpty else { return }
        let modalActive = MyRequestsPresentationPolicy.isModalActive
        if MyRequestsPresentationPolicy.shouldPresent(
            unseen: watcher.unseenEvents.count,
            authenticated: appState.isAuthenticated,
            loading: appState.isLoading,
            modalActive: modalActive
        ) {
            isPresented = true
        } else if modalActive, !PlayerModalPresence.isPlayerActive, !retryPending {
            // What's New or a picker is up and has no close signal of its own: look again shortly.
            retryPending = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                retryPending = false
                evaluate()
            }
        }
    }

    private func clear() {
        watcher.markAllSeen()
        Task { await dependencies.syncAppIconBadge() }
    }
}

extension View {
    func myRequestsPresentation() -> some View {
        modifier(MyRequestsPresentation())
    }
}
