import Foundation
import Observation

/// Device-local download settings (Sodalite#81). Not in `DevicePreferences`: nothing here is ever
/// synced or shown on tvOS, so it stays out of the cloud-parity inventory entirely.
@MainActor @Observable
final class DownloadPreferences {
    private enum Keys {
        static let wifiOnly = "downloads.wifiOnly"
        static let lastQuality = "downloads.lastQuality"
    }
    @ObservationIgnored private let store: UserDefaults

    var wifiOnly: Bool { didSet { store.set(wifiOnly, forKey: Keys.wifiOnly) } }
    var lastQuality: StreamingQuality { didSet { store.set(lastQuality.rawValue, forKey: Keys.lastQuality) } }

    init(store: UserDefaults = .standard) {
        self.store = store
        wifiOnly = store.object(forKey: Keys.wifiOnly) as? Bool ?? true
        lastQuality = store.string(forKey: Keys.lastQuality).flatMap(StreamingQuality.init(rawValue:)) ?? .original
    }
}
