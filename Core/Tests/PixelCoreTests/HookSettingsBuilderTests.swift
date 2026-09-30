import Foundation
import PixelIPC
import Testing
@testable import PixelCore

@Suite struct HookSettingsBuilderTests {
    static let bundleHelper = "/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook"
    static let marker = "--pixel-open-space-managed"

    /// Helper paths a user could really have: spaces, apostrophes, accents, shell metacharacters.
    static let awkwardPaths = [
        bundleHelper,
        "/opt/pixel/pixel-hook",
        "/Users/seraphin/Applications/L'atelier de Séraphin/Pixel Open Space.app/Contents/Helpers/pixel-hook",
        "/Volumes/Données/Café \"crème\" ☕/pixel-hook",
        "/tmp/a$HOME`id`$(echo x)\\b;|&*?[]{}~ #!/pixel hook",
        "/tmp/it's'' ''/pixel-hook",
    ]

    private func parse(_ data: Data) throws -> HookJSON {
        try HookJSON.parse(data)
    }

    @Test func commandQuotesThePathOnlyWhenNeeded() {
        #expect(HookSettingsBuilder.hookCommand(helperPath: "/opt/pixel/pixel-hook", managed: false) == "/opt/pixel/pixel-hook")
        #expect(HookSettingsBuilder.hookCommand(helperPath: Self.bundleHelper, managed: false)
                == "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'")
        #expect(HookSettingsBuilder.hookCommand(helperPath: Self.bundleHelper, managed: true)
                == "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook' --pixel-open-space-managed")
    }

    @Test func settingsHaveTheProposalShape() throws {
        let command = HookSettingsBuilder.hookCommand(helperPath: Self.bundleHelper, managed: false)
        let data = HookSettingsBuilder.settingsJSON(hookCommand: command)
        #expect(try JSONSerialization.jsonObject(with: data) is [String: Any])

        let root = try #require(try parse(data).objectValue)
        #expect(root.keys == ["hooks"])
        let hooks = try #require(root["hooks"]?.objectValue)
        #expect(Set(hooks.keys) == Set(HookEventName.subscribed.map(\.rawValue)))
        #expect(hooks.count == 19)
        for event in hooks.keys {
            let groups = try #require(hooks[event]?.arrayValue, "\(event)")
            #expect(groups.count == 1)
            // No `matcher`: all tools, all notification types.
            #expect(groups.first?.objectValue?.keys == ["hooks"])
            let handlers = try #require(groups.first?["hooks"]?.arrayValue)
            #expect(handlers.count == 1)
            let handler = try #require(handlers.first?.objectValue)
            #expect(Set(handler.keys) == ["type", "command", "timeout"])
            #expect(handler["type"] == .string("command"))
            #expect(handler["command"] == .string(command))
            #expect(handler["timeout"]?.intValue == 3)
        }
        for excluded in ["WorktreeCreate", "WorktreeRemove", "MessageDisplay", "UserPromptExpansion"] {
            #expect(hooks[excluded] == nil)
        }
    }

    @Test func outputIsDeterministicAndSorted() throws {
        let command = HookSettingsBuilder.hookCommand(helperPath: Self.bundleHelper, managed: false)
        let data = HookSettingsBuilder.settingsJSON(hookCommand: command)
        #expect(HookSettingsBuilder.settingsJSON(hookCommand: command) == data)
        #expect(HookSettingsBuilder.settingsJSON(hookCommand: command, events: HookEventName.subscribed.reversed()) == data)
        #expect(HookSettingsBuilder.settingsJSON(hookCommand: command, events: HookEventName.subscribed + [.stop]) == data)

        let hooks = try #require(try parse(data)["hooks"]?.objectValue)
        #expect(hooks.keys == hooks.keys.sorted())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n  \"hooks\""))
        // Slashes stay readable.
        #expect(text.contains("/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook"))
    }

    @Test func customEventsAndTimeout() throws {
        let data = HookSettingsBuilder.settingsJSON(hookCommand: "/bin/true", events: [.stop, .other("Setup")], timeoutSeconds: 10)
        let hooks = try #require(try parse(data)["hooks"]?.objectValue)
        #expect(hooks.keys == ["Setup", "Stop"])
        #expect(hooks["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["timeout"]?.intValue == 10)

        let clamped = HookSettingsBuilder.settingsJSON(hookCommand: "/bin/true", events: [.stop], timeoutSeconds: 0)
        #expect(try parse(clamped)["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["timeout"]?.intValue == 1)

        let empty = HookSettingsBuilder.settingsJSON(hookCommand: "/bin/true", events: [])
        #expect(try parse(empty)["hooks"] == .object(HookJSONObject()))
    }

    @Test(arguments: HookSettingsBuilderTests.awkwardPaths, [false, true])
    func commandSurvivesJSONRoundTrip(path: String, managed: Bool) throws {
        let command = HookSettingsBuilder.hookCommand(helperPath: path, managed: managed)
        let data = HookSettingsBuilder.settingsJSON(hookCommand: command)
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(decoded["hooks"] as? [String: Any])
        let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let handlers = try #require(groups.first?["hooks"] as? [[String: Any]])
        #expect(handlers.first?["command"] as? String == command)
    }

    /// Claude Code runs a shell-form command with `sh -c`: the quoted path must come back as one intact word.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/sh")),
          arguments: HookSettingsBuilderTests.awkwardPaths, [false, true])
    func commandIsOneShellWord(path: String, managed: Bool) throws {
        let command = HookSettingsBuilder.hookCommand(helperPath: path, managed: managed)
        let words = try shellWords(command)
        #expect(words == (managed ? [path, Self.marker] : [path]))
    }

    /// Splits `command` the way `sh -c` would, by letting the shell print its arguments NUL-separated.
    private func shellWords(_ command: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -- \(command); printf '%s\\0' \"$@\""]
        let output = Pipe()
        process.standardOutput = output
        try SpawnGate.run { try process.run() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }
}
