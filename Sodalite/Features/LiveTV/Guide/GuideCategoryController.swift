import Foundation
import Observation

/// Category narrowing shared by the guide grid and the iPhone channel list (#201): the channels whose
/// current program carries the category flag. Jellyfin's own channel-level flags answer from the
/// whole guide window (Movies, Kids) or never match at all (News, Sports), so this asks the program
/// query instead, the same one the Overview rows use, and narrows on the client like the genres do.
@Observable
@MainActor
final class GuideCategoryController {

    private(set) var category: GuideFilter.Category?
    /// True while the matching channels are being resolved, so the owner shows progress rather than
    /// the "nothing matches" state.
    private(set) var isResolving = false
    /// Channels airing a program of `category`. nil while no category is selected.
    private(set) var channelIDs: Set<String>?

    /// Called whenever `channelIDs` changes.
    @ObservationIgnored var onChannelsChanged: () -> Void = {}

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    private var generation = 0

    init(service: JellyfinLiveTvServiceProtocol, userID: String) {
        self.service = service
        self.userID = userID
    }

    func apply(_ newValue: GuideFilter.Category?) async {
        guard newValue != category else { return }
        category = newValue
        await resolve()
    }

    /// "Airing now" is as old as the moment it was asked.
    func invalidate() {
        if category != nil { Task { await resolve() } }
    }

    private func resolve() async {
        generation += 1
        let current = generation
        guard let category else {
            channelIDs = nil
            isResolving = false
            onChannelsChanged()
            return
        }
        isResolving = true
        channelIDs = []
        onChannelsChanged()
        // A failed lookup leaves the set empty, which the owner shows as "nothing matches". The chip
        // stays on, so tapping it twice asks again.
        let programs = try? await service.getProgramIndex(
            userID: userID, window: .airing, genres: nil, category: category,
            cap: GuideGenreController.programCap)
        guard current == generation else { return }
        channelIDs = Set((programs ?? []).compactMap(\.channelId))
        isResolving = false
        onChannelsChanged()
    }

    func admits(_ channel: JellyfinChannel) -> Bool {
        channelIDs?.contains(channel.id) ?? true
    }
}
