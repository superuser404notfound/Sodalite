import Foundation

nonisolated struct NamedItem: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

nonisolated struct NamedItemsResponse: Codable, Sendable {
    let items: [NamedItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}
