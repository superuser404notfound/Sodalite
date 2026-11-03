import Foundation

/// Pure merge rules for cloud sync. No CloudKit types so everything unit-tests.
enum CloudSyncMerge {

    /// Stamps are issued monotonically: never at-or-below the highest stamp seen
    /// from any device, so clock skew between devices cannot let an older change
    /// outrank a newer one.
    static func monotonicStamp(now: Date, highestSeen: Date?) -> Date {
        guard let highestSeen, now <= highestSeen else { return now }
        return highestSeen.addingTimeInterval(0.001)
    }

    /// Last-writer-wins: remote replaces local only when strictly newer; ties stay put.
    static func remoteWins(localUpdatedAt: Date, remoteUpdatedAt: Date) -> Bool {
        remoteUpdatedAt > localUpdatedAt
    }

    /// First-adoption merge for a server present on BOTH sides. Local stamps are
    /// fabricated at adoption, so cloud wins for server info, password, and home
    /// rows; remembered users and Seerr sessions union (addedAt is real history).
    static func adoptServerPayload(local: ServerSyncPayload, cloud: ServerSyncPayload, stamp: Date) -> ServerSyncPayload {
        var merged = cloud
        merged.updatedAt = stamp
        let resolved = resolveRememberedUsers(
            local: local.rememberedUsers,
            cloud: cloud.rememberedUsers,
            localForgotten: local.forgottenUsers ?? [:],
            cloudForgotten: cloud.forgottenUsers ?? [:]
        )
        merged.rememberedUsers = resolved.users
        merged.forgottenUsers = resolved.forgotten.isEmpty ? nil : resolved.forgotten
        merged.seerrSessions = unionSeerrSessions(local: local.seerrSessions, cloud: cloud.seerrSessions)
        if merged.isDefaultServer == nil { merged.isDefaultServer = local.isDefaultServer }
        // Both stamps fill from local when the cloud copy predates them, on the same reading as the
        // fields above: a record written by a build that did not know the field says nothing about
        // it, and dropping what this device knows would republish the server with no history at all.
        if merged.addedAt == nil { merged.addedAt = local.addedAt }
        if merged.urlsUpdatedAt == nil { merged.urlsUpdatedAt = local.urlsUpdatedAt }
        if merged.homeRows == nil { merged.homeRows = local.homeRows }
        if merged.defaultUserID == nil { merged.defaultUserID = local.defaultUserID }
        if merged.jellyfinPassword == nil {
            merged.jellyfinPassword = local.jellyfinPassword
            merged.passwordUserID = local.passwordUserID
        }
        // Union per profile, local wins: a password this device knows is first-hand knowledge, and
        // the cloud copy can only be the same secret or a stale one.
        if local.jellyfinPasswords?.isEmpty == false || merged.jellyfinPasswords?.isEmpty == false {
            var passwords = merged.jellyfinPasswords ?? [:]
            for (userID, password) in local.jellyfinPasswords ?? [:] {
                passwords[userID] = password
            }
            merged.jellyfinPasswords = passwords.isEmpty ? nil : passwords
        }
        return merged
    }

    /// Sodalite#45. The remembered list unions, so a removal has to travel as a removal: a device
    /// whose list is merely behind would otherwise publish it as an authoritative prune. A removal
    /// holds the profile out until a sign-in NEWER than the removal arrives, which is the only thing
    /// that distinguishes a deliberate re-add from a device that has not heard about the removal yet.
    /// Without that date the removal and the re-add would fight forever: each side would keep handing
    /// the other back what it just dropped.
    static func resolveRememberedUsers(
        local: [RememberedUser],
        cloud: [RememberedUser],
        localForgotten: [String: Date],
        cloudForgotten: [String: Date]
    ) -> (users: [RememberedUser], forgotten: [String: Date]) {
        var forgotten = localForgotten
        for (id, removedAt) in cloudForgotten {
            forgotten[id] = max(forgotten[id] ?? removedAt, removedAt)
        }
        var users: [RememberedUser] = []
        for user in unionRememberedUsers(local: local, cloud: cloud) {
            guard let removedAt = forgotten[user.id] else {
                users.append(user)
                continue
            }
            guard user.addedAt > removedAt else { continue }
            forgotten.removeValue(forKey: user.id)
            users.append(user)
        }
        return (users, forgotten)
    }

    /// The server-level mirror of `resolveRememberedUsers`, and needed for the same reason: a
    /// server record is republished in full by any device that touches it, so a removal expressed
    /// as "my list is shorter" is indistinguishable from a device that has not heard yet, and the
    /// two would hand the server back and forth forever. The removal travels as a date instead, and
    /// only an `addedAt` newer than it (somebody deliberately signing in again) takes it back.
    static func unionForgottenServers(local: [String: Date], cloud: [String: Date]) -> [String: Date] {
        var forgotten = local
        for (id, removedAt) in cloud {
            forgotten[id] = max(forgotten[id] ?? removedAt, removedAt)
        }
        return forgotten
    }

    /// Whether a tombstone still holds a server out. A server with no known `addedAt` predates the
    /// stamp (or arrived from a device that does not write one), and a removal outranks it: the
    /// removal is the more recent statement of intent either way.
    static func removalHolds(removedAt: Date?, addedAt: Date?) -> Bool {
        guard let removedAt else { return false }
        guard let addedAt else { return true }
        return addedAt <= removedAt
    }

    /// Which side's URL slots to keep. `urlsUpdatedAt` moves only on a real edit, so a device
    /// republishing slots it never touched carries the older stamp and loses, whatever its
    /// record-level stamp says. Ties keep the local side, matching `remoteWins`.
    ///
    /// A nil local stamp means this device never edited the slots and has nothing to defend, so the
    /// incoming copy wins. A nil remote stamp means the sender is on a build that predates the
    /// field: it cannot claim an edit, so a device holding a real edit keeps it.
    static func remoteURLsWin(localUpdatedAt: Date?, remoteUpdatedAt: Date?) -> Bool {
        guard let localUpdatedAt else { return true }
        guard let remoteUpdatedAt else { return false }
        return remoteUpdatedAt > localUpdatedAt
    }

    /// Union by user id; the newer addedAt wins per user, and on a tie the local copy stays. A name or
    /// image refresh keeps `addedAt`, so a tie is exactly the case where this device read the profile
    /// from the server itself: letting the cloud win it handed a stale peer's old name back until the
    /// next refresh. Sorted newest-first to match listRememberedUsers ordering.
    static func unionRememberedUsers(local: [RememberedUser], cloud: [RememberedUser]) -> [RememberedUser] {
        var byID: [String: RememberedUser] = [:]
        for user in local { byID[user.id] = user }
        for user in cloud {
            if let existing = byID[user.id], existing.addedAt >= user.addedAt { continue }
            byID[user.id] = user
        }
        return byID.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// Union by jellyfin user id; cloud wins collisions. Sorted for determinism.
    static func unionSeerrSessions(local: [RememberedSeerrSession], cloud: [RememberedSeerrSession]) -> [RememberedSeerrSession] {
        var byID: [String: RememberedSeerrSession] = [:]
        for session in local { byID[session.jellyfinUserID] = session }
        for session in cloud { byID[session.jellyfinUserID] = session }
        return byID.values.sorted { $0.jellyfinUserID < $1.jellyfinUserID }
    }

    /// Sodalite#46. Union by scope key, newest entry per key wins. Eviction deliberately
    /// does not propagate: an evicted entry coming back from the cloud is less harmful
    /// than a lost selection. The cap is re-applied so both devices converge on one set.
    static func unionTrackMemory(local: TrackMemoryPayload, cloud: TrackMemoryPayload) -> TrackMemoryPayload {
        var byKey = local.entries
        for (key, entry) in cloud.entries {
            if let existing = byKey[key], existing.updatedAt >= entry.updatedAt { continue }
            byKey[key] = entry
        }
        return TrackMemoryPayload(
            updatedAt: max(local.updatedAt, cloud.updatedAt),
            entries: TrackSelectionMemory.capped(byKey)
        )
    }

    /// Sodalite#50. Union by reveal key, later reveal wins. Same shape as unionTrackMemory:
    /// eviction deliberately does not propagate, and the cap is re-applied so both devices
    /// converge on one set.
    /// Sodalite#222: the hides union the same way, so a hide and a reveal on two devices both
    /// survive and the newer one decides.
    static func unionSpoilerReveals(local: SpoilerRevealPayload, cloud: SpoilerRevealPayload) -> SpoilerRevealPayload {
        let entries = SpoilerRevealMemory.capped(newestPerKey(local.entries, cloud.entries))
        let hidden = newestPerKey(local.hiddenAt ?? [:], cloud.hiddenAt ?? [:])
        return SpoilerRevealPayload(
            updatedAt: max(local.updatedAt, cloud.updatedAt),
            entries: entries,
            hiddenAt: SpoilerRevealMemory.prunedHides(hidden, entries: entries)
        )
    }

    private static func newestPerKey(_ local: [String: Date], _ cloud: [String: Date]) -> [String: Date] {
        var byKey = local
        for (key, date) in cloud {
            if let existing = byKey[key], existing >= date { continue }
            byKey[key] = date
        }
        return byKey
    }

    /// Sodalite#50 follow-up. Per key, newest entry wins, `standard` included: the tombstone has to
    /// be able to beat an older rule, which is why it travels as a stored state rather than a
    /// missing key. Ties keep the local side, matching `remoteWins`. The cap is re-applied so both
    /// devices converge on one set.
    static func mergeSpoilerSeriesRules(
        local: SpoilerSeriesRulesPayload,
        cloud: SpoilerSeriesRulesPayload
    ) -> SpoilerSeriesRulesPayload {
        var byKey = local.entries
        for (key, entry) in cloud.entries {
            if let existing = byKey[key], existing.updatedAt >= entry.updatedAt { continue }
            byKey[key] = entry
        }
        return SpoilerSeriesRulesPayload(
            updatedAt: max(local.updatedAt, cloud.updatedAt),
            entries: SpoilerSeriesRules.capped(byKey)
        )
    }
}
