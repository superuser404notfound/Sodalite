import Foundation

/// The `Device` field of the MediaBrowser header, which Jellyfin shows as the device name and which
/// servers and plugins forward to addons (Sodalite#260). It was "Apple TV" on every platform, so an
/// iPhone and an Apple TV on the same profile looked identical. The value is the device type, not
/// the user's own name for the device: it has to stay the same so a rule keyed on it keeps working.
nonisolated enum ClientDevice {
    static let name: String = {
        #if os(tvOS)
        "Apple TV"
        #elseif os(macOS)
        "Mac"
        #else
        name(modelIdentifier: modelIdentifier, isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
        #endif
    }()

    /// iOS half of the mapping. `UIDevice.userInterfaceIdiom` would say the same but is MainActor,
    /// and the Top Shelf builds its header off the main actor.
    static func name(modelIdentifier: String, isiOSAppOnMac: Bool) -> String {
        if isiOSAppOnMac { return "Mac" }
        return modelIdentifier.hasPrefix("iPad") ? "iPad" : "iPhone"
    }

    /// "iPhone17,1" on hardware. The simulator reports the host's "arm64" and keeps the simulated
    /// model in its environment.
    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
