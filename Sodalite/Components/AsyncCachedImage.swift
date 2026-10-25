import SwiftUI

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
    var onImageLoaded: ((PlatformImage) -> Void)? = nil
    /// Fires false when a load starts and true once every candidate has failed. The placeholder is
    /// also what shows WHILE loading, so a caller that deliberately blanks its placeholder (the
    /// detail-page logo reserving its slot, Sodalite#97) can only tell "still coming" from "never
    /// coming" here, and put its own fallback back.
    var onLoadFailed: ((Bool) -> Void)? = nil
    /// Crop the decoded image to its non-transparent pixels before it is cached, so the content
    /// closure and its size see the visible mark and not the canvas around it. The title logo only
    /// (Sodalite#192).
    var trimsTransparentMargin = false
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
        onImageLoaded: ((PlatformImage) -> Void)? = nil,
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
        onImageLoaded: ((PlatformImage) -> Void)? = nil,
        onLoadFailed: ((Bool) -> Void)? = nil,
        trimsTransparentMargin: Bool = false,
        @ViewBuilder sizedContent: @escaping (Image, CGSize) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.fallbackURL = fallbackURL
        self.onImageLoaded = onImageLoaded
        self.onLoadFailed = onLoadFailed
        self.trimsTransparentMargin = trimsTransparentMargin
        self.content = sizedContent
        self.placeholder = placeholder
        // A card that scrolls back into a lazy row is a new view, and an empty first frame faded its
        // cached artwork in again over the placeholder, a reload in all but the network (Sodalite#212).
        _loaded = State(initialValue: url.flatMap {
            ImageCache.shared.image(for: Self.cacheKey(for: $0, trimmed: trimsTransparentMargin))
        })
    }

    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appState) private var appState
    @State private var loaded: PlatformImage?
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
                content(Image(platformImage: loaded), loaded.size)
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
        // A hit is drawn without the reset below, so a card seeded from the cache in `init` keeps its
        // first frame instead of blanking and fading back in.
        if let url, let cached = ImageCache.shared.image(for: Self.cacheKey(for: url, trimmed: trimsTransparentMargin)) {
            retryOnActivate = false
            onLoadFailed?(false)
            loaded = cached
            onImageLoaded?(cached)
            return
        }
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

    nonisolated private static func cacheKey(for url: URL, trimmed: Bool) -> URL {
        trimmed ? ImageCache.trimmedKey(for: url) : url
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
        let cacheKey = Self.cacheKey(for: url, trimmed: trimsTransparentMargin)

        if let cached = ImageCache.shared.image(for: cacheKey) {
            return .image(cached)
        }

        // Request built on MainActor to read the MainActor-isolated tokens; attach auth only for a participating Jellyfin server, matched by host and port, so external URLs (TMDB/CDN posters) don't see our token.
        var request = URLRequest(url: url)
        // 15s, not the 60s default: one hanging poster otherwise holds the row in placeholder for a full minute.
        request.timeoutInterval = 15
        if let token = ImageAuth.snapshot(dependencies.sessionRegistry).token(for: url) {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }

        let outcome = await Self.fetchAndDecode(
            request: request, attempt: attempt, trimsTransparentMargin: trimsTransparentMargin)
        guard case .image(let prepared) = outcome else { return outcome }
        // Cache before the cancellation check: a `.task(id:)` invalidation may cancel between decode and @State write, but the bytes are already in memory, so skipping the store would re-pay bandwidth+decode on next mount. Only a WHOLE image ever gets here, so a payload that stopped in the middle cannot latch itself into the session (Sodalite#123).
        ImageCache.shared.store(prepared, for: cacheKey)
        guard !Task.isCancelled else { return .noImage }
        return .image(prepared)
    }

    /// Network + decode + force-decompress off the MainActor. `preparingForDisplay()` runs the pixel decode now so the first draw isn't a scroll frame-drop; static + `nonisolated` keeps it on the cooperative pool. Cancellation propagates from the enclosing `.task(id:)`.
    ///
    /// `attempt` reaches `ImageFetch` rather than staying here: a 200 is not the same as a whole
    /// image, and the retry that follows one has to ask the SERVER, not the HTTP cache that just
    /// stored the half file (Sodalite#123).
    ///
    /// The trim runs here, after `ImageFetch` has refused a payload that stopped short, so a
    /// half-written logo is never measured (Sodalite#123), and before the cache, so a hit costs
    /// nothing (Sodalite#192).
    nonisolated private static func fetchAndDecode(
        request: URLRequest, attempt: Int, trimsTransparentMargin: Bool
    ) async -> ImageLoadOutcome {
        switch await ImageFetch.load(request, attempt: attempt) {
        case .whole(let data):
            guard var image = PlatformImage(data: data) else { return .noImage }
            if trimsTransparentMargin {
                let trimmed = image.trimmingTransparentMargin()
                if trimmed !== image {
                    LogTap.shared.note(
                        "[Image] trimmed \(imageKind(request.url)) \(itemTail(request.url))"
                            + " \(Int(image.size.width))x\(Int(image.size.height))"
                            + " -> \(Int(trimmed.size.width))x\(Int(trimmed.size.height))"
                    )
                    image = trimmed
                }
            }
            return .image(image.preparedForDisplay() ?? image)
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
    nonisolated(unsafe) private let cache: NSCache<NSURL, PlatformImage>

    nonisolated private let evictions = EvictionCounter()

    /// The decoded bytes the cache may hold, from `costLimit(physicalMemory:)`.
    nonisolated let costLimit: Int

    /// Cost-based eviction by decoded byte size; the byte budget gates (countLimit stays generous), bounded so long sessions don't grow into hundreds of MB.
    nonisolated private init() {
        let cache = NSCache<NSURL, PlatformImage>()
        costLimit = Self.costLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)
        cache.totalCostLimit = costLimit
        cache.countLimit = 1000
        cache.delegate = evictions
        self.cache = cache
    }

    /// 75 MB per GB of RAM, between 150 MB (Apple TV HD, 2 GB) and 300 MB (Apple TV 4K 2022, 4 GB).
    ///
    /// The budget is not a share of the RAM, it is a share of what jetsam allows the process, about
    /// 2.1 GB on a 4 GB Apple TV (AE#104), and Home stays alive under the player: a 4K session put the
    /// engine at some 900 MB on its own. A flat 150 MB held some 60 cards at the widths `ImageWidth`
    /// asks for, under what one Home screen draws, so prefetching the lower rows evicted the ones on
    /// screen (Sodalite#212). `NSCache` also empties itself under memory pressure, which is the
    /// second line behind this one.
    nonisolated static func costLimit(physicalMemory: UInt64) -> Int {
        let gigabytes = (Double(physicalMemory) / Double(1 << 30)).rounded()
        let budget = Int(gigabytes) * 75_000_000
        return min(max(budget, 150_000_000), 300_000_000)
    }

    /// How many images a prefetch may warm: half the budget, counted in typical cards (a 640px
    /// poster decodes to 2.46 MB, a 960px landscape card to 2.07 MB), so the screen keeps the other
    /// half and a prefetch can never push out what it is drawing (Sodalite#212).
    nonisolated static func prefetchLimit(costLimit: Int) -> Int {
        costLimit / 2 / 2_500_000
    }

    /// Evictions since the last call, for the diagnostic line a prefetch writes.
    nonisolated func takeEvictionCount() -> Int {
        evictions.take()
    }

    // nonisolated so the prefetch hot path stores from off-actor tasks without a per-image MainActor hop (NSCache is thread-safe).
    nonisolated func image(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    nonisolated func store(_ image: PlatformImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: estimatedBytes(for: image))
    }

    /// A trimmed image is a different image from the one at its URL, so it is cached under its own
    /// key: a surface that asks for the same URL untrimmed must not read the crop, nor the logo the
    /// canvas. A fragment never reaches the server, so the request itself is unchanged.
    nonisolated static func trimmedKey(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = "trimmed"
        return components?.url ?? url
    }

    /// Wipe on profile switches: a poster cached with user A's token may be unfetchable under user B's permissions.
    func clear() {
        cache.removeAllObjects()
    }

    /// Decoded size estimate: width × height × scale² × 4 bytes (RGBA8). Ignores HDR/wide-gamut backing, fine as an NSCache cost signal.
    nonisolated private func estimatedBytes(for image: PlatformImage) -> Int {
        let scale = image.pixelScale
        let pixels = image.size.width * scale * image.size.height * scale
        return Int(pixels) * 4
    }
}

/// Counts what `NSCache` throws out. A cache that is too small for its screen shows up here first:
/// in the log, a Home that evicts while it prefetches is Sodalite#212 coming back.
nonisolated private final class EvictionCounter: NSObject, NSCacheDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        lock.withLock { count += 1 }
    }

    func take() -> Int {
        lock.withLock {
            defer { count = 0 }
            return count
        }
    }
}

// MARK: - Prefetch

extension ImageCache {
    /// Background batch cache-warm: skips cached URLs, fans out the rest with bounded concurrency, drops failures silently. `auth` mirrors `load`: X-Emby-Token only for a participating Jellyfin server so external CDN URLs don't leak the token.
    /// Returns how many images it decoded into the cache, for the caller's diagnostic line.
    @discardableResult
    static func prefetch(_ urls: [URL], auth: ImageAuth) async -> Int {
        let pending = urls.filter { ImageCache.shared.image(for: $0) == nil }
        guard !pending.isEmpty else { return 0 }

        return await withTaskGroup(of: Bool.self) { group in
            // 6 in flight: saturates a home LAN without crowding foreground fetches; matches URLSession's per-host default.
            let maxConcurrent = 6
            var iter = pending.makeIterator()

            for _ in 0..<min(maxConcurrent, pending.count) {
                guard let url = iter.next() else { break }
                group.addTask {
                    await prefetchOne(url: url, auth: auth)
                }
            }
            var warmed = 0
            for await stored in group {
                if stored { warmed += 1 }
                if let url = iter.next() {
                    group.addTask {
                        await prefetchOne(url: url, auth: auth)
                    }
                }
            }
            return warmed
        }
    }

    nonisolated private static func prefetchOne(url: URL, auth: ImageAuth) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let token = auth.token(for: url) {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        // Same funnel as the foreground path: a prefetch must never be the thing that puts a
        // half-written resize into either cache, and the HTTP entry it would leave behind is what
        // the first focus would then read (Sodalite#123).
        guard case .whole(let data) = await ImageFetch.load(request),
              let image = PlatformImage(data: data)
        else { return false }
        ImageCache.shared.store(image.preparedForDisplay() ?? image, for: url)
        return true
    }
}
