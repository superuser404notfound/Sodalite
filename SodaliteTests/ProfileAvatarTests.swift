import Foundation
import Testing
@testable import Sodalite

/// ASD-R201: one initials rule and one URL rule for every avatar.
@MainActor
struct ProfileAvatarTests {
    @Test func initialsTakeTwoWordsOrTwoLetters() {
        #expect("Vincent Herbst".profileInitials == "VH")
        #expect("anna".profileInitials == "AN")
        #expect("A".profileInitials == "A")
        #expect("".profileInitials == "")
    }

    @Test func aNamedServersAvatarCarriesNoToken() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        let url = try #require(container.profileAvatarURL(
            userID: "u1", tag: "t", baseURL: URL(string: "https://jf.example")!))
        #expect(url.absoluteString.hasPrefix("https://jf.example/Users/u1/Images/Primary"))
        #expect(!url.absoluteString.lowercased().contains("api_key"))
        #expect(!url.absoluteString.lowercased().contains("apikey"))
    }

    @Test func noTagMeansInitials() {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        #expect(container.profileAvatarURL(userID: "u1", tag: nil, baseURL: URL(string: "https://jf.example")!) == nil)
    }
}
