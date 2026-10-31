import CoreGraphics
import Testing
@testable import Sodalite

/// The tab switch in both tvOS shells: a page leaves towards the side its tab sits on and the new
/// one arrives from the other. Got backwards, every switch reads as moving against the bar.
struct ShellPageSwitchTests {

    private let tabs: [ShellTab] = [.home, .music, .settings]

    @Test("Moving along the bar points forward, moving back points back")
    func direction() {
        #expect(ShellPageSwitch.direction(from: .home, to: .settings, in: tabs) == 1)
        #expect(ShellPageSwitch.direction(from: .settings, to: .music, in: tabs) == -1)
        #expect(ShellPageSwitch.direction(from: .home, to: .home, in: tabs) == 0)
    }

    @Test("A tab the bar no longer carries does not slide")
    func unknownTab() {
        #expect(ShellPageSwitch.direction(from: .home, to: .settings, in: [.home]) == 0)
    }

    @Test("Kept pages wait on their own side of the shown page")
    func restingSide() {
        #expect(ShellPageSwitch.restingSide(of: .home, shown: .music, in: tabs) == -1)
        #expect(ShellPageSwitch.restingSide(of: .settings, shown: .music, in: tabs) == 1)
        #expect(ShellPageSwitch.restingSide(of: .music, shown: .music, in: tabs) == 0)
        #expect(ShellPageSwitch.restingSide(of: .music, shown: nil, in: tabs) == 0)
    }
}
