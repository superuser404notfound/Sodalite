import Testing
@testable import Sodalite

struct CloudArrivalRestorePolicyTests {
    @Test func freshInstallThatNowHasServersRestores() {
        #expect(CloudArrivalRestorePolicy.shouldRerunRestore(
            isAuthenticated: false, launchPickerShown: false, hasKnownServers: true))
    }

    @Test func launchPickerIsNotCoveredBySplash() {
        #expect(!CloudArrivalRestorePolicy.shouldRerunRestore(
            isAuthenticated: false, launchPickerShown: true, hasKnownServers: true))
    }

    @Test func signedInOrStillEmptyDoesNothing() {
        #expect(!CloudArrivalRestorePolicy.shouldRerunRestore(
            isAuthenticated: true, launchPickerShown: false, hasKnownServers: true))
        #expect(!CloudArrivalRestorePolicy.shouldRerunRestore(
            isAuthenticated: false, launchPickerShown: false, hasKnownServers: false))
    }
}
