import SwiftUI
import Testing
@testable import Sodalite

struct PhoneLandscapeSizeClassTests {
    @Test func phoneLandscapeReportsCompactWidth() {
        #expect(PhoneLandscapeSizeClass.resolve(.regular, vertical: .compact, isPhone: true) == .compact)
    }

    @Test func phonePortraitIsUnchanged() {
        #expect(PhoneLandscapeSizeClass.resolve(.compact, vertical: .regular, isPhone: true) == .compact)
    }

    @Test func padKeepsRegularWidthAtEveryHeight() {
        #expect(PhoneLandscapeSizeClass.resolve(.regular, vertical: .compact, isPhone: false) == .regular)
        #expect(PhoneLandscapeSizeClass.resolve(.regular, vertical: .regular, isPhone: false) == .regular)
    }
}
