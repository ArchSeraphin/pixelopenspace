import Foundation
import Testing
@testable import PixelCore

@Suite struct AutoScrollTests {
    static let view = ViewMetrics(width: 1000, height: 700, backingScale: 2)

    private func velocity(_ x: Double, _ y: Double) -> SceneVector {
        AutoScroll.velocity(pointer: SceneVector(x, y), view: Self.view)
    }

    @Test func constants() {
        #expect(AutoScroll.band == 48 && AutoScroll.fastBand == 16)
        #expect(AutoScroll.speed == 200 && AutoScroll.fastSpeed == 600)
    }

    @Test func insideTheBandSlowTowardTheEdge() {
        #expect(velocity(47, 350) == SceneVector(-200, 0))
        #expect(velocity(1000 - 47, 350) == SceneVector(200, 0))
        // Origin bottom-left: the bottom edge is y = 0.
        #expect(velocity(500, 47) == SceneVector(0, -200))
        #expect(velocity(500, 700 - 47) == SceneVector(0, 200))
        #expect(velocity(16, 350) == SceneVector(-200, 0))
    }

    @Test func nearTheEdgeFast() {
        #expect(velocity(15, 350) == SceneVector(-600, 0))
        #expect(velocity(1000 - 15, 350) == SceneVector(600, 0))
        #expect(velocity(500, 0) == SceneVector(0, -600))
        #expect(velocity(500, 700 - 15) == SceneVector(0, 600))
    }

    @Test func outsideTheBandNothing() {
        #expect(velocity(49, 350) == SceneVector(0, 0))
        #expect(velocity(48, 350) == SceneVector(0, 0))
        #expect(velocity(500, 350) == SceneVector(0, 0))
        #expect(velocity(1000 - 49, 700 - 49) == SceneVector(0, 0))
        // The pointer left the scene: no scroll.
        #expect(velocity(-5, 350) == SceneVector(0, 0))
        #expect(velocity(500, 720) == SceneVector(0, 0))
    }

    @Test func cornerScrollsOnBothAxes() {
        #expect(velocity(10, 690) == SceneVector(-600, 600))
        #expect(velocity(1000 - 30, 20) == SceneVector(200, -200))
        #expect(velocity(40, 5) == SceneVector(-200, -600))
    }
}
