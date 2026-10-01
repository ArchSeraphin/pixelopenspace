import Foundation

// The words shared by the scene presenter, the sprite sets and the compositor (7.4).

/// The 14 character animations of 7.4.4.
public enum CharacterAnimation: String, CaseIterable, Codable, Sendable {
    case stand, walk, sitDown, sitIdle, type, think, stretch, coffee, sleep, raiseHand, celebrate, grab, cough, wave

    /// Frames per direction (7.4.4): 48 drawn toward SE, 44 toward NE.
    public var framesPerFacing: Int {
        switch self {
        case .stand, .sitDown, .sitIdle, .think, .sleep, .wave: return 2
        case .walk, .type, .coffee, .raiseHand, .grab, .cough: return 4
        case .stretch, .celebrate: return 6
        }
    }

    /// Frames per second, always an allowed cadence of `AnimationClock`.
    public var fps: Double {
        switch self {
        case .stand, .sitIdle, .think: return 2
        case .walk, .sitDown, .celebrate, .grab: return 8
        case .type: return 12
        case .stretch, .raiseHand, .cough: return 6
        case .coffee, .wave: return 4
        case .sleep: return 1.5
        }
    }

    /// One-shot animations play once and hold their last frame.
    public var loops: Bool {
        switch self {
        case .stand, .walk, .sitIdle, .type, .think, .sleep, .raiseHand, .cough: return true
        case .sitDown, .stretch, .coffee, .celebrate, .grab, .wave: return false
        }
    }

    /// Ticks per frame at 24 ticks per second.
    public var holds: [Int] { AnimationClock.holds(fps: fps, frames: framesPerFacing) }

    /// Directions drawn by hand; the others are reshaded mirrors. raiseHand only exists toward the viewer.
    public var drawnFacings: [Facing] { self == .raiseHand ? [.se] : [.se, .ne] }

    /// Every direction of the sprite sheet: drawn ones first, then their mirrors.
    public var facings: [Facing] { self == .raiseHand ? [.se, .sw] : [.se, .ne, .sw, .nw] }

    /// "agent.<rawValue>".
    public var spriteID: SpriteID { SpriteID("agent.\(rawValue)") }
}

/// What a monitor shows (7.4.3): screen content of row A, LED of row B.
public enum ScreenState: String, CaseIterable, Codable, Sendable {
    case off, boot, idle, thinking, working, waiting, done, error, quota, background

    public var frames: Int {
        switch self {
        case .off, .done: return 1
        case .idle, .waiting, .quota: return 2
        case .thinking, .error, .background: return 3
        case .boot, .working: return 4
        }
    }

    /// Frames per second; 0 for a still screen (one frame).
    public var fps: Double {
        switch self {
        case .off, .done: return 0
        case .boot, .working, .error: return 8
        case .idle, .quota: return 1
        case .thinking, .waiting: return 4
        case .background: return 2
        }
    }

    /// Ticks per frame; [] for a still screen.
    public var holds: [Int] { AnimationClock.holds(fps: fps, frames: frames) }

    /// "screen.<rawValue>".
    public var spriteID: SpriteID { SpriteID("screen.\(rawValue)") }
}

/// The primary overlay above an agent's head (7.4.5).
public enum OverlayKind: String, CaseIterable, Codable, Sendable {
    case bang, dots, tool, zzz, storm, check, background, quota
}

/// The icon in the tool bubble: leaf, pencil, `>_`, magnifier, globe, mini figure, plug, "?", gear.
public enum ToolIcon: String, CaseIterable, Codable, Sendable {
    case read, edit, bash, search, web, subagent, mcp, question, other

    public init(_ tool: ToolKind) {
        switch tool {
        case .read: self = .read
        case .edit: self = .edit
        case .bash: self = .bash
        case .search: self = .search
        case .web: self = .web
        case .subagent: self = .subagent
        case .question: self = .question
        case .mcp: self = .mcp
        case .other: self = .other
        }
    }

    /// "ov.tool.<rawValue>".
    public var spriteID: SpriteID { SpriteID("ov.tool.\(rawValue)") }
}

/// Small signs shown beside an agent, in this order: no news, draft in the input box, degraded mode,
/// bypassPermissions, external session.
public enum SceneBadge: String, CaseIterable, Codable, Sendable {
    case stale, draft, degraded, unsafe, external

    /// "ov.<rawValue>".
    public var spriteID: SpriteID { SpriteID("ov.\(rawValue)") }
}
