import Foundation
import AetherEngine

@MainActor
final class MultiviewEnginePool {
    let primary: AetherEngine
    private let make: () throws -> AetherEngine
    private var secondaries: [Int: AetherEngine] = [:]

    init(primary: AetherEngine, make: @escaping () throws -> AetherEngine = { try AetherEngine() }) {
        self.primary = primary
        self.make = make
    }

    func slot(of engine: AetherEngine) -> Int? {
        if engine === primary { return 0 }
        return secondaries.first { $0.value === engine }?.key
    }

    /// Slot 0 is the app's engine; 1-3 are created on first use and kept, a stopped engine costs little.
    func engine(forSlot slot: Int) throws -> AetherEngine {
        if slot == 0 { return primary }
        if let engine = secondaries[slot] { return engine }
        let engine = try make()
        engine.deactivatesAudioSessionOnStop = true
        engine.logTag = "tile\(slot + 1)"
        secondaries[slot] = engine
        return engine
    }
}
