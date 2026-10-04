import SwiftUI
import UIKit

/// Three passes, 250ms and then 500ms apart. Long enough to outlast the server finishing the resize
/// it served half of, short enough that a caller's own fallback is not held back by much when the
/// payload never does arrive whole (Sodalite#123). Passes two and three go to the server rather than
/// to the HTTP cache, which is what makes them passes at all: the cache answers a refused payload
/// with itself. File scope because a generic type cannot hold a static stored property.
private let imageLoadAttemptLimit = 3
private let imageLoadRetryDelayMilliseconds = 250

/// Authenticated, memory-cached AsyncImage replacement: attaches the Jellyfin `X-Emby-Token` header (stock AsyncImage can't inject headers, so auth-gated image endpoints 401), re-issues on URL change via `.task(id:)` (profile switch swaps the token), and keeps a memory-only cache (URLSession's disk cache can serve stale 401s across launches).
struct AsyncCachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Second URL tried when the primary is nil or fails, e.g. a series Thumb falling back to backdrop/episode still.
    var fallbackURL: URL? = nil
    /// Fires with the decoded image whenever one lands, cache hit included, so a caller can derive
    /// artwork colours (ArtworkTint) without decoding the bytes a second time.
    var onImageLoaded: ((UIImage) -> Void)? = nil
    /// Fires false when a load starts and true once every candidate has failed. The placeholder is
    /// also what shows WHILE loading, so a caller that deliberately blanks its placeholder (the
    /// detail-page logo reserving its slot, Sodalite#97) can only tell "still coming" from "never
    /// coming" here, and put its own fallback back.
    var onLoadFailed: ((Bool) -> Void)? = nil
    /// Built with the decoded image AND that image's own size, so a caller that has to size its
    /// frame from the source's aspect ratio reads both out of the same state. Handing the size back
    /// through `onImageLoaded` instead puts it in the CALLER's state, one view up, where the image
    /// can render a pass before the aspect arrives: the detail-page logo drew every first open
    /// square that way (Sodalite#97).
    let content: (Image, CGSize) -> Content
    let placeholder: () -> Placeholder

    init(
        url: URL?,
        fallbackURL: URL? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onLoadFailed: ((Bool) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            fallbackURL: fallbackURL,
            onImageLoaded: onImageLoaded,
            onLoadFailed: onLoadFailed,
            sizedContent: { image, _ in content(image) },
            placeholder: placeholder
        )
    }

    init(
        url: URL?,
        fallbackURL: URL? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onLoadFailed: ((Bool) -> Void)? = nil,
        @ViewBuilder sizedContent: @escaping (Image, CGSize) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.onImageLoaded = onImageLoaded
        self.onLoadFailed = onLoadFailed
        self.content = sizedContent
        self.placeholder = placeholder
    }

    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appState) private var appState
    @State private var loaded: UIImage?
    /// Failures that heal on their own (offline blip, an iOS local-network permission prompt still
    /// unanswered, a resize the server had not finished writing) must not latch the placeholder
    /// forever.
    ///
    /// Two triggers, and the second one is why (Sodalite#126). Scene activation covers a dismissed
    /// permission alert, but an Apple TV never leaves `.active` inside a session, so on that device
    /// the only healing this view had could not fire at all: a profile picture that failed while the
    /// server was down stayed initials until the app was force-quit, measured on Wohnzimmer,
    /// tvOS 26.6. `requestContentReload` is the app's "an outside cause made your last failure
    /// obsolete" signal, and an image that failed transiently is one of the things that gave up.
    @State private var retryOnActivate = false

    var body: some View {
        ZStack {
            if let loaded {
                content(Image(uiImage: loaded), loaded.size)
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
                    // Above the placeholder for the length of the swap, which is what lets the
                    // placeholder stay opaque underneath instead of having to fade in step.
                    .zIndex(1)
            } else {
                placeholder()
                    // The image faded IN and the placeholder was removed with no transition at all,
                    // so between the two there was a gap where neither was drawn: every artwork on
                    // the page appeared to pop out and then fade back (Sodalite discussion #98,
                    // point 3). It now holds full strength until the image above it is opaque, and
                    // lets go behind it, so nothing ever uncovers what is behind them both.
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.25)))
                    .zIndex(0)
            }
        }
        .task(id: "\(url?.absoluteString ?? "")|\(fallbackURL?.absoluteString ?? "")") {
            await load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, retryOnActivate, loaded == nil {
                Task { await load() }
            }
        }
        // The server came back, or a permission did. Only the loads that failed in a way that can
        // heal ask again; a 404 and a body that is not an image read the same however often you try.
        .onChange(of: appState.requestContentReload) { _, _ in
            if retryOnActivate, loaded == nil {
                Task { await load() }
            }
        }
    }

    @MainActor
    private func load() async {
        // Reset on URL change so a stale image from the previous profile doesn't flash while the new one loads.
        loaded = nil
        retryOnActivate = false
        onLoadFailed?(false)

        let result = await ImageLoadLadder.run(
            candidates: [url, fallbackURL],
            attemptLimit: imageLoadAttemptLimit,
            retryDelayMilliseconds: imageLoadRetryDelayMilliseconds,
            perAttempt: { candidate, attempt in
                await loadImage(from: candidate, attempt: attempt)
            },
            onOutcome: { attempt, candidate, outcome in
                // Quiet by default, or the ring buffer is useless: a Home screen loads dozens of
                // images, and most carry no fallback URL, so the ladder asks a nil candidate that
                // always answers `noImage`. Worth a line only when something can actually be
                // learned from it (Sodalite#123):
                //   - a payload that stopped short, the bug being chased
                //   - a dropped connection
                //   - a refusal on a RETRY, which is the shape that decides whether the ladder
                //     recovers; the same refusal on the first pass is just an item with no logo.
                guard candidate != nil else { return }
                switch outcome {
                case .image: return
                case .noImage where attempt == 0: return
                case .incompletePayload, .transientFailure, .noImage: break
                }
                LogTap.shared.note(
                    "[Image] attempt \(attempt + 1)/\(imageLoadAttemptLimit)"
                        + " \(outcome.diagnosticName) \(Self.imageKind(candidate))"
                        + " \(Self.itemTail(candidate))"
                )
            },
            sleep: { milliseconds in
                try await Task.sleep(for: .milliseconds(milliseconds))
            }
        )

        switch result {
        case .image(let image):
            loaded = image
            onImageLoaded?(image)
        case .exhausted(let armSceneRetry):
            retryOnActivate = armSceneRetry
            onLoadFailed?(true)
        case .cancelled:
            // Nothing was decided, so nothing is reported: painting a failure here would put the
            // text title up for a load that never finished being asked.
            break
        }
    }

    /// "Logo", "Backdrop", "Primary": the segment after /Images/, which is what a reader of the
    /// diagnostic log is actually looking for.
    nonisolated private static func imageKind(_ url: URL?) -> String {
        guard let parts = url?.pathComponents,
              let index = parts.firstIndex(of: "Images"),
              index + 1 < parts.count
        else { return "?" }
        return parts[index + 1]
    }

    /// Last six of the item id: enough to tell two logos apart in the log, short enough to read.
    nonisolated private static func itemTail(_ url: URL?) -> String {
        guard let parts = url?.pathComponents,
              let index = parts.firstIndex(of: "Items"),
              index + 1 < parts.count
        else { return "" }
        return String(parts[index + 1].suffix(6))
    }

    @MainActor
    private func loadImage(from url: URL?, attempt: Int) async -> ImageLoadOutcome {
        guard let url else { return .noImage }

        if let cached = ImageCache.shared.image(for: url) {
            return .image(cached)
        }

        // Request built on MainActor to read the MainActor-isolated tokens; attach auth only for a participating Jellyfin server, matched by host and port, so external URLs (TMDB/CDN posters) don't see our token.
        var request = URLRequest(url: url)
        // 15s, not the 60s default: one hanging poster otherwise holds the row in placeholder for a full minute.
        request.timeoutInterval = 15
        if let token = ImageAuth.snapshot(dependencies.sessionRegistry).token(for: url) {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }

        let outcome = await Self.fetchAndDecode(request: request, attempt: attempt)
        guard case .image(let prepared) = outcome else { return outcome }
        // Cache before the cancellation check: a `.task(id:)` invalidation may cancel between decode and @State write, but the bytes are already in memory, so skipping the store would re-pay bandwidth+decode on next mount. Only a WHOLE image ever gets here, so a payload that stopped in the middle cannot latch itself into the session (Sodalite#123).
        ImageCache.shared.store(prepared, for: url)
        guard !Task.isCancelled else { return .noImage }
        return .image(prepared)
    }

    /// Network + decode + force-decompress off the MainActor. `preparingForDisplay()` runs the pixel decode now so the first draw isn't a scroll frame-drop; static + `nonisolated` keeps it on the cooperative pool. Cancellation propagates from the enclosing `.task(id:)`.
    ///
    /// `attempt` reaches `ImageFetch` rather than staying here: a 200 is not the same as a whole
    /// image, and the retry that follows one has to ask the SERVER, not the HTTP cache that just
    /// stored the half file (Sodalite#123).
    nonisolated private static func fetchAndDecode(request: URLRequest, attempt: Int) async -> ImageLoadOutcome {
        switch await ImageFetch.load(request, attempt: attempt) {
        case .whole(let data):
            guard let image = UIImage(data: data) else { return .noImage }
            return .image(image.preparingForDisplay() ?? image)
        case .incomplete:
            return .incompletePayload
        case .noImage:
            return .noImage
        case .transientFailure:
            return .transientFailure
        }
    }
}

extension AsyncCachedImage where Placeholder == ProgressView<EmptyView, EmptyView> {
    init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content) {
        self.init(url: url, content: content, placeholder: { ProgressView() })
    }
}

// MARK: - Cache

final class ImageCache: @unchecked Sendable {
    // Plain `nonisolated` (not `(unsafe)`): Sendable constant reachable from background prefetch under the project's MainActor default isolation.
    nonisolated static let shared = ImageCache()

    // `nonisolated(unsafe)`: NSCache is thread-safe, so prefetch can `store` from background tasks without a per-image MainActor hop.
    nonisolated(unsafe) private let cache: NSCache<NSURL, UIImage>

    /// Cost-based eviction by decoded byte size; the 150 MB budget gates (countLimit stays generous), bounded so long sessions don't grow into hundreds of MB.
    nonisolated private init() {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 150_000_000
        cache.countLimit = 1000
        self.cache = cache
    }

    // nonisolated so the prefetch hot path stores from off-actor tasks without a per-image MainActor hop (NSCache is thread-safe).
    nonisolated func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: estimatedBytes(for: image))
    }

    /// Wipe on profile switches: a poster cached with user A's token may be unfetchable under user B's permissions.
    func clear() {
        cache.removeAllObjects()
    }

    /// Decoded size estimate: width × height × scale² × 4 bytes (RGBA8). Ignores HDR/wide-gamut backing, fine as an NSCache cost signal.
    nonisolated private func estimatedBytes(for image: UIImage) -> Int {
        let scale = image.scale
        let pixels = image.size.width * scale * image.size.height * scale
        return Int(pixels) * 4
    }
}

// MARK: - Prefetch

extension ImageCache {
    /// Background batch cache-warm: skips cached URLs, fans out the rest with bounded concurrency, drops failures silently. `auth` mirrors `load`: X-Emby-Token only for a participating Jellyfin server so external CDN URLs don't leak the token.
    static func prefetch(_ urls: [URL], auth: ImageAuth) async {
        let pending = urls.filter { ImageCache.shared.image(for: $0) == nil }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            // 6 in flight: saturates a home LAN without crowding foreground fetches; matches URLSession's per-host default.
            let maxConcurrent = 6
            var iter = pending.makeIterator()

            for _ in 0..<min(maxConcurrent, pending.count) {
                guard let url = iter.next() else { break }
                group.addTask {
                    await prefetchOne(url: url, auth: auth)
                }
            }
            for await _ in group {
                if let url = iter.next() {
                    group.addTask {
                        await prefetchOne(url: url, auth: auth)
                    }
                }
            }
        }
    }

    nonisolated private static func prefetchOne(url: URL, auth: ImageAuth) async {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let token = auth.token(for: url) {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        // Same funnel as the foreground path: a prefetch must never be the thing that puts a
        // half-written resize into either cache, and the HTTP entry it would leave behind is what
        // the first focus would then read (Sodalite#123).
        guard case .whole(let data) = await ImageFetch.load(request),
              let image = UIImage(data: data)
        else { return }
        ImageCache.shared.store(image.preparingForDisplay() ?? image, for: url)
    }
}
