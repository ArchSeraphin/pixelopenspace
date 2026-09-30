import Foundation
import PixelIPC

/// Builds `run/hooks-settings.json`, passed to `claude --settings`, which sends every subscribed hook event
/// to `pixel-hook` (proposal 5.2): synchronous `command` hooks, no `matcher` (= all), no output.
public enum HookSettingsBuilder {
    /// Shell-form command running the helper. Claude Code passes it to `sh -c`, and the app bundle path contains
    /// spaces, so the path is POSIX-quoted. `managed` appends `HookWire.managedMarker` (global install, step 5).
    public static func hookCommand(helperPath: String, managed: Bool) -> String {
        let quoted = ShellQuote.quote(helperPath)
        return managed ? quoted + " " + HookWire.managedMarker : quoted
    }

    /// `{"hooks":{"<Event>":[{"hooks":[{"type":"command","command":…,"timeout":3}]}]}}`, pretty-printed with
    /// sorted keys: the same input always gives the same bytes. `timeoutSeconds` is a ceiling (at least 1);
    /// `pixel-hook` returns in milliseconds.
    public static func settingsJSON(hookCommand: String, events: [HookEventName] = HookEventName.subscribed,
                                    timeoutSeconds: Int = 3) -> Data {
        let group = MatcherGroup(hooks: [Handler(type: "command", command: hookCommand, timeout: max(1, timeoutSeconds))])
        var hooks: [String: [MatcherGroup]] = [:]
        for event in events where !event.rawValue.isEmpty {
            hooks[event.rawValue] = [group]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Only strings and integers: encoding cannot fail.
        return try! encoder.encode(Settings(hooks: hooks))
    }

    private struct Settings: Encodable {
        var hooks: [String: [MatcherGroup]]
    }

    private struct MatcherGroup: Encodable {
        var hooks: [Handler]
    }

    private struct Handler: Encodable {
        var type: String
        var command: String
        var timeout: Int
    }
}
