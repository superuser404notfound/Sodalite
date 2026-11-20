import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The bitmap type the shared code passes around: `UIImage` on iOS/tvOS, `NSImage` on macOS.
///
/// One alias and a handful of named helpers, rather than aliasing UIKit's names onto AppKit's
/// classes. The two frameworks agree on far less than their names suggest (an `NSImage` has
/// representations and no scale, `NSColor` is colour-space aware where `UIColor` is not), so a
/// shim that let `UIImage` compile on macOS would be quietly lying at every call site that reads a
/// pixel. What the app actually needs of a bitmap is small and is listed below.
#if canImport(UIKit)
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
typealias PlatformImage = NSImage
#endif

extension Image {
    /// Platform-agnostic spelling of `Image(uiImage:)` / `Image(nsImage:)`.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}

#if canImport(AppKit)
nonisolated extension NSImage {
    /// The backing bitmap, for the code that measures or crops pixels rather than drawing the image.
    ///
    /// `NSImage` is a list of representations and picks one per draw, so it cannot answer this
    /// without being told a size; `nil` asks for the whole image at its natural size, which is what
    /// every caller here wants.
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }
}
#endif

// nonisolated throughout: image decode and measurement run on the cooperative pool (the
// prefetch, the tint reading, the trickplay crop), and the project's default actor
// isolation would otherwise put every one of these on the main actor.
nonisolated extension PlatformImage {
    /// Pixels per point. AppKit sizes an image in points and leaves the backing scale to whichever
    /// representation is drawn, so the answer there is the ratio the pixels imply.
    var pixelScale: CGFloat {
        #if canImport(UIKit)
        scale
        #elseif canImport(AppKit)
        guard size.width > 0, let cgImage else { return 1 }
        return CGFloat(cgImage.width) / size.width
        #endif
    }

    /// Forces the pixel decode now so the first draw is not a dropped scroll frame.
    ///
    /// UIKit does this off the caller's thread and hands back a new image; AppKit has no equivalent
    /// and decodes lazily on the drawing thread, so on macOS this is the identity and the cost
    /// stays where AppKit puts it.
    func preparedForDisplay() -> PlatformImage? {
        #if canImport(UIKit)
        preparingForDisplay()
        #elseif canImport(AppKit)
        self
        #endif
    }

    /// Forces the pixel decode off the caller's actor, answering nil for bytes that do not decode.
    ///
    /// The nil matters more than the speed: MediaPlayer crashes decoding a truncated cover lazily on
    /// its own thread, so the Now-Playing path needs the failure here rather than there. AppKit
    /// decodes lazily with no async entry point, so on macOS the answer is whether a bitmap can be
    /// got out of it at all.
    func byPreparedForDisplay() async -> PlatformImage? {
        #if canImport(UIKit)
        return await byPreparingForDisplay()
        #elseif canImport(AppKit)
        return cgImage == nil ? nil : self
        #endif
    }

    /// An SF Symbol as a bitmap, for the few places that draw one into an image rather than laying
    /// one out in SwiftUI.
    static func systemSymbol(_ name: String, pointSize: CGFloat) -> PlatformImage? {
        #if canImport(UIKit)
        return UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        )
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        #endif
    }

    /// Wraps a bitmap. `size` is in points and is what AppKit draws the image at; UIKit derives the
    /// same thing from the pixel count and the scale it is given.
    static func wrapping(_ cgImage: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        let scale = size.width > 0 ? CGFloat(cgImage.width) / size.width : 1
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: size)
        #endif
    }

    /// An image drawn by `body` into a bitmap of `size`, in a top-left-origin coordinate space on
    /// both platforms so one body can draw for both.
    static func drawn(
        size: CGSize,
        opaque: Bool = false,
        _ body: (CGContext) -> Void
    ) -> PlatformImage {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            body(context.cgContext)
        }
        #elseif canImport(AppKit)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        if let context = NSGraphicsContext.current?.cgContext {
            if opaque {
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
            }
            body(context)
        }
        image.unlockFocus()
        return image
        #endif
    }
}
