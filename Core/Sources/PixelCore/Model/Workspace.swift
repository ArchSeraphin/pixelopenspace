import Foundation

/// Claude Code permission modes accepted by `--permission-mode`
/// (https://code.claude.com/docs/en/cli-reference.md).
public enum PermissionMode: String, Codable, Sendable, CaseIterable {
    case `default`, acceptEdits, plan, auto, dontAsk, bypassPermissions
}

public struct AgentDefaults: Codable, Hashable, Sendable {
    public var model: String?
    public var permissionMode: PermissionMode
    public var templateID: PromptTemplateID?

    public init(model: String? = nil, permissionMode: PermissionMode = .default, templateID: PromptTemplateID? = nil) {
        self.model = model
        self.permissionMode = permissionMode
        self.templateID = templateID
    }
}

/// A project = a folder = an island of desks.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public let id: ProjectID
    /// Shown on the island sign (10 characters, then an ellipsis).
    public var name: String
    /// Absolute, standardized path (symlinks resolved).
    public var path: String
    /// Index into `Palette.projectHues` (0...9).
    public var hueIndex: Int
    /// Order in the sidebar and for ⌘1…⌘9. Never moves the island.
    public var order: Int
    /// World slot assigned at creation and kept for life (append-only layout).
    public var slot: Int
    /// Slots of parts 1, 2… (annexes), allocated once and kept for life like `slot` (workspace v2): `annexSlots[p − 1]`
    /// holds part p. Emptied when the project is archived. Decoded as `[]` when absent (files of version 1).
    public var annexSlots: [Int]
    public var defaults: AgentDefaults
    public var createdAt: Date
    public var archived: Bool

    public init(id: ProjectID = ProjectID(), name: String, path: String, hueIndex: Int, order: Int, slot: Int,
                defaults: AgentDefaults = AgentDefaults(), createdAt: Date, archived: Bool = false,
                annexSlots: [Int] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.hueIndex = hueIndex
        self.order = order
        self.slot = slot
        self.annexSlots = annexSlots
        self.defaults = defaults
        self.createdAt = createdAt
        self.archived = archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ProjectID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        hueIndex = try c.decode(Int.self, forKey: .hueIndex)
        order = try c.decode(Int.self, forKey: .order)
        slot = try c.decode(Int.self, forKey: .slot)
        annexSlots = try c.decodeIfPresent([Int].self, forKey: .annexSlots) ?? []
        defaults = try c.decode(AgentDefaults.self, forKey: .defaults)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        archived = try c.decode(Bool.self, forKey: .archived)
    }
}

public struct AgentLook: Codable, Hashable, Sendable {
    public var skin: Int
    public var hairStyle: Int
    public var hairColor: Int
    /// `nil` = wear the project's colour.
    public var outfitPaletteIndex: Int?
    public var accessory: Int?

    public init(skin: Int = 0, hairStyle: Int = 0, hairColor: Int = 0, outfitPaletteIndex: Int? = nil, accessory: Int? = nil) {
        self.skin = skin
        self.hairStyle = hairStyle
        self.hairColor = hairColor
        self.outfitPaletteIndex = outfitPaletteIndex
        self.accessory = accessory
    }
}

/// pid + start time of the `claude` process an agent last ran, to detect orphans after an app crash.
public struct ProcessStamp: Codable, Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// `SessionStart.source` values (https://code.claude.com/docs/en/hooks.md).
public enum SessionSource: String, Codable, Sendable {
    case startup, resume, clear, compact, fork, unknown

    public init(hookValue: String?) {
        self = hookValue.flatMap(SessionSource.init(rawValue:)) ?? .unknown
    }
}

/// One Claude Code conversation an agent has run. Appended by the `recordSession` effect.
public struct SessionRef: Codable, Hashable, Sendable {
    public var sessionID: String
    /// Working directory of `SessionStart` (the worktree with `--worktree`): `--resume` is launched here.
    /// `CwdChanged` only brings it back to the project folder (`Workspace.apply(_:agent:)`).
    public var cwd: String
    public var startedAt: Date
    public var source: SessionSource
    public var endedAt: Date?
    /// `SessionEnd.reason` (clear, resume, logout, prompt_input_exit, other) or `processExit`.
    public var endReason: String?
    public var transcriptPath: String?
    public var model: String?

    public init(sessionID: String, cwd: String, startedAt: Date, source: SessionSource,
                endedAt: Date? = nil, endReason: String? = nil, transcriptPath: String? = nil, model: String? = nil) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.startedAt = startedAt
        self.source = source
        self.endedAt = endedAt
        self.endReason = endReason
        self.transcriptPath = transcriptPath
        self.model = model
    }
}

/// An agent = a desk = one Claude Code session at a time.
public struct Agent: Codable, Identifiable, Hashable, Sendable {
    public let id: AgentID
    public var projectID: ProjectID
    /// Generated ("Nova", "Bip"…), editable.
    public var name: String
    /// Desk inside the island; stable.
    public var deskIndex: Int
    public var look: AgentLook
    /// `nil` → project default → Claude Code default.
    public var model: String?
    public var permissionMode: PermissionMode
    /// Name passed to `--worktree`, optional.
    public var worktree: String?
    /// Append-only log of conversations; the resume target is `sessions.last`.
    public var sessions: [SessionRef]
    public var lastProcess: ProcessStamp?
    /// The queue itself is derived from task cards (step 2b); only the pause flag lives here.
    public var queuePaused: Bool
    public var createdAt: Date

    public init(id: AgentID = AgentID(), projectID: ProjectID, name: String, deskIndex: Int, look: AgentLook = AgentLook(),
                model: String? = nil, permissionMode: PermissionMode = .default, worktree: String? = nil,
                sessions: [SessionRef] = [], lastProcess: ProcessStamp? = nil, queuePaused: Bool = false, createdAt: Date) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.deskIndex = deskIndex
        self.look = look
        self.model = model
        self.permissionMode = permissionMode
        self.worktree = worktree
        self.sessions = sessions
        self.lastProcess = lastProcess
        self.queuePaused = queuePaused
        self.createdAt = createdAt
    }
}

/// Persisted as `state/workspace.json`. Version 2 (step 3): `Project.annexSlots` and generated looks
/// (`Migrator.workspaceSteps`, then `PersistenceCodec.decodeWorkspace`); an older app opens it read-only.
public struct Workspace: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var projects: [Project]
    public var agents: [Agent]

    public init(schemaVersion: Int = Workspace.currentSchemaVersion, projects: [Project] = [], agents: [Agent] = []) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.agents = agents
    }
}
