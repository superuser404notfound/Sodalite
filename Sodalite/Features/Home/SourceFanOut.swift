import Foundation

/// How one source answered a fan-out (audit BRW-R202).
enum SourceOutcome<T: Sendable>: Sendable {
    case value(T)
    case failed(unauthorized: Bool)
    case timedOut
}

/// The per-source fan-out Home, Customize and the libraries list share: the active source has no
/// deadline (it is the one Home always waited for), every secondary is raced against `deadline`.
/// Outcomes come back in source order. A cancelled caller cancels the secondaries' work too
/// (`Deadline.race`, BRW-206).
enum SourceFanOut {
    static func collect<T: Sendable>(
        _ sources: [HomeSource],
        deadline: Duration,
        work: @escaping @MainActor @Sendable (HomeSource) async throws -> T
    ) async -> [SourceOutcome<T>] {
        await withTaskGroup(of: (Int, SourceOutcome<T>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask(priority: source.isActive ? nil : .utility) {
                    let attempt: @MainActor @Sendable () async -> SourceOutcome<T> = {
                        do {
                            return .value(try await work(source))
                        } catch let error as APIError {
                            if case .unauthorized = error { return .failed(unauthorized: true) }
                            return .failed(unauthorized: false)
                        } catch {
                            return .failed(unauthorized: false)
                        }
                    }
                    if source.isActive { return (index, await attempt()) }
                    return (index, await Deadline.race(deadline) { @MainActor in await attempt() } ?? .timedOut)
                }
            }
            var collected = [SourceOutcome<T>?](repeating: nil, count: sources.count)
            for await (index, outcome) in group { collected[index] = outcome }
            return collected.map { $0 ?? .timedOut }
        }
    }
}

extension JellyfinItem {
    /// Tags an item with the server it came from unless it already says so.
    func stamped(serverID: String) -> JellyfinItem {
        var copy = self
        if copy.serverID == nil { copy.serverID = serverID }
        return copy
    }
}
