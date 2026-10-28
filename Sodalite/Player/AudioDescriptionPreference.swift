import AVFoundation
import MediaAccessibility

/// The system's Audio Descriptions switch (Settings > Accessibility), the same one AVKit's own
/// players follow. Read at each load, so a change applies from the next title on.
enum AudioDescriptionPreference {
    static var isPreferred: Bool {
        let characteristics = MAAudibleMediaCopyPreferredCharacteristics().takeRetainedValue() as? [String] ?? []
        return characteristics.contains(AVMediaCharacteristic.describesVideoForAccessibility.rawValue)
    }
}
