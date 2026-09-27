import Foundation

/// User-facing release notes, newest-first; add each new entry at the top of `entries`.
/// WhatsNewView fires once on first launch after update; group highlights by kind (.new / .improve / .fix).
enum Changelog {
    static let entries: [ChangelogEntry] = [
        // MARK: 1.1.0
        ChangelogEntry(
            version: "1.1.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.1_1_0.restingTouch.title",
                    "changelog.1_1_0.restingTouch.body",
                    icon: "hand.tap.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_1_0.durations.title",
                    "changelog.1_1_0.durations.body",
                    icon: "clock.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_1_0.statusPill.title",
                    "changelog.1_1_0.statusPill.body",
                    icon: "paintpalette.fill"
                ),
            ]
        ),
        // MARK: 1.0.0
        ChangelogEntry(
            version: "1.0.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.milestone.title",
                    "changelog.1_0_0.milestone.body",
                    icon: "party.popper.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.pip.title",
                    "changelog.1_0_0.pip.body",
                    icon: "pip.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.appearance.title",
                    "changelog.1_0_0.appearance.body",
                    icon: "paintpalette.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.trackMemory.title",
                    "changelog.1_0_0.trackMemory.body",
                    icon: "bookmark.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.forcedSubtitles.title",
                    "changelog.1_0_0.forcedSubtitles.body",
                    icon: "captions.bubble.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.childLock.title",
                    "changelog.1_0_0.childLock.body",
                    icon: "lock.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.cloudSync.title",
                    "changelog.1_0_0.cloudSync.body",
                    icon: "icloud"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.dualUrl.title",
                    "changelog.1_0_0.dualUrl.body",
                    icon: "network"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.spoilers.title",
                    "changelog.1_0_0.spoilers.body",
                    icon: "eye.slash.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.collections.title",
                    "changelog.1_0_0.collections.body",
                    icon: "rectangle.stack.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.peopleSearch.title",
                    "changelog.1_0_0.peopleSearch.body",
                    icon: "magnifyingglass.circle.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.favorites.title",
                    "changelog.1_0_0.favorites.body",
                    icon: "heart.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.restart.title",
                    "changelog.1_0_0.restart.body",
                    icon: "backward.end.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.clickToPause.title",
                    "changelog.1_0_0.clickToPause.body",
                    icon: "hand.tap.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.1_0_0.tvUserProfiles.title",
                    "changelog.1_0_0.tvUserProfiles.body",
                    icon: "person.2.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_0_0.personLibrary.title",
                    "changelog.1_0_0.personLibrary.body",
                    icon: "books.vertical.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_0_0.playback.title",
                    "changelog.1_0_0.playback.body",
                    icon: "play.circle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_0_0.detailNavigation.title",
                    "changelog.1_0_0.detailNavigation.body",
                    icon: "chevron.down.circle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_0_0.castCrew.title",
                    "changelog.1_0_0.castCrew.body",
                    icon: "person.2.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_0_0.topShelf.title",
                    "changelog.1_0_0.topShelf.body",
                    icon: "rectangle.topthird.inset.filled"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_0_0.requestFlow.title",
                    "changelog.1_0_0.requestFlow.body",
                    icon: "tray.and.arrow.down.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.1_0_0.everyScreen.title",
                    "changelog.1_0_0.everyScreen.body",
                    icon: "apps.iphone"
                ),
            ]
        ),
        // MARK: 0.13.0
        ChangelogEntry(
            version: "0.13.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_13_0.pipSubtitles.title",
                    "changelog.0_13_0.pipSubtitles.body",
                    icon: "pip.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_13_0.instantSubtitles.title",
                    "changelog.0_13_0.instantSubtitles.body",
                    icon: "bolt.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_13_0.smoothSeeking.title",
                    "changelog.0_13_0.smoothSeeking.body",
                    icon: "arrow.uturn.backward.circle.fill"
                ),
            ]
        ),
        // MARK: 0.12.0
        ChangelogEntry(
            version: "0.12.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.parental.title",
                    "changelog.0_12_0.parental.body",
                    icon: "lock.shield.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.subtitleSearch.title",
                    "changelog.0_12_0.subtitleSearch.body",
                    icon: "text.magnifyingglass"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.dualSubtitles.title",
                    "changelog.0_12_0.dualSubtitles.body",
                    icon: "captions.bubble.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.watchStats.title",
                    "changelog.0_12_0.watchStats.body",
                    icon: "chart.bar.xaxis"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.versionPicker.title",
                    "changelog.0_12_0.versionPicker.body",
                    icon: "square.stack.3d.up.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.playlists.title",
                    "changelog.0_12_0.playlists.body",
                    icon: "list.bullet.rectangle.portrait.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.shuffle.title",
                    "changelog.0_12_0.shuffle.body",
                    icon: "shuffle"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.trailers.title",
                    "changelog.0_12_0.trailers.body",
                    icon: "film.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_12_0.liveOverview.title",
                    "changelog.0_12_0.liveOverview.body",
                    icon: "tv"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_12_0.rewatchNextUp.title",
                    "changelog.0_12_0.rewatchNextUp.body",
                    icon: "arrow.clockwise"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_12_0.compactButtons.title",
                    "changelog.0_12_0.compactButtons.body",
                    icon: "rectangle.compress.vertical"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_12_0.backdropFix.title",
                    "changelog.0_12_0.backdropFix.body",
                    icon: "photo.fill"
                ),
            ]
        ),
        // MARK: 0.11.0
        ChangelogEntry(
            version: "0.11.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_11_0.liveDirectAudio.title",
                    "changelog.0_11_0.liveDirectAudio.body",
                    icon: "antenna.radiowaves.left.and.right"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_11_0.criticRating.title",
                    "changelog.0_11_0.criticRating.body",
                    icon: "percent"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_11_0.detailRedesign.title",
                    "changelog.0_11_0.detailRedesign.body",
                    icon: "doc.text.image"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_11_0.liveResilience.title",
                    "changelog.0_11_0.liveResilience.body",
                    icon: "dot.radiowaves.left.and.right"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_11_0.libraryPaging.title",
                    "changelog.0_11_0.libraryPaging.body",
                    icon: "square.grid.3x3.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_11_0.reliability.title",
                    "changelog.0_11_0.reliability.body",
                    icon: "checkmark.seal.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_11_0.episodeSynopsis.title",
                    "changelog.0_11_0.episodeSynopsis.body",
                    icon: "text.alignleft"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_11_0.subtitleLongCues.title",
                    "changelog.0_11_0.subtitleLongCues.body",
                    icon: "captions.bubble.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_11_0.requestFilters.title",
                    "changelog.0_11_0.requestFilters.body",
                    icon: "line.3.horizontal.decrease.circle.fill"
                ),
            ]
        ),
        // MARK: 0.10.0
        ChangelogEntry(
            version: "0.10.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_10_0.liveTV.title",
                    "changelog.0_10_0.liveTV.body",
                    icon: "tv"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_10_0.styledSubs.title",
                    "changelog.0_10_0.styledSubs.body",
                    icon: "captions.bubble.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_10_0.watchedFilter.title",
                    "changelog.0_10_0.watchedFilter.body",
                    icon: "line.3.horizontal.decrease.circle.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_10_0.mergedRow.title",
                    "changelog.0_10_0.mergedRow.body",
                    icon: "arrow.triangle.merge"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_10_0.backdrops.title",
                    "changelog.0_10_0.backdrops.body",
                    icon: "photo.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_10_0.liveDirect.title",
                    "changelog.0_10_0.liveDirect.body",
                    icon: "bolt.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_10_0.nowPlaying.title",
                    "changelog.0_10_0.nowPlaying.body",
                    icon: "iphone"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_10_0.detailCalm.title",
                    "changelog.0_10_0.detailCalm.body",
                    icon: "doc.text.image"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_10_0.latestRows.title",
                    "changelog.0_10_0.latestRows.body",
                    icon: "clock.badge.checkmark"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_10_0.channelErrors.title",
                    "changelog.0_10_0.channelErrors.body",
                    icon: "tv.slash"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_10_0.tabBar.title",
                    "changelog.0_10_0.tabBar.body",
                    icon: "menubar.rectangle"
                ),
            ]
        ),
        // MARK: 0.9.0
        ChangelogEntry(
            version: "0.9.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_9_0.music.title",
                    "changelog.0_9_0.music.body",
                    icon: "music.note.list"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_9_0.watched.title",
                    "changelog.0_9_0.watched.body",
                    icon: "checkmark.circle.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_9_0.detailLogos.title",
                    "changelog.0_9_0.detailLogos.body",
                    icon: "photo.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_9_0.restart.title",
                    "changelog.0_9_0.restart.body",
                    icon: "backward.end.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_9_0.artwork.title",
                    "changelog.0_9_0.artwork.body",
                    icon: "paintbrush.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_9_0.fasterDetail.title",
                    "changelog.0_9_0.fasterDetail.body",
                    icon: "bolt.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_9_0.episodeNowPlaying.title",
                    "changelog.0_9_0.episodeNowPlaying.body",
                    icon: "tv.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_9_0.playbackSync.title",
                    "changelog.0_9_0.playbackSync.body",
                    icon: "timeline.selection"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_9_0.nowPlaying.title",
                    "changelog.0_9_0.nowPlaying.body",
                    icon: "info.circle.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_9_0.surround.title",
                    "changelog.0_9_0.surround.body",
                    icon: "speaker.wave.3.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_9_0.streaming.title",
                    "changelog.0_9_0.streaming.body",
                    icon: "antenna.radiowaves.left.and.right"
                ),
            ]
        ),
        // MARK: 0.8.1
        ChangelogEntry(
            version: "0.8.1",
            highlights: [
                ChangelogHighlight(
                    .improve,
                    "changelog.0_8_1.scrubPreviewEngine.title",
                    "changelog.0_8_1.scrubPreviewEngine.body",
                    icon: "photo.on.rectangle"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_8_1.upNextOrder.title",
                    "changelog.0_8_1.upNextOrder.body",
                    icon: "forward.end.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_8_1.backgroundAudio.title",
                    "changelog.0_8_1.backgroundAudio.body",
                    icon: "speaker.slash.fill"
                ),
            ]
        ),
        // MARK: 0.8.0
        ChangelogEntry(
            version: "0.8.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_8_0.multiServer.title",
                    "changelog.0_8_0.multiServer.body",
                    icon: "server.rack"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_8_0.scrubPreview.title",
                    "changelog.0_8_0.scrubPreview.body",
                    icon: "photo.on.rectangle"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_8_0.detailPages.title",
                    "changelog.0_8_0.detailPages.body",
                    icon: "rectangle.stack.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_8_0.castPages.title",
                    "changelog.0_8_0.castPages.body",
                    icon: "person.2.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_8_0.libraryRows.title",
                    "changelog.0_8_0.libraryRows.body",
                    icon: "rectangle.grid.1x2.fill"
                ),
            ]
        ),
        // MARK: 0.7.0
        ChangelogEntry(
            version: "0.7.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_7_0.deletion.title",
                    "changelog.0_7_0.deletion.body",
                    icon: "trash.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_7_0.adminRequests.title",
                    "changelog.0_7_0.adminRequests.body",
                    icon: "person.2.badge.gearshape.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_7_0.liveStats.title",
                    "changelog.0_7_0.liveStats.body",
                    icon: "chart.line.uptrend.xyaxis"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_7_0.formats.title",
                    "changelog.0_7_0.formats.body",
                    icon: "film.stack.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_7_0.hdrRouting.title",
                    "changelog.0_7_0.hdrRouting.body",
                    icon: "tv.and.hifispeaker.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_7_0.uiPolish.title",
                    "changelog.0_7_0.uiPolish.body",
                    icon: "sparkles.tv.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_7_0.playerFixes.title",
                    "changelog.0_7_0.playerFixes.body",
                    icon: "wrench.and.screwdriver.fill"
                ),
            ]
        ),
        // MARK: 0.6.0
        ChangelogEntry(
            version: "0.6.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_6_0.engine.title",
                    "changelog.0_6_0.engine.body",
                    icon: "gearshape.2.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_6_0.playback.title",
                    "changelog.0_6_0.playback.body",
                    icon: "play.rectangle.fill"
                ),
            ]
        ),
        // MARK: 0.5.0
        ChangelogEntry(
            version: "0.5.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.dolbyVision.title",
                    "changelog.0_5_0.dolbyVision.body",
                    icon: "tv.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.hdr10Plus.title",
                    "changelog.0_5_0.hdr10Plus.body",
                    icon: "sun.max.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.subtitleRework.title",
                    "changelog.0_5_0.subtitleRework.body",
                    icon: "captions.bubble.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.chapterMarkers.title",
                    "changelog.0_5_0.chapterMarkers.body",
                    icon: "list.dash"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.errorCategories.title",
                    "changelog.0_5_0.errorCategories.body",
                    icon: "exclamationmark.triangle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.pictureSpeed.title",
                    "changelog.0_5_0.pictureSpeed.body",
                    icon: "rectangle.expand.vertical"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.touchpadAccuracy.title",
                    "changelog.0_5_0.touchpadAccuracy.body",
                    icon: "hand.tap.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.foregroundReload.title",
                    "changelog.0_5_0.foregroundReload.body",
                    icon: "arrow.clockwise"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_5_0.staleSubtitleGhost.title",
                    "changelog.0_5_0.staleSubtitleGhost.body",
                    icon: "captions.bubble"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_5_0.supporterIcon.title",
                    "changelog.0_5_0.supporterIcon.body",
                    icon: "star.circle.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_5_0.uiAutoHide.title",
                    "changelog.0_5_0.uiAutoHide.body",
                    icon: "eye.slash.fill"
                ),
            ]
        ),
        // MARK: 0.4.1
        ChangelogEntry(
            version: "0.4.1",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_1.episodePicker.title",
                    "changelog.0_4_1.episodePicker.body",
                    icon: "list.bullet.rectangle"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_1.resumeButton.title",
                    "changelog.0_4_1.resumeButton.body",
                    icon: "play.rectangle.on.rectangle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.detailLoading.title",
                    "changelog.0_4_1.detailLoading.body",
                    icon: "bolt.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.atmosLabel.title",
                    "changelog.0_4_1.atmosLabel.body",
                    icon: "speaker.wave.3.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.backgroundPause.title",
                    "changelog.0_4_1.backgroundPause.body",
                    icon: "pause.circle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.profileGrid.title",
                    "changelog.0_4_1.profileGrid.body",
                    icon: "person.2.circle.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_1.endOfContent.title",
                    "changelog.0_4_1.endOfContent.body",
                    icon: "checkmark.circle.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_1.polishFixes.title",
                    "changelog.0_4_1.polishFixes.body",
                    icon: "wrench.and.screwdriver.fill"
                ),
            ]
        ),
        // MARK: 0.4.0
        ChangelogEntry(
            version: "0.4.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_0.topshelf.title",
                    "changelog.0_4_0.topshelf.body",
                    icon: "rectangle.stack.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_0.siri.title",
                    "changelog.0_4_0.siri.body",
                    icon: "waveform"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_0.episodeImages.title",
                    "changelog.0_4_0.episodeImages.body",
                    icon: "photo.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_0.tintButtons.title",
                    "changelog.0_4_0.tintButtons.body",
                    icon: "paintpalette.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_0.cardHeights.title",
                    "changelog.0_4_0.cardHeights.body",
                    icon: "rectangle.grid.3x2.fill"
                ),
            ]
        ),
    ]

    /// Newest release, used by WhatsNewView and the version-tracking preference.
    static var latest: ChangelogEntry? {
        entries.first
    }
}
