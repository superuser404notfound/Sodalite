import Foundation

/// One server a search runs against (Sodalite#85).
struct SearchSource {
    let serverID: String
    let userID: String
    let itemService: JellyfinItemServiceProtocol
    let isActive: Bool
}
