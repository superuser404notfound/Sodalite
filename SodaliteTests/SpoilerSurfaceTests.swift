import Foundation
import Testing

/// Sodalite#50 touches one line per surface. These pin that each of those lines is still there,
/// since a dropped veil is invisible in every other test: the screen simply shows the spoiler.
struct SpoilerSurfaceTests {
    @Test("episode card art and synopsis are veiled")
    func episodeRowComponentsVeiled() throws {
        let source = try sourceFile("Sodalite/Features/Detail/EpisodeRowComponents.swift")
        #expect(source.contains(".spoilerVeil(for: episode, style: .image)"))
        #expect(source.contains(".spoilerVeil(for: episode, style: .text)"))
        #expect(source.contains("let episode: JellyfinItem"))
    }

    @Test("the synopsis box reveals before it expands")
    func synopsisTwoStep() throws {
        let source = try sourceFile("Sodalite/Features/Detail/EpisodeRowComponents.swift")
        #expect(source.contains("SpoilerReveal.reveal(episode"))
    }

    @Test("the episode context menu offers a reveal for art-only spoilers")
    func contextMenuReveal() throws {
        let source = try sourceFile("Sodalite/Features/Detail/SeriesDetailView.swift")
        #expect(source.contains("spoiler.reveal"))
        #expect(source.contains("SpoilerReveal.reveal(episode"))
    }

    @Test("the shared media card veils episode art")
    func mediaCardVeiled() throws {
        let source = try sourceFile("Sodalite/Components/MediaCard.swift")
        #expect(source.contains(".spoilerVeil(for: item, style: .image, veils: !showsSeriesArtwork)"))
    }

    /// Sodalite#66. Two halves of one decision: Home marks the item so its URL chain stays on show
    /// art, and the row drops the blur. If only the second half survived a refactor, the card would
    /// paint an unblurred episode still.
    @Test("Home hands the spoiler decision to both the URL chain and the row")
    func homePassesSeriesArtwork() throws {
        let source = try sourceFile("Sodalite/Features/Home/HomeView.swift")
        #expect(source.contains("func needsSpoilerSafeArtwork("))
        #expect(source.contains("spoilerSafe: needsSpoilerSafeArtwork("))
        #expect(source.contains("showsSeriesArtwork: cwImage != .still"))
        let row = try sourceFile("Sodalite/Components/HorizontalMediaRow.swift")
        #expect(row.contains("showsSeriesArtwork: showsSeriesArtwork"))
    }

    @Test("the expandable text box takes an optional spoiler item and reveals first")
    func expandableTextBoxTwoStep() throws {
        let source = try sourceFile("Sodalite/Components/ExpandableTextBox.swift")
        #expect(source.contains("var spoilerItem: JellyfinItem?"))
        #expect(source.contains("SpoilerReveal.reveal("))
    }

    @Test("both detail heroes pass their item to the text box")
    func detailHeroesPassItem() throws {
        let movie = try sourceFile("Sodalite/Features/Detail/MovieDetailView.swift")
        #expect(movie.contains("spoilerItem: vm.item"))
        let series = try sourceFile("Sodalite/Features/Detail/SeriesDetailView.swift")
        #expect(series.contains("spoilerItem: displayItem"))
    }

    @Test("a veiled episode never paints its own backdrop full bleed")
    func backdropFallsBackToSeries() throws {
        let service = try sourceFile("Sodalite/Services/Jellyfin/JellyfinImageService.swift")
        #expect(service.contains("func parentBackdropURL("))
        let series = try sourceFile("Sodalite/Features/Detail/SeriesDetailView.swift")
        #expect(series.contains("parentBackdropURL(for: episode, maxWidth: maxWidth)"))
    }

    @Test("the player takes an injected policy rather than reading the environment")
    func playerInjectsPolicy() throws {
        let vm = try sourceFile("Sodalite/Player/PlayerViewModel.swift")
        #expect(vm.contains("let spoilerPolicy: SpoilerPolicy"))
        #expect(vm.contains("spoilerPolicy: SpoilerPolicy = .disabled"))
        let launcher = try sourceFile("Sodalite/Player/PlayerLauncher.swift")
        #expect(launcher.contains("spoilerPolicy: spoilerPolicy"))
    }

    @Test("the now-playing description is dropped, not blurred")
    func nowPlayingDropsDescription() throws {
        let source = try sourceFile("Sodalite/Player/PlayerViewModel+NowPlaying.swift")
        #expect(source.contains("spoilerPolicy.isHidden(item)"))
    }

    /// Sodalite#103 replaced the next-episode card with a pill, and the episode still went with it.
    /// That removed the player's only spoiler-bearing surface: the title and the S/E line were
    /// deliberately unveiled before and still are, because the viewer is being asked whether to
    /// continue into exactly that episode. So the invariant flips from "veil the still" to "there
    /// is no still", and a re-added image has to answer this test before it answers a design one.
    @Test("the next-episode prompt carries no still to veil")
    func nextEpisodePromptHasNoArtwork() throws {
        let source = try sourceFile("Sodalite/Player/UI/PlayerOverlayView.swift")
        #expect(!source.contains("AsyncCachedImage"))
        #expect(!source.contains(".spoilerVeil("))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
