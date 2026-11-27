import Foundation

/// The `Device` field of the MediaBrowser header, which Jellyfin shows as the device name and which
/// servers and plugins forward to addons (Sodalite#260). It was "Apple TV" on every platform, so an
/// iPhone and an Apple TV on the same profile looked identical. The value is the device type, not
/// the user's own name for the device: it has to stay the same so a rule keyed on it keeps working.
///
/// Not `UIDevice`: that is MainActor, and `TopShelfAPI`, which every app target compiles, reads this
/// from a nonisolated context.
nonisolated enum ClientDevice {
    static let name: String = {
        #if os(tvOS)
        "Apple TV"
        #elseif os(macOS)
        "Mac"
        #else
        iOSName(modelIdentifier: modelIdentifier, isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
        #endif
    }()

    /// The iOS app also runs on a Mac and on Vision Pro, which must not pass for a phone: an addon
    /// that serves phones smaller files would hand them those.
    static func iOSName(modelIdentifier: String, isiOSAppOnMac: Bool) -> String {
        if isiOSAppOnMac { return "Mac" }
        if modelIdentifier.hasPrefix("iPad") { return "iPad" }
        if modelIdentifier.hasPrefix("RealityDevice") { return "Apple Vision Pro" }
        return "iPhone"
    }

    /// "iPhone17,1", "AppleTV14,1" on hardware. The simulator reports the host's "arm64" and keeps
    /// the simulated model in its environment.
    static var modelIdentifier: String {
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
