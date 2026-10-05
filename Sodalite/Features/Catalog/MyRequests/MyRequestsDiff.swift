import Foundation

/// Turns two looks at the user's own requests into the changes worth telling them about.
enum MyRequestsDiff {
    static func apply(
        snapshot: MyRequestsSnapshot?,
        observations: [MyRequestObservation],
        selfID: Int,
        now: Date
    ) -> (events: [MyRequestEvent], snapshot: MyRequestsSnapshot) {
        let own = observations.filter { $0.requesterID == selfID }
        var next = MyRequestsSnapshot(baselineDate: snapshot?.baselineDate ?? now, entries: [:])
        for observation in own {
            next.entries[observation.requestID] = entry(for: observation)
        }
        guard let snapshot else { return ([], next) }

        var events: [MyRequestEvent] = []
        for observation in own {
            let prior: MyRequestsSnapshot.Entry
            if let known = snapshot.entries[observation.requestID] {
                prior = known
            } else if let created = observation.createdAt, created > snapshot.baselineDate {
                // Made after we started watching (another device, or while this one slept): it was pending once.
                prior = .init(requestStatus: SeerrRequestStatus.pendingApproval.rawValue, mediaStatus: nil, availableSeasons: [])
            } else {
                continue
            }
            if let event = event(for: observation, prior: prior, now: now) {
                events.append(event)
            }
        }
        return (events, next)
    }

    private static func entry(for observation: MyRequestObservation) -> MyRequestsSnapshot.Entry {
        .init(
            requestStatus: observation.requestStatus.rawValue,
            mediaStatus: observation.mediaStatus?.rawValue,
            availableSeasons: observation.availableSeasons.intersection(observation.requestedSeasons)
        )
    }

    private static func event(
        for observation: MyRequestObservation,
        prior: MyRequestsSnapshot.Entry,
        now: Date
    ) -> MyRequestEvent? {
        func make(_ kind: MyRequestEvent.Kind, seasons: [Int] = []) -> MyRequestEvent {
            MyRequestEvent(
                requestID: observation.requestID,
                kind: kind,
                mediaType: observation.mediaType,
                tmdbID: observation.tmdbID,
                seasons: seasons,
                jellyfinItemID: observation.jellyfinItemID,
                title: nil,
                posterPath: nil,
                date: now
            )
        }

        // Shows count per season of THIS request: another user's season landing must not notify.
        if observation.mediaType == .tv {
            let newly = observation.availableSeasons
                .intersection(observation.requestedSeasons)
                .subtracting(prior.availableSeasons)
            if !newly.isEmpty { return make(.available, seasons: newly.sorted()) }
        } else {
            let available = SeerrMediaStatus.available.rawValue
            if observation.mediaStatus?.rawValue == available, prior.mediaStatus != available {
                return make(.available)
            }
        }

        guard observation.requestStatus.rawValue != prior.requestStatus else { return nil }
        switch observation.requestStatus {
        case .approved, .completed:
            return prior.requestStatus == SeerrRequestStatus.pendingApproval.rawValue ? make(.approved) : nil
        case .declined:
            return make(.declined)
        case .failed:
            return make(.failed)
        case .pendingApproval:
            return nil
        }
    }
}
