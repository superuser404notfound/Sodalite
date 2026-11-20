import Foundation

/// What identifies an external subtitle stream across a renumbering: Jellyfin keeps no file name on
/// the stream, and the index shifts when a file is added or removed in front of it (audit PUI-202).
struct ExternalSubtitleSignature: Hashable, Sendable {
    let language: String?
    let codec: String?
    let title: String?
    let displayTitle: String?

    init(_ stream: MediaStream) {
        language = stream.language?.lowercased()
        codec = stream.codec?.lowercased()
        title = stream.title
        displayTitle = stream.displayTitle
    }

    static func externals(in streams: [MediaStream]) -> [ExternalSubtitleSignature] {
        streams.filter { $0.isExternal == true }.map(ExternalSubtitleSignature.init)
    }

    /// The external stream that is new in `after`: the first one whose signature occurs more often
    /// than in `before`. Works whichever way Jellyfin orders the externals.
    static func newlyAttached(before: [ExternalSubtitleSignature], after: [MediaStream]) -> MediaStream? {
        var remaining = before.reduce(into: [ExternalSubtitleSignature: Int]()) { $0[$1, default: 0] += 1 }
        for stream in after where stream.isExternal == true {
            let signature = ExternalSubtitleSignature(stream)
            if let left = remaining[signature], left > 0 {
                remaining[signature] = left - 1
            } else {
                return stream
            }
        }
        return nil
    }
}

/// Feature #4: in-player subtitle search/download via Jellyfin RemoteSearch
/// (server needs OpenSubtitles plugin); downloads attach server-side as
/// external streams, applied live through the sidecar subtitle path.
@MainActor
extension PlayerViewModel {

    /// ISO 639-2/T codes (`Locale` output) mapped to /B codes (curated list +
    /// Jellyfin) for the languages where the two variants differ.
    private static let alpha3TtoB: [String: String] = [
        "deu": "ger", "fra": "fre", "ces": "cze", "nld": "dut",
        "ell": "gre", "ron": "rum", "zho": "chi"
    ]

    /// Settings language list minus the "Auto" (nil) entry, which has no code.
    var subtitleSearchLanguageOptions: [PlaybackPreferences.LanguageChoice] {
        PlaybackPreferences.subtitleLanguageChoices.filter { $0.code != nil }
    }

    /// Opens the overlay and runs the first search. Language seed: preferred
    /// subtitle language, else device language, else English.
    func presentSubtitleSearch() {
        let deviceCode = Locale.current.language.languageCode?.identifier(.alpha3)
            .map { Self.alpha3TtoB[$0] ?? $0 }
        let seed = preferences.preferredSubtitleLanguage ?? deviceCode ?? "eng"
        subtitleSearchLanguage = seed
        subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
        subtitleSearchVisible = true
        Task { [weak self] in await self?.searchSubtitles() }
    }

    func dismissSubtitleSearch() {
        subtitleSearchGeneration += 1
        subtitleSearchVisible = false
        subtitleSearchState = .idle
    }

    func setSubtitleSearchLanguage(_ code: String) {
        guard code != subtitleSearchLanguage else { return }
        subtitleSearchLanguage = code
        Task { [weak self] in await self?.searchSubtitles() }
    }

    func searchSubtitles() async {
        subtitleSearchState = .loading
        subtitleSearchGeneration += 1
        let generation = subtitleSearchGeneration
        let itemID = item.id
        let language = subtitleSearchLanguage
        do {
            let raw = try await searchRemoteSubtitlesWithRetry(language: language, itemID: itemID)
            // Drop a late result of an older search (another language, the same one asked twice) or of
            // an item the player has left.
            guard generation == subtitleSearchGeneration, item.id == itemID else { return }
            // Hash matches are timed against this exact file; surface first, then popularity.
            let results = raw.sorted { lhs, rhs in
                if (lhs.isHashMatch == true) != (rhs.isHashMatch == true) {
                    return lhs.isHashMatch == true
                }
                return (lhs.downloadCount ?? 0) > (rhs.downloadCount ?? 0)
            }
            let hashMatchCount = results.filter { $0.isHashMatch == true }.count
            LogTap.shared.note("[SubSearch] lang=\(subtitleSearchLanguage) results=\(results.count) hashMatch=\(hashMatchCount)")
            if results.isEmpty {
                subtitleSearchState = .empty
                subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
            } else {
                subtitleSearchState = .results(results)
                subtitleSearchFocus = .result(0)
            }
        } catch {
            guard generation == subtitleSearchGeneration, item.id == itemID else { return }
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.error",
                       defaultValue: "Subtitle search failed. The server may not have a subtitle provider installed.")
            )
            subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
        }
    }

    /// RemoteSearch with one retry: the OpenSubtitles provider cold-starts and
    /// times out on a session's first query, so a retry avoids a false "no
    /// provider installed" message.
    private func searchRemoteSubtitlesWithRetry(language: String, itemID: String) async throws -> [RemoteSubtitleInfo] {
        do {
            return try await playbackService.searchRemoteSubtitles(itemID: itemID, language: language)
        } catch {
            LogTap.shared.note("[SubSearch] first attempt failed (\(error)); retrying once")
            try await Task.sleep(for: .milliseconds(400))
            return try await playbackService.searchRemoteSubtitles(itemID: itemID, language: language)
        }
    }

    /// Downloads `info` server-side, finds the newly attached external stream,
    /// applies it live, and dismisses. If the server hasn't attached it by the
    /// time polling stops (slow CDN), parks in `.downloadTimedOut` ("Try again").
    func downloadAndApplySubtitle(_ info: RemoteSubtitleInfo) async {
        subtitleSearchState = .downloading(id: info.id)
        // External subs are never deduped; their signatures (not their indices, which shift when the
        // server renumbers) are the "before" snapshot for spotting the newly attached one.
        let before = ExternalSubtitleSignature.externals(in: subtitleStreams)
        let itemID = item.id
        let sourceID = mediaSourceID
        do {
            try await playbackService.downloadRemoteSubtitle(itemID: itemID, subtitleID: info.id)
        } catch {
            guard item.id == itemID else { return }
            // Download request itself failed (real error, not slow-CDN pending).
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.downloadFailed",
                       defaultValue: "Could not download this subtitle. Please try another one.")
            )
            subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
            return
        }
        await applyNewlyAttachedSubtitle(info: info, before: before, itemID: itemID, sourceID: sourceID)
    }

    /// Re-checks a timed-out download without re-issuing it. Backs "Try again".
    func retryTimedOutDownload() async {
        guard case .downloadTimedOut(let info, let before, _) = subtitleSearchState else { return }
        subtitleSearchState = .downloading(id: info.id)
        await applyNewlyAttachedSubtitle(info: info, before: before, itemID: item.id, sourceID: mediaSourceID)
    }

    /// Polls PlaybackInfo (5 attempts) for an external subtitle not in `before`.
    /// On success applies + dismisses; on timeout parks in `.downloadTimedOut`.
    /// Per-attempt errors swallowed so a slow-CDN hiccup reads as pending.
    /// `itemID` / `sourceID` are the session the download was started for: the poll outlives an
    /// auto-advance, and reading them live would apply this item's new stream index to the next one.
    private func applyNewlyAttachedSubtitle(
        info: RemoteSubtitleInfo, before: [ExternalSubtitleSignature], itemID: String, sourceID: String
    ) async {
        var newStream: MediaStream?
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            guard item.id == itemID else { return }
            let response = try? await playbackService.getPlaybackInfo(
                itemID: itemID, userID: userID, profile: nil
            )
            guard item.id == itemID else { return }
            guard let response else { continue }
            guard let source = response.mediaSources.first(where: { $0.id == sourceID })
                ?? response.mediaSources.first else { continue }
            let refreshed = Self.dedupedSubtitleStreams(from: source.mediaStreams)
            if let added = ExternalSubtitleSignature.newlyAttached(before: before, after: refreshed) {
                adoptRefreshedMediaStreams(source.mediaStreams)
                newStream = added
                break
            }
        }

        guard let applied = newStream else {
            // Accepted but not yet attached; on a slow CDN the fetch finishes
            // seconds later, so this is "still working", not a failure.
            subtitleSearchState = .downloadTimedOut(
                info: info,
                before: before,
                message: String(localized: "player.subtitle.search.downloadPending",
                                defaultValue: "The download is taking longer than expected. The server may still be fetching it on a slow connection. Wait a moment, then tap Try again.")
            )
            subtitleSearchFocus = .retry
            return
        }
        selectSubtitleTrack(id: applied.index, userInitiated: true)
        dismissSubtitleSearch()
        scheduleControlsHide()
    }

    // MARK: - Host-driven focus navigation

    var subtitleSearchCurrentLanguageIndex: Int {
        subtitleSearchLanguageOptions.firstIndex { $0.code == subtitleSearchLanguage } ?? 0
    }

    private var currentSubtitleResults: [RemoteSubtitleInfo] {
        if case .results(let r) = subtitleSearchState { return r }
        return []
    }

    func subtitleSearchMoveLeft() {
        if case .language(let i) = subtitleSearchFocus, i > 0 {
            subtitleSearchFocus = .language(i - 1)
        }
    }

    func subtitleSearchMoveRight() {
        if case .language(let i) = subtitleSearchFocus,
           i + 1 < subtitleSearchLanguageOptions.count {
            subtitleSearchFocus = .language(i + 1)
        }
    }

    func subtitleSearchMoveDown() {
        switch subtitleSearchFocus {
        case .language:
            if !currentSubtitleResults.isEmpty {
                subtitleSearchFocus = .result(0)
            } else if isSubtitleDownloadTimedOut {
                subtitleSearchFocus = .retry
            }
        case .result(let i):
            if i + 1 < currentSubtitleResults.count { subtitleSearchFocus = .result(i + 1) }
        case .retry:
            break
        }
    }

    func subtitleSearchMoveUp() {
        switch subtitleSearchFocus {
        case .language:
            break
        case .result(let i):
            subtitleSearchFocus = i > 0 ? .result(i - 1) : .language(subtitleSearchCurrentLanguageIndex)
        case .retry:
            subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
        }
    }

    func subtitleSearchConfirm() {
        switch subtitleSearchFocus {
        case .language(let i):
            let opts = subtitleSearchLanguageOptions
            guard opts.indices.contains(i), let code = opts[i].code else { return }
            setSubtitleSearchLanguage(code)
        case .result(let i):
            let results = currentSubtitleResults
            guard results.indices.contains(i) else { return }
            Task { [weak self] in await self?.downloadAndApplySubtitle(results[i]) }
        case .retry:
            Task { [weak self] in await self?.retryTimedOutDownload() }
        }
    }

    private var isSubtitleDownloadTimedOut: Bool {
        if case .downloadTimedOut = subtitleSearchState { return true }
        return false
    }

    // MARK: - Delete external subtitle (hold-to-delete)

    func requestSubtitleDeletion(streamIndex: Int) {
        subtitleDeleteFocus = .cancel
        subtitleDeleteState = .confirm(streamIndex: streamIndex)
        trackDropdown = .none
    }

    func subtitleDeletePromptToggleFocus() {
        guard case .confirm = subtitleDeleteState else { return }
        subtitleDeleteFocus = subtitleDeleteFocus == .cancel ? .delete : .cancel
    }

    func subtitleDeletePromptConfirm() {
        switch subtitleDeleteState {
        case .confirm(let streamIndex):
            if subtitleDeleteFocus == .delete {
                subtitleDeleteState = .deleting
                Task { [weak self] in await self?.performSubtitleDeletion(streamIndex: streamIndex) }
            } else {
                subtitleDeleteState = .hidden
                scheduleControlsHide()
            }
        case .error:
            subtitleDeleteState = .hidden
            scheduleControlsHide()
        case .deleting, .hidden:
            break
        }
    }

    /// Touch path (iOS): confirm deletion directly, bypassing the focus-toggle dance the remote uses.
    func subtitleDeletePromptConfirmDelete() {
        subtitleDeleteFocus = .delete
        subtitleDeletePromptConfirm()
    }

    /// Menu/back: dismiss, ignored mid-deletion.
    func subtitleDeletePromptDismiss() {
        if case .deleting = subtitleDeleteState { return }
        subtitleDeleteState = .hidden
        scheduleControlsHide()
    }

    private func performSubtitleDeletion(streamIndex: Int) async {
        if activeSubtitleIndex == streamIndex { selectSubtitleTrack(id: nil) }
        if activeSecondarySubtitleIndex == streamIndex { selectSecondarySubtitleTrack(id: nil) }
        let itemID = item.id
        do {
            try await playbackService.deleteSubtitle(itemID: itemID, index: streamIndex)
            let response = try await playbackService.getPlaybackInfo(
                itemID: itemID, userID: userID, profile: nil
            )
            guard item.id == itemID else { return }
            if let source = response.mediaSources.first(where: { $0.id == mediaSourceID })
                ?? response.mediaSources.first {
                adoptRefreshedMediaStreams(source.mediaStreams, removing: streamIndex)
            }
            subtitleDeleteState = .hidden
            scheduleControlsHide()
        } catch {
            subtitleDeleteState = .error(
                String(localized: "player.subtitle.delete.failed",
                       defaultValue: "Could not delete the subtitle. You may not have permission.")
            )
        }
    }
}

// MARK: - Renumbered streams

extension PlayerViewModel {

    /// Takes a fresh PlaybackInfo stream list after a subtitle was added or removed. Jellyfin renumbers
    /// the streams, so the active picks and the engine track map are re-keyed to the streams they named,
    /// and both stream lists change together (audit PUI-202, PUI-203).
    func adoptRefreshedMediaStreams(_ mediaStreams: [MediaStream]?, removing removedIndex: Int? = nil) {
        let old = subtitleStreams.filter { $0.index != removedIndex }
        let new = subtitleMenuStreams(from: mediaStreams ?? [])
        activeSubtitleIndex = Self.remappedSubtitleIndex(activeSubtitleIndex, old: old, new: new)
        activeSecondarySubtitleIndex = Self.remappedSubtitleIndex(activeSecondarySubtitleIndex, old: old, new: new)
        externalEngineTrackIDs = externalEngineTrackIDs.reduce(into: [:]) { result, entry in
            if let index = Self.remappedSubtitleIndex(entry.key, old: old, new: new) {
                result[index] = entry.value
            }
        }
        subtitleStreams = new
        sourceMediaStreams = mediaStreams ?? []
    }

    /// Where the stream that carried `index` in `old` sits in `new`: the same kind of stream (language,
    /// codec, titles, external flag), counted by occurrence so two identical files keep their order.
    /// nil when it is gone.
    static func remappedSubtitleIndex(_ index: Int?, old: [MediaStream], new: [MediaStream]) -> Int? {
        guard let index, let target = old.first(where: { $0.index == index }) else { return nil }
        func key(_ stream: MediaStream) -> [String?] {
            [stream.language?.lowercased(), stream.codec?.lowercased(), stream.title, stream.displayTitle,
             stream.isExternal == true ? "external" : "embedded", stream.isForced == true ? "forced" : nil]
        }
        let targetKey = key(target)
        let ordinal = old.prefix { $0.index != index }.filter { key($0) == targetKey }.count
        let matches = new.filter { key($0) == targetKey }
        return matches.indices.contains(ordinal) ? matches[ordinal].index : nil
    }
}
