import Testing
import Foundation
@testable import Sodalite

/// The in-player subtitle search (OpenSubtitles through Jellyfin RemoteSearch). Reddit report,
/// 2026-11-28: with one Chinese entry only Simplified was reachable, because the plugin reads `zh`
/// as zh-CN.
@MainActor
struct SubtitleSearchLanguageTests {

    @Test("Chinese is offered as Simplified (chi) and Traditional (zh-tw), next to each other")
    func chineseSplit() {
        let codes = PlayerViewModel.subtitleSearchLanguageChoices.map(\.code)
        let chi = codes.firstIndex(of: "chi")
        #expect(chi.map { codes[$0 + 1] } == "zh-tw")
        #expect(codes.filter { $0 == "chi" }.count == 1)
    }

    @Test("the search list has no Auto entry and keeps every settings language")
    func keepsSettingsLanguages() {
        let search = Set(PlayerViewModel.subtitleSearchLanguageChoices.compactMap(\.code))
        #expect(!PlayerViewModel.subtitleSearchLanguageChoices.contains { $0.code == nil })
        for code in PlaybackPreferences.subtitleLanguageChoices.compactMap(\.code) {
            #expect(search.contains(code))
        }
    }

    @Test("the settings list itself stays on 3-letter codes")
    func settingsUntouched() {
        #expect(!PlaybackPreferences.subtitleLanguageChoices.contains { $0.code == "zh-tw" })
    }

    @Test("a Traditional Chinese device starts on zh-tw", arguments: ["zh-Hant", "zh_TW", "zh-Hant-HK", "zh_MO"])
    func traditionalSeed(identifier: String) {
        #expect(PlayerViewModel.subtitleSearchSeed(preferred: nil, locale: Locale(identifier: identifier)) == "zh-tw")
        #expect(PlayerViewModel.subtitleSearchSeed(preferred: "chi", locale: Locale(identifier: identifier)) == "zh-tw")
    }

    @Test("a Simplified Chinese device stays on chi", arguments: ["zh-Hans", "zh_CN", "zh-Hans-SG"])
    func simplifiedSeed(identifier: String) {
        #expect(PlayerViewModel.subtitleSearchSeed(preferred: nil, locale: Locale(identifier: identifier)) == "chi")
    }

    @Test("other seeds are untouched")
    func otherSeeds() {
        #expect(PlayerViewModel.subtitleSearchSeed(preferred: nil, locale: Locale(identifier: "de_DE")) == "ger")
        #expect(PlayerViewModel.subtitleSearchSeed(preferred: "chi", locale: Locale(identifier: "en_US")) == "chi")
        #expect(PlayerViewModel.subtitleSearchSeed(preferred: "fre", locale: Locale(identifier: "zh_TW")) == "fre")
    }
}
