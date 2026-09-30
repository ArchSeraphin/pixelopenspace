# Étape 2b-1 : post-its (modèle, cycle de vie, tableau, éditeur) : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** donner à Pixel Open Space son tableau de post-its : créer, coller une liste, éditer avec un modèle de prompt et son aperçu exact, assigner à un agent (glisser-déposer ou « Donner à… »), faire vivre les colonnes par le réducteur `TaskLifecycle`, le tout persisté dans `state/tasks.json`.

**Architecture:** tout ce qui décide est pur et dans `Core/Sources/PixelCore` (compile et se teste sous Linux) : modèle `TaskCard`/`TaskBoardState`, rangs fractionnaires, codec et validateur de `tasks.json`, réducteur `TaskLifecycle` (table C1 à C20 de la proposition 4.3b), `PromptComposer` + `PromptSanitizer` (5.6), import de liste collée, requêtes du tableau (filtres, file dérivée). L'app (`App/Sources`) suit le motif déjà en place : l'état vit dans `AppModel` (propriété `board`), les intentions dans une extension `AppModel+Tasks.swift`, l'écriture disque dans `PersistenceStore`, l'interface en SwiftUI simple (maquettes 6(b), 6(c), 6(l)).

**Tech Stack:** Swift 6 (mode de langage 6.0, concurrence stricte), swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), SwiftUI/AppKit macOS 14+, XcodeGen (`project.yml`), aucune dépendance nouvelle.

**Spec:** `docs/PROPOSITION.md`, sections 3.5 (TaskStore), 3.6 (règles de file, pour ce qui touche au tableau), 4.1 (types `TaskCard`…), **4.3b (table C1 à C20 et invariants, à suivre ligne par ligne)**, 4.5 (fichiers), 5.6 (`PromptSanitizer`, règles 1 à 5), 6(b), 6(c), 6(l), 8 (étape 2b, tâche 1 et moitié UI de la tâche 2). La livraison dans le PTY (`DeliveryPlan`, `TaskDispatcher`, gardes G1 à G4) est l'étape **2b-2** : ici, l'effet `pump` est reçu mais ne fait rien d'autre que journaliser.

## Global Constraints

- Le cœur (`Core/`) doit compiler et passer ses tests **sous Linux et macOS** : Foundation seulement, pas d'AppKit, pas de `NSRegularExpression` exotique, pas d'API Darwin sans `#if canImport(Darwin)`.
- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete` : tous les types publics du cœur sont `Sendable`.
- Tests en swift-testing (`import Testing`), comme les 378 tests existants ; `cd Core && swift test` doit rester vert (et sans blocage).
- Le cœur est **pur** : dates, identifiants et UUID viennent de l'appelant (paramètres `now:`, `id:`), jamais de `Date()` ni de `UUID()` implicites dans le réducteur.
- Identifiants existants à réutiliser (`Core/Sources/PixelCore/Model/Identifiers.swift`) : `TaskCardID`, `PromptTemplateID`, `InstructionID`, `AgentID`, `ProjectID`.
- Signaux d'agent existants à consommer tels quels (`Core/Sources/PixelCore/State/AgentInputEffect.swift`) : `AgentCardSignal` (`deliveryConfirmed(promptID:)`, `turnCommitted(promptID:)`, `turnWaitingBackground`, `turnReopened(promptID:)`, `turnFailed`, `interrupted`, `sessionLost`, `deliveryFailed(DeliveryAbortReason)`).
- Persistance : même style que `workspace.json` (`PersistenceCodec`, encodeur trié, dates ISO 8601 à la milliseconde, `schemaVersion`, `Migrator`, fichier 0600 atomique, sauvegarde du jour, lecture seule si format plus récent, fichier illisible mis de côté).
- Interface en **français**, code et identifiants en **anglais**, commentaires en anglais au ton du code existant.
- **Jamais de tiret cadratin** (U+2014) nulle part : code, commentaires, chaînes, docs.
- L'app **n'approuve jamais rien** et n'écrit rien dans un terminal à cette étape.
- Signature et projet : ne jamais modifier `Config/Local.xcconfig` ; après un changement de `project.yml`, relancer `xcodegen generate`.
- Build de l'app : `xcodebuild -project PixelOpenSpace.xcodeproj -scheme PixelOpenSpace -configuration Debug -derivedDataPath build/DerivedData -skipPackagePluginValidation build` doit finir par `** BUILD SUCCEEDED **`.

## Review Focus

1. **Carte orpheline** : une carte assignée à un agent qui n'existe plus (agent retiré, fichier `tasks.json` d'une autre machine) : au chargement et au retrait d'un agent, elle doit redevenir « À faire », non assignée, jamais disparaître. Tests : `TaskBoardValidatorTests.unknownAssigneeIsUnassigned`, `TaskLifecycleTests.agentRemovedUnassignsTodoAndFlagsInProgress`.
2. **Collage de texte hostile** : un titre ou une description contenant `ESC[201~`, des caractères de contrôle, des contrôles bidi, ou commençant par `!` ou `/` : l'aperçu doit montrer exactement le texte nettoyé et le nombre de caractères retirés. Tests : `PromptSanitizerTests` (un test par règle 1 à 5).
3. **Signal d'agent sans carte correspondante** (`turnCommitted` d'un tour lancé à la main, `deliveryConfirmed` sans livraison en attente) : aucune carte ne doit bouger. Tests : `TaskLifecycleTests.stopWithoutMatchingPromptIDMovesNothing`, `confirmationWithoutPendingDeliveryIsIgnored`.
4. **Rangs qui se tassent** : insérer 200 fois en tête ou entre deux mêmes voisins doit garder un ordre strict et des clés de taille raisonnable. Test : `RankKeyTests.repeatedInsertionsStayOrdered`.
5. **Fichier `tasks.json` corrompu ou plus récent** : la carte ne se perd pas en silence (fichier mis de côté + bannière, ou lecture seule). Tests : `TaskBoardCodecTests.newerSchemaThrows`, `corruptThrows` ; côté app, même chemin que `workspace.json` dans `PersistenceStore`.

---

## Carte des fichiers

Cœur (`Core/Sources/PixelCore/`) :
- `Tasks/TaskModel.swift` (nouveau) : `Column`, `Priority`, `CardFlag`, `CardEventKind`, `CardEvent`, `DeliveryInfo`, `TaskCard`, `QueuedInstruction`, `PromptTemplate`, `TaskBoardState`, `QueueItem`.
- `Tasks/RankKey.swift` (nouveau) : clés d'ordre fractionnaires.
- `Tasks/TaskBoardValidator.swift` (nouveau) : réparation des invariants au chargement.
- `Tasks/StarterTemplates.swift` (nouveau) : les 3 modèles de départ.
- `Persistence/Codecs.swift` (modifié) : `encodeTasks` / `decodeTasks`.
- `Persistence/Migrator.swift` (modifié) : `tasksSteps: [MigrationStep] = []`.
- `Tasks/TaskLifecycle.swift` (nouveau) : `TaskInput`, `TaskContext`, `TaskEffect`, `TaskRejection`, `ConfirmationKind`, `TaskLifecycle.reduce`, `TaskLifecycle.confirmation(for:state:context:)`.
- `Tasks/PromptComposer.swift` (nouveau) et `Tasks/PromptSanitizer.swift` (nouveau) : `SanitizedPrompt`.
- `Tasks/PasteImporter.swift` (nouveau).
- `Tasks/BoardQuery.swift` (nouveau) : `BoardFilter`, `BoardQuery.filtered`, `BoardQuery.queue(of:)`, `FuzzyMatcher`.

Tests (`Core/Tests/PixelCoreTests/`) : `TaskModelTests.swift`, `RankKeyTests.swift`, `TaskBoardCodecTests.swift`, `TaskBoardValidatorTests.swift`, `TaskLifecycleTests.swift`, `TaskLifecyclePropertyTests.swift`, `PromptComposerTests.swift`, `PromptSanitizerTests.swift`, `PasteImporterTests.swift`, `BoardQueryTests.swift`.

App (`App/Sources/`) :
- `System/AppDirectories.swift` (modifié) : `tasksFile` (`state/tasks.json`).
- `System/PersistenceStore.swift` (modifié) : `loadTasks`, `scheduleSave(_ board: TaskBoardState, version:)`, flush.
- `AppMain/AppEnvironment.swift` (modifié) : charger `tasks.json` et le passer à `AppModel`.
- `Model/AppModel.swift` (modifié) : `private(set) var board: TaskBoardState`, `commitBoard(_:)`, flush.
- `Model/AppModel+Tasks.swift` (nouveau) : intentions du tableau, `applyTask(_:)` qui passe par `TaskLifecycle.reduce` et exécute les effets.
- `Model/AppModel+Engine.swift` (modifié) : l'effet `.card(signal)` des agents devient `applyTask(.agentSignal(agentID, signal))` ; `.pumpQueue` reste journalisé.
- `Model/AppModel+Intents.swift` (modifié) : retirer un agent libère ses cartes (`.agentRemoved`).
- `UI/Board/…` (nouveau dossier) : `BoardPanelView.swift`, `BoardColumnView.swift`, `TaskCardView.swift`, `BoardFilterBar.swift`, `QuickAddField.swift`, `CardEditorSheet.swift`, `TemplateManagerSheet.swift`, `PasteListSheet.swift`, `CardDragPayload.swift`.
- `UI/Agents/AgentCardView.swift` (modifié) : cible de dépôt d'un post-it, ligne « file : N post-its » et titre de la carte en cours.
- `Commands/AppCommand.swift`, `UI/Commands/AppMenuCommands.swift`, `UI/Commands/CommandAvailability.swift`, `UI/Support/WorkbenchState.swift`, `UI/Main/RootView.swift`, `UI/Main/SheetContentView.swift` (modifiés) : ⌘N nouveau post-it, ⌘B tableau, ⇧⌘V coller une liste, feuilles éditeur et modèles.

---

### Task 1: Modèle des post-its, rangs, codec et validateur de `tasks.json`

**Files:**
- Create: `Core/Sources/PixelCore/Tasks/TaskModel.swift`, `Core/Sources/PixelCore/Tasks/RankKey.swift`, `Core/Sources/PixelCore/Tasks/TaskBoardValidator.swift`, `Core/Sources/PixelCore/Tasks/StarterTemplates.swift`
- Modify: `Core/Sources/PixelCore/Persistence/Codecs.swift`, `Core/Sources/PixelCore/Persistence/Migrator.swift`
- Test: `Core/Tests/PixelCoreTests/TaskModelTests.swift`, `RankKeyTests.swift`, `TaskBoardCodecTests.swift`, `TaskBoardValidatorTests.swift`

**Interfaces:**
- Consumes: `TaskCardID`, `PromptTemplateID`, `InstructionID`, `AgentID`, `ProjectID` ; `PersistenceCodec.decode(_:from:current:migrations:allowNewerSchema:)` (interne au module) ; `Migrator`.
- Produces (utilisé par toutes les tâches suivantes) :

```swift
public enum Column: String, Codable, CaseIterable, Sendable { case todo, inProgress, review, done }
extension Column { public var title: String }   // "À faire", "En cours", "À valider", "Fait"

public enum Priority: Int, Codable, CaseIterable, Sendable, Comparable { case low = 0, normal = 1, high = 2 }
extension Priority { public var title: String }  // "basse", "normale", "haute"

public enum CardFlag: String, Codable, CaseIterable, Sendable {
    case deliveryFailed, interrupted, turnFailed, sessionLost, backgroundRunning
}

public enum CardEventKind: String, Codable, Sendable {
    case created, edited, assigned, unassigned, reassigned, reordered, deliveryStarted, deliveryConfirmed,
         deliveryFailed, turnEnded, turnReopened, turnFailed, interrupted, sessionLost, continued, putBack,
         markedForReview, resent, validated, reopened, projectChanged
}

public struct CardEvent: Codable, Hashable, Sendable {
    public var at: Date
    public var kind: CardEventKind
    public var from: Column?
    public var to: Column?
    public var agentID: AgentID?
    /// Short free text (reason of a failure, previous project name…), French.
    public var note: String?
    public init(at: Date, kind: CardEventKind, from: Column? = nil, to: Column? = nil, agentID: AgentID? = nil, note: String? = nil)
}

public struct DeliveryInfo: Codable, Hashable, Sendable {
    public var sessionID: String?
    public var promptID: String?
    public var sentAt: Date
    public var confirmedAt: Date?
    public var turnEndedAt: Date?
    /// Sent but neither confirmed nor failed yet.
    public var isPending: Bool { confirmedAt == nil }
    public init(sessionID: String? = nil, promptID: String? = nil, sentAt: Date, confirmedAt: Date? = nil, turnEndedAt: Date? = nil)
}

public struct TaskCard: Codable, Identifiable, Hashable, Sendable {
    public let id: TaskCardID
    public var title: String
    public var details: String
    public var projectID: ProjectID?
    public var column: Column
    /// Display order inside the column (`RankKey`).
    public var rank: String
    public var priority: Priority
    public var tags: [String]
    /// Only source of the assignment.
    public var assignee: AgentID?
    /// Rank in the assignee's queue; non-nil exactly when `column == .todo && assignee != nil`.
    public var queueRank: String?
    public var templateID: PromptTemplateID?
    /// Current or last delivery; earlier ones are summarized in `history`.
    public var delivery: DeliveryInfo?
    public var flags: Set<CardFlag>
    public var history: [CardEvent]
    /// Set once the card has been validated at least once (XP counted once, step 6).
    public var validatedOnce: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: TaskCardID = TaskCardID(), title: String, details: String = "", projectID: ProjectID?,
                column: Column = .todo, rank: String, priority: Priority = .normal, tags: [String] = [],
                assignee: AgentID? = nil, queueRank: String? = nil, templateID: PromptTemplateID? = nil,
                delivery: DeliveryInfo? = nil, flags: Set<CardFlag> = [], history: [CardEvent] = [],
                validatedOnce: Bool = false, createdAt: Date, updatedAt: Date? = nil)   // updatedAt defaults to createdAt
}

/// Ad hoc instruction in an agent's queue ("Donner une consigne", "Continuer la tâche", ↺ précision).
public struct QueuedInstruction: Codable, Identifiable, Hashable, Sendable {
    public let id: InstructionID
    public var agentID: AgentID
    public var text: String
    /// The card this instruction continues or refines (C14, C17), if any.
    public var cardID: TaskCardID?
    /// Instructions come before cards; among them, by this rank.
    public var queueRank: String
    /// Set while this instruction is being delivered.
    public var delivery: DeliveryInfo?
    public var createdAt: Date
    public init(id: InstructionID = InstructionID(), agentID: AgentID, text: String, cardID: TaskCardID? = nil,
                queueRank: String, delivery: DeliveryInfo? = nil, createdAt: Date)
}

public struct PromptTemplate: Codable, Identifiable, Hashable, Sendable {
    public let id: PromptTemplateID
    public var name: String
    /// Variables: {titre} {description} {projet} {chemin} {tags} {priorite}.
    public var body: String
    public init(id: PromptTemplateID = PromptTemplateID(), name: String, body: String)
}

/// What an agent's queue is made of (derived, never stored).
public enum QueueItem: Hashable, Sendable { case instruction(InstructionID), card(TaskCardID) }

/// Persisted as `state/tasks.json`.
public struct TaskBoardState: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var cards: [TaskCard]
    public var instructions: [QueuedInstruction]
    public var templates: [PromptTemplate]
    public init(schemaVersion: Int = TaskBoardState.currentSchemaVersion, cards: [TaskCard] = [],
                instructions: [QueuedInstruction] = [], templates: [PromptTemplate] = [])
    public func card(_ id: TaskCardID) -> TaskCard?
    public func template(_ id: PromptTemplateID) -> PromptTemplate?
    /// Cards of a column, by `rank` then `createdAt` then id.
    public func cards(in column: Column) -> [TaskCard]
    /// A fresh board with `StarterTemplates.make(ids:)` (first launch, no `tasks.json`).
    public static func initial(templateIDs: [PromptTemplateID]) -> TaskBoardState
}

public enum RankKey {
    /// A key strictly between `lower` and `upper` (nil = open end). Keys use the digits 0-9a-z and compare with `<`.
    /// Precondition: lower < upper when both are given (otherwise returns a key after `lower`).
    public static func between(_ lower: String?, _ upper: String?) -> String
    public static func after(_ key: String?) -> String      // between(key, nil)
    public static func before(_ key: String?) -> String     // between(nil, key)
    /// n evenly spread keys, ascending (renumbering, imports).
    public static func spread(_ count: Int) -> [String]
}

public enum StarterTemplates {
    /// "Corriger un bug", "Ajouter une fonctionnalité", "Écrire la documentation", with these ids (3 expected).
    public static func make(ids: [PromptTemplateID]) -> [PromptTemplate]
}

public enum TaskBoardValidator {
    /// Repairs a loaded board against the workspace's agents and projects; French messages for the load banner.
    public static func validate(_ board: TaskBoardState, agents: Set<AgentID>, projects: Set<ProjectID>)
        -> (board: TaskBoardState, issues: [String])
}

extension PersistenceCodec {
    public static func encodeTasks(_ board: TaskBoardState) throws -> Data
    public static func decodeTasks(_ data: Data, migrations: [MigrationStep] = Migrator.tasksSteps,
                                   allowNewerSchema: Bool = false) throws -> (board: TaskBoardState, migratedFrom: Int?)
}
extension Migrator { public static let tasksSteps: [MigrationStep] }   // [] for v1
```

Règles du validateur (une ligne de test chacune) : assignee inconnu → carte « À faire » non assignée (`inProgress`/`review` aussi, avec le drapeau `sessionLost` retiré et un événement `unassigned`), `projectID` inconnu → `nil` ; `queueRank` présent hors `todo ∧ assignee` → retiré ; `todo ∧ assignee ∧ queueRank == nil` → `RankKey.after` du dernier rang de la file de cet agent ; deux cartes `inProgress` pour le même agent → la plus ancienne (`updatedAt`) garde son état, les autres reçoivent le drapeau `interrupted` (aucune n'est déplacée ni perdue) ; `templateID` inconnu → `nil` ; consigne d'un agent inconnu → supprimée ; rangs dupliqués dans une colonne → renumérotés par `RankKey.spread` en gardant l'ordre ; tags : espaces retirés, `#` initial retiré, vides retirés, doublons retirés (insensible à la casse, premier gardé). Titre vide après `trimmingCharacters(in: .whitespacesAndNewlines)` → « Sans titre ».

Décodage tolérant : tous les champs ajoutés plus tard doivent avoir une valeur par défaut au décodage ; implémenter `init(from:)` de `TaskCard` avec `decodeIfPresent` pour `details` (""), `tags` ([]), `flags` ([]), `history` ([]), `validatedOnce` (false), `priority` (.normal), `updatedAt` (= `createdAt`).

- [ ] **Step 1: Write the failing tests.** `RankKeyTests` : `between(nil, nil)` non vide ; pour 500 paires aléatoires déterministes (générateur LCG à graine fixe, pas de `Math.random`), `a < between(a, b) < b` ; `repeatedInsertionsStayOrdered` : 200 insertions successives en tête (`before(first)`), 200 entre deux voisins fixes, l'ordre reste strict et chaque clé fait au plus 40 caractères ; `spread(5)` strictement croissant. `TaskModelTests` : `cards(in:)` trie par rang ; `initial` contient 3 modèles aux noms attendus ; `Column.title`, `Priority.title`. `TaskBoardCodecTests` : aller-retour encode/decode égal ; sortie triée et stable (deux encodages identiques octet par octet) ; `newerSchemaThrows` (`schemaVersion: 2` → `PersistenceError.newerSchema(found: 2, supported: 1)`) ; `allowNewerSchema: true` décode ; `corruptThrows` (`"[1,2"` → `.corrupt`) ; champs optionnels absents → valeurs par défaut (fixture JSON minimale écrite dans le test). `TaskBoardValidatorTests` : une fonction de test par règle ci-dessus, dont `unknownAssigneeIsUnassigned`.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "RankKeyTests|TaskModelTests|TaskBoardCodecTests|TaskBoardValidatorTests"` → échec de compilation (types absents).
- [ ] **Step 3: Implement** les fichiers listés, en suivant le style de `Workspace.swift`, `Codecs.swift` et `WorkspaceValidator.swift` (lire ces trois fichiers d'abord). `RankKey` : alphabet `0123456789abcdefghijklmnopqrstuvwxyz`, milieu entre deux clés chiffre par chiffre (on prolonge la clé la plus courte par le chiffre minimal pour `lower` et maximal+1 virtuel pour `upper`), jamais de clé se terminant par `0` (sinon plus rien ne peut s'insérer avant elle).
- [ ] **Step 4: Run.** Même commande → PASS ; puis `cd Core && swift test` complet → 378 + nouveaux tests verts.
- [ ] **Step 5: Commit.** `git add Core && git commit -m "Core step 2b: task card model, rank keys, tasks.json codec and validator"`

### Task 2: Réducteur `TaskLifecycle` (C1 à C20) et propriétés

**Files:**
- Create: `Core/Sources/PixelCore/Tasks/TaskLifecycle.swift`
- Test: `Core/Tests/PixelCoreTests/TaskLifecycleTests.swift`, `Core/Tests/PixelCoreTests/TaskLifecyclePropertyTests.swift`

**Interfaces:**
- Consumes: tout le modèle de la tâche 1 ; `AgentCardSignal`, `DeliveryAbortReason` (existants).
- Produces :

```swift
/// What the reducer needs to know about the world (all read by the caller, at call time).
public struct TaskContext: Sendable {
    public var now: Date
    /// Project of each app agent (unknown agents are absent).
    public var agentProjects: [AgentID: ProjectID]
    /// Agents whose `claude` process is running.
    public var liveAgents: Set<AgentID>
    public init(now: Date, agentProjects: [AgentID: ProjectID], liveAgents: Set<AgentID>)
}

public enum TaskInput: Equatable, Sendable {
    case create(id: TaskCardID, title: String, details: String, projectID: ProjectID?, priority: Priority, tags: [String], templateID: PromptTemplateID?)   // C1, appended at the end of "À faire"
    case edit(TaskCardID, CardEdit)
    case assign(TaskCardID, to: AgentID)            // C2 / C3 (project changes to the agent's)
    case unassign(TaskCardID)                        // C4
    case reorderQueue(TaskCardID, after: TaskCardID?)   // C4, inside the assignee's queue (nil = head)
    case move(TaskCardID, to: Column, after: TaskCardID?)   // drag between/inside columns: C5, C15, C16, C18; same column = reorder
    case deliveryStarted(QueueItem, agent: AgentID, sessionID: String?)   // C6
    case agentSignal(AgentID, AgentCardSignal)       // C7, C8, C10 to C13
    case retry(TaskCardID)                           // C9
    case continueTask(TaskCardID, instructionID: InstructionID)   // C14
    case putBack(TaskCardID)                         // C15
    case markForReview(TaskCardID)                   // C16
    case resend(TaskCardID, precision: String, instructionID: InstructionID)   // C17
    case validate(TaskCardID)                        // C18
    case reopen(TaskCardID)                          // C19
    case delete(TaskCardID)                          // C20
    case giveInstruction(agent: AgentID, text: String, instructionID: InstructionID, atHead: Bool)
    case agentRemoved(AgentID)
    case upsertTemplate(PromptTemplate)
    case deleteTemplate(PromptTemplateID)            // cards using it fall back to nil
}

public enum CardEdit: Equatable, Sendable {
    case title(String), details(String), priority(Priority), tags([String]), template(PromptTemplateID?), project(ProjectID?)
}

public enum TaskRejection: Equatable, Sendable {
    case unknownCard, unknownAgent, notInTodo, dragToInProgress, notAllowed(String)
}

public enum TaskEffect: Equatable, Sendable {
    case pump(AgentID)                    // the dispatcher (step 2b-2) may deliver the head of this queue
    case notify(String)                   // French text, e.g. "Échec d'envoi de « Titre » à Nova"
    case validated(TaskCardID, firstTime: Bool)   // XP later (step 6)
    case rejected(TaskRejection, message: String) // UI toast; the state is unchanged
    case warn(String)                     // C17 session changed, and similar
}

/// Asked by the UI before applying an input (C3, C18 from todo or inProgress, C20 from inProgress).
public enum ConfirmationKind: Equatable, Sendable {
    case assignAcrossProjects(agent: AgentID, from: ProjectID?, to: ProjectID)
    case markDoneWithoutReview(TaskCardID)
    case deleteInProgress(TaskCardID)
}

public enum TaskLifecycle {
    public static func reduce(_ state: TaskBoardState, _ input: TaskInput, context: TaskContext) -> (TaskBoardState, [TaskEffect])
    public static func confirmation(for input: TaskInput, state: TaskBoardState, context: TaskContext) -> ConfirmationKind?
}
```

Sémantique à respecter exactement (proposition 4.3b, lire la table en entier) :
- Chaque transition ajoute un `CardEvent` à `history` et met `updatedAt = context.now`. Une entrée refusée ne change **rien** (pas même `updatedAt`) et émet un seul `.rejected`.
- C2/C3 : garde `column == .todo` et agent connu dans `agentProjects`. Si le projet de la carte diffère de celui de l'agent (ou est `nil`), `projectID` devient celui de l'agent, événement `projectChanged` en plus. `queueRank = RankKey.after(dernier rang de la file de l'agent, consignes comprises dans l'ordre global)`. Effet `.pump(agent)`. `confirmation(for:)` renvoie `.assignAcrossProjects` quand les projets diffèrent et que la carte en a un.
- C4 : `unassign` sur `todo` → `assignee = nil`, `queueRank = nil` ; réassigner à `b` = `assign` ; `reorderQueue` recalcule `queueRank` entre les voisins ; effet `.pump` de l'agent concerné (le nouveau).
- C5 : `assign`/`move(.inProgress)` d'une carte `inProgress`, `review` ou `done` (et tout `move(to: .inProgress)`) → `.rejected(.dragToInProgress, message: "Glisse-la sur un agent pour la lancer.")` ou `"Remets-la d'abord à faire."` selon le cas.
- C6 : `deliveryStarted(.card(id))` exige que la carte soit en tête de la file de `agent` → `delivery = DeliveryInfo(sessionID:, sentAt: now)` (colonne inchangée, drapeau `deliveryFailed` retiré). Pour `.instruction(id)` : `instruction.delivery = …`.
- C7 : `agentSignal(a, .deliveryConfirmed(p))` : s'il existe une consigne de `a` avec livraison en attente, elle est **retirée** ; si elle a un `cardID` dont la carte est `review` (C17) ou `inProgress` (C14), la carte passe/reste `inProgress` avec `delivery = DeliveryInfo(promptID: p, sentAt: …, confirmedAt: now)` et drapeaux retirés. Sinon, la carte de `a` en `todo` dont `delivery?.isPending == true` passe `inProgress`, `queueRank = nil`, `delivery.promptID = p`, `delivery.confirmedAt = now`. Sans livraison en attente : rien ne bouge (`confirmationWithoutPendingDeliveryIsIgnored`).
- C8 : `.deliveryFailed(r)` : la carte (ou consigne) en attente reste en tête, `delivery` effacée (une carte) ou `delivery = nil` (une consigne), carte : drapeau `deliveryFailed` ; effet `.notify("Échec d'envoi de « <titre> » à l'agent. La file est en pause.")`.
- C9 : `retry` exige le drapeau `deliveryFailed` → retiré, effet `.pump(assignee)`.
- C10 : `.turnCommitted(p)` : la carte `inProgress` de `a` dont `delivery.promptID == p`, ou, si `p == nil` ou si la carte a `delivery.promptID == nil`, la seule carte `inProgress` de `a` dont `delivery.turnEndedAt == nil` → `review`, `delivery.turnEndedAt = now`, drapeau `backgroundRunning` retiré. Aucune correspondance → rien (`stopWithoutMatchingPromptIDMovesNothing`). Toujours émettre `.pump(a)` après un `turnCommitted`, même sans carte (la file peut enchaîner).
- C11 : `.turnWaitingBackground` → drapeau `backgroundRunning` sur la carte `inProgress` de `a`.
- C12 : `.turnReopened(p)` : carte `review` de `a` avec `delivery.promptID == p` et `validatedOnce == false` → `inProgress`, `turnEndedAt = nil`.
- C13 : `.turnFailed` / `.interrupted` / `.sessionLost` → drapeau correspondant sur la carte `inProgress` de `a` (colonne inchangée). `.sessionLost` sur une carte `todo` en livraison en attente → comme C8.
- C14 : `continueTask` exige `inProgress`, un drapeau parmi `interrupted`/`turnFailed`/`sessionLost`, et l'assignee dans `liveAgents` → drapeaux retirés, consigne « Continue la tâche : <titre> » (id fourni, `cardID`) **en tête** (`RankKey.before` de la première clé de la file), effet `.pump`.
- C15 : `putBack` depuis `inProgress` ou `review` → `todo`, non assigné, drapeaux retirés, `delivery` versée à `history` (événement `putBack` avec `note` = "tour <promptID>") puis `nil`, rang en fin de « À faire ». Aussi `move(to: .todo)`.
- C16 : `markForReview` / `move(to: .review)` depuis `inProgress` → `review`.
- C17 : `resend` exige `review` → consigne « <précision> » en tête de file de l'assignee (`cardID`) ; si l'assignee n'est pas dans `liveAgents` → `.rejected(.notAllowed(…), message: "Relance d'abord la session de l'agent.")` ; carte inchangée jusqu'au C7 de la consigne.
- C18 : `validate` / `move(to: .done)` depuis `review` → `done`, `.validated(id, firstTime: !validatedOnce && delivery != nil)` puis `validatedOnce = true` si `delivery != nil`. Depuis `todo` ou `inProgress` : permis (la confirmation est l'affaire de l'UI via `confirmation(for:)` qui renvoie `.markDoneWithoutReview`), mêmes effets ; une carte `todo` assignée quitte la file (`assignee` gardé pour l'historique ? non : `assignee = nil`, `queueRank = nil`).
- C19 : `reopen` depuis `done` → `todo`, non assignée, rang en fin, `validatedOnce` inchangé.
- C20 : `delete` → carte retirée, ainsi que les consignes qui la référencent ; `confirmation(for:)` renvoie `.deleteInProgress` pour une carte `inProgress`.
- `giveInstruction` : consigne pour l'agent (tête si `atHead`, sinon après les autres consignes mais avant les cartes), effet `.pump`.
- `agentRemoved(a)` : cartes `todo` de `a` → non assignées (rang en fin de colonne) ; cartes `inProgress`/`review` de `a` → `todo` non assignées avec événement `unassigned` (même traitement que C15) ; consignes de `a` supprimées. Test `agentRemovedUnassignsTodoAndFlagsInProgress`.
- `edit` : titre vide refusé (`.rejected(.notAllowed, "Un post-it a besoin d'un titre.")`) ; tags normalisés comme au validateur ; `edit(.project)` interdit si la carte est assignée (refus explicite).
- `deleteTemplate` : les cartes qui l'utilisent passent à `templateID = nil`.

Invariants (fichier `TaskLifecyclePropertyTests.swift`, 300 séquences de 60 entrées aléatoires déterministes par graine, sur un monde de 3 agents dans 2 projets, dont un agent hors ligne) : (1) au plus une carte `inProgress` par agent **sans drapeau** (une carte qui arrive en `inProgress` alors qu'une autre y est déjà pour le même agent ne doit pas pouvoir se produire : C7 d'une carte `todo` alors qu'une autre carte du même agent est déjà `inProgress` sans drapeau → la carte déjà en cours reçoit `interrupted`, ce cas est testé explicitement) ; (2) `queueRank != nil` ⇔ `todo ∧ assignee != nil` ; (3) une carte `done` n'a jamais de livraison en attente ; (4) `.validated(_, firstTime: true)` au plus une fois par carte sur toute la séquence ; (5) aucune entrée ne fait disparaître une carte hors `delete` ; (6) toute carte assignée l'est à un agent de `agentProjects`.

- [ ] **Step 1: Write the failing tests.** `TaskLifecycleTests` : **un `@Test` par ligne C1 à C20** (nommés `c01_create…` à `c20_delete…`), plus les cas nommés dans cette tâche et dans Review Focus, plus un test par `ConfirmationKind`. Fabriquer un petit monde (`Fixture`) : 2 projets, 3 agents, `now` fixe, ids déterministes (`UUID(uuidString: "00000000-0000-0000-0000-00000000000N")`). `TaskLifecyclePropertyTests` : les 6 invariants.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "TaskLifecycle"` → échec de compilation.
- [ ] **Step 3: Implement** `TaskLifecycle.swift` : un `struct Step` mutable interne (comme `AgentStateMachine.swift`, lire son organisation d'abord) avec `emit(_:)`, une méthode par entrée, des helpers `queue(of:)`, `headOfQueue(_:)`, `lastRankInTodo()`.
- [ ] **Step 4: Run.** `cd Core && swift test` → tout vert.
- [ ] **Step 5: Commit.** `git commit -m "Core step 2b: TaskLifecycle reducer (C1 to C20) with property tests"`

### Task 3: `PromptComposer`, `PromptSanitizer`, `PasteImporter`

**Files:**
- Create: `Core/Sources/PixelCore/Tasks/PromptComposer.swift`, `Core/Sources/PixelCore/Tasks/PromptSanitizer.swift`, `Core/Sources/PixelCore/Tasks/PasteImporter.swift`
- Test: `Core/Tests/PixelCoreTests/PromptComposerTests.swift`, `PromptSanitizerTests.swift`, `PasteImporterTests.swift`

**Interfaces:**
- Consumes: `TaskCard`, `PromptTemplate`, `Priority` (tâche 1).
- Produces :

```swift
public struct PromptSubject: Sendable {
    public var title: String; public var details: String; public var projectName: String?
    public var projectPath: String?; public var tags: [String]; public var priority: Priority
    public init(card: TaskCard, projectName: String?, projectPath: String?)
}
public enum PromptComposer {
    /// Template resolution: card.templateID, else projectDefault, else none. Unknown ids count as none.
    public static func resolveTemplate(card: TaskCard, projectDefault: PromptTemplateID?, in board: TaskBoardState) -> PromptTemplate?
    /// With a template: its body with {titre} {description} {projet} {chemin} {tags} {priorite} replaced
    /// ({tags} = "#a #b", {priorite} = Priority.title, missing values = ""); unknown {x} kept verbatim.
    /// Without: the title, then a line break and the description when it is not blank.
    public static func compose(_ subject: PromptSubject, template: PromptTemplate?) -> String
}

public struct SanitizedPrompt: Equatable, Sendable {
    public var text: String
    /// Characters removed by rules 2 and 3.
    public var removedCount: Int
    /// Rule 4 added "Tâche : ".
    public var prefixed: Bool
    /// ≤ 800 characters and ≤ 3 lines: typed, not pasted (5.6).
    public var isShort: Bool
    /// Over 16 KB (UTF-8): the app asks before sending.
    public var needsConfirmation: Bool
    public var isEmpty: Bool { text.isEmpty }
}
public enum PromptSanitizer {
    public static let shortMaxCharacters = 800
    public static let shortMaxLines = 3
    public static let confirmationBytes = 16 * 1024
    public static func sanitize(_ raw: String) -> SanitizedPrompt
    /// "112 caractères · saisie courte · aucun caractère retiré" (mockup 6(l)); "collage" for long texts,
    /// "3 caractères retirés", "préfixé par « Tâche : »".
    public static func summary(_ prompt: SanitizedPrompt) -> String
}

public struct PastedCard: Equatable, Sendable { public var title: String; public var details: String }
public enum PasteImporter {
    /// One card per line; bullets "-", "*", "•", "1.", "1)", "[ ]", "[x]", "- [ ]" removed; blank lines ignored;
    /// an indented line (tab or ≥ 2 spaces) under a card is appended to its details (joined by "\n").
    public static func cards(from text: String) -> [PastedCard]
}
```

Règles du nettoyage, dans l'ordre (5.6), un test chacune : (1) CRLF et CR → LF, tabulation → deux espaces ; (2) retirer ESC (U+001B), les C0 sauf LF, DEL (U+007F) et les C1 (U+0080 à U+009F) : `"a\u{1B}[201~b"` devient `"a[201~b"` avec `removedCount == 1` ; (3) retirer largeur nulle (U+200B, U+200C, U+200D, U+2060), contrôles bidi (U+200E, U+200F, U+202A à U+202E, U+2066 à U+2069), BOM (U+FEFF) ; (4) après `trimmingCharacters(in: .whitespaces)` du début, si le premier caractère est `!`, `/`, `?` ou `@`, préfixer par « Tâche : » ; (5) retirer les sauts de ligne finaux (et espaces finaux). Compter les caractères en `Character` (graphèmes) pour `isShort` ; lignes = nombre de LF + 1 ; `needsConfirmation` sur `text.utf8.count > 16384`. Emoji et accents conservés tels quels (test). Texte vide ou fait de contrôles → `isEmpty`.

- [ ] **Step 1: Write the failing tests** (règles ci-dessus ; `compose` avec chaque variable, variable inconnue gardée, sans modèle avec et sans description ; `resolveTemplate` carte > projet > rien, id inconnu ; `PasteImporter` : puces variées, lignes vides, indentation, liste numérotée `1.` et `1)`, texte sans saut de ligne final, CRLF).
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "PromptComposerTests|PromptSanitizerTests|PasteImporterTests"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `cd Core && swift test` → vert.
- [ ] **Step 5: Commit.** `git commit -m "Core step 2b: prompt composer, sanitizer and pasted-list import"`

### Task 4: Requêtes du tableau (`BoardQuery`, `FuzzyMatcher`)

**Files:**
- Create: `Core/Sources/PixelCore/Tasks/BoardQuery.swift`
- Test: `Core/Tests/PixelCoreTests/BoardQueryTests.swift`

**Interfaces:**
- Consumes: modèle de la tâche 1.
- Produces :

```swift
public struct BoardFilter: Equatable, Sendable {
    public var projectID: ProjectID?          // nil = all projects
    public var columns: Set<Column>           // empty = all
    public var tags: Set<String>              // all must be present (case-insensitive)
    public var text: String                   // fuzzy on title, details, tags
    public var assignee: AgentID?
    public init(projectID: ProjectID? = nil, columns: Set<Column> = [], tags: Set<String> = [], text: String = "", assignee: AgentID? = nil)
    public var isEmpty: Bool
}
public enum FuzzyMatcher {
    /// Case- and diacritic-insensitive; every whitespace-separated word of `query` must be a subsequence of
    /// some word-joined `candidate` text. Empty query matches everything.
    public static func matches(_ query: String, _ candidate: String) -> Bool
}
public enum BoardQuery {
    /// Every column (even empty), cards filtered and ordered by `rank`.
    public static func filtered(_ board: TaskBoardState, _ filter: BoardFilter) -> [Column: [TaskCard]]
    /// Instructions of the agent by queueRank, then its todo cards by queueRank.
    public static func queue(of agent: AgentID, in board: TaskBoardState) -> [QueueItem]
    /// 1-based position of a card in its assignee's queue ("file #2"), nil if not queued.
    public static func queuePosition(of card: TaskCardID, in board: TaskBoardState) -> Int?
    /// The card an agent is working on (inProgress), if any.
    public static func currentCard(of agent: AgentID, in board: TaskBoardState) -> TaskCard?
    /// All tags used on the board, sorted, case-insensitively unique.
    public static func allTags(_ board: TaskBoardState) -> [String]
}
```

- [ ] **Step 1: Write the failing tests** : filtre par projet, colonne, tags (ET), texte (accent « Pagination » trouvé par « pagi », « deploiement » trouve « Déploiement »), combinaison ; toutes les colonnes présentes même vides ; `queue(of:)` consignes puis cartes, chacune par rang ; `queuePosition` ; `currentCard` ; `allTags` dédoublonné.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter BoardQueryTests`.
- [ ] **Step 3: Implement** (repli des diacritiques : `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`, disponible sous Linux).
- [ ] **Step 4: Run** `cd Core && swift test` → vert.
- [ ] **Step 5: Commit.** `git commit -m "Core step 2b: board queries and fuzzy matching"`

### Task 5: Persistance et branchement dans l'app (sans interface)

**Files:**
- Modify: `App/Sources/System/AppDirectories.swift`, `App/Sources/System/PersistenceStore.swift`, `App/Sources/AppMain/AppEnvironment.swift`, `App/Sources/Model/AppModel.swift`, `App/Sources/Model/AppModel+Engine.swift`, `App/Sources/Model/AppModel+Intents.swift`
- Create: `App/Sources/Model/AppModel+Tasks.swift`

**Interfaces:**
- Consumes: tâches 1 à 4.
- Produces (utilisé par la tâche 6) :

```swift
// AppModel
private(set) var board: TaskBoardState
func commitBoard(_ newBoard: TaskBoardState)          // like commit(_:) for the workspace
// AppModel+Tasks.swift
@discardableResult func applyTask(_ input: TaskInput) -> [TaskEffect]   // reduce with a fresh TaskContext, commit, run effects
func taskConfirmation(for input: TaskInput) -> ConfirmationKind?
@discardableResult func createCard(title: String, projectID: ProjectID?) -> TaskCardID?   // nil when the title is blank
func createCards(fromPasted text: String, projectID: ProjectID?) -> [TaskCardID]
func promptPreview(for cardID: TaskCardID) -> SanitizedPrompt?     // PromptComposer + PromptSanitizer, exactly what 2b-2 will type
func queue(of agent: AgentID) -> [QueueItem]
func queuePosition(of card: TaskCardID) -> Int?
func currentCard(of agent: AgentID) -> TaskCard?
var boardFilter: BoardFilter                            // observed, not persisted
var filteredBoard: [Column: [TaskCard]] { get }
```

- `PersistenceStore` : `loadTasks(agents:projects:now:) -> LoadedFile<TaskBoardState>` sur le modèle de `loadWorkspace` (fichier absent → `TaskBoardState.initial(templateIDs:)` avec 3 ids neufs ; puis `TaskBoardValidator.validate`) ; `scheduleSave(_ board: TaskBoardState, version:)` avec son propre couple pending/written et sa tâche de 500 ms ; `flush()` écrit aussi le tableau. Réutiliser `write(_:to:currentSchema:)` et les sauvegardes du jour (le nom de fichier distingue déjà).
- `AppModel.commitBoard` respecte `isPersistenceSuspended` comme `commit(_:)` ; `flushPersistence()` sauve aussi le tableau.
- `applyTask` : construit `TaskContext(now: Date(), agentProjects: Dictionary(uniqueKeysWithValues: workspace.agents.map { ($0.id, $0.projectID) }), liveAgents: Set(runtimes.filter { $0.value.pid != nil }.keys))`, appelle `TaskLifecycle.reduce`, `commitBoard`, puis effets : `.pump(a)` → `AppLog.sessions.debug` (« pump reçu, livraison à l'étape 2b-2 ») ; `.notify(text)` → `showToast(text, style: .warning)` ; `.rejected(_, message)` → `showToast(message)` ; `.warn(text)` → `showToast(text, style: .warning)` ; `.validated` → rien pour l'instant. Vérifier les styles de `Toast.Style` existants dans `Model/ModelTypes.swift` et utiliser ceux qui existent.
- `AppModel+Engine.swift` : l'effet `.card(let signal)` d'un agent appelle `applyTask(.agentSignal(agentID, signal))` (lire le code actuel autour de la ligne 33 : il faut l'identifiant de l'agent dans ce contexte).
- `AppModel+Intents.swift` : l'intention qui retire un agent applique aussi `applyTask(.agentRemoved(id))`.

- [ ] **Step 1:** lire `AppModel.swift`, `AppModel+Engine.swift`, `AppModel+Intents.swift`, `PersistenceStore.swift`, `AppEnvironment.swift`, `AppDirectories.swift`, `ModelTypes.swift`.
- [ ] **Step 2:** implémenter ; aucun changement d'interface visible.
- [ ] **Step 3: Build.** `xcodegen generate && xcodebuild … build` (commande des contraintes globales) → `** BUILD SUCCEEDED **`, sans nouvel avertissement de concurrence.
- [ ] **Step 4:** `cd Core && swift test` toujours vert.
- [ ] **Step 5: Commit.** `git commit -m "App step 2b: tasks.json persistence and TaskLifecycle wiring"`

### Task 6: Interface du tableau, éditeur, modèles, commandes, glisser-déposer

**Files:**
- Create: `App/Sources/UI/Board/BoardPanelView.swift`, `BoardColumnView.swift`, `TaskCardView.swift`, `BoardFilterBar.swift`, `QuickAddField.swift`, `CardEditorSheet.swift`, `TemplateManagerSheet.swift`, `PasteListSheet.swift`, `CardDragPayload.swift`
- Modify: `App/Sources/UI/Main/RootView.swift`, `App/Sources/UI/Main/SheetContentView.swift`, `App/Sources/UI/Support/WorkbenchState.swift`, `App/Sources/Commands/AppCommand.swift`, `App/Sources/Commands/CommandCenter.swift`, `App/Sources/UI/Commands/AppMenuCommands.swift`, `App/Sources/UI/Commands/CommandAvailability.swift`, `App/Sources/UI/Agents/AgentCardView.swift`

**Interfaces:**
- Consumes: tâche 5 (`AppModel.board`, `applyTask`, `taskConfirmation`, `createCard`, `createCards`, `promptPreview`, `boardFilter`, `filteredBoard`, `queuePosition`, `currentCard`).

Comportement (maquettes 6(b), 6(c), 6(l) ; lire aussi les vues existantes pour réutiliser `ProjectHue`, `StateStyle`, les feuilles et `WorkbenchState.activeSheet`) :
- **Panneau « Tableau »** à droite de la liste des agents (colonne de la maquette 6(b)), affiché ou masqué par ⌘B (commande `toggleBoard`, menu Présentation), largeur réglable, état mémorisé (`@AppStorage`). Quatre sections empilées « À FAIRE (n) », « EN COURS (n) », « À VALIDER (n) », « FAIT (n) ▸ » (repliée par défaut).
- **Barre de filtres** : projet (Tous / chaque projet), tags (menu des tags existants, cumulables), recherche texte (`FuzzyMatcher`) ; bouton « + ⌘N ».
- **⌘N** (commande `newCard`, menu Fichier) : ouvre le panneau si besoin et un champ de titre en tête de « À faire » ; Entrée crée (`createCard`, projet = filtre projet courant sinon projet sélectionné), Échap annule. Objectif : un post-it en moins de 5 s.
- **Coller une liste** (⇧⌘V, commande `pasteCards`) : feuille avec une zone de texte préremplie par le presse-papiers, aperçu du nombre de post-its (`PasteImporter`), projet cible, bouton « Créer n post-its ».
- **Carte** : titre, 2 lignes de description, punaise colorée selon la priorité (rouge haute, jaune normale, verte basse) avec la priorité en toutes lettres dans l'aide et pour VoiceOver, pastille de couleur du projet, tags `#x`, ligne d'état (« non assigné », « ☺ Nova · file #2 », « ☺ Pixou · en cours », drapeaux lisibles : « échec d'envoi », « interrompue », « tâche de fond en cours »…). « À valider » : boutons « Valider » (⌘↩ quand la carte a le focus) et « ↺ » (feuille « Renvoyer avec une précision » → `.resend`). Double-clic ou Entrée : éditeur.
- **Menu contextuel** : Modifier…, Donner à › (agents du projet, puis « Autres projets » ; confirmation si `taskConfirmation` le demande), Retirer de la file, Remettre à faire, Marquer à valider, Valider, Rouvrir, Continuer la tâche (si drapeau), Réessayer l'envoi (si `deliveryFailed`), Supprimer (⌘⌫, confirmation si `deleteInProgress`). N'afficher que les actions permises par l'état de la carte.
- **Glisser-déposer** : une carte se glisse (payload `CardDragPayload` = l'UUID en texte, type `UTType.plainText` ou un type exporté propre, sans conflit avec le dépôt de dossiers existant de `RootView`) vers une autre section (`.move(id, to:, after:)`) ou **sur une carte d'agent** (`AgentCardView` devient cible de dépôt → `.assign`, avec la confirmation inter-projets). Un refus s'affiche en toast (message du réducteur).
- **Éditeur** (feuille, maquette 6(l)) : titre, description, projet (désactivé si assignée), priorité (3 boutons), tags (ajout, retrait), modèle (menu + « Gérer les modèles… »), ligne d'assignation, **aperçu du prompt** en police à chasse fixe via `promptPreview`, avec `PromptSanitizer.summary`, historique lisible (date courte + libellé français de chaque `CardEventKind`), Supprimer. Chaque champ s'applique par `applyTask(.edit(…))` à la validation.
- **Modèles** (feuille) : liste, créer, dupliquer, modifier (nom, corps, rappel des variables), supprimer, « Défaut du projet » (écrit `Project.defaults.templateID` via une intention workspace existante ou nouvelle dans `AppModel+Intents.swift`).
- **Carte d'agent** : ligne « file : n post-it(s) » et « ▣ <titre de la carte en cours> ».
- Accessibilité : chaque carte a un libellé VoiceOver complet (« Post-it Pagination /users, priorité haute, projet API, à faire, assigné à Nova, file 2 »). Jamais la couleur seule.

- [ ] **Step 1:** lire `RootView.swift`, `WorkbenchState.swift`, `SheetContentView.swift`, `AppCommand.swift`, `CommandCenter.swift`, `AppMenuCommands.swift`, `CommandAvailability.swift`, `AgentBoardView.swift`, `AgentCardView.swift`, `ProjectHue.swift`, une feuille existante (`NewAgentSheet.swift`).
- [ ] **Step 2:** implémenter par petits fichiers, en suivant les conventions existantes (commandes déclarées dans `AppCommand`, disponibilité dans `CommandAvailability`).
- [ ] **Step 3: Build** (commande des contraintes globales) → `** BUILD SUCCEEDED **`.
- [ ] **Step 4:** relancer l'app compilée (`open build/DerivedData/Build/Products/Debug/PixelOpenSpace.app`) et vérifier qu'elle démarre et que `~/Library/Application Support/PixelOpenSpace/state/tasks.json` est créé après une création de post-it si l'environnement le permet ; sinon le signaler.
- [ ] **Step 5: Commit.** `git commit -m "App step 2b: cork board panel, card editor, templates, drag to agents"`

## Hors de ce plan (étape 2b-2 et 2b-3)

`DispatchPolicy`, `DeliveryPlan` et ses gardes, `TaskDispatcher`, « Premier agent libre », « Lancer un nouvel agent avec ce post-it », « Glisser dans le tour en cours », la relance complète (feuille « Relancer les sessions », orphelins). Ils consommeront `TaskLifecycle` (`deliveryStarted`, signaux) et `BoardQuery.queue(of:)` tels que définis ici.
