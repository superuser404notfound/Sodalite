import Foundation
import UserNotifications

/// Permission and (iOS) banners for changes to the user's own requests. tvOS has no banners, only the badge.
enum MyRequestsNotifier {
    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asked right after the user's own request activity, never at launch.
    static func requestAuthorizationIfUndetermined() async {
        guard await authorizationStatus() == .notDetermined else { return }
        #if os(tvOS)
        let options: UNAuthorizationOptions = [.badge]
        #else
        let options: UNAuthorizationOptions = [.alert, .badge, .sound]
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    #if os(iOS)
    static func post(_ events: [MyRequestEvent]) async {
        guard await authorizationStatus() == .authorized else { return }
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title ?? String(localized: "catalog.notify.mine.panel.title", defaultValue: "Your requests")
            content.body = event.statusText
            if event.kind == .available, let itemID = event.jellyfinItemID {
                content.userInfo = ["itemID": itemID]
            }
            let request = UNNotificationRequest(identifier: "seerr.mine.\(event.id)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
    #endif
}

extension MyRequestEvent {
    var statusText: String {
        switch kind {
        case .approved:
            String(localized: "catalog.notify.mine.status.approved", defaultValue: "Approved")
        case .declined:
            String(localized: "catalog.notify.mine.status.declined", defaultValue: "Declined")
        case .failed:
            String(localized: "catalog.notify.mine.status.failed", defaultValue: "Request failed")
        case .available:
            if let seasonText {
                String(
                    format: String(localized: "catalog.notify.mine.status.availableSeasons", defaultValue: "Ready to watch: %@"),
                    seasonText
                )
            } else {
                String(localized: "catalog.notify.mine.status.available", defaultValue: "Ready to watch")
            }
        }
    }

    private var seasonText: String? {
        guard mediaType == .tv, !seasons.isEmpty else { return nil }
        let format = String(localized: "catalog.allRequests.edit.season.format", defaultValue: "Season %d")
        return seasons.map { String(format: format, $0) }.joined(separator: ", ")
    }
}
