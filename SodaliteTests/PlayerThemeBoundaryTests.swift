import Testing
import Foundation
@testable import Sodalite

/// The player is a UIKit modal with a UIHostingController inside it, and a hosting controller starts
/// from a BLANK SwiftUI environment. Nothing warns about that: an unset environment key answers with
/// its default, and `ResolvedAppearanceTheme.default` is system blue, so the transport bar's focused
/// chip drew blue on a pink accent while the scrubber next to it was correct.
struct PlayerThemeBoundaryTests {

    /// What made the defect silent instead of loud. Pinned so the trap stays legible: the fallback is
    /// a real, plausible theme, not an empty value anyone would notice in a diff.
    @Test func theUnsetEnvironmentAnswersWithSystemBlue() {
        #expect(ResolvedAppearanceTheme.default.accent == .systemBlue)
    }

    /// The single place that has to put the environment back.
    @Test func theHostingBoundaryReinjectsTheTheme() throws {
        let source = try sourceFile("Sodalite/Player/PlayerHostController.swift")

        #expect(source.contains("UIHostingController(rootView: overlay)"))
        #expect(source.contains(#".environment(\.appearanceTheme, theme)"#))
    }

    /// Both launchers read the theme on the SwiftUI side, where it is still valid, and carry it over
    /// by hand. Reading it any deeper is reading it below the boundary, which is the defect.
    @Test func bothLaunchersCarryTheThemeAcross() throws {
        for path in ["Sodalite/Player/PlayerLauncher.swift", "Sodalite/Player/LivePlayerLauncher.swift"] {
            let source = try sourceFile(path)
            #expect(source.contains(#"@Environment(\.appearanceTheme)"#), "\(path) does not read the theme")
            #expect(source.contains("theme: appearanceTheme"), "\(path) does not hand it to the host")
        }
    }

    /// `Color.accentColor` is the static asset, a hard-coded blue that ignores the session accent, so
    /// a `tint ?? .accentColor` fallback is the same defect written a second way. The player tint is
    /// non-optional now, so no consumer in the tree has a branch that needs one.
    @Test func thePlayerTreeHasNoSystemBlueFallback() throws {
        let offenders = try swiftFiles(under: "Sodalite/Player")
            .filter { try sourceFile($0).contains("accentColor") }

        #expect(offenders.isEmpty, "accentColor in \(offenders)")
    }

    // MARK: - Helpers

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(under relativePath: String) throws -> [String] {
        let root = repository.appendingPathComponent(relativePath)
        let found = FileManager.default.enumerator(atPath: root.path)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .map { "\(relativePath)/\($0)" } ?? []
        #expect(!found.isEmpty, "no sources found under \(relativePath)")
        return found
    }
}
