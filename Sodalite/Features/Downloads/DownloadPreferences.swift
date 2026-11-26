import Foundation
import Observation

/// Device-local download settings (Sodalite#81). Not in `DevicePreferences`: nothing here is ever
/// synced or shown on tvOS, so it stays out of the cloud-parity inventory entirely.
///
/// `defaultQuality` nil means the quality dialog asks on every download, the behavior before the
/// setting existed and still the default.
@MainActor @Observable
final class DownloadPreferences {
    private enum Keys {
        static let wifiOnly = "downloads.wifiOnly"
        static let defaultQuality = "downloads.defaultQuality"
    }
    @ObservationIgnored private let store: UserDefaults

    var wifiOnly: Bool { didSet { store.set(wifiOnly, forKey: Keys.wifiOnly) } }
    var defaultQuality: StreamingQuality? {
        didSet { store.set(defaultQuality?.rawValue, forKey: Keys.defaultQuality) }
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        wifiOnly = store.object(forKey: Keys.wifiOnly) as? Bool ?? true
        defaultQuality = store.string(forKey: Keys.defaultQuality).flatMap(StreamingQuality.init(rawValue:))
    }
}
