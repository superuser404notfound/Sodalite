import Foundation

/// Which of Home's artwork a prefetch warms (Sodalite#212).
///
/// Every row in full was several times what `ImageCache` holds, and `NSCache` throws out the oldest
/// entries first, which were the top rows: the prefetch of the bottom ones evicted the cards on
/// screen, and scrolling back up loaded them from the server again. So only the head of each row,
/// the cards a first look at it shows, and only top rows first until the limit. The rest loads as
/// it comes into view, the way it would without any prefetch.
enum HomePrefetchPlan {

    /// A tvOS row shows about seven posters or four landscape cards; one card beyond that warms the
    /// first move to the right.
    static let headPerRow = 8

    static func urls(rows: [[URL]], perRow: Int = headPerRow, limit: Int) -> [URL] {
        var seen = Set<URL>()
        var plan: [URL] = []
        for row in rows {
            for url in row.prefix(perRow) where seen.insert(url).inserted {
                guard plan.count < limit else { return plan }
                plan.append(url)
            }
        }
        return plan
    }
}
