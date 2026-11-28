import CoreGraphics
import Foundation
import AetherEngine

/// The ratio Fill zooms to: detected (`auto`) or picked by hand (Sodalite#118).
enum FillRatio: String, CaseIterable, Sendable {
    case auto, r4x3, r185, r200, r239

    var aspect: Double? {
        switch self {
        case .auto: return nil
        case .r4x3: return 4.0 / 3.0
        case .r185: return 1.85
        case .r200: return 2.00
        case .r239: return 2.39
        }
    }
}

/// Where a scan for the picture area stands, for greying out Fill (Auto) only when it has nothing
/// left to find.
enum PictureAreaScanState: Sendable, Equatable {
    case idle, scanning, finished, unavailable
}

/// One row of the in-player picture menu. Fill zooms until the picture covers the screen, which on
/// a film with bars painted into a 16:9 file means zooming past those bars.
enum PictureChoice: Hashable, Sendable {
    case original
    case fill(FillRatio)

    static let all: [PictureChoice] = [.original] + FillRatio.allCases.map { .fill($0) }

    /// The part of the picture that should cover the screen, normalized to the frame. nil for
    /// Original. A picked ratio is centred and fitted inside the picture plane.
    func area(presentationAspect: Double, detected: PictureArea?) -> CGRect? {
        guard case .fill(let ratio) = self else { return nil }
        guard let aspect = ratio.aspect, presentationAspect > 0 else {
            return detected?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if aspect > presentationAspect {
            let h = presentationAspect / aspect
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        let w = aspect / presentationAspect
        return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
    }

    /// Only Fill (Auto) can grey out: once a scan has finished (or cannot run) and the zoom it would
    /// apply changes nothing. A hand-picked ratio stays available, it is the override for exactly the
    /// cases the conservative detection gets wrong.
    static func isEnabled(_ choice: PictureChoice, presentationSize: CGSize, surface: CGSize,
                          detected: PictureArea?, scanState: PictureAreaScanState) -> Bool {
        guard choice == .fill(.auto) else { return true }
        guard scanState == .finished || scanState == .unavailable else { return true }
        guard presentationSize.width > 0, presentationSize.height > 0,
              surface.width > 0, surface.height > 0 else { return true }
        let area = detected?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return PictureFillGeometry.changesPicture(presentationSize: presentationSize, area: area, bounds: surface)
    }

    static func ratioLabel(_ ratio: Double) -> String {
        if abs(ratio - 4.0 / 3.0) < 0.01 { return "4:3" }
        if abs(ratio - 1.78) < 0.01 { return "16:9" }
        return String(format: "%.2f:1", locale: Locale(identifier: "en_US_POSIX"), ratio)
    }

    /// "Fill (Auto)", "Fill (Auto, 2.39:1)" once a ratio was found, "Fill (1.85:1)" for a pick. The
    /// two words come from the catalog, so every language composes the same way.
    func fillTitle(fill: String, auto: String, detected: PictureArea?) -> String {
        guard case .fill(let ratio) = self else { return fill }
        if let aspect = ratio.aspect { return "\(fill) (\(Self.ratioLabel(aspect)))" }
        if let found = detected, !found.isFullFrame, let snapped = found.snappedRatio {
            return "\(fill) (\(auto), \(Self.ratioLabel(snapped)))"
        }
        return "\(fill) (\(auto))"
    }

    var pictureMode: PlaybackPreferences.PictureMode {
        if case .fill = self { return .fill }
        return .original
    }
}
