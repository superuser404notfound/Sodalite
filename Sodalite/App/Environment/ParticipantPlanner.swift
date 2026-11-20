import Foundation

struct SessionCredential: Equatable, Sendable {
    let userID: String
    let token: String
}

struct ParticipantCandidate: Equatable {
    let server: JellyfinServer
    let credential: SessionCredential
}

/// Which servers join the active one in a combined Home (Sodalite#85).
enum ParticipantPlanner {
    static let cap = 5

    static func plan(
        servers: [JellyfinServer],
        activeServerID: String?,
        enabled: Bool,
        excluded: Set<String>,
        lastActivated: [String: Date],
        credential: (String) -> SessionCredential?
    ) -> [ParticipantCandidate] {
        guard enabled else { return [] }
        let others = servers.enumerated().filter {
            $0.element.id != activeServerID && !excluded.contains($0.element.id)
        }
        let ordered = others.sorted { lhs, rhs in
            switch (lastActivated[lhs.element.id], lastActivated[rhs.element.id]) {
            case let (l?, r?): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }
        var result: [ParticipantCandidate] = []
        for entry in ordered where result.count < cap - 1 {
            guard let credential = credential(entry.element.id) else { continue }
            result.append(ParticipantCandidate(server: entry.element, credential: credential))
        }
        return result
    }
}
