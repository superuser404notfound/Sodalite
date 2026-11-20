import Foundation

/// One participant the Music tab can run against (Sodalite#85).
struct MusicSource {
    let serverID: String
    let serverName: String
    let userID: String
    let musicService: JellyfinMusicServiceProtocol
    let isActive: Bool
}

nonisolated enum MusicProbe {
    /// Participants with a music library, in participant order. See `ParticipantProbe`.
    static func capableServerIDs(
        _ sources: [MusicSource], secondaryDeadline: Duration, previouslyCapable: Set<String> = []
    ) async -> [String] {
        await ParticipantProbe.capableServerIDs(
            sources.map { source in
                let service = source.musicService
                let userID = source.userID
                return ParticipantProbe.Target(serverID: source.serverID, isActive: source.isActive) {
                    (try? await service.hasMusicLibrary(userID: userID)) ?? false
                }
            },
            secondaryDeadline: secondaryDeadline, previouslyCapable: previouslyCapable)
    }
}

enum MusicSwitcher {
    static func isVisible(capable: [String]) -> Bool { capable.count > 1 }

    static func options(capable: [String], sources: [MusicSource]) -> [CatalogPickerSheet.Option] {
        sources.filter { capable.contains($0.serverID) }.map { .init(id: $0.serverID, label: $0.serverName) }
    }
}
