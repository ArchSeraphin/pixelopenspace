import Foundation
import Testing
@testable import PixelCore

@Suite struct CameraFlightTests {
    static let from = SceneVector(-120.5, 40)
    static let to = SceneVector(300.25, -260)
    static let flight = CameraFlight(from: from, to: to, start: 10)

    @Test func departure() {
        let flight = Self.flight
        #expect(CameraFlight.duration == 0.4)
        #expect(flight.position(at: 10) == Self.from)
        #expect(flight.position(at: 3) == Self.from)
        #expect(!flight.isFinished(at: 10))
    }

    @Test func arrival() {
        let flight = Self.flight
        #expect(flight.position(at: 10.4) == Self.to)
        #expect(flight.position(at: 99) == Self.to)
        #expect(flight.isFinished(at: 10.4) && flight.isFinished(at: 11))
        #expect(!flight.isFinished(at: 10.39))
    }

    @Test func symmetricAroundTheMiddle() {
        let flight = Self.flight
        let mid = flight.position(at: 10.2)
        #expect(abs(mid.x - (Self.from.x + Self.to.x) / 2) < 1e-9 && abs(mid.y - (Self.from.y + Self.to.y) / 2) < 1e-9)
        // Ease-in-out: what is done after t is what remains before duration − t.
        for k in 1..<20 {
            let t = 0.4 * Double(k) / 20
            let early = flight.position(at: 10 + t), late = flight.position(at: 10.4 - t)
            #expect(abs((early.x - Self.from.x) - (Self.to.x - late.x)) < 1e-9)
            #expect(abs((early.y - Self.from.y) - (Self.to.y - late.y)) < 1e-9)
        }
        // Slow start, slow end: the first tenth covers far less than a tenth of the way.
        let first = flight.position(at: 10.04)
        #expect(abs(first.x - Self.from.x) < 0.02 * abs(Self.to.x - Self.from.x))
    }

    @Test func monotone() {
        let flight = Self.flight
        var previous = flight.position(at: 9.9)
        for k in 0...120 {
            let p = flight.position(at: 9.9 + Double(k) * 0.005)
            #expect(p.x >= previous.x, "x goes toward the right")
            #expect(p.y <= previous.y, "y goes down")
            previous = p
        }
    }

    @Test func zeroDurationIsDoneAtOnce() {
        let flight = CameraFlight(from: Self.from, to: Self.to, start: 5, duration: 0)
        #expect(flight.isFinished(at: 5) && flight.isFinished(at: 4))
        #expect(flight.position(at: 5) == Self.to && flight.position(at: 4) == Self.to)
    }

    @Test func customDuration() {
        let flight = CameraFlight(from: SceneVector(0, 0), to: SceneVector(100, 0), start: 0, duration: 2)
        #expect(abs(flight.position(at: 1).x - 50) < 1e-9)
        #expect(!flight.isFinished(at: 1.9) && flight.isFinished(at: 2))
    }
}
