import Foundation
import Testing
@testable import PixelCore

@Suite struct IsoMathTests {
    @Test func constants() {
        #expect(IsoMath.tileWidth == 64 && IsoMath.tileHeight == 32 && IsoMath.levelHeight == 16)
        #expect(IsoMath.seatHeight == 16 && IsoMath.deskTopHeight == 24 && IsoMath.screenTopHeight == 44)
        #expect(IsoMath.characterHeight == 56 && IsoMath.wallHeight == 96)
    }

    @Test func toSceneAxes() {
        #expect(IsoMath.toScene(GridPoint(0, 0)) == ScenePoint(x: 0, y: 0))
        #expect(IsoMath.toScene(GridPoint(1, 0)) == ScenePoint(x: 32, y: -16))
        #expect(IsoMath.toScene(GridPoint(0, 1)) == ScenePoint(x: -32, y: -16))
        #expect(IsoMath.toScene(GridPoint(3, 5)) == ScenePoint(x: -64, y: -128))
    }

    @Test func tileCenter() {
        #expect(IsoMath.tileCenter(GridPoint(0, 0)) == ScenePoint(x: 0, y: -16))
        #expect(IsoMath.tileCenter(GridPoint(2, 1)) == ScenePoint(x: 32, y: -64))
    }

    @Test func toGridInvertsToScene() {
        for i in -12...12 {
            for j in -12...12 {
                let s = IsoMath.toScene(GridPoint(i, j))
                let back = IsoMath.toGrid(x: Double(s.x), y: Double(s.y))
                #expect(back.i == Double(i) && back.j == Double(j), "(\(i), \(j))")
            }
        }
        // The tile centre is half a tile along both axes.
        let centre = IsoMath.tileCenter(GridPoint(4, 2))
        let grid = IsoMath.toGrid(x: Double(centre.x), y: Double(centre.y))
        #expect(grid.i == 4.5 && grid.j == 2.5)
    }

    @Test func depthDrawsFarthestFirstThenByLayer() {
        let layers = DepthLayer.allCases
        #expect(layers.map(\.rawValue) == [0, 2, 4, 5, 8])
        #expect(IsoMath.depth(GridPoint(2, 3), layer: .furniture) == 52)
        // Every layer of a tile is drawn after every layer of a farther tile.
        for layer in layers {
            for other in layers {
                #expect(IsoMath.depth(GridPoint(0, 0), layer: layer) < IsoMath.depth(GridPoint(1, 0), layer: other))
                #expect(IsoMath.depth(GridPoint(4, 6), layer: layer) < IsoMath.depth(GridPoint(6, 5), layer: other))
            }
        }
        for (a, b) in zip(layers, layers.dropFirst()) {
            #expect(IsoMath.depth(GridPoint(3, 3), layer: a) < IsoMath.depth(GridPoint(3, 3), layer: b))
        }
        #expect(IsoMath.depth(i: 2.5, j: 1, layer: .character) == 39)
        #expect(IsoMath.depth(i: 2, j: 3, layer: .furniture) == Double(IsoMath.depth(GridPoint(2, 3), layer: .furniture)))
    }

    @Test func facing() {
        #expect(Facing.allCases == [.ne, .nw, .se, .sw])
        #expect(Facing.ne.step == GridPoint(0, -1) && Facing.nw.step == GridPoint(-1, 0))
        #expect(Facing.se.step == GridPoint(1, 0) && Facing.sw.step == GridPoint(0, 1))
        #expect(Facing.allCases.filter(\.isTowardViewer) == [.se, .sw])
        #expect(Facing.se.mirrored == .sw && Facing.sw.mirrored == .se && Facing.ne.mirrored == .nw && Facing.nw.mirrored == .ne)
        #expect(Facing.se.opposite == .nw && Facing.nw.opposite == .se && Facing.sw.opposite == .ne && Facing.ne.opposite == .sw)
        for f in Facing.allCases {
            #expect(f.mirrored.mirrored == f && f.opposite.opposite == f)
            #expect(f.step + f.opposite.step == GridPoint(0, 0))
            #expect(f.mirrored.isTowardViewer == f.isTowardViewer)
            #expect(f.opposite.isTowardViewer != f.isTowardViewer)
        }
        // A step toward the viewer moves down on screen.
        for f in Facing.allCases {
            #expect((IsoMath.toScene(f.step).y < 0) == f.isTowardViewer)
        }
    }

    @Test func gridPointOrderIsRowMajor() {
        let points = [GridPoint(2, 1), GridPoint(0, 2), GridPoint(5, 0), GridPoint(1, 1)]
        #expect(points.sorted() == [GridPoint(5, 0), GridPoint(1, 1), GridPoint(2, 1), GridPoint(0, 2)])
        #expect(GridPoint(1, 2) + GridPoint(3, -1) == GridPoint(4, 1))
        #expect(GridPoint(1, 2) - GridPoint(3, -1) == GridPoint(-2, 3))
    }

    @Test func gridRect() {
        let rect = GridRect(origin: GridPoint(2, 3), size: GridSize(w: 4, d: 2))
        #expect(rect.contains(GridPoint(2, 3)) && rect.contains(GridPoint(5, 4)))
        #expect(!rect.contains(GridPoint(6, 3)) && !rect.contains(GridPoint(2, 5)) && !rect.contains(GridPoint(1, 3)))
        #expect(rect.tiles == [GridPoint(2, 3), GridPoint(3, 3), GridPoint(4, 3), GridPoint(5, 3),
                               GridPoint(2, 4), GridPoint(3, 4), GridPoint(4, 4), GridPoint(5, 4)])
        #expect(rect.contains(GridRect(origin: GridPoint(3, 3), size: GridSize(w: 3, d: 2))))
        #expect(!rect.contains(GridRect(origin: GridPoint(3, 3), size: GridSize(w: 4, d: 2))))
        let touching = GridRect(origin: GridPoint(6, 3), size: GridSize(w: 2, d: 2))
        #expect(!rect.intersects(touching), "edges that only touch do not intersect")
        #expect(rect.intersects(GridRect(origin: GridPoint(5, 4), size: GridSize(w: 3, d: 3))))
        #expect(rect.union(touching) == GridRect(origin: GridPoint(2, 3), size: GridSize(w: 6, d: 2)))
        let far = GridRect(origin: GridPoint(-1, 10), size: GridSize(w: 1, d: 1))
        #expect(rect.union(far) == GridRect(origin: GridPoint(-1, 3), size: GridSize(w: 7, d: 8)))
        let empty = GridRect(origin: GridPoint(0, 0), size: GridSize(w: 0, d: 3))
        #expect(empty.tiles.isEmpty && !empty.intersects(rect) && rect.union(empty) == rect)
    }

    @Test func gridTypesAreCodable() throws {
        let rect = GridRect(origin: GridPoint(1, 2), size: GridSize(w: 3, d: 4))
        let data = try JSONEncoder().encode(rect)
        #expect(try JSONDecoder().decode(GridRect.self, from: data) == rect)
        #expect(try JSONDecoder().decode(Facing.self, from: JSONEncoder().encode(Facing.sw)) == .sw)
    }
}
