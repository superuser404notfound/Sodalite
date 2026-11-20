import Testing
@testable import Sodalite

struct MultiviewLayoutTests {
    @Test("one tile fills the screen, two to four share two columns")
    func columns() {
        #expect(MultiviewLayout.columns(tileCount: 1) == 1)
        #expect(MultiviewLayout.columns(tileCount: 2) == 2)
        #expect(MultiviewLayout.columns(tileCount: 3) == 2)
        #expect(MultiviewLayout.columns(tileCount: 4) == 2)
    }

    @Test("the add tile fills the empty fourth cell only")
    func addTile() {
        #expect(MultiviewLayout.showsAddTile(tileCount: 1) == false)
        #expect(MultiviewLayout.showsAddTile(tileCount: 2) == false)
        #expect(MultiviewLayout.showsAddTile(tileCount: 3) == true)
        #expect(MultiviewLayout.showsAddTile(tileCount: 4) == false)
    }

    @Test("the add button shows while the grid has no empty cell to put an add tile in")
    func addButton() {
        #expect(MultiviewLayout.showsAddButton(tileCount: 1) == true)
        #expect(MultiviewLayout.showsAddButton(tileCount: 2) == true)
        #expect(MultiviewLayout.showsAddButton(tileCount: 3) == false)
        #expect(MultiviewLayout.showsAddButton(tileCount: 4) == false)
    }
}
