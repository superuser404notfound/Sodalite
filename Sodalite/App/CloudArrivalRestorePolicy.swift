/// Whether synced iCloud data arriving while nobody is signed in should re-run the launch restore.
/// The case it exists for is a fresh install, where the first restore ended on discovery because the
/// keychain was empty. Over the launch profile picker it only made the splash cover the picker
/// (SHELL-206), except when the picker's own server was just deleted on another device, which still
/// needs the re-route.
enum CloudArrivalRestorePolicy {
    static func shouldRerunRestore(
        isAuthenticated: Bool,
        launchPickerShown: Bool,
        launchPickerServerStillKnown: Bool = true,
        hasKnownServers: Bool
    ) -> Bool {
        guard !isAuthenticated else { return false }
        if launchPickerShown { return !launchPickerServerStillKnown }
        return hasKnownServers
    }
}
