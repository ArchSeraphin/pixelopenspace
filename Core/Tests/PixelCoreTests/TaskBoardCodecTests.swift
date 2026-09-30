import Foundation
import Testing
@testable import PixelCore

@Suite struct TaskBoardCodecTests {
    typealias S = TaskBoardSamples

    @Test func roundTrip() throws {
        let board = S.board()
        let data = try PersistenceCodec.encodeTasks(board)
        let (decoded, migratedFrom) = try PersistenceCodec.decodeTasks(data)
        #expect(decoded == board)
        #expect(migratedFrom == nil)
    }

    @Test func outputIsSortedAndStable() throws {
        let board = S.board()
        let first = try PersistenceCodec.encodeTasks(board)
        let second = try PersistenceCodec.encodeTasks(board)
        #expect(first == second)
        // Decoding gives back the same bytes (a Set of flags never reorders the file).
        #expect(try PersistenceCodec.encodeTasks(try PersistenceCodec.decodeTasks(first).board) == first)

        let text = String(decoding: first, as: UTF8.self)
        let cardsKey = try #require(text.range(of: "\"cards\""))
        let instructionsKey = try #require(text.range(of: "\"instructions\""))
        let versionKey = try #require(text.range(of: "\"schemaVersion\""))
        let templatesKey = try #require(text.range(of: "\"templates\""))
        #expect(cardsKey.lowerBound < instructionsKey.lowerBound)
        #expect(instructionsKey.lowerBound < versionKey.lowerBound)
        #expect(versionKey.lowerBound < templatesKey.lowerBound)
        #expect(text.contains("\"createdAt\" : \"2026-09-21T14:13:21.123Z\""))
        #expect(text.contains("\"column\" : \"inProgress\""))
        #expect(text.contains("\"priority\" : 2"))
        #expect(text.contains("Pagination /users"))
        // Flags in declaration order, whatever the Set's order.
        let background = try #require(text.range(of: "\"backgroundRunning\""))
        let interrupted = try #require(text.range(of: "\"interrupted\""))
        #expect(interrupted.lowerBound < background.lowerBound)
    }

    @Test func flagsAreWrittenInDeclarationOrder() throws {
        var board = TaskBoardState()
        board.cards = [TaskCard(id: S.card(1), title: "Drapeaux", projectID: nil, column: .inProgress, rank: "i",
                                flags: Set(CardFlag.allCases), createdAt: S.t0)]
        let text = String(decoding: try PersistenceCodec.encodeTasks(board), as: UTF8.self)
        let positions = try CardFlag.allCases.map { flag in
            try #require(text.range(of: "\"\(flag.rawValue)\"")).lowerBound
        }
        #expect(positions == positions.sorted())
    }

    @Test func newerSchemaThrows() throws {
        var json = String(decoding: try PersistenceCodec.encodeTasks(S.board()), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2, \"boards\" : []")
        let data = Data(json.utf8)
        #expect(throws: PersistenceError.newerSchema(found: 2, supported: 1)) { try PersistenceCodec.decodeTasks(data) }
    }

    @Test func newerSchemaDecodesReadOnly() throws {
        var json = String(decoding: try PersistenceCodec.encodeTasks(S.board()), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2, \"boards\" : []")
        let (board, migratedFrom) = try PersistenceCodec.decodeTasks(Data(json.utf8), allowNewerSchema: true)
        #expect(board.schemaVersion == 2)
        #expect(board.cards.count == 5)
        #expect(migratedFrom == nil)
    }

    @Test func corruptThrows() {
        for text in ["[1,2", "", "not json", "[1, 2]", "{\"schemaVersion\": \"one\"}", "{\"schemaVersion\": 1, \"cards\": 3}",
                     "{\"schemaVersion\": 1, \"cards\": [{\"id\": \"nope\"}]}"] {
            do {
                _ = try PersistenceCodec.decodeTasks(Data(text.utf8))
                Issue.record("Expected corrupt for \(text)")
            } catch let error as PersistenceError {
                guard case .corrupt(let message) = error else {
                    Issue.record("Expected corrupt for \(text), got \(error)")
                    continue
                }
                #expect(!message.isEmpty)
            } catch {
                Issue.record("Unexpected error \(error)")
            }
        }
    }

    @Test func missingOptionalFieldsTakeTheirDefaults() throws {
        let minimal = """
        {"schemaVersion": 1,
         "cards": [{"id": "00000000-0000-0000-0000-000000000001", "title": "Pagination /users",
                    "column": "todo", "rank": "i", "createdAt": "2026-09-21T14:13:20.123Z"}]}
        """
        let (board, _) = try PersistenceCodec.decodeTasks(Data(minimal.utf8))
        #expect(board.instructions.isEmpty && board.templates.isEmpty)
        let card = try #require(board.cards.first)
        #expect(card.id == S.card(1))
        #expect(card.title == "Pagination /users")
        #expect(card.details == "")
        #expect(card.tags.isEmpty && card.flags.isEmpty && card.history.isEmpty)
        #expect(card.priority == .normal)
        #expect(!card.validatedOnce)
        #expect(card.projectID == nil && card.assignee == nil && card.queueRank == nil)
        #expect(card.templateID == nil && card.delivery == nil)
        #expect(card.createdAt == S.t0)
        #expect(card.updatedAt == card.createdAt)
    }

    @Test func emptyAndHeaderOnlyFilesDecode() throws {
        #expect(try PersistenceCodec.decodeTasks(Data("{\"schemaVersion\": 1}".utf8)).board == TaskBoardState())
        // Without schemaVersion: read as the current version.
        let (board, from) = try PersistenceCodec.decodeTasks(Data("{\"cards\": [], \"templates\": []}".utf8))
        #expect(board == TaskBoardState())
        #expect(from == nil)
    }

    @Test func unknownFlagsAreIgnored() throws {
        let json = """
        {"schemaVersion": 1,
         "cards": [{"id": "00000000-0000-0000-0000-000000000001", "title": "t", "column": "inProgress", "rank": "i",
                    "flags": ["interrupted", "somethingLater"], "createdAt": "2026-09-21T14:13:20.123Z"}]}
        """
        let card = try #require(try PersistenceCodec.decodeTasks(Data(json.utf8)).board.cards.first)
        #expect(card.flags == [.interrupted])
    }

    @Test func olderVersionsMigrateThroughTheCodec() throws {
        // A fake v0 → v1 step: v0 called the cards "notes".
        let step = MigrationStep(from: 0) { object in
            var object = object
            object["cards"] = object["notes"] ?? []
            object.removeValue(forKey: "notes")
            return object
        }
        let v0 = """
        {"schemaVersion": 0,
         "notes": [{"id": "00000000-0000-0000-0000-000000000001", "title": "Ancienne", "column": "done", "rank": "i",
                    "createdAt": "2026-09-21T14:13:20.123Z"}]}
        """
        let (board, from) = try PersistenceCodec.decodeTasks(Data(v0.utf8), migrations: [step])
        #expect(from == 0)
        #expect(board.schemaVersion == 1)
        #expect(board.cards.map(\.title) == ["Ancienne"])
        #expect(throws: PersistenceError.self) { try PersistenceCodec.decodeTasks(Data(v0.utf8)) }
    }

    @Test func registeredStepsCoverEveryOlderVersion() {
        for version in 1..<TaskBoardState.currentSchemaVersion {
            #expect(Migrator.tasksSteps.contains { $0.from == version })
        }
        #expect(Migrator.tasksSteps.isEmpty)
    }
}
