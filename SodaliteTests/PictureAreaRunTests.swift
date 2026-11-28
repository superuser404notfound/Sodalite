import Testing
import Foundation
import CoreGraphics
import AetherEngine
@testable import Sodalite

/// A still source that holds its first answer until the test lets it go.
private actor GatedStills: StillSource {
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false
    private let image: CGImage

    init(image: CGImage) { self.image = image }

    func open() {
        opened = true
        gate?.resume()
        gate = nil
    }

    func thumbnailOutcome(at seconds: Double, maxWidth: Int) async -> StillOutcome {
        if !opened { await withCheckedContinuation { gate = $0 } }
        return .image(image)
    }
}

/// A source that never has a still, so a first pass finds too few frames and answers nil.
private struct NoStills: StillSource {
    func thumbnailOutcome(at seconds: Double, maxWidth: Int) async -> StillOutcome { .unavailable }
}

private func letterboxed() -> CGImage {
    let w = 480, h = 270
    var px = [UInt8](repeating: 0, count: w * h)
    for y in 35..<235 { for x in 0..<w { px[y * w + x] = UInt8(100 + (x * 7 + y * 3) % 60) } }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

@MainActor
struct PictureAreaRunTests {
    private func makeViewModel(cacheFile: URL) throws -> PlayerViewModel {
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"m1","Name":"m1","Type":"Movie","ServerId":"srv","RunTimeTicks":72000000000}"#.utf8))
        let vm = PlayerViewModel(
            item: item, startFromBeginning: false, playbackService: RecordingPlaybackService(), userID: "user",
            preferences: PlaybackPreferences(store: UserDefaults(suiteName: "test.picturearea.\(UUID())")!))
        vm.pictureAreaCache = PictureAreaCache(fileURL: cacheFile)
        vm.mediaSourceID = "ms"
        vm.selectPictureChoice(.fill(.auto))
        return vm
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("picture-areas-\(UUID().uuidString).json")
    }

    @Test func aFinishedScanLandsAndIsCached() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try makeViewModel(cacheFile: file)
        let stills = GatedStills(image: letterboxed())
        await stills.open()
        let task = vm.runPictureAreaScan(source: stills, duration: 7200, displayAspect: 16.0 / 9.0)
        await task.firstPassDone()
        #expect(vm.detectedPictureArea?.snappedRatio.map { (2.39...2.40).contains($0) } == true)
        #expect(vm.pictureAreaScanState == .finished)
        #expect(PictureAreaCache(fileURL: file).area(for: vm.pictureAreaCacheKey) != nil)
        vm.stopPictureAreaScan()
    }

    @Test func staleScanResultIsDropped() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try makeViewModel(cacheFile: file)
        let stills = GatedStills(image: letterboxed())
        let task = vm.runPictureAreaScan(source: stills, duration: 7200, displayAspect: 16.0 / 9.0)
        vm.advanceSessionGeneration()
        await stills.open()
        await task.firstPassDone()
        #expect(vm.detectedPictureArea == nil)
        vm.stopPictureAreaScan()
    }

    @Test func noScanForLiveOrPreroll() {
        #expect(PlayerViewModel.shouldScanPictureArea(choice: .fill(.auto), hasStartedPlaying: true,
                                                      isLive: false, isPreroll: false))
        #expect(!PlayerViewModel.shouldScanPictureArea(choice: .fill(.auto), hasStartedPlaying: true,
                                                       isLive: true, isPreroll: false))
        #expect(!PlayerViewModel.shouldScanPictureArea(choice: .fill(.auto), hasStartedPlaying: true,
                                                       isLive: false, isPreroll: true))
        #expect(!PlayerViewModel.shouldScanPictureArea(choice: .fill(.auto), hasStartedPlaying: false,
                                                       isLive: false, isPreroll: false))
        #expect(!PlayerViewModel.shouldScanPictureArea(choice: .fill(.r239), hasStartedPlaying: true,
                                                       isLive: false, isPreroll: false))
        #expect(!PlayerViewModel.shouldScanPictureArea(choice: .original, hasStartedPlaying: true,
                                                       isLive: false, isPreroll: false))
    }

    @Test func cachedAreaAppliesWithoutScan() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try makeViewModel(cacheFile: file)
        let scope = PictureArea(rect: CGRect(x: 0, y: 0.128, width: 1, height: 0.744), snappedRatio: 2.39)
        vm.pictureAreaCache.store(scope, for: vm.pictureAreaCacheKey)
        vm.preparePictureArea(scanURL: nil)
        #expect(vm.detectedPictureArea == scope)
    }

    private static let scope = PictureArea(rect: CGRect(x: 0, y: 0.128, width: 1, height: 0.744), snappedRatio: 2.39)

    /// Review of Sodalite#118: a same-item reload does not move the generation, so a first pass the
    /// stop left running used to land in the new session with a partial area.
    @Test func aStoppedScanNeverLands() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try makeViewModel(cacheFile: file)
        let stills = GatedStills(image: letterboxed())
        let task = vm.runPictureAreaScan(source: stills, duration: 7200, displayAspect: 16.0 / 9.0)
        vm.stopPictureAreaScan()
        await stills.open()
        await task.firstPassDone()
        #expect(vm.detectedPictureArea == nil)
        #expect(vm.pictureAreaScanState != .finished)
    }

    /// A first pass with no answer must not leave the previous episode's zoom on this one.
    @Test func aFirstPassWithoutAnswerDropsTheProvisionalArea() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try makeViewModel(cacheFile: file)
        vm.provisionalPictureArea = Self.scope
        let task = vm.runPictureAreaScan(source: NoStills(), duration: 7200, displayAspect: 16.0 / 9.0)
        await task.firstPassDone()
        #expect(vm.provisionalPictureArea == nil)
        #expect(vm.effectivePictureArea != Self.scope.rect)
        vm.stopPictureAreaScan()
    }

    /// Item recovery swaps in another file under a same-item reload; the old file's area is not its.
    @Test func aReplacedFileForgetsTheArea() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try makeViewModel(cacheFile: file)
        vm.detectedPictureArea = Self.scope
        vm.provisionalPictureArea = Self.scope
        vm.pictureAreaScanState = .finished
        vm.forgetPictureArea()
        #expect(vm.detectedPictureArea == nil)
        #expect(vm.provisionalPictureArea == nil)
        #expect(vm.pictureAreaScanState == .idle)
    }

    /// A hand-picked ratio is the override for a wrong detection, so a quality change or an outage
    /// retry keeps it. A new item starts from the preference again.
    @Test func aPickedRatioSurvivesASameItemReload() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = try makeViewModel(cacheFile: file)
        vm.applySessionPictureChoice()
        vm.selectPictureChoice(.fill(.r239))
        vm.resetSessionState(.sameItemReload)
        vm.applySessionPictureChoice()
        #expect(vm.activePictureChoice == .fill(.r239))
        vm.resetSessionState(.itemSwitch(to: vm.item))
        vm.applySessionPictureChoice()
        #expect(vm.activePictureChoice != .fill(.r239))
    }
}
