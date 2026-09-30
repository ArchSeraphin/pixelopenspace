import Foundation
import Testing
@testable import PixelCore

@Suite struct ClaudeLocatorTests {
    static let home = "/Users/seraphin"

    @Test func candidatesInOrderWithoutDuplicates() {
        let candidates = ClaudeLocatorPlan.candidates(override: "~/bin/claude-dev", pathEnv: LaunchFixtures.path, home: Self.home)
        #expect(candidates == [
            "/Users/seraphin/bin/claude-dev",
            "/Users/seraphin/.local/bin/claude",
            LaunchFixtures.herdNode + "/claude",
            "/opt/homebrew/bin/claude",
            "/usr/bin/claude",
            "/bin/claude",
            "/usr/sbin/claude",
            "/sbin/claude",
            "/usr/local/bin/claude",
            "/Users/seraphin/.claude/local/claude",
            "/Users/seraphin/.npm-global/bin/claude",
        ])
    }

    @Test func knownLocationsWithoutPath() {
        #expect(ClaudeLocatorPlan.candidates(override: nil, pathEnv: nil, home: Self.home + "/") == [
            "/Users/seraphin/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Users/seraphin/.claude/local/claude",
            "/Users/seraphin/.npm-global/bin/claude",
        ])
    }

    @Test func blankOverrideAndOddPathEntriesAreSkipped() {
        let candidates = ClaudeLocatorPlan.candidates(override: "  ", pathEnv: "::relative/bin:.:/opt/tools/:/:~/.bun/bin",
                                                      home: Self.home)
        #expect(Array(candidates.prefix(3)) == ["/opt/tools/claude", "/claude", "/Users/seraphin/.bun/bin/claude"])
        #expect(!candidates.contains { !$0.hasPrefix("/") })
        #expect(Set(candidates).count == candidates.count)
    }

    @Test func overrideComesFirstEvenWhenAlsoKnown() {
        let candidates = ClaudeLocatorPlan.candidates(override: "/usr/local/bin/claude", pathEnv: "/usr/local/bin", home: Self.home)
        #expect(candidates.first == "/usr/local/bin/claude")
        #expect(candidates.filter { $0 == "/usr/local/bin/claude" }.count == 1)
    }
}

@Suite struct ClaudeVersionTests {
    @Test(arguments: [
        ("2.1.280 (Claude Code)", SemVer(2, 1, 280)),
        ("claude 2.1.280", SemVer(2, 1, 280)),
        ("v2.1.280", SemVer(2, 1, 280)),
        ("2.1.234\n", SemVer(2, 1, 234)),
        ("Claude Code 10.20.30-beta.1", SemVer(10, 20, 30)),
    ])
    func parses(_ text: String, _ expected: SemVer) {
        #expect(SemVer(parsing: text) == expected)
    }

    @Test(arguments: ["", "claude", "2.1", "v2", "1.2.3.4", "version: x.y.z"])
    func rejects(_ text: String) {
        #expect(SemVer(parsing: text) == nil)
    }

    @Test func ordering() {
        #expect(SemVer(2, 1, 233) < ClaudeRequirements.minimumVersion)
        #expect(!(SemVer(2, 1, 234) < ClaudeRequirements.minimumVersion))
        #expect(SemVer(2, 1, 280) > ClaudeRequirements.minimumVersion)
        #expect(SemVer(2, 2, 0) > SemVer(2, 1, 999))
        #expect(SemVer(3, 0, 0) > SemVer(2, 99, 99))
        #expect(SemVer(2, 1, 10) > SemVer(2, 1, 9))
        #expect(ClaudeRequirements.minimumVersion.description == "2.1.234")
    }

    @Test func codableAsText() throws {
        let data = try JSONEncoder().encode([SemVer(2, 1, 280)])
        #expect(String(decoding: data, as: UTF8.self) == "[\"2.1.280\"]")
        #expect(try JSONDecoder().decode([SemVer].self, from: data) == [SemVer(2, 1, 280)])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([SemVer].self, from: Data("[\"abc\"]".utf8)) }
    }
}
