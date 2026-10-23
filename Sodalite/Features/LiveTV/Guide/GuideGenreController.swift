import Foundation
import Observation

/// Genre narrowing state shared by the guide grid and the iPhone channel list (#182): the selection,
/// the genres on offer per scope, and the set of channels that match. The owner supplies the time
/// window for the "whole guide" scope and is told when the matching channels change.
@Observable
@MainActor
final class GuideGenreController {

    /// Upper bound on programs pulled for a genre list or a match. A full day of a 500-channel
    /// IPTV line-up is about 12k programs; past this the list is a sample, which still names every
    /// genre that is on more than rarely.
    static let programCap = 6000

    private(set) var filter = GuideGenreFilter()
    /// The genres on offer per scope, nil until fetched.
    private(set) var names: [GuideGenreFilter.Scope: [String]] = [:]
    private(set) var loadingScope: GuideGenreFilter.Scope?
    private(set) var error: String?
    /// True while the matching channels are being resolved, so the owner shows progress rather than
    /// the "nothing matches" state.
    private(set) var isResolving = false
    /// Channels with a program in the active selection. nil while no genre is selected.
    private(set) var channelIDs: Set<String>?

    /// The owner's time window for `.guide`.
    @ObservationIgnored var guideWindow: () -> (start: Date, end: Date) = { (Date(), Date()) }
    /// Called when a selection switches to "now", so a time-scrolled owner can return to the present.
    @ObservationIgnored var onSnapToNow: () -> Void = {}
    /// Called whenever `channelIDs` changes.
    @ObservationIgnored var onChannelsChanged: () -> Void = {}

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String
    private var generation = 0

    init(service: JellyfinLiveTvServiceProtocol, userID: String) {
        self.service = service
        self.userID = userID
    }

    private func window(for scope: GuideGenreFilter.Scope) -> GuideProgramWindow {
        switch scope {
        case .now: return .airing
        case .guide:
            let window = guideWindow()
            return .range(start: window.start, end: window.end)
        }
    }

    /// Fetch the genres on offer for `scope`. The "now" list is always refetched, it goes stale
    /// within the hour; the window list is kept until `invalidate()`.
    func loadNames(for scope: GuideGenreFilter.Scope) async {
        if scope == .guide, names[scope] != nil { return }
        guard loadingScope != scope else { return }
        loadingScope = scope
        error = nil
        defer { if loadingScope == scope { loadingScope = nil } }
        do {
            let programs = try await service.getProgramIndex(
                userID: userID, window: window(for: scope), genres: nil, category: nil, cap: Self.programCap)
            names[scope] = GuideGenreFilter.genreNames(in: programs)
        } catch {
            self.error = ErrorText.user(for: error)
        }
    }

    func apply(_ newValue: GuideGenreFilter) async {
        guard newValue != filter else { return }
        let snapsToNow = newValue.isActive && newValue.scope == .now
            && (!filter.isActive || filter.scope != .now)
        filter = newValue
        // Same reasoning as the categories: a "now" match parked at 23:00 reads as a broken filter.
        if snapsToNow { onSnapToNow() }
        await resolve()
    }

    /// The owner's window moved or the user refreshed: both lists describe the old moment, and so
    /// does the set of matching channels.
    func invalidate() {
        names = [:]
        if filter.isActive { Task { await resolve() } }
    }

    private func resolve() async {
        generation += 1
        let current = generation
        guard filter.isActive else {
            channelIDs = nil
            isResolving = false
            onChannelsChanged()
            return
        }
        isResolving = true
        channelIDs = []
        onChannelsChanged()
        do {
            let programs = try await service.getProgramIndex(
                userID: userID, window: window(for: filter.scope),
                genres: filter.queryValue, category: nil, cap: Self.programCap)
            guard current == generation else { return }
            channelIDs = Set(programs.compactMap(\.channelId))
            error = nil
        } catch {
            guard current == generation else { return }
            // Leaving the list empty would read as "nothing matches". Drop the selection instead
            // and say why in the picker.
            filter.genres = []
            channelIDs = nil
            self.error = ErrorText.user(for: error)
        }
        isResolving = false
        onChannelsChanged()
    }

    func admits(_ channel: JellyfinChannel) -> Bool {
        channelIDs?.contains(channel.id) ?? true
    }

    /// Whether a program falls outside an active selection, which the guide dims.
    func isOutside(_ program: JellyfinProgram) -> Bool {
        filter.isActive && !filter.matches(program)
    }
}
