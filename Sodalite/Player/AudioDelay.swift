import Foundation

/// The audio delay (AetherEngine#464) as Sodalite offers it: one value per device, in milliseconds,
/// positive plays the sound later. Lip-sync error comes from the chain behind the box (a TV's
/// picture processing, a receiver), not from the file or the viewer, so Settings and the player's
/// audio menu both write the same device value.
enum AudioDelay {
    static let step = 25
    /// The engine takes up to 2 s. Half a second already covers a TV's slowest picture mode with
    /// room to spare, and keeps the Settings list short enough to scroll.
    static let limit = 500
    static let choices: [Int] = Array(stride(from: -limit, through: limit, by: step))

    static func clamped(_ milliseconds: Int) -> Int {
        min(max(milliseconds, -limit), limit)
    }

    /// The value `steps` places away, landing on the step grid and stopping at both ends.
    static func stepped(_ milliseconds: Int, by steps: Int) -> Int {
        let snapped = Int((Double(milliseconds) / Double(step)).rounded()) * step
        return clamped(snapped + steps * step)
    }

    static func seconds(_ milliseconds: Int) -> Double {
        Double(clamped(milliseconds)) / 1000
    }

    /// "0 ms", "+150 ms", "-75 ms". The sign stays visible on the positive side, so a value reads as
    /// "later" or "earlier" without the subtitle next to it.
    static func label(_ milliseconds: Int) -> String {
        milliseconds == 0 ? "0 ms" : String(format: "%+d ms", milliseconds)
    }
}
