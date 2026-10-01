import Foundation
import Testing
@testable import PixelCore

private func worldBox(_ w: Int, _ d: Int) -> SceneBox {
    CameraMath.worldBox(for: GridRect(origin: GridPoint(0, 0), size: GridSize(w: w, d: d)))
}

@Suite struct MinimapTests {
    static let worlds: [SceneBox] = [worldBox(12, 15), worldBox(24, 24), worldBox(36, 24), worldBox(36, 33),
                                     worldBox(60, 12), SceneBox(minX: 0, minY: 0, maxX: 300, maxY: 2000)]

    @Test func keepsTheAspectRatio() {
        for world in Self.worlds {
            let map = Minimap.layout(world: world)
            let aspect = world.width / world.height
            #expect(abs(map.width / map.height - aspect) / aspect < 0.05, "\(world): \(map.width)×\(map.height)")
            #expect(map.world == world)
        }
    }

    @Test func sizeStaysInTheBounds() {
        #expect(Minimap.maxWidth == 220 && Minimap.maxHeight == 140)
        for world in Self.worlds {
            let map = Minimap.layout(world: world)
            #expect(map.width <= Minimap.maxWidth && map.height <= Minimap.maxHeight)
            #expect(map.width.truncatingRemainder(dividingBy: 2) == 0 && map.height.truncatingRemainder(dividingBy: 2) == 0)
            // The limiting side uses (almost) all of its room.
            #expect(map.width >= Minimap.maxWidth - 2 || map.height >= Minimap.maxHeight - 2, "\(map.width)×\(map.height)")
        }
        let small = Minimap.layout(world: worldBox(36, 24), maxWidth: 101, maxHeight: 300)
        #expect(small.width == 100 && small.height <= 300)
        // 1920 × 1056 texels in 220 × 140: width-bound.
        let wide = Minimap.layout(world: worldBox(36, 24))
        #expect(wide.width == 220 && wide.height == 120)
    }

    @Test func sceneMinimapRoundTrip() {
        var rng = SplitMix64(seed: 8)
        for world in Self.worlds {
            let map = Minimap.layout(world: world)
            // Corners: top-left of the world is (0, 0), y down.
            #expect(map.point(of: SceneVector(world.minX, world.maxY)) == SceneVector(0, 0))
            #expect(map.point(of: SceneVector(world.maxX, world.minY)) == SceneVector(map.width, map.height))
            let texelsPerPoint = max(world.width / map.width, world.height / map.height)
            for _ in 0..<50 {
                let scene = SceneVector(Double.random(in: world.minX...world.maxX, using: &rng),
                                        Double.random(in: world.minY...world.maxY, using: &rng))
                let point = map.point(of: scene)
                #expect(point.x.truncatingRemainder(dividingBy: 2) == 0 && point.y.truncatingRemainder(dividingBy: 2) == 0)
                #expect(point.x >= 0 && point.x <= map.width && point.y >= 0 && point.y <= map.height)
                let back = map.scenePoint(at: point)
                #expect(abs(back.x - scene.x) <= texelsPerPoint + 1e-9 && abs(back.y - scene.y) <= texelsPerPoint + 1e-9)
            }
            // Minimap → scene → minimap is exact on the 2 pt grid.
            for x in stride(from: 0.0, through: map.width, by: 2) {
                let p = SceneVector(x, map.height / 2 - (map.height / 2).truncatingRemainder(dividingBy: 2))
                #expect(map.point(of: map.scenePoint(at: p)) == p)
            }
        }
        // Higher in the scene is higher on the minimap (smaller y).
        let map = Minimap.layout(world: worldBox(36, 24))
        #expect(map.point(of: SceneVector(0, 0)).y < map.point(of: SceneVector(0, -500)).y)
    }

    @Test func viewportIsClipped() {
        let world = worldBox(36, 24)
        let map = Minimap.layout(world: world)
        // A view larger than the world: the whole minimap.
        let wide = ViewMetrics(width: 5000, height: 4000, backingScale: 2)
        let whole = map.viewport(pose: CameraPose(zoom: .x1, center: world.center), view: wide)
        #expect(whole == SceneBox(minX: 0, minY: 0, maxX: map.width, maxY: map.height))
        // A view inside the world: its box, scaled, y down (minY is the top edge).
        let view = ViewMetrics(width: 400, height: 300, backingScale: 2)
        let inside = map.viewport(pose: CameraPose(zoom: .x1, center: world.center), view: view)
        let scale = map.width / world.width
        // Each edge is rounded to the 2 pt grid: up to 1 pt per edge.
        #expect(abs(inside.width - 400 * scale) <= 3 && abs(inside.height - 300 * scale) <= 3)
        #expect(abs(inside.center.x - map.width / 2) <= 2 && abs(inside.center.y - map.height / 2) <= 2)
        #expect(inside.minY < inside.maxY)
        // Past the top-left corner of the world: clipped to the minimap.
        let corner = map.viewport(pose: CameraPose(zoom: .x1, center: SceneVector(world.minX, world.maxY)), view: view)
        #expect(corner.minX == 0 && corner.minY == 0)
        #expect(abs(corner.maxX - 200 * scale) <= 2 && abs(corner.maxY - 150 * scale) <= 2)
        // Entirely outside: an empty box on the border.
        let away = map.viewport(pose: CameraPose(zoom: .x1, center: SceneVector(world.maxX + 5000, 0)), view: view)
        #expect(away.width == 0 && away.minX == map.width)
        for box in [whole, inside, corner, away] {
            for edge in [box.minX, box.minY, box.maxX, box.maxY] { #expect(edge.truncatingRemainder(dividingBy: 2) == 0) }
        }
    }
}
