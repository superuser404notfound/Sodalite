import Foundation

/// The channels a live session zaps through, in the server's order, which is the guide's (Sodalite#173).
struct LiveChannelLineup: Equatable, Sendable {
    let channels: [JellyfinChannel]

    func contains(_ channelID: String) -> Bool {
        channels.contains { $0.id == channelID }
    }

    /// Wraps at both ends, like a TV. Nil when there is nowhere to go.
    func neighbour(of channelID: String, offset: Int) -> JellyfinChannel? {
        guard channels.count > 1,
              let index = channels.firstIndex(where: { $0.id == channelID }) else { return nil }
        let count = channels.count
        let target = ((index + offset) % count + count) % count
        return target == index ? nil : channels[target]
    }
}
