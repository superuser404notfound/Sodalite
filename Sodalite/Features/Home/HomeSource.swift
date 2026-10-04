import Foundation

/// One server a Home row is fetched from: the active one, or in a combined Home a secondary
/// (Sodalite#85).
struct HomeSource {
    let serverID: String
    let serverName: String
    let userID: String
    let libraryService: JellyfinLibraryServiceProtocol
    let isActive: Bool
}
