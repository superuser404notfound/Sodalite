import Foundation

/// Everything the live player needs to launch a channel: the channel item
/// and the program that prompted playback (for initial Now Playing metadata).
struct LivePlaybackContext: Identifiable, Equatable {
    var id: String { channel.id }
    let channel: JellyfinChannel
    let program: JellyfinProgram?
    var zapFilter: GuideFilter = .default
}
