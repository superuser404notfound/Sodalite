import Foundation

/// How a `PlayerHostController` relates to the view model it shows. One view model can move between
/// the normal player, a multiview grid and a tile's full screen without reloading or stopping (Sodalite#175).
enum PlayerPresentationMode: Sendable, Equatable {
    /// A fresh player: loads on appear, stops on dismiss.
    case standalone
    /// The survivor of a multiview session: already playing, otherwise a normal player.
    case continuing
    /// A tile's full screen: the multiview session owns playback and app lifecycle.
    case multiviewTile

    var launchesPlayback: Bool { self == .standalone }
    var stopsOnDismiss: Bool { self != .multiviewTile }
    var observesAppLifecycle: Bool { self != .multiviewTile }
    var offersPictureInPicture: Bool { self != .multiviewTile }
    var offersMultiview: Bool { self != .multiviewTile }
}
