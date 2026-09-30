# Étape 2b-3 : quitter, relancer, reprendre : plan d'implémentation

> **For agentic workers:** implement task by task; steps use checkbox (`- [ ]`) syntax.

**Goal:** après un redémarrage (ou un crash) de l'app, retrouver ses projets, ses post-its et ses sessions : une bannière propose de relancer, une feuille permet de choisir quelles sessions reprendre (`claude --resume`) et quoi faire de chaque post-it resté « En cours » ; rien ne repart tout seul.

**Architecture:** décisions pures dans le cœur (`RelaunchPlanner` : quelles sessions peuvent être reprises, et comment) ; l'app ajoute la bannière, la feuille, l'application des choix et la garde « Attendre la fin des tours » dans le dispatcher.

**Spec:** `docs/PROPOSITION.md` 2.5 (flux « quitter, planter, relancer », à suivre en entier), 4.3b (C13 à C15), 6(p) (deux maquettes), 8 (critère d'acceptation 5). Plans précédents : `docs/superpowers/plans/2026-09-30-etape-2b1-post-its.md`, `docs/superpowers/plans/2026-09-30-etape-2b2-livraison.md`.

## Déjà en place (étape 2a, ne pas refaire)

Orphelins (`Agent.lastProcess`, `.offline(.orphanElsewhere)`, bannière et « Terminer ce processus », jeton de hooks régénéré à chaque lancement) ; phases `.offline(.appRelaunched)` / `.notStarted` ; « Relancer la session » (⇧⌘R) par agent avec `LaunchPlanner(.resume(...))` et repli en nouvelle session si la reprise échoue vite (`resumeAttempts`, `failedResumes`) ; feuille de sortie (« Attendre la fin des tours », « Quitter quand même », `AppModel+Quit.swift`). Lire ces fichiers avant d'écrire : `App/Sources/Model/AppModel.swift`, `AppModel+Sessions.swift`, `AppModel+Quit.swift`, `App/Sources/UI/Status/Banner.swift`, `BannerStackView.swift`, `App/Sources/UI/Sheets/QuitSheet.swift`, `Core/Sources/PixelCore/Launch/LaunchPlanner.swift`.

## Global Constraints

Celles des plans 2b-1 et 2b-2 (cœur compatible Linux, Swift 6 strict, swift-testing, cœur pur, interface en français, jamais de tiret cadratin U+2014, aucune approbation automatique). En plus : **jamais** de `--resume` d'un `session_id` détenu par un processus vivant ; le tour interrompu **ne reprend jamais tout seul**.

## Review Focus

1. Orphelin encore vivant : sa ligne est désactivée dans la feuille, « Relancer » impossible tant que le pid vit. Test : `RelaunchPlannerTests.orphanAliveIsNotResumable`.
2. Transcript purgé (fichier `transcriptPath` absent) : la ligne annonce « une nouvelle session sera créée » et n'est pas cochée par défaut. Test : `transcriptMissingProposesNewSession`.
3. Dossier de la session disparu (worktree supprimé) : reprise en fork dans le dossier du projet. Test : `missingFolderForksInProjectFolder`.
4. Post-it « En cours » d'un agent relancé : drapeau `sessionLost` dès le chargement, choix par défaut « Remettre à faire », jamais d'envoi automatique. Test côté cœur : le réducteur reçoit `.agentSignal(a, .sessionLost)` pour chaque agent hors ligne au démarrage (test d'intégration de `TaskLifecycle`).
5. « Attendre la fin des tours » : aucune livraison ne démarre tant que la sortie est en attente. Test : `DispatchPolicyTests.quitPendingBlocksDelivery` (nouvelle cause `WaitCause.quitting`, libellé « l'app va quitter »).

---

### Task 1: `RelaunchPlanner` (cœur, pur) et cause `quitting`

**Files:** Create `Core/Sources/PixelCore/Launch/RelaunchPlanner.swift`, `Core/Tests/PixelCoreTests/RelaunchPlannerTests.swift` ; Modify `Core/Sources/PixelCore/Delivery/DispatchPolicy.swift` (+ tests).

```swift
public enum RelaunchStatus: Equatable, Sendable {
    case resumable(SessionRef)                 // --resume <id> in ref.cwd
    case forkInProjectFolder(SessionRef)       // ref.cwd is gone: --resume <id> --fork-session in the project folder
    case newSession(reason: String)            // transcript purged, never started…: "une nouvelle session sera créée"
    case orphanAlive(pid: Int32)               // not relaunchable while this pid lives
}
public struct RelaunchCandidate: Equatable, Sendable {
    public var agentID: AgentID
    public var status: RelaunchStatus
    public var selectedByDefault: Bool          // resumable / fork: true; newSession, orphan: false
    public var cardInProgress: TaskCardID?      // BoardQuery.currentCard
    public var lastActivity: Date?              // sessions.last.endedAt ?? startedAt
}
public struct FileFacts: Sendable {             // filled by the app (FileManager), injected for purity
    public var existingPaths: Set<String>
    public init(existingPaths: Set<String>)
}
public enum RelaunchPlanner {
    /// Agents whose runtime phase is .offline(.appRelaunched) or .offline(.orphanElsewhere), in sidebar order.
    public static func candidates(workspace: Workspace, runtimes: [AgentID: AgentRuntime], board: TaskBoardState,
                                  files: FileFacts, alivePIDs: Set<Int32>) -> [RelaunchCandidate]
}
```

`WaitCause.quitting` (libellé « l'app va quitter ») et un paramètre `quitPending: Bool` (défaut `false`) à `DispatchPolicy.nextDelivery`, vérifié juste après « file vide ». Un test par statut, par valeur par défaut, et `quitPendingBlocksDelivery`.

### Task 2: Relance dans l'app

**Files:** Create `App/Sources/UI/Sheets/RelaunchSheet.swift` ; Modify `App/Sources/Model/AppModel+Sessions.swift` (ou un nouveau `AppModel+Relaunch.swift`), `App/Sources/UI/Status/Banner.swift`, `BannerStackView.swift`, `App/Sources/UI/Main/SheetContentView.swift`, `App/Sources/UI/Support/WorkbenchState.swift`, `App/Sources/Sessions/TaskDispatcher.swift` (passer `quitPending: isWaitingForTurnsToQuit`), `App/Sources/Model/AppModel.swift` (au démarrage, `applyTask(.agentSignal(a, .sessionLost))` pour chaque agent hors ligne qui a une carte `inProgress`).

- Bannière (2.5) « n sessions peuvent être relancées » : [Tout relancer] (candidats cochés par défaut, choix « Remettre à faire » pour leurs post-its en cours) · [Choisir…] (feuille) · [Plus tard] (masque la bannière jusqu'au prochain lancement).
- Feuille « Relancer les sessions » (maquette 6(p)) : une ligne par candidat (nom · projet, titre du post-it en cours ou « session 7d2f… », « il y a 2 h », dossier), case à cocher, choix « Continuer la tâche » / « Remettre à faire » (défaut) pour un post-it en cours, ligne désactivée « ⚠ tourne encore hors de l'app (pid n) » avec [Terminer ce processus] [Laisser tourner] ; bouton « Relancer n sessions ».
- Appliquer : pour chaque ligne cochée, lancer selon le statut (`.resume`, fork dans le dossier du projet, ou nouvelle session) ; post-it : « Remettre à faire » → `.putBack` ; « Continuer la tâche » → `.continueTask` **après** que la session a démarré (agent vivant, C14 l'exige), jamais avant.
- « Laisser tourner » : l'orphelin garde sa ligne désactivée, son poste affiche « session détenue par un autre processus », Relancer reste désactivé (déjà en 2a : vérifier).
- Build, lancement de l'app une fois, lecture des logs (l'écran n'est pas visible).
