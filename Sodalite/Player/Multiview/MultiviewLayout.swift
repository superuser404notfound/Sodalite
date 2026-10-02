import Foundation

enum MultiviewLayout {
    static func columns(tileCount: Int) -> Int {
        tileCount <= 1 ? 1 : 2
    }

    /// Three tiles leave the fourth cell of the 2x2 grid empty, which is where adding happens.
    static func showsAddTile(tileCount: Int) -> Bool {
        tileCount == 3
    }

    static func showsAddButton(tileCount: Int) -> Bool {
        tileCount == 1 || tileCount == 2
    }
}
