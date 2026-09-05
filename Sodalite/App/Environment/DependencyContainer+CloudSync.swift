import Foundation

/// Bridge between the sync payloads and the app's real stores (keychain +
/// preference stores). Collect reads local state into a payload; apply writes a
/// payload back. Apply paths run with isApplyingCloudChanges set so the
/// mutation hooks in DependencyContainer do not echo the change back to CloudKit.
extension DependencyContainer {

    // MARK: Servers

    func collectServerPayload(serverID: String, stamp: Date) -> ServerSyncPayload? {
        guard let server = listKnownServers().first(where: { $0.id == serverID }) else { return nil }
        let users = listRememberedUsers(serverID: serverID)
        let sessions: [RememberedSeerrSession] = users.compactMap { user in
            guard let data = try? keychainService.loadData(
                for: KeychainKeys.rememberedSeerr(jellyfinServerID: serverID, jellyfinUserID: user.id)
            ) else { return nil }
            return try? JSONDecoder().decode(RememberedSeerrSession.self, from: data)
        }
        let homeRows = HomeRowsSyncState(
            configsJSON: HomeRowConfig.rawConfigData(serverID: serverID),
            mergeCWNextUp: HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID),
            rewatchNextUp: HomeRowConfig.enableRewatchingNextUp(serverID: serverID),
            collectionGrouping: HomeRowConfig.collectionGrouping(serverID: serverID).rawValue,
            librarySorts: {
                let sorts = LibrarySortStore.allSorts(serverID: serverID)
                return sorts.isEmpty ? nil : sorts
            }()
        )
        // One password per profile. The active user is included explicitly: they may have signed in
        // moments ago and not be in the remembered list yet.
        var passwordUserIDs = Set(users.map(\.id))
        let activeUserID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))
        if let activeUserID { passwordUserIDs.insert(activeUserID) }
        var passwords: [String: String] = [:]
        for userID in passwordUserIDs {
            if let password = try? keychainService.loadString(
                for: KeychainKeys.jellyfinPassword(serverID: serverID, userID: userID)
            ) {
                passwords[userID] = password
            }
        }
        // Legacy fields for devices that predate the per-user layout: give them the active
        // profile's password, which is the one their single slot used to hold anyway.
        let legacyUserID = activeUserID.flatMap { passwords[$0] != nil ? $0 : nil } ?? passwords.keys.sorted().first
        let forgotten = listForgottenUsers(serverID: serverID)
        return ServerSyncPayload(
            updatedAt: stamp,
            server: server,
            rememberedUsers: users,
            jellyfinPassword: legacyUserID.flatMap { passwords[$0] },
            passwordUserID: legacyUserID,
            jellyfinPasswords: passwords.isEmpty ? nil : passwords,
            seerrSessions: sessions,
            homeRows: homeRows,
            defaultUserID: authPreferences.defaultUserID(serverID: serverID),
            forgottenUsers: forgotten.isEmpty ? nil : forgotten,
            isDefaultServer: authPreferences.defaultServerID == serverID
        )
    }

    func applyServerPayload(_ payload: ServerSyncPayload) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        let serverID = payload.server.id
        // Where a server on this device came from. The tokens ride the profiles, the session slot does
        // not sync, and the difference is invisible until a switch fails on it (Sodalite#74/#76).
        sessionNote(
            "cloud record for \(payload.server.name) [\(serverID.prefix(8))]: "
            + "\(payload.rememberedUsers.count) profile(s), \(payload.seerrSessions.count) seerr session(s)."
        )

        // Upsert in place; a remote add appends so it never hijacks local MRU order.
        var servers = listKnownServers()
        if let idx = servers.firstIndex(where: { $0.id == serverID }) {
            servers[idx] = payload.server
        } else {
            servers.append(payload.server)
        }
        if let data = try? JSONEncoder().encode(servers) {
            try? keychainService.save(data, for: KeychainKeys.knownServers)
        }

        // A synced URL edit to the active server must reach the live client without a relaunch
        // (an Apple TV picks up edits made on the iPhone). scheduleRouteResolve only reads + probes,
        // so it is safe inside the apply path and does not echo a cloud write back.
        if payload.server.id == activeServer?.id {
            // The in-memory copy has to move with the keychain: a profile switch persists whatever
            // AppState holds through addServer, so leaving it on the pre-sync snapshot wrote the old
            // URL slots straight back out again (Sodalite#45). id-guarded inside AppState.
            appState?.updateActiveServer(payload.server)
            scheduleRouteResolve()
        }

        // Remembered profiles union across devices (Sodalite#45). A payload is a statement about the
        // sender, and a sender whose list is merely behind used to prune profiles, tokens included,
        // on every device. A removal travels as `forgottenUserIDs` instead, and the local tombstones
        // hold too: the other device may not have heard yet and its payload still lists the profile.
        let localForgotten = listForgottenUsers(serverID: serverID)
        let resolved = CloudSyncMerge.resolveRememberedUsers(
            local: listRememberedUsers(serverID: serverID),
            cloud: payload.rememberedUsers,
            localForgotten: localForgotten,
            cloudForgotten: payload.forgottenUsers ?? [:]
        )
        let forgotten = resolved.forgotten
        if resolved.users.isEmpty {
            try? keychainService.delete(for: KeychainKeys.rememberedUsers(serverID: serverID))
        } else if let data = try? JSONEncoder().encode(resolved.users) {
            try? keychainService.save(data, for: KeychainKeys.rememberedUsers(serverID: serverID))
        }
        setForgottenUsers(forgotten, serverID: serverID)

        // Additive on purpose: a password is device-local knowledge (a device signed in with Quick
        // Connect or the picker never has one), so "the payload carries none" means "the sender does
        // not know it", not "there is none". Deleting on that reading let one passwordless device
        // strip the password from every other one. Only a local logout or forgetUser removes them.
        var incomingPasswords = payload.jellyfinPasswords ?? [:]
        if let password = payload.jellyfinPassword, let owner = payload.passwordUserID {
            incomingPasswords[owner] = password
        }
        for (userID, password) in incomingPasswords where forgotten[userID] == nil {
            try? keychainService.save(
                password,
                for: KeychainKeys.jellyfinPassword(serverID: serverID, userID: userID)
            )
        }

        // Seerr sessions are additive too, on the same reading: a device where nobody ever signed
        // into Jellyseerr collects no session at all, so "the payload carries none" means the sender
        // does not know one. Sweeping on that reading let one Seerr-less device sign every other
        // device out of Jellyseerr. A real sign-out still reaches other devices, through the 401 on
        // their next restore, which already drops the entry there.
        for session in payload.seerrSessions where forgotten[session.jellyfinUserID] == nil {
            if let data = try? JSONEncoder().encode(session) {
                try? keychainService.save(data, for: KeychainKeys.rememberedSeerr(
                    jellyfinServerID: serverID, jellyfinUserID: session.jellyfinUserID))
            }
        }

        // A removal learned here takes the profile's credentials with it, the same teardown a local
        // forget does, else a forgotten profile keeps its password and Seerr cookie on every other
        // device. Only for removals that are news: re-running it is harmless but pointless.
        for userID in forgotten.keys where localForgotten[userID] == nil {
            purgeUserCredentials(id: userID, serverID: serverID)
        }

        if let homeRows = payload.homeRows {
            if let configs = homeRows.configsJSON {
                HomeRowConfig.setRawConfigData(configs, serverID: serverID)
            }
            HomeRowConfig.setMergeContinueWatchingNextUp(homeRows.mergeCWNextUp, serverID: serverID)
            HomeRowConfig.setEnableRewatchingNextUp(homeRows.rewatchNextUp, serverID: serverID)
            // Absent on payloads from builds before Sodalite#44; leave the local mode alone rather than resetting it to the server default.
            if let grouping = homeRows.collectionGrouping {
                HomeRowConfig.setCollectionGrouping(CollectionGrouping(storedValue: grouping), serverID: serverID)
            }
            // Absent on payloads from builds before Sodalite#78, and per scope: a tile this payload
            // says nothing about keeps whatever this device chose for it.
            if let sorts = homeRows.librarySorts {
                LibrarySortStore.applySorts(sorts, serverID: serverID)
            }
            NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
        }

        // Absent on payloads from builds that still kept the pin in the global auth store; leave the local pin alone rather than clearing it.
        if let defaultUserID = payload.defaultUserID {
            authPreferences.setDefaultUserID(defaultUserID, serverID: serverID)
        }

        // The default-server pin, likewise absent on older payloads. Only a device that knows this
        // server can speak about it, which is the whole point of it living here (Sodalite#45).
        if let isDefaultServer = payload.isDefaultServer {
            if isDefaultServer {
                authPreferences.defaultServerID = serverID
            } else if authPreferences.defaultServerID == serverID {
                authPreferences.defaultServerID = nil
            }
        }
    }

    /// Remote record delete: same teardown as a local removeServer (successor
    /// promotion included), but suppressed so it does not echo back to CloudKit.
    func applyRemoteServerDeletion(serverID: String) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        try? removeServer(id: serverID)
    }

    // MARK: Settings stores

    func collectSettingsPayload(_ key: CloudSyncStoreKey, stamp: Date) -> SettingsSyncPayload {
        collectSettingsPayload(key, stamp: stamp, from: SettingsStores(container: self))
    }

    /// Same mapping, read out of a given set of stores. A reset passes stores built against an empty
    /// suite, so "what a first launch holds" comes from the one mapping the parity test already pins
    /// every setting to, instead of a second list that would drift from it (Sodalite#76).
    func collectSettingsPayload(
        _ key: CloudSyncStoreKey,
        stamp: Date,
        from stores: SettingsStores
    ) -> SettingsSyncPayload {
        switch key {
        case .playback:
            let p = stores.playback
            return .playback(PlaybackSettingsPayload(
                updatedAt: stamp,
                autoplayNextEpisode: p.autoplayNextEpisode,
                autoSkipIntro: p.autoSkipIntro,
                autoSkipOutro: p.autoSkipOutro,
                nextEpisodeCountdownSeconds: p.nextEpisodeCountdownSeconds,
                skipIntervalSeconds: p.skipIntervalSeconds,
                preferredAudioLanguage: p.preferredAudioLanguage,
                preferredSubtitleLanguage: p.preferredSubtitleLanguage,
                autoSubtitleForForeignAudio: p.autoSubtitleForForeignAudio,
                styledASSSubtitles: p.styledASSSubtitles,
                subtitleFontSize: p.subtitleFontSize.rawValue,
                subtitleColor: p.subtitleColor.rawValue,
                subtitleBackground: p.subtitleBackground.rawValue,
                subtitleDelaySeconds: p.subtitleDelaySeconds,
                subtitleVerticalPosition: p.subtitleVerticalPosition.rawValue,
                subtitleFont: p.subtitleFont.rawValue,
                subtitleWeight: p.subtitleWeight.rawValue,
                pictureMode: p.pictureMode.rawValue,
                showStatsForNerds: p.showStatsForNerds,
                showEngineDiagnostics: p.showEngineDiagnostics,
                preferLosslessAudioBridge: p.preferLosslessAudioBridge,
                showScrubPreview: p.showScrubPreview,
                preferServerTrickplay: p.preferServerTrickplay,
                playerRotationLocked: p.playerRotationLocked,
                networkBufferDepth: p.networkBufferDepth.rawValue,
                rememberTrackSelections: p.rememberTrackSelections,
                autoForcedSubtitles: p.autoForcedSubtitles,
                autoSkipRecap: p.autoSkipRecap,
                subtitlesOnSkipBack: p.subtitlesOnSkipBack,
                liveTeletextPage: p.liveTeletextPage.rawValue,
                autoplayCountdown: p.autoplayCountdown,
                forceDolbyVisionOnNonDVDisplay: p.forceDolbyVisionOnNonDVDisplay,
                touchpadScrubbing: p.touchpadScrubbing
            ))
        case .appearance:
            let a = stores.appearance
            return .appearance(AppearanceSettingsPayload(
                updatedAt: stamp,
                accentChoice: a.storedAccentRawValue,
                backgroundStyle: a.storedBackgroundRawValue,
                showContentLogos: a.showContentLogos,
                continueWatchingImage: a.continueWatchingImage.rawValue,
                largeCards: a.largeCards,
                nowPlayingUsesSeriesPoster: a.nowPlayingUsesSeriesPoster,
                spoilerProtectionEnabled: a.spoilerProtectionEnabled,
                spoilerHideEpisodes: a.spoilerHideEpisodes,
                spoilerHideMovies: a.spoilerHideMovies,
                showPosterBadges: a.showPosterBadges,
                showTopShelfRow: a.showTopShelfRow,
                showLibraryNames: a.showLibraryNames,
                hiddenTabs: a.hiddenTabs.map(\.rawValue).sorted()
            ))
        case .auth:
            return .auth(AuthSettingsPayload(
                updatedAt: stamp,
                launchBehavior: stores.auth.launchBehavior.rawValue,
                // Legacy mirror for devices still on a build without the per-server pin: the default server's is the one they would have used.
                defaultUserID: stores.auth.defaultServerID
                    .flatMap { stores.auth.defaultUserID(serverID: $0) },
                defaultServerID: stores.auth.defaultServerID,
                profileReprompt: stores.auth.profileReprompt.rawValue
            ))
        case .seerrNotifications:
            return .seerrNotifications(SeerrNotificationSettingsPayload(
                updatedAt: stamp,
                notifyPendingRequests: stores.seerrNotifications.notifyPendingRequests
            ))
        case .parentalControls:
            return .parentalControls(ParentalControlsSettingsPayload(
                updatedAt: stamp,
                protectedProfileIDs: stores.parentalControls.protectedProfileIDs.sorted(),
                entryLockedProfileIDs: stores.parentalControls.entryLockedProfileIDs.sorted()
            ))
        case .trackMemory:
            return .trackMemory(TrackMemoryPayload(
                updatedAt: stamp,
                entries: stores.trackMemory.entries
            ))
        case .spoilerReveals:
            return .spoilerReveals(SpoilerRevealPayload(
                updatedAt: stamp,
                entries: stores.spoilerReveals.entries
            ))
        case .spoilerSeriesRules:
            return .spoilerSeriesRules(SpoilerSeriesRulesPayload(
                updatedAt: stamp,
                entries: stores.spoilerSeriesRules.entries
            ))
        }
    }

    func applySettingsPayload(_ payload: SettingsSyncPayload) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        switch payload {
        case .playback(let p):
            let store = playbackPreferences
            store.autoplayNextEpisode = p.autoplayNextEpisode
            store.autoSkipIntro = p.autoSkipIntro
            store.autoSkipOutro = p.autoSkipOutro
            store.nextEpisodeCountdownSeconds = p.nextEpisodeCountdownSeconds
            store.skipIntervalSeconds = p.skipIntervalSeconds
            store.preferredAudioLanguage = p.preferredAudioLanguage
            store.preferredSubtitleLanguage = p.preferredSubtitleLanguage
            store.autoSubtitleForForeignAudio = p.autoSubtitleForForeignAudio
            store.styledASSSubtitles = p.styledASSSubtitles
            store.subtitleFontSize = PlaybackPreferences.SubtitleFontSize(rawValue: p.subtitleFontSize) ?? store.subtitleFontSize
            store.subtitleColor = PlaybackPreferences.SubtitleColor(rawValue: p.subtitleColor) ?? store.subtitleColor
            store.subtitleBackground = PlaybackPreferences.SubtitleBackground(rawValue: p.subtitleBackground) ?? store.subtitleBackground
            store.subtitleDelaySeconds = p.subtitleDelaySeconds
            store.subtitleVerticalPosition = PlaybackPreferences.SubtitleVerticalPosition(rawValue: p.subtitleVerticalPosition) ?? store.subtitleVerticalPosition
            store.subtitleFont = PlaybackPreferences.SubtitleFont(rawValue: p.subtitleFont) ?? store.subtitleFont
            store.subtitleWeight = PlaybackPreferences.SubtitleWeight(rawValue: p.subtitleWeight) ?? store.subtitleWeight
            store.pictureMode = PlaybackPreferences.PictureMode(rawValue: p.pictureMode) ?? store.pictureMode
            store.showStatsForNerds = p.showStatsForNerds
            store.showEngineDiagnostics = p.showEngineDiagnostics
            store.preferLosslessAudioBridge = p.preferLosslessAudioBridge
            store.showScrubPreview = p.showScrubPreview
            store.preferServerTrickplay = p.preferServerTrickplay
            // Absent on payloads from builds before these fields existed; leave the local
            // value alone rather than resetting it to a default.
            if let rotationLocked = p.playerRotationLocked { store.playerRotationLocked = rotationLocked }
            if let depth = p.networkBufferDepth {
                store.networkBufferDepth = PlaybackPreferences.NetworkBufferDepth(rawValue: depth) ?? store.networkBufferDepth
            }
            if let remember = p.rememberTrackSelections { store.rememberTrackSelections = remember }
            if let forced = p.autoForcedSubtitles { store.autoForcedSubtitles = forced }
            if let autoSkipRecap = p.autoSkipRecap { store.autoSkipRecap = autoSkipRecap }
            if let skipBackSubs = p.subtitlesOnSkipBack { store.subtitlesOnSkipBack = skipBackSubs }
            if let teletextPage = p.liveTeletextPage {
                store.liveTeletextPage = PlaybackPreferences.LiveTeletextPage(rawValue: teletextPage) ?? store.liveTeletextPage
            }
            if let countdown = p.autoplayCountdown { store.autoplayCountdown = countdown }
            if let forceDV = p.forceDolbyVisionOnNonDVDisplay { store.forceDolbyVisionOnNonDVDisplay = forceDV }
            if let touchpadScrub = p.touchpadScrubbing { store.touchpadScrubbing = touchpadScrub }
        case .appearance(let a):
            let store = appearancePreferences
            if let accentChoice = AppearancePreferences.AccentChoice(rawValue: a.accentChoice) {
                store.accentChoice = accentChoice
            }
            if let backgroundStyle = BackgroundStyle(rawValue: a.backgroundStyle) {
                store.backgroundStyle = backgroundStyle
            }
            store.showContentLogos = a.showContentLogos
            store.continueWatchingImage = AppearancePreferences.ContinueWatchingImage(rawValue: a.continueWatchingImage) ?? store.continueWatchingImage
            store.largeCards = a.largeCards
            store.nowPlayingUsesSeriesPoster = a.nowPlayingUsesSeriesPoster
            store.spoilerProtectionEnabled = a.spoilerProtectionEnabled
            store.spoilerHideEpisodes = a.spoilerHideEpisodes
            store.spoilerHideMovies = a.spoilerHideMovies
            store.showPosterBadges = a.showPosterBadges
            store.showTopShelfRow = a.showTopShelfRow
            store.showLibraryNames = a.showLibraryNames
            // Absent field = sender predates tab visibility, so it carries no opinion; applying an empty set would silently unhide the receiver's tabs (Sodalite#62).
            if let tabs = a.hiddenTabs {
                store.hiddenTabs = Set(tabs.compactMap(AppTab.init(rawValue:)).filter(\.isHideable))
            }
        case .auth(let a):
            authPreferences.launchBehavior = AuthPreferences.LaunchBehavior(rawValue: a.launchBehavior) ?? authPreferences.launchBehavior
            // a.defaultUserID and a.defaultServerID are both retired here, still written for older
            // builds and deliberately not applied. The first carries no server, so it would pin the
            // wrong server's profile; the second cannot tell "never pinned" from "cleared", so a
            // device that had never pinned anything cleared every other device's pin (Sodalite#45).
            // Both ride the server record now.
            // Absent on payloads from builds before the reprompt interval existed; keep-current, else those builds would read as "off".
            if let reprompt = a.profileReprompt {
                authPreferences.profileReprompt = AuthPreferences.ProfileRepromptInterval(rawValue: reprompt) ?? authPreferences.profileReprompt
            }
        case .seerrNotifications(let s):
            seerrNotificationPreferences.notifyPendingRequests = s.notifyPendingRequests
        case .parentalControls(let p):
            parentalControlsPreferences.protectedProfileIDs = Set(p.protectedProfileIDs)
            parentalControlsPreferences.entryLockedProfileIDs = Set(p.entryLockedProfileIDs)
        case .trackMemory(let t):
            trackSelectionMemory.replaceAll(t.entries)
        case .spoilerReveals(let s):
            spoilerRevealMemory.replaceAll(s.entries)
        case .spoilerSeriesRules(let r):
            spoilerSeriesRules.replaceAll(r.entries)
        }
    }

    // MARK: Security (Guardian PIN)

    func collectSecurityPayload(stamp: Date) -> SecuritySyncPayload? {
        guard let data = try? keychainService.loadData(for: KeychainKeys.guardianPINBlob),
              let blob = try? JSONDecoder().decode(GuardianPINCrypto.Blob.self, from: data)
        else { return nil }
        return SecuritySyncPayload(updatedAt: stamp, pinBlob: blob)
    }

    func applySecurityPayload(_ payload: SecuritySyncPayload) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        // Write the blob directly (saveGuardianPIN would re-derive from a plain
        // PIN we do not have). The local throttle is deliberately untouched.
        if let data = try? JSONEncoder().encode(payload.pinBlob) {
            try? keychainService.save(data, for: KeychainKeys.guardianPINBlob)
        }
    }

    func applyRemoteSecurityDeletion() {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        try? clearGuardianPIN()
    }
}

/// The stores one settings payload is collected from: the container's own, or a set built against an
/// empty suite when something needs to know what a first launch would hold (Sodalite#76).
@MainActor
struct SettingsStores {
    let playback: PlaybackPreferences
    let appearance: AppearancePreferences
    let auth: AuthPreferences
    let seerrNotifications: SeerrNotificationPreferences
    let parentalControls: ParentalControlsPreferences
    let trackMemory: TrackSelectionMemory
    let spoilerReveals: SpoilerRevealMemory
    let spoilerSeriesRules: SpoilerSeriesRules

    init(container: DependencyContainer) {
        playback = container.playbackPreferences
        appearance = container.appearancePreferences
        auth = container.authPreferences
        seerrNotifications = container.seerrNotificationPreferences
        parentalControls = container.parentalControlsPreferences
        trackMemory = container.trackSelectionMemory
        spoilerReveals = container.spoilerRevealMemory
        spoilerSeriesRules = container.spoilerSeriesRules
    }

    private init(store: UserDefaults) {
        playback = PlaybackPreferences(store: store)
        appearance = AppearancePreferences(store: store)
        auth = AuthPreferences(store: store)
        seerrNotifications = SeerrNotificationPreferences(defaults: store)
        parentalControls = ParentalControlsPreferences(store: store)
        trackMemory = TrackSelectionMemory(store: store)
        spoilerReveals = SpoilerRevealMemory(store: store)
        spoilerSeriesRules = SpoilerSeriesRules(store: store)
    }

    /// Every store parsed from an empty suite, which is what each of them does on a first launch. The
    /// domain is cleared on the way in as well as being throwaway: a previous reset may have left the
    /// migrations these inits run behind in it.
    static func factoryDefaults() -> SettingsStores? {
        let name = "de.superuser404.Sodalite.factoryDefaults"
        guard let scratch = UserDefaults(suiteName: name) else { return nil }
        scratch.removePersistentDomain(forName: name)
        return SettingsStores(store: scratch)
    }
}
