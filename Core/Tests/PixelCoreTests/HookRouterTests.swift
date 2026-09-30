import Foundation
import Testing
@testable import PixelCore

@Suite struct HookRouterTests {
    static let token = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    let agent = AgentID()
    let other = AgentID()

    private func envelope(agent: AgentID?, token: String? = Self.token, pid: Int32? = 4242) -> HookEnvelope {
        HookEnvelope(version: 1, agentID: agent, token: token, claudePID: pid, timestampNs: 1,
                     event: HookEvent(name: .stop, sessionID: "s", payload: .other))
    }

    private func route(_ e: HookEnvelope, agents: [AgentID: RoutingEntry]? = nil) -> RouteDecision {
        HookRouter.route(e, expectedToken: Self.token, agents: agents ?? [agent: RoutingEntry(pid: 4242, sessionID: "s")])
    }

    @Test func acceptsTheAgentsOwnClaude() {
        #expect(route(envelope(agent: agent)) == .accept(agent))
    }

    @Test func ignoresANestedClaude() {
        #expect(route(envelope(agent: agent, pid: 5151)) == .ignoreNested(agent))
    }

    @Test func acceptsWhenAPIDIsUnknown() {
        // pixel-hook could not find its claude ancestor.
        #expect(route(envelope(agent: agent, pid: nil)) == .accept(agent))
        // The PTY pid is not recorded yet.
        #expect(route(envelope(agent: agent), agents: [agent: RoutingEntry()]) == .accept(agent))
    }

    @Test func unknownAgent() {
        #expect(route(envelope(agent: other)) == .unknownAgent(other))
        #expect(route(envelope(agent: agent), agents: [:]) == .unknownAgent(agent))
    }

    @Test func externalSession() {
        #expect(route(envelope(agent: nil)) == .external)
        #expect(route(envelope(agent: nil, pid: nil)) == .external)
    }

    @Test func rejectsMissingOrWrongTokens() {
        #expect(route(envelope(agent: agent, token: nil)) == .rejectToken)
        #expect(route(envelope(agent: agent, token: "")) == .rejectToken)
        #expect(route(envelope(agent: agent, token: "0f1e2d3c4b5a69788796a5b4c3d2e1f1")) == .rejectToken)
        #expect(route(envelope(agent: agent, token: String(Self.token.dropLast()))) == .rejectToken)
        #expect(route(envelope(agent: agent, token: Self.token + "0")) == .rejectToken)
        // Checked before anything else, external sessions included.
        #expect(route(envelope(agent: nil, token: nil)) == .rejectToken)
        #expect(route(envelope(agent: other, token: "wrong")) == .rejectToken)
        #expect(route(envelope(agent: agent, token: "wrong", pid: 5151)) == .rejectToken)
    }

    @Test func emptyExpectedTokenRejectsEverything() {
        let e = envelope(agent: agent, token: "")
        #expect(HookRouter.route(e, expectedToken: "", agents: [agent: RoutingEntry(pid: 4242)]) == .rejectToken)
    }

    @Test func tokenComparison() {
        #expect(HookRouter.tokensMatch("abc", "abc"))
        #expect(HookRouter.tokensMatch("é☕", "é☕"))
        #expect(!HookRouter.tokensMatch("abc", "abd"))
        #expect(!HookRouter.tokensMatch("ab", "abc"))
        #expect(!HookRouter.tokensMatch("abc", "ab"))
        #expect(!HookRouter.tokensMatch("abc\0", "abc"))
        #expect(!HookRouter.tokensMatch("", ""))
    }
}
