import Foundation

public enum NightMode: String, Codable, Sendable {
    case followSystem, alwaysDay, alwaysNight
}

public struct NotificationPrefs: Codable, Hashable, Sendable {
    /// Always post a macOS notification when an agent starts waiting, even with the app in front (decision 18).
    public var waitingAlways: Bool
    /// Post "turn done" and error notifications only when the app is in the background.
    public var turnDoneWhenInBackground: Bool
    /// Replace commands and paths by a generic text (lock screen, Notification Center).
    public var hideDetails: Bool

    public init(waitingAlways: Bool = true, turnDoneWhenInBackground: Bool = true, hideDetails: Bool = false) {
        self.waitingAlways = waitingAlways
        self.turnDoneWhenInBackground = turnDoneWhenInBackground
        self.hideDetails = hideDetails
    }
}

public struct SoundPrefs: Codable, Hashable, Sendable {
    public var muted: Bool
    public var volume: Double
    public var waiting: Bool
    public var turnDone: Bool
    public var others: Bool

    public init(muted: Bool = false, volume: Double = 0.3, waiting: Bool = true, turnDone: Bool = true, others: Bool = false) {
        self.muted = muted
        self.volume = volume
        self.waiting = waiting
        self.turnDone = turnDone
        self.others = others
    }
}

public struct TerminalPrefs: Codable, Hashable, Sendable {
    public var fontName: String?
    public var fontSize: Double
    public var optionAsMeta: Bool
    public var scrollback: Int

    public init(fontName: String? = nil, fontSize: Double = 12, optionAsMeta: Bool = false, scrollback: Int = 2_000) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.optionAsMeta = optionAsMeta
        self.scrollback = scrollback
    }
}

/// Persisted as `state/settings.json`. Every field has a default so older files decode.
public struct AppSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = AppSettings.currentSchemaVersion
    public var claudePathOverride: String?
    public var defaultModel: String?
    public var defaultPermissionMode: PermissionMode = .default
    public var disableAgentViewInEmbedded: Bool = true
    public var forceClassicRenderer: Bool = false
    public var disableNonessentialTraffic: Bool = false
    public var extraEnv: [String: String] = [:]
    public var autoChainQueue: Bool = true
    public var sendGraceSeconds: Double = 1.5
    public var stopQuietWindowSeconds: Double = 3
    public var quickAnswerHeuristics: Bool = true
    public var notifications: NotificationPrefs = NotificationPrefs()
    public var sounds: SoundPrefs = SoundPrefs()
    public var gamificationEnabled: Bool = true
    public var nightMode: NightMode = .followSystem
    public var defaultZoom: Int = 2
    public var reduceMotion: Bool = false
    public var terminal: TerminalPrefs = TerminalPrefs()
    public var eventLogEnabled: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, claudePathOverride, defaultModel, defaultPermissionMode, disableAgentViewInEmbedded,
             forceClassicRenderer, disableNonessentialTraffic, extraEnv, autoChainQueue, sendGraceSeconds,
             stopQuietWindowSeconds, quickAnswerHeuristics, notifications, sounds, gamificationEnabled, nightMode,
             defaultZoom, reduceMotion, terminal, eventLogEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        claudePathOverride = try c.decodeIfPresent(String.self, forKey: .claudePathOverride)
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultPermissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .defaultPermissionMode) ?? d.defaultPermissionMode
        disableAgentViewInEmbedded = try c.decodeIfPresent(Bool.self, forKey: .disableAgentViewInEmbedded) ?? d.disableAgentViewInEmbedded
        forceClassicRenderer = try c.decodeIfPresent(Bool.self, forKey: .forceClassicRenderer) ?? d.forceClassicRenderer
        disableNonessentialTraffic = try c.decodeIfPresent(Bool.self, forKey: .disableNonessentialTraffic) ?? d.disableNonessentialTraffic
        extraEnv = try c.decodeIfPresent([String: String].self, forKey: .extraEnv) ?? d.extraEnv
        autoChainQueue = try c.decodeIfPresent(Bool.self, forKey: .autoChainQueue) ?? d.autoChainQueue
        sendGraceSeconds = try c.decodeIfPresent(Double.self, forKey: .sendGraceSeconds) ?? d.sendGraceSeconds
        stopQuietWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .stopQuietWindowSeconds) ?? d.stopQuietWindowSeconds
        quickAnswerHeuristics = try c.decodeIfPresent(Bool.self, forKey: .quickAnswerHeuristics) ?? d.quickAnswerHeuristics
        notifications = try c.decodeIfPresent(NotificationPrefs.self, forKey: .notifications) ?? d.notifications
        sounds = try c.decodeIfPresent(SoundPrefs.self, forKey: .sounds) ?? d.sounds
        gamificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .gamificationEnabled) ?? d.gamificationEnabled
        nightMode = try c.decodeIfPresent(NightMode.self, forKey: .nightMode) ?? d.nightMode
        defaultZoom = try c.decodeIfPresent(Int.self, forKey: .defaultZoom) ?? d.defaultZoom
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? d.reduceMotion
        terminal = try c.decodeIfPresent(TerminalPrefs.self, forKey: .terminal) ?? d.terminal
        eventLogEnabled = try c.decodeIfPresent(Bool.self, forKey: .eventLogEnabled) ?? d.eventLogEnabled
    }
}
