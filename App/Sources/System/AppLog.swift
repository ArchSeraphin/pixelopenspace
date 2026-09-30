import OSLog

/// Unified-logging categories (Console.app, subsystem `fr.vv2.pixelopenspace`). Nothing is written to disk by the
/// app itself; hook contents are never logged, only event names and routing decisions.
enum AppLog {
    static let subsystem = "fr.vv2.pixelopenspace"

    static let model = Logger(subsystem: subsystem, category: "model")
    static let hooks = Logger(subsystem: subsystem, category: "hooks")
    static let sessions = Logger(subsystem: subsystem, category: "sessions")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let locator = Logger(subsystem: subsystem, category: "locator")
}
