import Foundation
import Testing
@testable import PixelCore

@Suite struct AgentPresenterTests {
    static let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func runtime(_ phase: AgentPhase, pid: Int32? = 4242, since: Date = t0) -> AgentRuntime {
        var r = AgentRuntime(phase: phase, phaseSince: since)
        r.pid = pid
        r.hookHealth = .healthy
        return r
    }

    private func present(_ phase: AgentPhase, after seconds: TimeInterval = 5) -> AgentStatusDisplay {
        AgentPresenter.present(runtime(phase), now: Self.t0 + seconds)
    }

    @Test(arguments: [
        (AgentPhase.offline(.notStarted), AgentStateKind.offline, "Hors ligne", "power"),
        (.launching, .launching, "Démarre", "arrow.up.circle"),
        (.idle, .idle, "Au repos", "zzz"),
        (.thinking, .thinking, "Réfléchit", "ellipsis.bubble"),
        (.working(.bash), .working, "Travaille", "terminal"),
        (.done, .done, "Tour terminé", "checkmark.circle.fill"),
        (.waitingBackground(tasks: 1, crons: 0), .waitingBackground, "Attend une tâche de fond", "hourglass"),
        (.quotaPaused(resetAt: nil, autoResume: true), .quotaPaused, "En pause : limite d'usage", "clock"),
        (.error(.api("overloaded")), .error, "Erreur", "exclamationmark.triangle.fill"),
    ])
    func titleAndSymbolForEveryPhase(phase: AgentPhase, kind: AgentStateKind, title: String, symbol: String) {
        let d = present(phase)
        #expect(d.kind == kind)
        #expect(d.title == title)
        #expect(d.symbolName == symbol)
        #expect(d.urgency == kind.urgency)
        #expect(d.since == Self.t0)
        #expect(d.badges.isEmpty)
    }

    @Test func everyKindIsCovered() {
        let phases: [AgentPhase] = [.offline(.exited), .launching, .idle, .thinking, .working(.read), .done,
                                    .waitingBackground(tasks: 0, crons: 1), .quotaPaused(resetAt: nil, autoResume: false),
                                    .error(.crashed(nil))]
        var kinds = Set(phases.map { present($0).kind })
        var waiting = runtime(.thinking)
        waiting.pendingWaits[.terminal] = PendingWait(reason: .terminal, subagentID: nil, since: Self.t0)
        kinds.insert(AgentPresenter.present(waiting, now: Self.t0).kind)
        #expect(kinds == Set(AgentStateKind.allCases))
    }

    @Test func idleForMoreThanTenMinutesIsAsleep() {
        #expect(present(.idle, after: 600).title == "Au repos")
        let asleep = present(.idle, after: 601)
        #expect(asleep.title == "Endormi")
        #expect(asleep.symbolName == "moon.zzz")
        #expect(asleep.kind == .idle)
        // Offline is never "asleep".
        #expect(present(.offline(.closedByUser), after: 3_600).title == "Hors ligne")
    }

    @Test func permissionWait() {
        var r = runtime(.working(.bash))
        r.pendingWaits[.tool(toolUseID: "t1")] = PendingWait(reason: .permission(tool: "Bash", summary: "rm -rf dist"),
                                                             subagentID: nil, since: Self.t0 + 1)
        let d = AgentPresenter.present(r, now: Self.t0 + 43)
        #expect(d == AgentStatusDisplay(kind: .waitingInput, title: "Attend ta réponse", detail: "Bash : rm -rf dist",
                                        symbolName: "exclamationmark.bubble.fill", urgency: 3, since: Self.t0 + 1,
                                        badges: []))
    }

    @Test func questionWaitShowsTheQuestion() {
        var r = runtime(.thinking)
        let q = AskedQuestion(header: "Base", question: "Quelle base de données ?", options: ["SQLite"], multiSelect: false)
        r.pendingWaits[.tool(toolUseID: "q1")] = PendingWait(reason: .question([q]), subagentID: nil, since: Self.t0)
        let d = AgentPresenter.present(r, now: Self.t0)
        #expect(d.title == "Te pose une question")
        #expect(d.detail == "Quelle base de données ?")
        #expect(d.symbolName == "questionmark.bubble.fill")
    }

    @Test func oldestWaitIsShownWithTheOthersAsABadge() {
        var r = runtime(.working(.edit))
        r.pendingWaits[.tool(toolUseID: "t2")] = PendingWait(reason: .permission(tool: "Edit", summary: "b.swift"),
                                                             subagentID: nil, since: Self.t0 + 2)
        r.pendingWaits[.tool(toolUseID: "t1")] = PendingWait(reason: .permission(tool: "Edit", summary: "a.swift"),
                                                             subagentID: "sub-1", since: Self.t0 + 1)
        var d = AgentPresenter.present(r, now: Self.t0 + 3)
        #expect(d.detail == "Edit : a.swift")
        #expect(d.badges == ["+1 attente"])
        r.pendingWaits[.elicitation("e1")] = PendingWait(reason: .elicitation(server: "github", message: "Choisis"),
                                                         subagentID: nil, since: Self.t0 + 3)
        d = AgentPresenter.present(r, now: Self.t0 + 3)
        #expect(d.badges == ["+2 attentes"])
    }

    @Test func simultaneousWaitsAreShownInAStableOrder() {
        var r = runtime(.working(.bash))
        for id in ["t9", "t3", "t5", "t1", "t7"] {
            r.pendingWaits[.tool(toolUseID: id)] = PendingWait(reason: .permission(tool: "Bash", summary: id),
                                                               subagentID: nil, since: Self.t0)
        }
        r.pendingWaits[.terminal] = PendingWait(reason: .terminal, subagentID: nil, since: Self.t0)
        #expect(AgentPresenter.present(r, now: Self.t0).detail == "Bash : t1")
        #expect(StatusSummary.compute([AgentID(): r]).waiting.first?.reason == .permission(tool: "Bash", summary: "t1"))
    }

    @Test func waitDescriptions() {
        typealias P = AgentPresenter
        #expect(P.describe(WaitReason.permission(tool: "WebFetch", summary: "")) == "WebFetch")
        #expect(P.describe(WaitReason.question([])) == "question")
        let two = [AskedQuestion(header: "Nom", question: "", options: [], multiSelect: false),
                   AskedQuestion(header: "Couleur", question: "Laquelle ?", options: [], multiSelect: true)]
        #expect(P.describe(WaitReason.question(two)) == "Nom (+1)")
        #expect(P.describe(WaitReason.elicitation(server: "github", message: "Choisis un dépôt")) == "Choisis un dépôt")
        #expect(P.describe(WaitReason.elicitation(server: "github", message: "")) == "dialogue MCP : github")
        #expect(P.describe(WaitReason.notification(type: "permission_prompt")) == "demande de permission")
        #expect(P.describe(WaitReason.notification(type: "quota_auto_resume_stale"))
                == "limite réinitialisée : appuie sur Entrée dans le terminal")
        #expect(P.describe(WaitReason.notification(type: "something_new")) == "regarde le terminal")
        #expect(P.describe(WaitReason.terminal) == "regarde le terminal")
        #expect(P.symbolName(for: WaitReason.terminal) == "exclamationmark.bubble.fill")
    }

    @Test(arguments: [
        (ToolKind.read, "doc.text", "lecture"), (.edit, "pencil", "modification"), (.bash, "terminal", "commande"),
        (.search, "magnifyingglass", "recherche"), (.web, "globe", "web"), (.subagent, "person.2", "sous-agent"),
        (.question, "questionmark.bubble", "question"), (.mcp("github"), "puzzlepiece", "MCP : github"),
        (.other("activité"), "hammer", "activité"),
    ])
    func workingShowsTheTool(tool: ToolKind, symbol: String, label: String) {
        let d = present(.working(tool))
        #expect(d.symbolName == symbol)
        #expect(d.detail == label)
    }

    @Test func phaseDetails() {
        #expect(present(.waitingBackground(tasks: 2, crons: 1)).detail == "2 tâches de fond · 1 tâche planifiée")
        #expect(present(.waitingBackground(tasks: 0, crons: 3)).detail == "3 tâches planifiées")
        #expect(present(.quotaPaused(resetAt: Self.t0 + 725, autoResume: true)).detail
                == "reprise automatique dans 12 min")
        #expect(present(.quotaPaused(resetAt: Self.t0, autoResume: true)).detail == "reprise imminente")
        #expect(present(.quotaPaused(resetAt: nil, autoResume: true)).detail == "reprise automatique")
        #expect(present(.quotaPaused(resetAt: nil, autoResume: false)).detail == "pas de reprise automatique")
        #expect(present(.error(.api("overloaded"))).detail == "serveurs surchargés")
        #expect(present(.error(.api("teapot"))).detail == "erreur API : teapot")
        #expect(present(.error(.account("authentication_failed"))).detail
                == "Claude Code n'est plus connecté : lance /login")
        #expect(present(.error(.crashed(139))).detail == "arrêt inattendu (code 139)")
        #expect(present(.error(.crashed(nil))).detail == "arrêté par un signal")
        #expect(present(.error(.launchFailed("claude introuvable"))).detail == "lancement impossible : claude introuvable")
        #expect(present(.offline(.notStarted)).detail == "pas encore lancé")
        #expect(present(.offline(.closedByUser)).detail == "session fermée")
        #expect(present(.offline(.appRelaunched)).detail == "l'app a redémarré")
        #expect(present(.offline(.exited)).detail == "session terminée")
        #expect(present(.offline(.orphanElsewhere)).detail == "session détenue par un autre processus")
        #expect(present(.thinking).detail == nil)
        #expect(present(.done).detail == nil)
    }

    @Test func livenessBadges() {
        var r = runtime(.thinking)
        r.activeSubagentIDs = ["sub-1", "sub-2"]
        r.stale = true
        r.hookHealth = .degraded
        #expect(AgentPresenter.present(r, now: Self.t0).badges == ["2 sous-agents", "sans nouvelles", "mode dégradé"])
        r.activeSubagentIDs = ["sub-1"]
        #expect(AgentPresenter.present(r, now: Self.t0).badges.first == "1 sous-agent")
        // No process: nothing is alive.
        var offline = runtime(.offline(.exited), pid: nil)
        offline.hookHealth = .degraded
        #expect(AgentPresenter.present(offline, now: Self.t0).badges.isEmpty)
    }

    @Test func accessibilityLabel() {
        var r = runtime(.working(.bash))
        r.pendingWaits[.tool(toolUseID: "t1")] = PendingWait(reason: .permission(tool: "Bash", summary: "rm -rf dist"),
                                                             subagentID: nil, since: Self.t0)
        let now = Self.t0 + 42
        let d = AgentPresenter.present(r, now: now)
        #expect(AgentPresenter.accessibilityLabel(d, agentName: "Nova", projectName: "API", now: now)
                == "Nova, projet API, attend ta réponse : Bash : rm -rf dist, depuis 42 secondes")
        let off = AgentPresenter.present(runtime(.offline(.closedByUser), pid: nil), now: Self.t0 + 3_900)
        #expect(AgentPresenter.accessibilityLabel(off, agentName: "Oslo", projectName: "Infra", now: Self.t0 + 3_900)
                == "Oslo, projet Infra, hors ligne : session fermée, depuis 1 heure 5 minutes")
        var busy = runtime(.thinking)
        busy.activeSubagentIDs = ["sub-1"]
        let b = AgentPresenter.present(busy, now: Self.t0 + 1)
        #expect(AgentPresenter.accessibilityLabel(b, agentName: "Bip", projectName: "Site", now: Self.t0 + 1)
                == "Bip, projet Site, réfléchit, depuis 1 seconde, 1 sous-agent")
    }

    @Test func durationText() {
        #expect(DurationText.short(0) == "0 s")
        #expect(DurationText.short(12.9) == "12 s")
        #expect(DurationText.short(59) == "59 s")
        #expect(DurationText.short(60) == "1 min")
        #expect(DurationText.short(3 * 60 + 59) == "3 min")
        #expect(DurationText.short(3_599) == "59 min")
        #expect(DurationText.short(3_600 + 5 * 60) == "1 h 05")
        #expect(DurationText.short(26 * 3_600 + 42 * 60) == "26 h 42")
        #expect(DurationText.short(-5) == "0 s")
        #expect(DurationText.short(.nan) == "0 s")
        #expect(DurationText.short(.infinity) == "0 s")
        #expect(DurationText.spoken(1) == "1 seconde")
        #expect(DurationText.spoken(42) == "42 secondes")
        #expect(DurationText.spoken(60) == "1 minute")
        #expect(DurationText.spoken(180) == "3 minutes")
        #expect(DurationText.spoken(3_600) == "1 heure")
        #expect(DurationText.spoken(7_260) == "2 heures 1 minute")
    }
}
