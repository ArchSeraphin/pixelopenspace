import Foundation
import Testing
@testable import PixelCore

/// VoiceOver announcements (7.9): only waits and errors, grouped over 2 s, waits first.
@Suite struct AnnouncementBatcherTests {
    /// The first announcement opens a batch and gives the time to flush it; the next ones join it.
    @Test func groupsOverTwoSeconds() {
        var batcher = AnnouncementBatcher()
        #expect(batcher.add(.waiting, agentName: "Nova", time: 10) == 12)
        #expect(batcher.add(.waiting, agentName: "Sol", time: 10.5) == nil)
        #expect(batcher.add(.waiting, agentName: "Ivo", time: 11.9) == nil)
        #expect(batcher.flush(time: 12) == "3 agents attendent ta réponse")
        // A new batch after the flush, with its own window.
        #expect(batcher.add(.error, agentName: "Zéphyr", time: 13) == 15)
        #expect(batcher.flush(time: 15) == "Zéphyr est en erreur")
        // Another window.
        var slow = AnnouncementBatcher(window: 0.5)
        #expect(slow.add(.waiting, agentName: "Nova", time: 1) == 1.5)
    }

    @Test func singularAndPlural() {
        var one = AnnouncementBatcher()
        _ = one.add(.waiting, agentName: "Nova", time: 0)
        #expect(one.flush(time: 2) == "Nova attend ta réponse")
        var two = AnnouncementBatcher()
        _ = two.add(.waiting, agentName: "Nova", time: 0)
        _ = two.add(.waiting, agentName: "Sol", time: 1)
        #expect(two.flush(time: 2) == "2 agents attendent ta réponse")
        var errors = AnnouncementBatcher()
        _ = errors.add(.error, agentName: "Zéphyr", time: 0)
        _ = errors.add(.error, agentName: "Lune", time: 0.1)
        #expect(errors.flush(time: 2) == "2 agents sont en erreur")
        // The same agent twice in a batch counts once.
        var twice = AnnouncementBatcher()
        _ = twice.add(.waiting, agentName: "Nova", time: 0)
        _ = twice.add(.waiting, agentName: "Nova", time: 1)
        #expect(twice.flush(time: 2) == "Nova attend ta réponse")
    }

    /// Waits come first, whatever the order they arrived in.
    @Test func waitsBeforeErrors() {
        var batcher = AnnouncementBatcher()
        #expect(batcher.add(.error, agentName: "Zéphyr", time: 0) == 2)
        #expect(batcher.add(.waiting, agentName: "Nova", time: 0.3) == nil)
        #expect(batcher.flush(time: 2) == "Nova attend ta réponse ; Zéphyr est en erreur")
        var many = AnnouncementBatcher()
        _ = many.add(.error, agentName: "Zéphyr", time: 0)
        _ = many.add(.error, agentName: "Lune", time: 0)
        _ = many.add(.waiting, agentName: "Nova", time: 0)
        _ = many.add(.waiting, agentName: "Sol", time: 0)
        _ = many.add(.waiting, agentName: "Ivo", time: 0)
        #expect(many.flush(time: 2) == "3 agents attendent ta réponse ; 2 agents sont en erreur")
        #expect(AnnouncementKind.waiting < AnnouncementKind.error)
    }

    /// Nothing after a flush; nothing before the batch is due; nothing when nothing was added.
    @Test func nothingAfterAFlush() {
        var batcher = AnnouncementBatcher()
        #expect(batcher.flush(time: 0) == nil)
        _ = batcher.add(.waiting, agentName: "Nova", time: 10)
        #expect(batcher.flush(time: 11) == nil, "not due yet")
        #expect(batcher.flush(time: 12) == "Nova attend ta réponse")
        #expect(batcher.flush(time: 12) == nil)
        #expect(batcher.flush(time: 30) == nil)
    }
}
