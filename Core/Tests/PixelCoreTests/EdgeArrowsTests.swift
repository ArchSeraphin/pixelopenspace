import Foundation
import Testing
@testable import PixelCore

/// A fixed agent id: n in the last group of the UUID.
private func agentID(_ n: Int) -> AgentID {
    let hex = String(n, radix: 16, uppercase: true)
    return AgentID(UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - hex.count) + hex)!)
}

@Suite struct EdgeArrowsTests {
    /// 800 × 600 pt at x1, centred on the origin: the view shows x ∈ [−400, 400], y ∈ [−300, 300].
    static let view = ViewMetrics(width: 800, height: 600, backingScale: 2)
    static let pose = CameraPose(zoom: .x1, center: SceneVector(0, 0))

    @Test func visibleTargetHasNoArrow() {
        let targets = [EdgeArrowTarget(id: agentID(1), point: SceneVector(100, -50), priority: 1),
                       EdgeArrowTarget(id: agentID(2), point: SceneVector(399, 299), priority: 1)]
        #expect(EdgeArrows.layout(targets, pose: Self.pose, view: Self.view).isEmpty)
        #expect(EdgeArrows.layout([], pose: Self.pose, view: Self.view).isEmpty)
    }

    @Test func eightDirections() {
        // Clockwise from up, far away.
        let angles = (0..<8).map { Double($0) * .pi / 4 }
        let targets = angles.enumerated().map { index, angle in
            EdgeArrowTarget(id: agentID(index + 1), point: SceneVector(5000 * sin(angle), 5000 * cos(angle)), priority: 0)
        }
        let arrows = EdgeArrows.layout(targets, pose: Self.pose, view: Self.view)
        #expect(arrows.count == 8)
        for (index, target) in targets.enumerated() {
            let arrow = arrows.first { $0.id == target.id }
            #expect(arrow?.direction == index, "target \(index)")
        }
        let up = arrows.first { $0.id == agentID(1) }
        #expect(up?.position == SceneVector(400, 580))
        let right = arrows.first { $0.id == agentID(3) }
        #expect(right?.position == SceneVector(780, 300))
        let down = arrows.first { $0.id == agentID(5) }
        #expect(down?.position == SceneVector(400, 20))
        let left = arrows.first { $0.id == agentID(7) }
        #expect(left?.position == SceneVector(20, 300))
        // Up-right at 45°: the ray leaves through the top edge, 280 pt right of the centre.
        let upRight = arrows.first { $0.id == agentID(2) }
        #expect(upRight?.position == SceneVector(680, 580))
    }

    @Test func positionsLieOnTheInsetRect() {
        var rng = SplitMix64(seed: 99)
        let view = ViewMetrics(width: 1471, height: 833, backingScale: 2)
        let pose = CameraPose(zoom: .x2, center: SceneVector(37.25, -120.5))
        let targets = (0..<40).map { n in
            EdgeArrowTarget(id: agentID(n + 1), point: SceneVector(Double.random(in: -4000...4000, using: &rng),
                                                                   Double.random(in: -4000...4000, using: &rng)),
                            priority: Int(rng.next() % 3))
        }
        let visible = CameraMath.visibleBox(pose, view: view)
        let outside = targets.filter { !visible.contains($0.point) }
        let arrows = EdgeArrows.layout(targets, pose: pose, view: view)
        #expect(arrows.count == outside.count && !arrows.isEmpty)
        let x0 = EdgeArrows.inset, x1 = view.width - EdgeArrows.inset
        let y0 = EdgeArrows.inset, y1 = view.height - EdgeArrows.inset
        for arrow in arrows {
            let p = arrow.position
            let onVertical = (abs(p.x - x0) <= 1 || abs(p.x - x1) <= 1) && p.y >= y0 - 1 && p.y <= y1 + 1
            let onHorizontal = (abs(p.y - y0) <= 1 || abs(p.y - y1) <= 1) && p.x >= x0 - 1 && p.x <= x1 + 1
            #expect(onVertical || onHorizontal, "\(p)")
            // 2 pt per texel of UI: whole multiples of 2.
            #expect(p.x.truncatingRemainder(dividingBy: 2) == 0 && p.y.truncatingRemainder(dividingBy: 2) == 0, "\(p)")
            #expect((0..<8).contains(arrow.direction))
        }
    }

    @Test func closeTargetsArePushedApart() {
        // Two targets far to the right, nearly on the same ray: alone, each would sit at y ≈ 300.
        let high = EdgeArrowTarget(id: agentID(9), point: SceneVector(4000, 10), priority: 2)
        let low = EdgeArrowTarget(id: agentID(1), point: SceneVector(4000, 0), priority: 1)
        let alone = EdgeArrows.layout([high], pose: Self.pose, view: Self.view)
        let arrows = EdgeArrows.layout([low, high], pose: Self.pose, view: Self.view)
        #expect(arrows.map(\.id) == [high.id, low.id])
        // The higher priority keeps its place.
        #expect(arrows[0].position == alone[0].position)
        // Both on the right edge, exactly `spacing` apart.
        #expect(arrows[0].position.x == 780 && arrows[1].position.x == 780)
        #expect(abs(arrows[0].position.y - arrows[1].position.y) == EdgeArrows.spacing)
        // Both still point right.
        #expect(arrows.allSatisfy { $0.direction == 2 })

        // Same priority: the lower id keeps its place.
        let a = EdgeArrowTarget(id: agentID(3), point: SceneVector(4000, 0), priority: 0)
        let b = EdgeArrowTarget(id: agentID(4), point: SceneVector(4000, 0), priority: 0)
        let tied = EdgeArrows.layout([b, a], pose: Self.pose, view: Self.view)
        #expect(tied.map(\.id) == [a.id, b.id])
        #expect(tied[0].position == SceneVector(780, 300))
        #expect(abs(tied[1].position.y - 300) == EdgeArrows.spacing)

        // Three on the same spot: none closer than `spacing` along the border.
        let three = (1...3).map { EdgeArrowTarget(id: agentID($0), point: SceneVector(0, 9000), priority: 0) }
        let row = EdgeArrows.layout(three, pose: Self.pose, view: Self.view)
        #expect(row.count == 3)
        for i in 0..<row.count {
            for j in (i + 1)..<row.count {
                #expect(abs(row[i].position.x - row[j].position.x) >= EdgeArrows.spacing, "\(row[i]) \(row[j])")
            }
        }
        #expect(row.allSatisfy { $0.position.y == 580 && $0.direction == 0 })
    }

    @Test func order() {
        let targets = [EdgeArrowTarget(id: agentID(5), point: SceneVector(-3000, 0), priority: 0),
                       EdgeArrowTarget(id: agentID(2), point: SceneVector(3000, 0), priority: 3),
                       EdgeArrowTarget(id: agentID(4), point: SceneVector(0, -3000), priority: 0),
                       EdgeArrowTarget(id: agentID(7), point: SceneVector(0, 3000), priority: 3),
                       EdgeArrowTarget(id: agentID(1), point: SceneVector(10, 20), priority: 9)]   // visible
        let arrows = EdgeArrows.layout(targets, pose: Self.pose, view: Self.view)
        // Priority first (highest first), then id.
        #expect(arrows.map(\.id) == [agentID(2), agentID(7), agentID(4), agentID(5)])
        // Same output whatever the input order.
        #expect(EdgeArrows.layout(targets.reversed(), pose: Self.pose, view: Self.view) == arrows)
        #expect(EdgeArrows.inset == 20 && EdgeArrows.spacing == 36)
    }

    @Test func followsTheCamera() {
        // The same target seen from a camera moved past it: the arrow flips side.
        let target = EdgeArrowTarget(id: agentID(1), point: SceneVector(1000, 0), priority: 0)
        let left = EdgeArrows.layout([target], pose: CameraPose(zoom: .x1, center: SceneVector(2000, 0)), view: Self.view)
        #expect(left.first?.direction == 6 && left.first?.position == SceneVector(20, 300))
        // At x2 the view covers half as many texels: a target at 300 is outside.
        let zoomed = EdgeArrows.layout([EdgeArrowTarget(id: agentID(1), point: SceneVector(300, 0), priority: 0)],
                                       pose: CameraPose(zoom: .x2, center: SceneVector(0, 0)), view: Self.view)
        #expect(zoomed.first?.direction == 2)
    }
}
