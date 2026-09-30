import Foundation
import Testing
@testable import PixelCore

@Suite struct ContractTests {
    @Test func hookEventNamesRoundTrip() {
        for name in HookEventName.subscribed {
            #expect(HookEventName(rawValue: name.rawValue) == name)
        }
        #expect(HookEventName(rawValue: "SomethingNew") == .other("SomethingNew"))
    }

    @Test func typedIDsEncodeAsBareUUID() throws {
        let id = AgentID()
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[\"\(id.raw.uuidString)\"]")
        #expect(try JSONDecoder().decode([AgentID].self, from: data) == [id])
    }

    @Test func settingsDecodeFromEmptyObject() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s == AppSettings())
    }

    @Test func derivedStateIsWaitingWhenAWaitIsOpen() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var r = AgentRuntime(phase: .working(.bash), phaseSince: t0)
        #expect(r.kind == .working)
        r.pendingWaits[.tool(toolUseID: "t1")] = PendingWait(reason: .permission(tool: "Bash", summary: "ls"), subagentID: nil, since: t0)
        #expect(r.kind == .waitingInput)
    }

    @Test func shellQuote() {
        #expect(ShellQuote.quote("/usr/bin/claude") == "/usr/bin/claude")
        #expect(ShellQuote.quote("/Applications/Pixel Open Space.app") == "'/Applications/Pixel Open Space.app'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
    }
}
