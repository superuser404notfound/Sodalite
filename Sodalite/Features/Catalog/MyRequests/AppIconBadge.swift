import UserNotifications

/// The one place the app-icon badge is written. Two features share it (the admin approval queue
/// and the user's own request changes), so each contributes instead of overwriting the other.
@MainActor
enum AppIconBadge {
    static func count(pendingApproval: Int?, adminNotificationsOn: Bool, unseenMine: Int) -> Int {
        (adminNotificationsOn ? pendingApproval ?? 0 : 0) + unseenMine
    }

    static func apply(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
