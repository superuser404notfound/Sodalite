import Foundation

struct JellyfinLibrary: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let collectionType: String?
    let imageTags: ImageTags?
    /// Jellyfin `ServerId`, so a combined My Media knows which server a library belongs to (Sodalite#85).
    var serverID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
        case serverID = "ServerId"
    }

    /// Identity across servers: Jellyfin derives a folder id from its path, so two servers with the
    /// same layout can mint the same one (Sodalite#85).
    var originKey: String { "\(serverID ?? "")|\(id)" }

    var libraryType: LibraryType {
        guard let collectionType else { return .unknown }
        return LibraryType(rawValue: collectionType) ?? .unknown
    }
}

enum LibraryType: String, Sendable {
    case movies
    case tvshows
    case music
    case books
    case homevideos
    case boxsets
    case playlists
    case unknown
}

/// Decodes one item, yielding nil instead of throwing when the element is malformed (e.g. a Jellyfin
/// entry with a null Name). Jellyfin's BaseItemDto.Name is nullable, and a standard `[JellyfinItem]`
/// decode is all-or-nothing: one such item would throw and strand the entire grid or row. Decoding
/// into `[FailableJellyfinItem]` and compact-mapping keeps the rest and drops only the bad element.
struct FailableJellyfinItem: Decodable {
    let value: JellyfinItem?
    init(from decoder: Decoder) throws {
        value = try? JellyfinItem(from: decoder)
    }
}

/// A `[JellyfinItem]` for top-level array endpoints that drops elements which fail to decode rather
/// than failing the whole response.
struct LossyJellyfinItems: Decodable, Sendable {
    let elements: [JellyfinItem]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([FailableJellyfinItem].self)
        elements = raw.compactMap(\.value)
        JellyfinDecodeReport.droppedElements(raw.count - elements.count, of: raw.count)
    }
}

struct JellyfinItemsResponse: Codable, Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([FailableJellyfinItem].self, forKey: .items) ?? []
        items = raw.compactMap(\.value)
        // Lenient like the elements above, and for the same reason: an endpoint that answers with
        // Items but omits TotalRecordCount used to throw the entire response away over a number
        // only paging reads (Sodalite#88). Falling back to what actually arrived keeps the grid.
        totalRecordCount = try container.decodeIfPresent(Int.self, forKey: .totalRecordCount) ?? items.count
        JellyfinDecodeReport.droppedElements(raw.count - items.count, of: raw.count)
    }

    /// The custom decoder suppresses the memberwise one; test doubles need a way to hand back a
    /// response without round-tripping their items through JSON.
    init(items: [JellyfinItem], totalRecordCount: Int) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }
}

/// Says out loud when the lenient decode above threw elements away.
///
/// The leniency exists so one malformed item cannot strand a whole grid, and it works, which is
/// exactly why it is invisible: a response whose every element is malformed decodes to an empty
/// array and renders as "nothing here" (Sodalite#88). The count is the discriminator between a
/// library that is empty and a library the client could not read.
enum JellyfinDecodeReport {
    static func droppedElements(_ dropped: Int, of total: Int) {
        guard dropped > 0 else { return }
        LogTap.shared.note("[jellyfin] response dropped \(dropped) of \(total) items that failed to decode")
    }
}
