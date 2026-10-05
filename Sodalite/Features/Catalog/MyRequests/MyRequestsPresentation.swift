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

/// What the panel does on each user or system step. Navigation waits for the cover to be gone,
/// because a detail cover cannot present while the panel is still on screen.
struct MyRequestsPanelFlow {
    enum Action: Equatable {
        case none
        case dismissPanel
        case navigate(String)
    }

    struct Dismissal: Equatable {
        let markSeen: Bool
        let deepLink: String?
    }

    private var pendingItemID: String?
    private var silent = false

    mutating func watch(_ itemID: String) -> Action {
        pendingItemID = itemID
        return .dismissPanel
    }

    mutating func bannerOpened(_ itemID: String, panelPresented: Bool) -> Action {
        guard panelPresented else { return .navigate(itemID) }
        pendingItemID = itemID
        return .dismissPanel
    }

    /// Leaving the app takes the panel down without counting it as read, so it comes back on return
    /// and never sits under the profile reprompt.
    mutating func didEnterBackground(panelPresented: Bool) -> Action {
        guard panelPresented else { return .none }
        silent = true
        return .dismissPanel
    }

    mutating func panelDidDismiss() -> Dismissal {
        defer {
            pendingItemID = nil
            silent = false
        }
        return Dismissal(markSeen: !silent, deepLink: silent ? nil : pendingItemID)
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
    @State private var flow = MyRequestsPanelFlow()
    @State private var retryPending = false

    private var isPresented: Bool { appState.isMyRequestsPanelPresented }

    private var presentedBinding: Binding<Bool> {
        Binding(
            get: { appState.isMyRequestsPanelPresented },
            set: { appState.isMyRequestsPanelPresented = $0 }
        )
    }

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
                perform(flow.bannerOpened(itemID, panelPresented: isPresented))
            }
            .onChange(of: watcher.unseenEvents.count) { _, _ in evaluate() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                perform(flow.didEnterBackground(panelPresented: isPresented))
                if watcher.isEnabled { MyRequestsBackgroundRefresh.schedule() }
            }
            .menuPresentation(isPresented: presentedBinding, onDismiss: {
                let dismissal = flow.panelDidDismiss()
                if dismissal.markSeen { clear() }
                if let itemID = dismissal.deepLink { appState.pendingDeepLinkItemID = itemID }
            }) {
                MyRequestsHintView(
                    events: watcher.unseenEvents,
                    onWatch: { itemID in perform(flow.watch(itemID)) },
                    onDone: { appState.isMyRequestsPanelPresented = false }
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
            appState.isMyRequestsPanelPresented = true
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

    private func perform(_ action: MyRequestsPanelFlow.Action) {
        switch action {
        case .none:
            break
        case .dismissPanel:
            appState.isMyRequestsPanelPresented = false
        case .navigate(let itemID):
            clear()
            appState.pendingDeepLinkItemID = itemID
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
