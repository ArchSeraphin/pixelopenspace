import Foundation
import Testing
@testable import PixelCore

/// True when `value` is a whole number of `step`s (floating point tolerance).
private func isMultiple(_ value: Double, of step: Double) -> Bool {
    let q = value / step
    return abs(q - q.rounded()) < 1e-6
}

private func world(_ w: Int, _ d: Int, origin: GridPoint = GridPoint(0, 0)) -> SceneBox {
    CameraMath.worldBox(for: GridRect(origin: origin, size: GridSize(w: w, d: d)))
}

private func randomDouble(_ rng: inout SplitMix64, in range: ClosedRange<Double>) -> Double {
    Double.random(in: range, using: &rng)
}

@Suite struct CameraMathTests {
    static let retina = ViewMetrics(width: 1470, height: 830, backingScale: 2)

    @Test func pointsPerTexelAndScale() {
        #expect(CameraMath.pointsPerTexel(.overview) == 0.5)
        #expect(CameraMath.pointsPerTexel(.x1) == 1)
        #expect(CameraMath.pointsPerTexel(.x2) == 2)
        #expect(CameraMath.pointsPerTexel(.x3) == 3)
        #expect(CameraMath.cameraScale(.overview) == 2)
        #expect(CameraMath.cameraScale(.x1) == 1)
        #expect(CameraMath.cameraScale(.x2) == 0.5)
        #expect(abs(CameraMath.cameraScale(.x3) - 1.0 / 3.0) < 1e-12)
        #expect(CameraMath.margin == 48 && CameraMath.keyboardStep == 64 && CameraMath.keyboardFastFactor == 4)
        // One physical pixel per texel in the overview on Retina; 2, 4 and 6 at x1, x2 and x3.
        #expect(CameraMath.pixelStep(.overview, backingScale: 2) == 1)
        #expect(CameraMath.pixelStep(.x1, backingScale: 2) == 0.5)
        #expect(CameraMath.pixelStep(.x2, backingScale: 2) == 0.25)
        #expect(abs(CameraMath.pixelStep(.x3, backingScale: 2) - 1.0 / 6.0) < 1e-12)
        #expect(CameraMath.pixelStep(.x1, backingScale: 1) == 1)
    }

    @Test func overviewOnlyOnRetina() {
        #expect(CameraMath.availableZooms(backingScale: 2) == [.overview, .x1, .x2, .x3])
        #expect(CameraMath.availableZooms(backingScale: 3) == [.overview, .x1, .x2, .x3])
        #expect(CameraMath.availableZooms(backingScale: 1) == [.x1, .x2, .x3])
    }

    @Test func worldBoxMatchesCanvas() {
        for (w, d) in [(12, 15), (24, 24), (36, 24)] {
            for origin in [GridPoint(0, 0), GridPoint(3, 2), GridPoint(-1, 4)] {
                let rect = GridRect(origin: origin, size: GridSize(w: w, d: d))
                let box = CameraMath.worldBox(for: rect)
                let size = SceneCompositor.canvasSize(for: rect)
                #expect(box.width == Double(size.width) && box.height == Double(size.height), "\(w)×\(d) at \(origin)")
                // Décision 16: canvasX = sceneX − minX, canvasY = maxY − sceneY, for every corner tile.
                for tile in [rect.origin, GridPoint(rect.end.i - 1, rect.origin.j), GridPoint(rect.origin.i, rect.end.j - 1),
                             GridPoint(rect.end.i - 1, rect.end.j - 1)] {
                    let scene = IsoMath.toScene(tile)
                    let canvas = SceneCompositor.imagePoint(of: tile, in: rect)
                    #expect(Double(scene.x) - box.minX == Double(canvas.x), "\(tile)")
                    #expect(box.maxY - Double(scene.y) == Double(canvas.y), "\(tile)")
                }
            }
            // For layout.bounds (origin (0, 0)): x ∈ [−32·D, 32·W], y ∈ [−16·(W + D), 96].
            let box = world(w, d)
            #expect(box == SceneBox(minX: Double(-32 * d), minY: Double(-16 * (w + d)), maxX: Double(32 * w), maxY: 96))
        }
    }

    @Test func snappedAlignsTexelsOnPhysicalPixels() {
        var rng = SplitMix64(seed: 3_2026)
        for n in 0..<200 {
            let scale = n % 2 == 0 ? 2 : 1
            let zooms = CameraMath.availableZooms(backingScale: scale)
            let zoom = zooms[Int(rng.next() % UInt64(zooms.count))]
            // Physical sizes of every parity combination.
            let pixelsW = 2 * (150 + Int(rng.next() % 1000)) + (n / 2) % 2
            let pixelsH = 2 * (100 + Int(rng.next() % 700)) + (n / 4) % 2
            let view = ViewMetrics(width: Double(pixelsW) / Double(scale), height: Double(pixelsH) / Double(scale),
                                   backingScale: scale)
            let centre = SceneVector(randomDouble(&rng, in: -3000...3000), randomDouble(&rng, in: -2000...200))
            let pose = CameraMath.snapped(CameraPose(zoom: zoom, center: centre), view: view)
            let step = CameraMath.pixelStep(zoom, backingScale: scale)
            let visible = CameraMath.visibleBox(pose, view: view)
            #expect(pose.zoom == zoom)
            #expect(isMultiple(visible.minX, of: step), "left edge, \(pixelsW) px, \(zoom), scale \(scale)")
            #expect(isMultiple(visible.minY, of: step), "bottom edge, \(pixelsH) px, \(zoom), scale \(scale)")
            // Every whole texel edge is a whole number of physical pixels from the view's edges.
            #expect(isMultiple(1, of: step))
            #expect(isMultiple(visible.maxX, of: step) && isMultiple(visible.maxY, of: step))
            // Snapping moves the camera by less than one physical pixel.
            #expect(abs(pose.center.x - centre.x) < step && abs(pose.center.y - centre.y) < step)
        }
    }

    @Test func snappedIsIdempotent() {
        var rng = SplitMix64(seed: 77)
        for n in 0..<200 {
            let scale = n % 3 == 0 ? 1 : 2
            let zooms = CameraMath.availableZooms(backingScale: scale)
            let zoom = zooms[n % zooms.count]
            let view = ViewMetrics(width: Double(301 + n) / Double(scale), height: Double(200 + 3 * n) / Double(scale),
                                   backingScale: scale)
            let pose = CameraPose(zoom: zoom, center: SceneVector(randomDouble(&rng, in: -2500...2500),
                                                                 randomDouble(&rng, in: -1500...100)))
            let once = CameraMath.snapped(pose, view: view)
            #expect(CameraMath.snapped(once, view: view) == once)
        }
    }

    @Test func clampedKeepsTheWorldInView() {
        let box = world(36, 24)
        let view = Self.retina
        var rng = SplitMix64(seed: 5)
        for zoom in [SceneZoom.x1, .x2, .x3] {
            let margin = CameraMath.margin / CameraMath.pointsPerTexel(zoom)
            for _ in 0..<50 {
                let far = SceneVector(randomDouble(&rng, in: -20_000...20_000), randomDouble(&rng, in: -20_000...20_000))
                let pose = CameraMath.clamped(CameraPose(zoom: zoom, center: far), world: box, view: view)
                let visible = CameraMath.visibleBox(pose, view: view)
                // The world is wider and taller than the view at these zooms: never more than the margin past it.
                #expect(visible.minX >= box.minX - margin - 1e-9 && visible.maxX <= box.maxX + margin + 1e-9)
                #expect(visible.minY >= box.minY - margin - 1e-9 && visible.maxY <= box.maxY + margin + 1e-9)
                #expect(pose.zoom == zoom)
            }
            // A pose already inside the allowed range does not move.
            let inside = CameraPose(zoom: zoom, center: box.center)
            #expect(CameraMath.clamped(inside, world: box, view: view) == inside)
        }
        // Pushed back exactly to the margin on the left.
        let left = CameraMath.clamped(CameraPose(zoom: .x1, center: SceneVector(-50_000, box.center.y)), world: box, view: view)
        #expect(CameraMath.visibleBox(left, view: view).minX == box.minX - CameraMath.margin)
    }

    @Test func smallWorldIsCentred() {
        let box = world(12, 15)   // 864 × 528 texels
        let view = Self.retina
        for zoom in [SceneZoom.overview, .x1] {
            for centre in [SceneVector(-9000, 4000), SceneVector(0, 0), SceneVector(500, -700)] {
                let pose = CameraMath.clamped(CameraPose(zoom: zoom, center: centre), world: box, view: view)
                #expect(pose.center == box.center, "\(zoom)")
            }
        }
        // x2 in a 2000 × 600 view: 1728 pt wide fits (centred on x), 1056 pt tall does not (clamped on y).
        let wide = ViewMetrics(width: 2000, height: 600, backingScale: 2)
        let pose = CameraMath.clamped(CameraPose(zoom: .x2, center: SceneVector(-9000, 4000)), world: box, view: wide)
        #expect(pose.center.x == box.center.x)
        let visible = CameraMath.visibleBox(pose, view: wide)
        #expect(visible.maxY == box.maxY + CameraMath.margin / 2)
    }

    @Test func fitAllPicksTheLargestZoom() {
        let box = world(36, 24)   // 1920 × 1056 texels
        let air = CameraMath.fitAll(world: box, view: Self.retina)
        #expect(air.pose.zoom == .overview && !air.needsMinimap)
        let big = CameraMath.fitAll(world: box, view: ViewMetrics(width: 3000, height: 2000, backingScale: 2))
        #expect(big.pose.zoom == .x1 && !big.needsMinimap)
        let huge = CameraMath.fitAll(world: box, view: ViewMetrics(width: 4500, height: 3000, backingScale: 2))
        #expect(huge.pose.zoom == .x2 && !huge.needsMinimap)
        let withBoard = CameraMath.fitAll(world: box, view: ViewMetrics(width: 1090, height: 830, backingScale: 2))
        #expect(withBoard.pose.zoom == .overview && !withBoard.needsMinimap)
        let plain = CameraMath.fitAll(world: box, view: ViewMetrics(width: 1090, height: 830, backingScale: 1))
        #expect(plain.pose.zoom == .x1 && plain.needsMinimap)
        // Centred on the world (to a physical pixel).
        for fit in [air, big, huge, withBoard, plain] {
            #expect(abs(fit.pose.center.x - box.center.x) <= 1 && abs(fit.pose.center.y - box.center.y) <= 1)
        }
        #expect(CameraMath.snapped(air.pose, view: Self.retina) == air.pose)
    }

    @Test func zoomKeepsThePointUnderTheCursor() {
        let box = world(120, 120)   // large enough that no clamp applies
        let view = Self.retina
        let start = CameraPose(zoom: .x1, center: box.center)
        for zoom in CameraMath.availableZooms(backingScale: 2) {
            let step = CameraMath.pixelStep(zoom, backingScale: 2)
            for cursor in [SceneVector(100, 700), SceneVector(735, 415), SceneVector(1400, 30)] {
                let before = CameraMath.scenePoint(atView: cursor, pose: start, view: view)
                let pose = CameraMath.zoomed(start, to: zoom, keeping: cursor, world: box, view: view)
                let after = CameraMath.scenePoint(atView: cursor, pose: pose, view: view)
                #expect(pose.zoom == zoom)
                #expect(abs(after.x - before.x) <= step + 1e-9 && abs(after.y - before.y) <= step + 1e-9,
                        "\(zoom) at \(cursor)")
                #expect(CameraMath.snapped(pose, view: view) == pose)
            }
            // nil: about the view's centre.
            let centred = CameraMath.zoomed(start, to: zoom, keeping: nil, world: box, view: view)
            #expect(abs(centred.center.x - start.center.x) <= step && abs(centred.center.y - start.center.y) <= step)
        }
    }

    @Test func stepStaysInAvailableZooms() {
        #expect(CameraMath.step(.x1, by: 1, backingScale: 2) == .x2)
        #expect(CameraMath.step(.x3, by: 1, backingScale: 2) == .x3)
        #expect(CameraMath.step(.x1, by: -1, backingScale: 2) == .overview)
        #expect(CameraMath.step(.overview, by: -1, backingScale: 2) == .overview)
        #expect(CameraMath.step(.x1, by: -1, backingScale: 1) == .x1)
        #expect(CameraMath.step(.overview, by: 1, backingScale: 1) == .x1)
        #expect(CameraMath.step(.overview, by: 0, backingScale: 1) == .x1)
        #expect(CameraMath.step(.x2, by: 5, backingScale: 2) == .x3)
        #expect(CameraMath.step(.x3, by: -10, backingScale: 2) == .overview)
        #expect(CameraMath.step(.x3, by: -2, backingScale: 1) == .x1)
        for scale in [1, 2] {
            let available = CameraMath.availableZooms(backingScale: scale)
            for zoom in SceneZoom.allCases {
                for delta in -3...3 {
                    #expect(available.contains(CameraMath.step(zoom, by: delta, backingScale: scale)))
                }
            }
        }
    }

    @Test func pannedMovesByViewPoints() {
        let box = world(120, 120)
        let view = Self.retina
        let start = CameraPose(zoom: .x2, center: box.center)
        let moved = CameraMath.panned(start, byViewPoints: SceneVector(40, -20), world: box, view: view)
        #expect(moved.center == SceneVector(box.center.x + 20, box.center.y - 10) && moved.zoom == .x2)
        let overview = CameraPose(zoom: .overview, center: box.center)
        let far = CameraMath.panned(overview, byViewPoints: SceneVector(40, -20), world: box, view: view)
        #expect(far.center == SceneVector(box.center.x + 80, box.center.y - 40))
        // Not snapped: a quarter point stays a quarter texel at x1.
        let x1 = CameraPose(zoom: .x1, center: box.center)
        let nudged = CameraMath.panned(x1, byViewPoints: SceneVector(0.25, 0), world: box, view: view)
        #expect(nudged.center.x == box.center.x + 0.25)
        // Clamped at the margin.
        let away = CameraMath.panned(x1, byViewPoints: SceneVector(-1_000_000, 0), world: box, view: view)
        #expect(CameraMath.visibleBox(away, view: view).minX == box.minX - CameraMath.margin)
    }

    @Test func viewSceneRoundTrip() {
        var rng = SplitMix64(seed: 11)
        let view = Self.retina
        for n in 0..<100 {
            let zoom = SceneZoom.allCases[n % 4]
            let pose = CameraPose(zoom: zoom, center: SceneVector(randomDouble(&rng, in: -2000...2000),
                                                                 randomDouble(&rng, in: -1500...100)))
            let scene = SceneVector(randomDouble(&rng, in: -3000...3000), randomDouble(&rng, in: -3000...3000))
            let back = CameraMath.scenePoint(atView: CameraMath.viewPoint(of: scene, pose: pose, view: view), pose: pose,
                                             view: view)
            #expect(abs(back.x - scene.x) < 1e-6 && abs(back.y - scene.y) < 1e-6)
            #expect(CameraMath.viewPoint(of: pose.center, pose: pose, view: view) == SceneVector(735, 415))
            // The visible box spans the view: bottom-left corner at (0, 0), top-right at (width, height).
            let visible = CameraMath.visibleBox(pose, view: view)
            let low = CameraMath.viewPoint(of: SceneVector(visible.minX, visible.minY), pose: pose, view: view)
            let high = CameraMath.viewPoint(of: SceneVector(visible.maxX, visible.maxY), pose: pose, view: view)
            #expect(abs(low.x) < 1e-6 && abs(low.y) < 1e-6)
            #expect(abs(high.x - 1470) < 1e-6 && abs(high.y - 830) < 1e-6)
        }
        // Up in the scene is up in the view (both y up).
        let pose = CameraPose(zoom: .x2, center: SceneVector(0, 0))
        #expect(CameraMath.viewPoint(of: SceneVector(10, 5), pose: pose, view: view) == SceneVector(755, 425))
    }

    @Test func initialPoseUsesDefaultZoom() {
        let box = world(36, 24)
        let retina = Self.retina
        let plain = ViewMetrics(width: 1470, height: 830, backingScale: 1)
        let focus = SceneVector(100.3, -400.7)
        let x2 = CameraMath.initialPose(defaultZoom: 2, world: box, focus: focus, view: retina)
        #expect(x2.zoom == .x2)
        #expect(abs(x2.center.x - focus.x) < 0.25 && abs(x2.center.y - focus.y) < 0.25)
        #expect(CameraMath.snapped(x2, view: retina) == x2)
        #expect(CameraMath.initialPose(defaultZoom: 0, world: box, focus: nil, view: retina).zoom == .overview)
        #expect(CameraMath.initialPose(defaultZoom: 0, world: box, focus: nil, view: plain).zoom == .x1)
        #expect(CameraMath.initialPose(defaultZoom: 3, world: box, focus: nil, view: plain).zoom == .x3)
        #expect(CameraMath.initialPose(defaultZoom: 9, world: box, focus: nil, view: retina).zoom == .x3)
        #expect(CameraMath.initialPose(defaultZoom: -4, world: box, focus: nil, view: plain).zoom == .x1)
        // Without a focus: the world's centre (the overview holds the whole world, so it is centred exactly).
        let whole = CameraMath.initialPose(defaultZoom: 0, world: box, focus: nil, view: retina)
        #expect(whole.center == box.center)
        // A focus near the edge is clamped.
        let edge = CameraMath.initialPose(defaultZoom: 1, world: box, focus: SceneVector(box.minX, box.maxY), view: retina)
        let visible = CameraMath.visibleBox(edge, view: retina)
        #expect(visible.minX >= box.minX - CameraMath.margin - 1 && visible.maxY <= box.maxY + CameraMath.margin + 1)
    }

    @Test func sceneBoxBasics() {
        let box = SceneBox(minX: -10, minY: -4, maxX: 30, maxY: 16)
        #expect(box.width == 40 && box.height == 20 && box.center == SceneVector(10, 6))
        #expect(box.contains(SceneVector(-10, 16)) && box.contains(SceneVector(0, 0)))
        #expect(!box.contains(SceneVector(30.5, 0)) && !box.contains(SceneVector(0, -4.1)))
        #expect(box.contains(SceneBox(minX: -10, minY: -4, maxX: 0, maxY: 0)))
        #expect(!box.contains(SceneBox(minX: -11, minY: 0, maxX: 0, maxY: 1)))
    }
}

@Suite struct PinchAccumulatorTests {
    @Test func belowTheThresholdNothing() {
        var pinch = PinchAccumulator()
        #expect(pinch.add(0.1) == 0)
        #expect(pinch.add(0.2) == 0)
        #expect(pinch.add(-0.25) == 0)
        #expect(pinch.add(-0.3) == 0)
    }

    @Test func pastTheThresholdOneStepThenRestart() {
        var pinch = PinchAccumulator()
        #expect(pinch.add(0.2) == 0)
        #expect(pinch.add(0.2) == 1)
        // Restarted from zero: 0.3 is not enough for another step.
        #expect(pinch.add(0.3) == 0)
        #expect(pinch.add(0.1) == 1)
        // A single large magnification is still one step.
        #expect(pinch.add(2.0) == 1)
        #expect(pinch.add(0) == 0)
    }

    @Test func sign() {
        var pinch = PinchAccumulator()
        #expect(pinch.add(-0.2) == 0)
        #expect(pinch.add(-0.2) == -1)
        // Changing direction first cancels what was gathered: 0.2 − 0.5 = −0.3, no step yet.
        #expect(pinch.add(0.2) == 0)
        #expect(pinch.add(-0.5) == 0)
        #expect(pinch.add(-0.1) == -1)
        #expect(PinchAccumulator.threshold == 0.35)
    }

    @Test func resetForgetsTheSum() {
        var pinch = PinchAccumulator()
        #expect(pinch.add(0.3) == 0)
        pinch.reset()
        #expect(pinch.add(0.3) == 0)
        #expect(pinch == {
            var fresh = PinchAccumulator()
            _ = fresh.add(0.3)
            return fresh
        }())
    }
}
