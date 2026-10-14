import Foundation
import Testing
@testable import Sodalite

@Suite("Appearance surface structure")
struct AppearanceSurfaceStructureTests {
    @Test("every background declares its own opaque ground")
    func backgroundsAreSelfOpaque() throws {
        // A translucent ground takes its tone from whatever the surface leaves behind it: an
        // isolation plate on a cover, the bare system backdrop on the tab shell. That is how one
        // theme came out near-black on a library grid and grey on Home (Sodalite#131). Driven off
        // allCases so a fifth background has to declare its ground here rather than inherit the
        // guarantee silently.
        let grounds: [BackgroundStyle: (file: String, ground: String)] = [
            .graphiteGlass: (
                "Sodalite/Extensions/GlassBackground.swift",
                "Color.Theme.surfaceElevated"
            ),
            .oledBlack: (
                "Sodalite/Features/Support/AppBackgroundView.swift",
                "Color.black.ignoresSafeArea()"
            ),
            .accentAurora: (
                "Sodalite/Features/Support/AccentAuroraBackground.swift",
                "Color.black"
            ),
            .cinemaNoir: (
                "Sodalite/Features/Support/CinemaNoirBackground.swift",
                "Color(white: 0.24)"
            )
        ]

        for style in BackgroundStyle.allCases {
            let entry = try #require(
                grounds[style],
                "\(style.rawValue) declares no opaque ground"
            )
            #expect(try sourceFile(entry.file).contains(entry.ground))
        }

        // Graphite is composed per platform, and the grounds above are the tvOS branch. iOS lifts
        // the same material with a white wash instead, which is what keeps it one tone there
        // (verified on the iPhone), so deleting the wash has to fail here too.
        let graphite = try sourceFile("Sodalite/Extensions/GlassBackground.swift")
        #expect(graphite.contains(".white.opacity(0.12), .white.opacity(0.04)"))
    }

    @Test("every themed surface floors its background on an opaque plate")
    func themedSurfacesFloorTheirBackground() throws {
        let source = try sourceFile("Sodalite/Extensions/GlassBackground.swift")
        let plate = "Color.black.ignoresSafeArea()"

        // Graphite Glass is a material, and a tvOS fullScreenCover keeps the presenter composited
        // behind the cover (measured), so the plate is what makes a surface opaque, not the
        // presentation style. Asserted per surface: a plate in a neighbouring declaration must not
        // satisfy this.
        #expect(declaration(named: "IsolatedThemedSurface", in: source)?.contains(plate) == true)
        #expect(
            declaration(named: "ThemedStaticBackgroundModifier", in: source)?
                .contains(plate) == true
        )

        for modifier in ["ThemedRootBackgroundModifier", "ThemedPresentationBackgroundModifier"] {
            #expect(
                declaration(named: modifier, in: source)?
                    .contains("IsolatedThemedSurface(") == true
            )
        }
    }

    @Test("presentation surface isolates content and increments depth")
    func presentationSurfacePrimitive() throws {
        let source = try sourceFile("Sodalite/Extensions/GlassBackground.swift")
        #expect(source.contains("func themedPresentationBackground()"))
        #expect(source.contains("Color.black.ignoresSafeArea()"))
        #expect(source.contains("parentDepth + 1"))
        #expect(source.contains("AppBackgroundView(theme: theme, mode: .automatic)"))
        #expect(source.contains(".presentationBackground(.clear)"))
    }

    @Test("path navigation has the same clear iOS container")
    func pathNavigationPrimitive() throws {
        let source = try sourceFile("Sodalite/Extensions/View+PlatformCompat.swift")
        #expect(source.contains("struct ThemeNavigationPathStack"))
        #expect(source.contains("NavigationStack(path: $path)"))
        #expect(source.contains("func themedNavigationDestination()"))
        #expect(source.contains("containerBackground(.clear, for: .navigation)"))
    }

    @Test("backdrop-less Settings pushes clear their destination hosts")
    func settingsDestinationHosts() throws {
        let expectedCounts = [
            "Sodalite/Features/Settings/SettingsView.swift": 2,
            "Sodalite/Features/Support/AppearanceSettingsView.swift": 2,
            "Sodalite/Features/Settings/ProfileSettingsView.swift": 1,
            "Sodalite/Features/Settings/Licenses/LicensesView.swift": 1,
            "Sodalite/Features/Support/AccentColorPickerView.swift": 1,
            "Sodalite/Features/Support/BackgroundPickerView.swift": 1,
            // Catalog's "Set up Seerr" pushes the same backdrop-less Seerr page as Settings does,
            // and without this it rendered as a black page over the app background.
            "Sodalite/Features/Catalog/CatalogView.swift": 1
        ]

        for (path, expectedCount) in expectedCounts {
            let source = try sourceFile(path)
            #expect(
                occurrenceCount(
                    of: ".themedNavigationDestination()",
                    in: source
                ) == expectedCount
            )
        }
    }

    @Test("backdrop-less Auth pushes clear their destination hosts")
    func authDestinationHosts() throws {
        let expectedCounts = [
            "Sodalite/Features/Auth/ServerDiscoveryView.swift": 2,
            "Sodalite/Features/Auth/LaunchProfilePickerView.swift": 1,
            "Sodalite/Features/Auth/ServerAddressEntryView.swift": 3,
            "Sodalite/Features/Auth/UserPickerView.swift": 1
        ]

        for (path, expectedCount) in expectedCounts {
            let source = try sourceFile(path)
            #expect(
                occurrenceCount(
                    of: ".themedNavigationDestination()",
                    in: source
                ) == expectedCount
            )
        }
    }

    @Test("settings owns one presentation renderer and child pages inherit it")
    func settingsSurfaceOwnership() throws {
        let tabRoot = try sourceFile("Sodalite/App/TabRootView.swift")
        let settings = try sourceFile("Sodalite/Features/Settings/SettingsView.swift")
        let seerr = try sourceFile("Sodalite/Features/Settings/SeerrSettingsView.swift")
        let licenses = try sourceFile("Sodalite/Features/Settings/Licenses/LicensesView.swift")
        let changelog = try sourceFile("Sodalite/Features/Changelog/ChangelogListView.swift")

        #expect(tabRoot.contains(
            "SettingsView(onClose: { showSettings = false })\n"
                + "                .themedPresentationBackground()"
        ))
        #expect(settings.contains("ThemeNavigationStack {"))
        #expect(!seerr.contains(".themedStaticBackground()"))
        #expect(!licenses.contains(".themedStaticBackground()"))
        #expect(!changelog.contains(".themedStaticBackground()"))
    }

    @Test("URL forms reveal only their isolated theme surface")
    func themedURLForms() throws {
        let source = try sourceFile(
            "Sodalite/Features/Settings/DualURLEditSheet.swift"
        )
        #expect(source.contains("ThemeNavigationStack {"))
        #expect(source.contains(".scrollContentBackground(.hidden)"))
        #expect(source.contains(".themedPresentationBackground()"))
    }

    @Test("auth roots inherit one selected theme surface")
    func authSurfaceOwnership() throws {
        let router = try sourceFile("Sodalite/App/AppRouter.swift")
        let discovery = try sourceFile("Sodalite/Features/Auth/ServerDiscoveryView.swift")
        let launchPicker = try sourceFile("Sodalite/Features/Auth/LaunchProfilePickerView.swift")

        #expect(router.contains(".themedRootBackground()"))
        #expect(discovery.contains("ThemeNavigationPathStack(path: $path)"))
        #expect(launchPicker.contains("ThemeNavigationStack {"))

        for path in [
            "Sodalite/Features/Auth/ServerDiscoveryView.swift",
            "Sodalite/Features/Auth/LaunchProfilePickerView.swift",
            "Sodalite/Features/Auth/UserPickerView.swift",
            "Sodalite/Features/Auth/ServerAddressEntryView.swift",
            "Sodalite/Features/Auth/LoginView.swift"
        ] {
            let source = try sourceFile(path)
            #expect(!source.contains(".glassBackground()"))
        }
    }

    @Test("auth covers own isolated presentation surfaces")
    func authPresentationOwnership() throws {
        let router = try sourceFile("Sodalite/App/AppRouter.swift")
        let launchPicker = try sourceFile("Sodalite/Features/Auth/LaunchProfilePickerView.swift")
        let switchSheet = try sourceFile("Sodalite/Features/Auth/ServerSwitchSheet.swift")

        #expect(router.contains("context: .reprompt"))
        #expect(router.contains(".themedPresentationBackground()"))
        #expect(launchPicker.contains("ServerDiscoveryView(addMode: true)"))
        #expect(launchPicker.contains(".themedPresentationBackground()"))
        #expect(switchSheet.contains(".themedPresentationBackground()"))
    }

    @Test("second URL form owns an isolated theme surface")
    func themedSecondURLForm() throws {
        let source = try sourceFile(
            "Sodalite/Features/Auth/AddSecondURLSheet.swift"
        )
        #expect(source.contains("ThemeNavigationStack {"))
        #expect(source.contains(".scrollContentBackground(.hidden)"))
        #expect(source.contains(".themedPresentationBackground()"))
    }

    @Test("What's New uses a themed presentation without fixed page black")
    func whatsNewSurface() throws {
        let router = try sourceFile("Sodalite/App/AppRouter.swift")
        let whatsNew = try sourceFile("Sodalite/Features/Changelog/WhatsNewView.swift")
        let cover = try #require(
            router.components(
                separatedBy: ".fullScreenCoverCompat(isPresented: $showWhatsNew)"
            ).dropFirst().first
        )
        let coverBody = cover.components(
            separatedBy: ".fullScreenCoverCompat(item: Binding("
        ).first ?? cover

        #expect(coverBody.contains("WhatsNewView(entry: entry)"))
        #expect(coverBody.contains(".themedPresentationBackground()"))
        #expect(!coverBody.contains(".pausesAppBackgroundMotion()"))
        #expect(!whatsNew.contains("Color.black.opacity(0.96)"))
    }

    @Test("security surfaces remain deliberately dark")
    func securitySurfaceExclusions() throws {
        #expect(try sourceFile(
            "Sodalite/Features/Settings/ParentalControls/PINEntryView.swift"
        ).contains("Color.black.opacity(0.92).ignoresSafeArea()"))
        #expect(try sourceFile(
            "Sodalite/Features/Settings/ParentalControls/PINRecoveryView.swift"
        ).contains("Color.black.opacity(0.95).ignoresSafeArea()"))
    }

    /// One top-level declaration, so a per-surface assertion cannot be satisfied by a neighbour.
    private func declaration(named name: String, in source: String) -> String? {
        source
            .components(separatedBy: "\nstruct ")
            .flatMap { $0.components(separatedBy: "\nprivate struct ") }
            .first { $0.hasPrefix(name) }
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

    private func occurrenceCount(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
