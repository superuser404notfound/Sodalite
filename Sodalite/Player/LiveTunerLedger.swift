import Foundation

/// One live stream Sodalite asked Jellyfin to open, written where the death of the process cannot
/// take it (#147).
///
/// Every server-side release the app has hangs off a teardown that only runs while the app is alive:
/// a stop, a failed load, a retune. A session that ends because the DEVICE went away, an Apple TV
/// that sleeps and is killed while suspended, runs none of them, and `activeLiveStreamID` is an
/// in-memory field that dies with the process. Jellyfin never reaps an open live stream, so the
/// tuner and its growing `.ts` stay until the server restarts. The handle has to outlive the app for
/// the next launch to be able to say anything at all.
struct OpenLiveStreamRecord: Codable, Equatable, Sendable {
    /// The Jellyfin user the stream was opened for. A user id belongs to exactly one server, so it
    /// names the server too: a record whose user is not the one signed in now belongs to a session
    /// this launch cannot speak for, and the sweep leaves it alone rather than firing its handle at
    /// whichever server happens to be active.
    let userID: String
    /// The channel. The sweep reads it to ask who is on the air before closing an id that names the
    /// channel rather than this stream (#70).
    let itemID: String
    let liveStreamID: String
    let mediaSourceID: String?
    let playSessionID: String?
    let openedAt: Date
}

/// Whether a leftover may be closed by name.
enum LiveStreamSweep {
    /// `LiveStreamId` names the CHANNEL, not the stream (`idPrefix + MediaSource.Id`, and a tuner
    /// host derives that from the profile, the channel and the tuner URL, so it is the same string
    /// for every tune of that channel). A close aimed at a stale one therefore lands on whatever is
    /// registered for that channel NOW, which can be another client's stream (#70).
    ///
    /// So the sweep asks the server who is on the air first and stands down when the channel belongs
    /// to somebody else. A device with no id counts as somebody else: the point of the question is to
    /// be sure, and a leftover tuner survives one more launch at no cost while a wrong close ends a
    /// stranger's programme.
    static func mayClose(
        _ record: OpenLiveStreamRecord,
        sessions: [JellyfinSessionInfo],
        ourDeviceID: String
    ) -> Bool {
        !sessions.contains { session in
            session.nowPlayingItemID == record.itemID && session.deviceID != ourDeviceID
        }
    }
}

/// The durable half of the tuner bookkeeping: `LiveTunerGate` orders our opens against our closes
/// inside one process, this one carries a handle across processes (#147).
@MainActor
final class LiveTunerLedger {
    static let shared = LiveTunerLedger()

    static let storageKey = "sodalite.openLiveStreams"
    /// A session holds one tuner at a time, so this is only ever more than a couple of entries when
    /// closes have been failing for a while. Bounded so a server that answers nothing cannot grow the
    /// list without end; the oldest go first, because the newest leftover is the one the tuner is
    /// most likely still ingesting for.
    static let capacity = 8

    private let defaults: UserDefaults
    /// Handles this process opened and has not closed yet. The sweep must not touch them: the record
    /// of the channel playing right now is the same shape as the record of one a kill left behind,
    /// and closing the first would take the picture off the screen.
    private var liveInThisProcess: Set<String> = []
    private var isSweeping = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func remember(_ record: OpenLiveStreamRecord) {
        liveInThisProcess.insert(record.liveStreamID)
        var kept = stored().filter { $0.liveStreamID != record.liveStreamID }
        kept.append(record)
        write(Array(kept.suffix(Self.capacity)))
    }

    /// Take a handle out of the ledger on the way to closing it, and hand back what was there.
    ///
    /// Taken BEFORE the request rather than after its answer, because the id names the CHANNEL: a
    /// re-negotiation closes one handle and opens the next under the same string, and a forget that
    /// waited for the first close to be answered would drop the record the second open had already
    /// written. A close that never reached the server puts its record back (`restore`), which is the
    /// only case where the ledger should still be carrying it.
    @discardableResult
    func take(liveStreamID: String) -> OpenLiveStreamRecord? {
        liveInThisProcess.remove(liveStreamID)
        let all = stored()
        write(all.filter { $0.liveStreamID != liveStreamID })
        return all.first { $0.liveStreamID == liveStreamID }
    }

    /// Put back a handle whose close never arrived. Not marked as live in this process: nothing is
    /// playing it, and the next launch should find it.
    func restore(_ record: OpenLiveStreamRecord) {
        guard !liveInThisProcess.contains(record.liveStreamID) else { return }
        var kept = stored().filter { $0.liveStreamID != record.liveStreamID }
        kept.append(record)
        write(Array(kept.suffix(Self.capacity)))
    }

    /// Drop a handle the sweep has dealt with.
    func forget(liveStreamID: String) {
        take(liveStreamID: liveStreamID)
    }

    /// What an earlier run left open for this user, newest first.
    func orphans(userID: String) -> [OpenLiveStreamRecord] {
        stored()
            .filter { $0.userID == userID && !liveInThisProcess.contains($0.liveStreamID) }
            .sorted { $0.openedAt > $1.openedAt }
    }

    /// One sweep per signed-in server. A record carries the user id of the server it was opened on, so
    /// a channel played from a secondary Combine server is closed through that server's own session
    /// (audit PHOST-208).
    func sweep(targets: [(userID: String, service: JellyfinPlaybackServiceProtocol)]) async {
        for target in targets {
            await sweep(userID: target.userID, using: target.service)
        }
    }

    /// Close what an earlier run left open, then forget it.
    ///
    /// Runs on a session that has just been restored, so the requests carry the same identity the
    /// leak was made under. Each close goes through `LiveTunerGate`, so a tune of the same channel
    /// started a moment later waits for it rather than racing it (#70).
    func sweep(userID: String, using service: JellyfinPlaybackServiceProtocol) async {
        guard !isSweeping else { return }
        let leftovers = orphans(userID: userID)
        guard !leftovers.isEmpty else { return }
        isSweeping = true
        defer { isSweeping = false }

        // Who is on the air, so a channel-scoped id is not fired blind. A server that will not answer
        // this is not a reason to leave a tuner running: the ranking is deliberate, a leak we can see
        // costs every client on that tuner host until the server restarts, and the hazard it trades
        // against needs a stranger to be on that exact channel at this exact moment.
        var sessions: [JellyfinSessionInfo] = []
        do {
            sessions = try await service.getSessions()
        } catch {
            LogTap.shared.note(
                "[Live] #147 sweep: the server would not say who is playing (\(error)), "
                + "closing on our own record")
        }

        for record in leftovers {
            let token = PlayerViewModel.liveLogToken(record.liveStreamID)
            let age = Int(Date().timeIntervalSince(record.openedAt) / 60)
            // Addressed to (this device, that play session), so it can reach nothing but our own
            // orphan. Sent whichever way the close below goes.
            if let playSession = record.playSessionID {
                try? await service.stopActiveEncodings(playSessionID: playSession)
            }
            guard LiveStreamSweep.mayClose(record, sessions: sessions, ourDeviceID: service.deviceID)
            else {
                LogTap.shared.note(
                    "[Live] #147 sweep: another client is watching that channel, leaving key=\(token) "
                    + "open (opened \(age)m ago)")
                continue
            }
            let stop = PlaybackStopReport(
                itemId: record.itemID,
                // Jellyfin's own shape for a plain item, and what a live answer gives back for a
                // channel: the source id falls back to the item it belongs to.
                mediaSourceId: record.mediaSourceID ?? record.itemID,
                playSessionId: record.playSessionID,
                positionTicks: 0,
                liveStreamId: record.liveStreamID
            )
            await LiveTunerGate.shared.close {
                // The stop report closes the stream server-side too, and it is also what clears the
                // session Jellyfin still lists as playing. The explicit close follows it because a
                // second close on the same id is a no-op, and a stop report that never arrives is not.
                try? await service.reportPlaybackStopped(stop)
                try? await service.closeLiveStream(liveStreamID: record.liveStreamID)
            }.value
            LogTap.shared.note(
                "[Live] #147 sweep: closed a tuner an earlier run left open, key=\(token) "
                + "(opened \(age)m ago)")
            forget(liveStreamID: record.liveStreamID)
        }
    }

    // MARK: - Storage

    private func stored() -> [OpenLiveStreamRecord] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let records = try? JSONDecoder().decode([OpenLiveStreamRecord].self, from: data)
        else { return [] }
        return records
    }

    private func write(_ records: [OpenLiveStreamRecord]) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
