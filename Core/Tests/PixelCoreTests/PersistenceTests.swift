import Foundation
import Testing
@testable import PixelCore

@Suite struct PersistenceCodecTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000.123)

    /// Dates built from millisecond literals, as a decoded file gives them back.
    static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    static func sampleWorkspace() -> Workspace {
        var w = Workspace()
        let p = w.addProject(path: "/Users/seraphin/Projets/pixel demo", name: "Démo",
                             defaults: AgentDefaults(model: "sonnet", permissionMode: .acceptEdits), now: t0)
        let a = w.addAgent(to: p, name: "Zéphyr", worktree: "zephyr", now: at(1_790_000_001.623))!
        let sessionID = "3f6c2a9e-8d41-4b7a-9c55-1e2f7a8b9c0d"
        w.apply(.recordSession(SessionRef(sessionID: sessionID, cwd: "/Users/seraphin/Projets/pixel demo",
                                          startedAt: at(1_790_000_002.13), source: .startup,
                                          transcriptPath: "/Users/seraphin/.claude/projects/x/3f6c.jsonl", model: "sonnet")), agent: a)
        w.apply(.endSession(sessionID: sessionID, reason: "prompt_input_exit", at: at(1_790_003_601.122)), agent: a)
        w.apply(.recordProcess(ProcessStamp(pid: 4242, startedAt: at(1_790_000_001.124))), agent: a)
        w.addProject(path: "/p/archivé", now: t0)
        w.archiveProject(w.projects[1].id)
        return w
    }

    @Test func workspaceRoundTrip() throws {
        let w = Self.sampleWorkspace()
        let data = try PersistenceCodec.encodeWorkspace(w)
        let (decoded, migratedFrom) = try PersistenceCodec.decodeWorkspace(data)
        #expect(decoded == w)
        #expect(migratedFrom == nil)
        // Same input, same bytes.
        #expect(try PersistenceCodec.encodeWorkspace(decoded) == data)
    }

    @Test func outputIsPrettySortedAndReadable() throws {
        let text = String(decoding: try PersistenceCodec.encodeWorkspace(Self.sampleWorkspace()), as: UTF8.self)
        #expect(text.contains("\n  \"agents\" : ["))
        #expect(text.contains("\"createdAt\" : \"2026-09-21T14:13:20.123Z\""))
        #expect(text.contains("/Users/seraphin/Projets/pixel demo"))
        #expect(!text.contains("\\/"))
        let agentsKey = try #require(text.range(of: "\"agents\""))
        let projectsKey = try #require(text.range(of: "\"projects\""))
        let versionKey = try #require(text.range(of: "\"schemaVersion\""))
        #expect(agentsKey.lowerBound < projectsKey.lowerBound && projectsKey.lowerBound < versionKey.lowerBound)
    }

    @Test(arguments: [
        0.0, 0.001, 0.999, 1_790_000_000.123, 1_790_000_000.5, 1_790_000_000.999, -1.25, 951_782_400.042, 4_102_444_800.001,
    ])
    func datesRoundTripToTheMillisecond(_ seconds: Double) throws {
        let date = Date(timeIntervalSince1970: seconds)
        let encoded = ISO8601Millis.format(date)
        let decoded = try #require(ISO8601Millis.parse(encoded))
        #expect(decoded == date)
        #expect(ISO8601Millis.format(decoded) == encoded)
    }

    @Test func dateFormatting() {
        #expect(ISO8601Millis.format(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(ISO8601Millis.format(Date(timeIntervalSince1970: -1.25)) == "1969-12-31T23:59:58.750Z")
        // 2000-02-29 (leap day), 2100-01-01.
        #expect(ISO8601Millis.format(Date(timeIntervalSince1970: 951_782_400.042)) == "2000-02-29T00:00:00.042Z")
        #expect(ISO8601Millis.format(Date(timeIntervalSince1970: 4_102_444_800)) == "2100-01-01T00:00:00.000Z")
        // Sub-millisecond precision is rounded.
        #expect(ISO8601Millis.format(Date(timeIntervalSince1970: 10.0004)) == "1970-01-01T00:00:10.000Z")
        #expect(ISO8601Millis.format(Date(timeIntervalSince1970: 10.0006)) == "1970-01-01T00:00:10.001Z")
    }

    @Test func dateParsingVariants() throws {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(ISO8601Millis.parse("2026-09-21T14:13:20Z") == t)
        #expect(ISO8601Millis.parse("2026-09-21T16:13:20+02:00") == t)
        #expect(ISO8601Millis.parse("2026-09-21T16:13:20+0200") == t)
        #expect(ISO8601Millis.parse("2026-09-21T11:13:20-03:00") == t)
        #expect(ISO8601Millis.parse("2026-09-21T14:13:20.1Z") == Date(timeIntervalSince1970: 1_790_000_000.1))
        #expect(ISO8601Millis.parse("2026-09-21T14:13:20.123456Z") == Date(timeIntervalSince1970: 1_790_000_000.123))
        #expect(ISO8601Millis.parse("2026-09-21T14:13:20.1235Z") == Date(timeIntervalSince1970: 1_790_000_000.124))
        for bad in ["", "2026-09-21", "2026-09-21T14:13:20", "2026-13-01T00:00:00Z", "2026-09-21T14:13:20.Z",
                    "2026-09-21T14:13:20Zjunk", "21/09/2026 14:13"] {
            #expect(ISO8601Millis.parse(bad) == nil)
        }
    }

    @Test func settingsRoundTripAndDefaults() throws {
        var s = AppSettings()
        s.claudePathOverride = "/Users/seraphin/.local/bin/claude"
        s.extraEnv = ["ANTHROPIC_LOG": "debug"]
        s.notifications.hideDetails = true
        s.terminal.fontSize = 13.5
        let (decoded, from) = try PersistenceCodec.decodeSettings(try PersistenceCodec.encodeSettings(s))
        #expect(decoded == s)
        #expect(from == nil)
        #expect(try PersistenceCodec.decodeSettings(Data("{}".utf8)).settings == AppSettings())
    }

    @Test func newerSchemaIsRejectedUnlessReadOnly() throws {
        var json = String(decoding: try PersistenceCodec.encodeWorkspace(Self.sampleWorkspace()), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 7, \"decor\" : []")
        let data = Data(json.utf8)
        #expect(throws: PersistenceError.newerSchema(found: 7, supported: 1)) { try PersistenceCodec.decodeWorkspace(data) }
        let readOnly = try PersistenceCodec.decodeWorkspace(data, allowNewerSchema: true)
        #expect(readOnly.workspace.schemaVersion == 7)
        #expect(readOnly.workspace.projects.count == 2)
        #expect(throws: PersistenceError.newerSchema(found: 2, supported: 1)) {
            try PersistenceCodec.decodeSettings(Data("{\"schemaVersion\": 2}".utf8))
        }
    }

    @Test func corruptFilesThrowCorrupt() {
        for text in ["", "not json", "[1, 2]", "{\"schemaVersion\": \"one\"}", "{\"schemaVersion\": 1, \"projects\": 3}",
                     "{\"schemaVersion\": 1, \"projects\": [], \"agents\": [{\"id\": \"nope\"}]}"] {
            #expect(throws: PersistenceError.self) { try PersistenceCodec.decodeWorkspace(Data(text.utf8)) }
            do {
                _ = try PersistenceCodec.decodeWorkspace(Data(text.utf8))
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

    @Test func missingSchemaVersionReadsAsCurrent() throws {
        let (w, from) = try PersistenceCodec.decodeWorkspace(Data("{\"schemaVersion\": 1, \"projects\": [], \"agents\": []}".utf8))
        #expect(w == Workspace())
        #expect(from == nil)
        #expect(try PersistenceCodec.decodeWorkspace(Data("{\"projects\": [], \"agents\": []}".utf8)).migratedFrom == nil)
    }
}

@Suite struct MigratorTests {
    /// A fake v0 → v1 step: v0 called the agent list "desks" and had no schemaVersion inside projects.
    static let fakeStep = MigrationStep(from: 0) { object in
        var object = object
        object["agents"] = object["desks"] ?? []
        object.removeValue(forKey: "desks")
        return object
    }

    @Test func readsSchemaVersionFirst() throws {
        #expect(try Migrator.schemaVersion(of: Data("{\"schemaVersion\": 3, \"x\": {}}".utf8)) == 3)
        #expect(try Migrator.schemaVersion(of: Data("{\"x\": 1}".utf8)) == nil)
        #expect(throws: PersistenceError.self) { try Migrator.schemaVersion(of: Data("[]".utf8)) }
    }

    @Test func appliesStepsInOrderAndStampsTheVersion() throws {
        let steps = [
            MigrationStep(from: 1) { var o = $0; o["trail"] = ((o["trail"] as? [String]) ?? []) + ["1→2"]; return o },
            MigrationStep(from: 0) { var o = $0; o["trail"] = ((o["trail"] as? [String]) ?? []) + ["0→1"]; return o },
        ]
        let migrated = try Migrator.migrate(["schemaVersion": 0], from: 0, to: 2, steps: steps)
        #expect(migrated["trail"] as? [String] == ["0→1", "1→2"])
        #expect(migrated["schemaVersion"] as? Int == 2)
        let unchanged = try Migrator.migrate(["a": 1], from: 2, to: 2, steps: steps)
        #expect(unchanged["a"] as? Int == 1 && unchanged["schemaVersion"] == nil)
    }

    @Test func missingOrFailingStepIsCorrupt() {
        #expect(throws: PersistenceError.self) { try Migrator.migrate([:], from: 0, to: 1, steps: []) }
        let failing = MigrationStep(from: 0) { _ in throw CocoaError(.featureUnsupported) }
        #expect(throws: PersistenceError.self) { try Migrator.migrate([:], from: 0, to: 1, steps: [failing]) }
        #expect(throws: PersistenceError.newerSchema(found: 3, supported: 1)) {
            try Migrator.migrate([:], from: 3, to: 1, steps: [])
        }
    }

    @Test func workspaceV0MigratesThroughTheCodec() throws {
        let v0 = """
        {"schemaVersion": 0,
         "projects": [{"id": "6E0B1C38-8C5A-4B1B-9E0C-1A2B3C4D5E6F", "name": "API", "path": "/p/api", "hueIndex": 2,
                       "order": 0, "slot": 0, "defaults": {"permissionMode": "default"},
                       "createdAt": "2026-09-21T14:13:20Z", "archived": false}],
         "desks": [{"id": "0B7F4C1E-2D3A-4E5F-8A9B-0C1D2E3F4A5B", "projectID": "6E0B1C38-8C5A-4B1B-9E0C-1A2B3C4D5E6F",
                    "name": "Nova", "deskIndex": 0, "look": {"skin": 0, "hairStyle": 0, "hairColor": 0},
                    "permissionMode": "plan", "sessions": [], "queuePaused": false,
                    "createdAt": "2026-09-21T14:13:20.5Z"}]}
        """
        let (w, from) = try PersistenceCodec.decodeWorkspace(Data(v0.utf8), migrations: [Self.fakeStep])
        #expect(from == 0)
        #expect(w.schemaVersion == 1)
        #expect(w.agents.map(\.name) == ["Nova"])
        #expect(w.agents[0].permissionMode == .plan)
        #expect(w.agents[0].createdAt == Date(timeIntervalSince1970: 1_790_000_000.5))
        // Without the step, a v0 file cannot be read.
        #expect(throws: PersistenceError.self) { try PersistenceCodec.decodeWorkspace(Data(v0.utf8)) }
    }

    @Test func registeredStepsCoverEveryOlderVersion() {
        for version in 1..<Workspace.currentSchemaVersion {
            #expect(Migrator.workspaceSteps.contains { $0.from == version })
        }
        for version in 1..<AppSettings.currentSchemaVersion {
            #expect(Migrator.settingsSteps.contains { $0.from == version })
        }
    }
}

@Suite struct WorkspaceValidatorTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func validWorkspaceIsUntouched() {
        let w = PersistenceCodecTests.sampleWorkspace()
        let (fixed, issues) = WorkspaceValidator.validate(w)
        #expect(fixed == w)
        #expect(issues.isEmpty)
    }

    @Test func repairsBrokenInvariants() throws {
        let p1 = Project(name: "A", path: "/a", hueIndex: 12, order: 0, slot: 0, createdAt: Self.t0)
        let p2 = Project(name: "B", path: "/b", hueIndex: -1, order: 1, slot: 0, createdAt: Self.t0)
        let p3 = Project(name: "C", path: "/c", hueIndex: 3, order: 2, slot: -4, createdAt: Self.t0)
        let archived = Project(name: "Old", path: "/old", hueIndex: 3, order: 3, slot: 0, createdAt: Self.t0, archived: true)
        var dupProject = p1
        dupProject.name = "A bis"
        let a1 = Agent(projectID: p1.id, name: "Nova", deskIndex: 0, createdAt: Self.t0)
        let a2 = Agent(projectID: p1.id, name: "Bip", deskIndex: 0, createdAt: Self.t0)
        let a3 = Agent(projectID: p1.id, name: "Lune", deskIndex: -2, createdAt: Self.t0)
        let a4 = Agent(projectID: p2.id, name: "Kiwi", deskIndex: 0, createdAt: Self.t0)
        let orphan = Agent(projectID: ProjectID(), name: "Perdu", deskIndex: 0, createdAt: Self.t0)
        var dupAgent = a4
        dupAgent.name = "Kiwi bis"
        let w = Workspace(projects: [p1, p2, p3, archived, dupProject], agents: [a1, a2, a3, a4, orphan, dupAgent])

        let (fixed, issues) = WorkspaceValidator.validate(w)
        #expect(fixed.projects.map(\.name) == ["A", "B", "C", "Old"])
        #expect(fixed.projects.map(\.hueIndex) == [9, 0, 3, 3])
        #expect(fixed.projects.map(\.slot) == [0, 1, 2, 0])
        #expect(fixed.agents.map(\.name) == ["Nova", "Bip", "Lune", "Kiwi"])
        #expect(fixed.agents.map(\.deskIndex) == [0, 1, 2, 0])
        #expect(issues.count == 9)
        #expect(issues.allSatisfy { !$0.isEmpty })

        // Idempotent.
        let (again, noIssues) = WorkspaceValidator.validate(fixed)
        #expect(again == fixed)
        #expect(noIssues.isEmpty)
    }

    @Test func agentsOfArchivedProjectsAreKept() throws {
        var w = Workspace()
        let p = w.addProject(path: "/p", now: Self.t0)
        let added = w.addAgent(to: p, now: Self.t0)
        _ = try #require(added)
        w.archiveProject(p)
        #expect(WorkspaceValidator.validate(w).workspace.agents.count == 1)
    }
}
