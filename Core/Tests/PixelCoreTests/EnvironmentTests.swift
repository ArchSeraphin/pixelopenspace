import Foundation
import Testing
@testable import PixelCore

@Suite struct EnvSanitizerTests {
    @Test func removesTerminalClaudeAndShellVariables() {
        let removed = [
            "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID",
            "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE",
            "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "WEZTERM_PANE", "LC_TERMINAL", "TMUX",
            "__CFBundleIdentifier", "XPC_SERVICE_NAME", "PWD", "OLDPWD", "SHLVL", "_",
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "PIXEL_AGENT_ID", "PIXEL_HOOK_TOKEN", "PIXEL_RESOLVING_ENVIRONMENT",
        ]
        var env = Dictionary(uniqueKeysWithValues: removed.map { ($0, "x") })
        env["PATH"] = LaunchFixtures.path
        env["HOME"] = "/Users/seraphin"
        env["CLAUDE_CODE_USE_BEDROCK"] = "1"
        env["ANTHROPIC_API_KEY"] = "sk"
        env["TERM"] = "xterm-kitty"
        env["NVM_DIR"] = "/Users/seraphin/Library/Application Support/Herd/config/nvm"
        let clean = EnvSanitizer.sanitize(env)
        #expect(clean == [
            "PATH": LaunchFixtures.path,
            "HOME": "/Users/seraphin",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "ANTHROPIC_API_KEY": "sk",
            "TERM": "xterm-kitty",
            "NVM_DIR": "/Users/seraphin/Library/Application Support/Herd/config/nvm",
        ])
    }

    @Test func pathWithSpacesIsKeptVerbatim() {
        let clean = EnvSanitizer.sanitize(["PATH": LaunchFixtures.path])
        #expect(clean["PATH"] == LaunchFixtures.path)
        #expect(clean["PATH"]!.split(separator: ":").contains(Substring(LaunchFixtures.herdNode)))
    }

    @Test func dropsEntriesExecveCannotCarry() {
        let clean = EnvSanitizer.sanitize(["": "a", "A=B": "c", "OK": "v", "NUL": "x\0y", "N\0": "z"])
        #expect(clean == ["OK": "v"])
    }
}

@Suite struct LoginShellEnvironmentTests {
    static let marker = "a1b2c3d4e5f6a7b8"

    @Test func commandForZshBashAndFish() {
        for shell in ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/fish"] {
            let (executable, arguments) = LoginShellEnvironment.command(shell: shell, marker: Self.marker)
            #expect(executable == shell)
            #expect(Array(arguments.prefix(3)) == ["-i", "-l", "-c"])
            #expect(arguments.count == 4)
            let script = arguments[3]
            #expect(script.contains("/usr/bin/env -0"))
            // Printed in two halves: the command text itself never contains the marker.
            #expect(!script.contains(Self.marker))
            #expect(script.contains("a1b2c3d4") && script.contains("e5f6a7b8"))
        }
    }

    @Test func commandForCshAndUnknownShell() {
        let tcsh = LoginShellEnvironment.command(shell: "/bin/tcsh", marker: Self.marker)
        #expect(tcsh.arguments.first == "-c")
        #expect(tcsh.arguments.count == 2)
        #expect(LoginShellEnvironment.command(shell: "", marker: Self.marker).executable == "/bin/zsh")
        #expect(LoginShellEnvironment.command(shell: "zsh", marker: Self.marker).executable == "/bin/zsh")
        #expect(LoginShellEnvironment.resolvingFlag == "PIXEL_RESOLVING_ENVIRONMENT")
    }

    @Test func parseTakesBytesBetweenTheFirstTwoMarkers() throws {
        var output = Data("Last login: Tue\nWelcome to zsh! \(Self.marker.prefix(4))\n".utf8)
        output += Data(Self.marker.utf8)
        output += Data("PATH=\(LaunchFixtures.path)\0HOME=/Users/seraphin\0EMPTY=\0EQ=a=b=c\0MULTI=line1\nline2\0malformed\0=novalue\0".utf8)
        output += Data(Self.marker.utf8)
        output += Data("bye\n\(Self.marker)\nTRAILING=1\0".utf8)
        let env = try #require(LoginShellEnvironment.parse(output, marker: Self.marker))
        #expect(env == [
            "PATH": LaunchFixtures.path,
            "HOME": "/Users/seraphin",
            "EMPTY": "",
            "EQ": "a=b=c",
            "MULTI": "line1\nline2",
        ])
    }

    @Test func parseSkipsInvalidUTF8() throws {
        var output = Data(Self.marker.utf8)
        output += Data("GOOD=1\0".utf8) + Data([0x42, 0x41, 0x44, 0x3D, 0xFF, 0xFE, 0x00]) + Data(Self.marker.utf8)
        #expect(LoginShellEnvironment.parse(output, marker: Self.marker) == ["GOOD": "1"])
    }

    @Test func parseFailsWithoutBothMarkers() {
        #expect(LoginShellEnvironment.parse(Data("PATH=/bin\0".utf8), marker: Self.marker) == nil)
        #expect(LoginShellEnvironment.parse(Data((Self.marker + "PATH=/bin\0").utf8), marker: Self.marker) == nil)
        #expect(LoginShellEnvironment.parse(Data((Self.marker + Self.marker).utf8), marker: Self.marker) == nil)
        #expect(LoginShellEnvironment.parse(Data(), marker: Self.marker) == nil)
        #expect(LoginShellEnvironment.parse(Data("x".utf8), marker: "") == nil)
    }

    /// End to end with the local `/bin/sh`: what the app does on macOS with the account's shell.
    @Test func realShellRoundTrip() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/env") else { return }
        let (executable, arguments) = LoginShellEnvironment.command(shell: "/bin/sh", marker: Self.marker)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // `sh -i -l` is not portable to every /bin/sh: keep only the script for this check.
        process.arguments = ["-c", arguments.last!]
        process.environment = ["PATH": LaunchFixtures.path + ":/usr/bin:/bin", "SPACED": "a b  c", "HOME": "/tmp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let env = try #require(LoginShellEnvironment.parse(data, marker: Self.marker))
        #expect(env["PATH"] == LaunchFixtures.path + ":/usr/bin:/bin")
        #expect(env["SPACED"] == "a b  c")
    }
}
