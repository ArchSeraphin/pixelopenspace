# Étape 2b-2 : livraison gardée et file par agent : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** un post-it assigné part tout seul dans le terminal de son agent quand celui-ci est libre, par une livraison gardée qui n'écrit jamais sur un dialogue et ne valide jamais rien à ta place ; la carte passe « En cours » sur `UserPromptSubmit`, « À valider » sur le `Stop` confirmé, et la file enchaîne.

**Architecture:** décisions pures dans le cœur : motifs d'écran réglés sur les vraies captures de Claude Code 2.1.285 (`ScreenPatterns` v2), plan d'envoi et gardes (`DeliveryPlan`, `DeliveryGuard`), politique de file (`DispatchPolicy`). L'app ajoute un `TaskDispatcher` (`@MainActor`) qui exécute un plan étape par étape contre le `TerminalHost`, relit l'écran et un compteur atomique de hooks par agent (garde G2), et fait circuler les entrées `deliveryStarted` / `deliveryAborted` dans les deux réducteurs (`AgentStateMachine`, `TaskLifecycle`).

**Tech Stack:** Swift 6, swift-testing, SwiftUI/AppKit, SwiftTerm (révision épinglée `a2706d2`).

**Spec:** `docs/PROPOSITION.md` 3.6, 4.3 (T13 à T13c, T30, T31), 4.3b (C6 à C9, C14, C17), **5.6 en entier**, 5.8 ; `docs/superpowers/plans/2026-09-30-etape-2b1-post-its.md` (types et réducteur déjà livrés) ; **résultats des spikes** : `Tools/spikes/results/20260930-185108/summary.md` et ses captures `*/screens/*.txt`.

## Ce que les spikes ont établi (macOS, Claude Code 2.1.285)

- Texte saisi d'un bloc puis `\r` seul après 30, 120 ou 250 ms : `UserPromptSubmit` à chaque fois, prompt identique, environ 60 ms après l'Entrée.
- `LF` dans le texte saisi = saut de ligne dans le prompt.
- `ESC[?2004h` actif ; amorce saisie puis collage entre crochets de 1200 caractères : prompt reçu = amorce + `\n\n<pasted_content id="…">\n` + texte collé exact ; l'écran affiche `❯ <amorce>[Pasted text #1 +12 lines]` (préfixe de l'amorce visible, collé au marqueur, sans espace).
- Prompt positionnel : `UserPromptSubmit` environ 0,5 s après `SessionStart`.
- Permission : `1` seul répond ; après `Stop`, un nouveau prompt enchaîne normalement.
- **Refus d'une permission par Échap : aucun événement de hook.** Seul l'écran dit que le dialogue a disparu.
- `AskUserQuestion` : `PreToolUse` puis `PermissionRequest` avant le dialogue ; options `1. Rouge`, `2. Bleu`, `3. Type something.`, `4. Chat about this` ; Échap : aucun événement.
- Aucun hook avant l'acceptation de la confiance du dossier.
- Latence de `pixel-hook` : p95 9,3 ms jusqu'au socket.

Décision : garder les délais de la proposition (120 ms sous 500 octets, 250 ms sous 2 Ko, 500 ms sous 16 Ko, 1 s au-delà) : ils sont au-dessus de tout ce qui a marché, et le bug de collage (#91205) concerne le collage, pas la saisie.

## Global Constraints

Les mêmes que le plan 2b-1 (cœur compatible Linux, Swift 6 strict, swift-testing, pas de `Date()` implicite dans le cœur, interface en français, jamais de tiret cadratin U+2014, aucune approbation automatique), plus :
- **L'app n'envoie jamais** de flèches, Ctrl+C, Ctrl+D, Ctrl+U, ni aucune touche de navigation ; seules les écritures du plan d'envoi (texte, marqueurs de collage, `\r`).
- Une garde qui échoue = **abandon**, jamais « on essaie quand même ». « Envoyer quand même » ne lève que la garde « zone de saisie vide » (brouillon).
- Aucune livraison en mode dégradé (`hookHealth != .healthy`), pendant une attente, `waitingBackground`, `quotaPaused`, `error`, `offline`, ni file en pause.

## Review Focus

1. **Dialogue qui surgit entre le texte et l'Entrée** (tour relancé par une tâche de fond, un cron, une reprise après limite) : la garde `beforeEnter` doit voir le `PreToolUse`/`PermissionRequest` (compteur G2) ou le dialogue à l'écran et abandonner **sans** `\r`. Test : `DeliveryPlanTests.beforeEnterAbortsOnNewHookEvent`, `beforeEnterAbortsOnDialog`.
2. **Brouillon de l'utilisateur dans la zone de saisie** : aucune écriture ; la carte indique « brouillon » ; « Envoyer quand même » ne contourne ni G1 ni G2 ni le dialogue. Tests : `DispatchPolicyTests.draftBlocks`, `sendAnywayLiftsOnlyDraft`.
3. **Écran non reconnu** (autre version de Claude Code, rendu plein écran inconnu) : aucune livraison, bandeau « Envoi automatique suspendu : écran non reconnu ». Test : `DeliveryPlanTests.unrecognizedScreenAborts`.
4. **Refus par Échap sans hook** : l'attente de permission doit se fermer quand l'écran ne montre plus de dialogue après la touche Échap, sinon la file reste bloquée pour toujours. Test : `AgentStateMachineTests.escapeRefusalClearsWaitFromScreen` (captures S5 et S7 `04-apres-echap`).
5. **Agent qui quitte pendant la livraison** : l'exécuteur s'arrête à la première étape suivante, `deliveryAborted(.processGone)`, rien n'est écrit dans un PTY mort. Test côté cœur : `DeliveryPlanTests.processGoneAbortsEveryGuard` ; côté app, relecture de `host.isRunning` avant chaque écriture.

---

### Task 1: `ScreenPatterns` v2 sur les vraies captures, et fermeture d'une attente par l'écran

**Files:**
- Create: `Core/Tests/PixelCoreTests/Fixtures/screens/real-2.1.285/` (copies des captures `S3.a-250ms/screens/02..05`, `S3.c-paste/screens/04`, `S3.e-permission/screens/03..04`, `S7/screens/03..04`, `S5/screens/*` s'il y en a, et une capture de confiance), la première ligne `# …` retirée.
- Modify: `Core/Sources/PixelCore/Util/ScreenPatterns.swift` (version 2), `Core/Tests/PixelCoreTests/ScreenPatternsTests.swift`, et si nécessaire `Core/Sources/PixelCore/State/AgentStateMachine.swift` + `AgentStateMachineTests.swift`.

Attendus, un test par capture : prêt (`❯ Try "fix lint errors"`) → `.empty` ; brouillon → `.draft("Réponds juste OK.")` ; en cours (`· Photosynthesizing… (1s · thinking)` au-dessus d'une zone de saisie vide) → `spinnerVisible`, `.empty`, pas de dialogue ; après collage → `.draft` dont le préfixe commence par l'amorce, le marqueur `[Pasted text #1 +12 lines]` n'empêchant pas la reconnaissance ; permission → `dialogVisible`, options `[("1","Yes"),("2","No")]` ; question → `dialogVisible`, 4 options ; après Échap → pas de dialogue, zone de saisie reconnue ; confiance du dossier → dialogue. Toutes → `recognized == true`. Les fixtures synthétiques existantes restent vertes. `ScreenPatterns.version = 2`.

Refus par Échap : lire comment `AgentStateMachine` traite `userKeystroke(.escape)` et `screen(ScreenFacts)` pendant une attente `.permission`/`.question`. Si un écran reconnu sans dialogue, relevé **après** une touche Échap, ne ferme pas l'attente, l'ajouter (T de la table 4.3 le plus proche ; noter la règle en commentaire) : l'attente se ferme, la phase revient à celle d'avant l'attente (en pratique `thinking`/`working` ou `idle` selon la suite), et aucune carte ne bouge. Test `escapeRefusalClearsWaitFromScreen`, plus un test qui montre qu'un écran sans dialogue **sans** Échap préalable ne ferme rien (le dialogue peut simplement ne pas être encore dessiné).

### Task 2: `DeliveryPlan` et gardes (pur)

**Files:** Create `Core/Sources/PixelCore/Delivery/DeliveryPlan.swift` ; Test `Core/Tests/PixelCoreTests/DeliveryPlanTests.swift`.

```swift
public enum DeliveryGuard: Equatable, Sendable {
    case beforeText
    case beforeEnter(prefix: String)
    case beforeRetryEnter(prefix: String)
}
public enum DeliveryStep: Equatable, Sendable {
    case check(DeliveryGuard)
    case write([UInt8])
    case awaitWriteCompletion
    case sleep(milliseconds: Int)
    case expectPromptSubmit(within: Int)      // milliseconds
}
public enum GuardVerdict: Equatable, Sendable { case pass, abort(String) }   // French reason for the card and the log
public struct GuardInputs: Equatable, Sendable {
    public var runtime: AgentRuntime
    public var queuePaused: Bool
    public var hookSeqAtStart: UInt64
    /// Read from the hook server's per-agent atomic counter just before the check.
    public var hookSeqNow: UInt64
    public var screen: ScreenFacts
    /// When the screen was read.
    public var screenAt: Date
    public var lastOutputAt: Date?
    public var now: Date
    /// "Envoyer quand même": lifts only the empty-input-box part of G3 before the text.
    public var draftOverride: Bool
}
public enum DeliveryPlan {
    public static let primer = "Réalise la tâche décrite dans le texte collé ci-dessous."
    public static let promptSubmitTimeoutMs = 3000
    public static let quietMs = 300
    public static let screenMaxAgeMs = 100
    /// Short text: typed. Long text: primer typed, then ESC[200~ body ESC[201~ (only if `bracketedPaste`);
    /// long text without bracketed paste → nil ("trop long pour un envoi sûr").
    public static func make(_ prompt: SanitizedPrompt, bracketedPaste: Bool) -> [DeliveryStep]?
    /// The prefix matched against UserPromptSubmit and looked for in the input box (primer for long texts).
    public static func prefix(for prompt: SanitizedPrompt) -> String
    public static func delayMs(forBytes count: Int) -> Int      // 120 / 250 / 500 / 1000
    public static func evaluate(_ guard: DeliveryGuard, _ inputs: GuardInputs) -> GuardVerdict
}
```

Plan attendu (5.6) : `check(.beforeText)`, `write(texte ou amorce)`, [si long : `write(ESC[200~ + corps + ESC[201~)`], `awaitWriteCompletion`, `sleep(delayMs)`, `check(.beforeEnter(prefix))`, `write([0x0D])`, `expectPromptSubmit(within: 3000)`. Le retry (`beforeRetryEnter`, un seul `\r` de plus) est piloté par l'exécuteur après l'échéance ; `make` ne l'inclut pas. Texte : UTF-8 du `SanitizedPrompt.text` (les `LF` restent des `LF`).

Gardes : G1 (processus vivant `runtime.pid != nil`, `hookHealth == .healthy`, phase `idle` ou `done`, `pendingWaits` vide, `pendingStop == nil`, pas `waitingBackground`/`quotaPaused`, file non en pause ; pour `beforeEnter`/`beforeRetryEnter`, la phase peut être celle posée par `deliveryStarted`) ; G2 (`hookSeqNow == hookSeqAtStart`) ; G3 (écran relevé il y a au plus 100 ms, `recognized`, pas de dialogue, pas de `quotaLine`, pas de spinner ; `beforeText` : zone `.empty` sauf `draftOverride` ; `beforeEnter`/`beforeRetryEnter` : zone `.draft(p)` avec `p` qui commence par les premiers caractères normalisés de `prefix` (même normalisation que `AgentStateMachine.normalizedPromptPrefix`)) ; G4 (pas de sortie depuis 300 ms, sauf si G3 est satisfaite, cf. 5.6 : le silence ne bloque jamais seul). Un test par condition de chaque garde, raison française lisible dans `abort`.

### Task 3: `DispatchPolicy` (pur)

**Files:** Create `Core/Sources/PixelCore/Delivery/DispatchPolicy.swift` ; Test `DispatchPolicyTests.swift`.

```swift
public enum WaitCause: Equatable, Sendable {
    case busy, waitingInput, waitingBackground, quotaPaused, draftInInputBox, screenUnknown, paused, offline,
         hooksUnhealthy, cooldown, deliveryInProgress
    public var label: String      // "occupé", "attend ta réponse", "✎ brouillon", "écran non reconnu", "file en pause"…
}
public enum DeliveryDecision: Equatable, Sendable { case deliver(QueueItem), wait(WaitCause), none }
public struct DispatchSettings: Equatable, Sendable {
    public var autoChain: Bool          // AppSettings.autoChainQueue
    public var graceSeconds: Double     // AppSettings.sendGraceSeconds (1.5)
    public init(autoChain: Bool = true, graceSeconds: Double = 1.5)
}
public enum DispatchPolicy {
    public static func nextDelivery(agent: Agent, runtime: AgentRuntime, queue: [QueueItem], now: Date,
                                    lastTurnEndedAt: Date?, settings: DispatchSettings, draftOverride: Bool) -> DeliveryDecision
    /// idle or done agent with an empty queue, longest idle first; else the shortest queue among live agents; nil if none live.
    public static func firstFreeAgent(in project: ProjectID, agents: [Agent], runtimes: [AgentID: AgentRuntime],
                                      queueLengths: [AgentID: Int]) -> AgentID?
}
```

Règles (3.6, 5.6 « Sémantique de la file ») : file vide → `.none` ; `queuePaused` → `.wait(.paused)` ; hors ligne → `.offline` ; `hookHealth != .healthy` → `.hooksUnhealthy` ; attente ouverte → `.waitingInput` ; `waitingBackground`/`quotaPaused` → idem ; `pendingDelivery != nil` → `.deliveryInProgress` ; phase autre que `idle`/`done` ou `pendingStop` → `.busy` ; moins de `graceSeconds` depuis `lastTurnEndedAt` → `.cooldown` ; `autoChain == false` et phase `done` → `.wait(.cooldown)` jusqu'à une action (documenter) ; écran non reconnu → `.screenUnknown` ; zone `.draft` → `.draftInInputBox` sauf `draftOverride` ; sinon `.deliver(queue[0])`. Un test par règle, dans cet ordre de priorité.

### Task 4: `TaskDispatcher` et intégration dans l'app

**Files:** Create `App/Sources/Sessions/TaskDispatcher.swift` ; Modify `App/Sources/Hooks/HookServer.swift` (compteur atomique par agent, incrémenté sur le fil du socket dès qu'un message portant cet `agent_id` arrive, avant le MainActor), `App/Sources/Sessions/TerminalHost.swift` (écriture avec complétion si SwiftTerm l'offre : `LocalProcess.send(data:completion:)` ou équivalent ; sinon attendre la vidange par un court délai documenté), `App/Sources/Model/AppModel+Engine.swift` (effets `.pumpQueue(afterSeconds:)` et `.setQueuePaused`), `App/Sources/Model/AppModel+Tasks.swift` (effet `.pump`), `App/Sources/Model/AppModel+Intents.swift`, UI (`AgentCardView`, `AgentCardButtons`, menu contextuel des post-its, `BoardPanelView`).

Comportement :
- `pump(agent)` : si aucun envoi en cours pour cet agent, `DispatchPolicy.nextDelivery` → `.deliver(item)` : composer le texte (`promptPreview` pour une carte ; texte de la consigne pour une consigne), `PromptSanitizer`, `DeliveryPlan.make` (nil → carte « trop long pour un envoi sûr », bouton « Ouvrir le terminal »), puis `dispatch(.deliveryStarted(PendingDelivery(itemID:prefix:startedAt:hookSeqAtStart:)))` dans l'`AgentStateMachine` et `applyTask(.deliveryStarted(item, agent:, sessionID:))`. Si la machine refuse (`pendingDelivery` resté nil), abandonner sans rien écrire.
- Exécution séquentielle des étapes dans une `Task` par agent, annulable : `check` relit l'écran (`ScreenPatterns.parse(host.visibleLines())`, horodaté) et le compteur G2 juste avant, puis `DeliveryPlan.evaluate` ; `write` relit `host.isRunning` ; `expectPromptSubmit` attend que `pendingDelivery` redevienne nil par un `UserPromptSubmit` (C7 arrive via le signal `deliveryConfirmed` déjà émis par la machine) ; à l'échéance, une seule fois : `check(.beforeRetryEnter)` puis `\r`, 3 s ; sinon `dispatch(.deliveryAborted(.noPromptSubmit))`. Tout échec de garde → `dispatch(.deliveryAborted(.guardFailed(raison)))` (la machine émet `deliveryFailed` + `setQueuePaused(true)`).
- `.setQueuePaused(b)` écrit `Agent.queuePaused` (workspace) ; `.pumpQueue(afterSeconds:)` programme un `pump` différé.
- UI : carte d'agent : « file : n », cause d'attente (`WaitCause.label`) quand la file n'est pas vide, bouton « Reprendre la file » si en pause, « Envoyer quand même » si brouillon ; post-it : « Premier agent libre » (`DispatchPolicy.firstFreeAgent`), « Lancer un nouvel agent avec ce post-it » (nouvel agent, prompt positionnel = texte nettoyé, carte assignée et livraison marquée démarrée pour que le `UserPromptSubmit` du prompt positionnel la confirme : lire `launchedWithPrompt` dans la machine), « Donner une consigne… » sur la carte d'agent (feuille, `.giveInstruction`, en tête si l'agent est occupé).
- Hors périmètre : « Glisser dans le tour en cours ».

### Task 5: Mesure de latence hook → écran

**Files:** Modify `App/Sources/Model/AppModel+Engine.swift`, `App/Sources/UI/Settings/*` (onglet « Avancé » ou section existante).

Pour chaque événement accepté, écart entre l'horodatage `ts_ns` du helper (déjà dans l'enveloppe) et l'instant où l'état est appliqué ; fenêtre glissante des 500 dernières mesures ; p50 et p95 affichés dans Réglages (« Latence hook → écran : p50 12 ms · p95 40 ms · 500 mesures »). Calcul du percentile dans le cœur (fonction pure testée).
