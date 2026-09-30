import Foundation
import Testing
@testable import PixelCore

@Suite struct NameGeneratorTests {
    @Test func listIsLargeUniqueAndShort() {
        #expect(NameGenerator.names.count >= 60)
        #expect(Set(NameGenerator.names.map { $0.lowercased() }).count == NameGenerator.names.count)
        for name in NameGenerator.names {
            #expect(name.count <= 10, "\(name) is too long for a desk label")
            #expect(!name.contains(" "))
            #expect(name.first!.isUppercase)
        }
    }

    @Test func deterministic() {
        for seed: UInt64 in [0, 1, 59, 60, 12_345, .max] {
            #expect(NameGenerator.name(seed: seed, avoiding: []) == NameGenerator.name(seed: seed, avoiding: []))
        }
        #expect(NameGenerator.name(seed: 0, avoiding: []) == NameGenerator.names[0])
        #expect(NameGenerator.name(seed: 61, avoiding: []) == NameGenerator.names[1])
    }

    @Test func avoidsNamesInUseCaseInsensitively() {
        #expect(NameGenerator.name(seed: 0, avoiding: ["nova"]) == NameGenerator.names[1])
        #expect(NameGenerator.name(seed: 59, avoiding: [NameGenerator.names[59]]) == NameGenerator.names[0])
    }

    @Test func fallsBackToNumberedAgents() {
        var used = Set(NameGenerator.names)
        #expect(NameGenerator.name(seed: 7, avoiding: used) == "Agent 1")
        used.insert("Agent 1")
        used.insert("agent 2")
        #expect(NameGenerator.name(seed: 7, avoiding: used) == "Agent 3")
    }

    @Test func everyNameIsReachable() {
        var produced: Set<String> = []
        for seed in 0..<UInt64(NameGenerator.names.count) { produced.insert(NameGenerator.name(seed: seed, avoiding: [])) }
        #expect(produced == Set(NameGenerator.names))
    }

    @Test func seedFromAgentID() throws {
        let id = try #require(AgentID(string: "01020304-0506-0708-090A-0B0C0D0E0F10"))
        #expect(NameGenerator.seed(for: id) == 0x0102_0304_0506_0708)
        #expect(NameGenerator.seed(for: id) == NameGenerator.seed(for: id))
    }
}
