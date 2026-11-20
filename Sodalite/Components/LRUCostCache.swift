import Foundation

/// A byte-budgeted cache that evicts the entry used LEAST RECENTLY, and counts what it evicts.
///
/// It replaces `NSCache` under `ImageCache` (Sodalite#212). `NSCache` documents no eviction order,
/// and a read does not move an entry to the back of it, so on a Home of 10 to 15 rows the cards
/// that had just been on screen went out as readily as the ones scrolled past long ago. Here a read
/// counts as a use: what was drawn last is what survives.
///
/// Thread-safe behind one lock, so prefetch tasks store from the cooperative pool without a hop.
nonisolated final class LRUCostCache<Key: Hashable, Value>: @unchecked Sendable {

    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var newer: Node?
        weak var older: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let lock = NSLock()
    private var nodes: [Key: Node] = [:]
    /// Least recently used end; `newest` is the other.
    private var oldest: Node?
    private var newest: Node?
    private var evictions = 0

    let costLimit: Int
    private var heldCost = 0
    var totalCost: Int { lock.withLock { heldCost } }

    init(costLimit: Int) {
        self.costLimit = costLimit
    }

    var count: Int { lock.withLock { nodes.count } }

    func value(for key: Key) -> Value? {
        lock.withLock {
            guard let node = nodes[key] else { return nil }
            moveToNewest(node)
            return node.value
        }
    }

    func store(_ value: Value, for key: Key, cost: Int) {
        lock.withLock {
            // One entry larger than the whole budget would evict everything and then itself.
            guard cost <= costLimit else { return }
            if let node = nodes[key] {
                heldCost += cost - node.cost
                node.value = value
                node.cost = cost
                moveToNewest(node)
            } else {
                let node = Node(key: key, value: value, cost: cost)
                nodes[key] = node
                append(node)
                heldCost += cost
            }
            trim(to: costLimit)
        }
    }

    /// Drops the least recently used entries until at most `fraction` of the budget is held.
    func trim(toFraction fraction: Double) {
        lock.withLock { trim(to: Int(Double(costLimit) * fraction)) }
    }

    func removeAll() {
        lock.withLock {
            nodes.removeAll()
            oldest = nil
            newest = nil
            heldCost = 0
        }
    }

    /// Evictions since the last call. A clear is not an eviction.
    func takeEvictionCount() -> Int {
        lock.withLock {
            defer { evictions = 0 }
            return evictions
        }
    }

    // MARK: list, lock held

    private func trim(to limit: Int) {
        while heldCost > limit, let victim = oldest {
            unlink(victim)
            nodes[victim.key] = nil
            heldCost -= victim.cost
            evictions += 1
        }
    }

    private func moveToNewest(_ node: Node) {
        guard node !== newest else { return }
        unlink(node)
        append(node)
    }

    private func append(_ node: Node) {
        node.older = newest
        node.newer = nil
        newest?.newer = node
        newest = node
        if oldest == nil { oldest = node }
    }

    private func unlink(_ node: Node) {
        let older = node.older
        let newer = node.newer
        older?.newer = newer
        newer?.older = older
        if oldest === node { oldest = newer }
        if newest === node { newest = older }
        node.older = nil
        node.newer = nil
    }
}
