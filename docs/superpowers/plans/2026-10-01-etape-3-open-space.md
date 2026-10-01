# Étape 3 : l'open space isométrique : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** remplacer la liste des agents par l'open space isométrique (proposition, section 8, « Étape 3 »). La scène SpriteKit dessine exactement ce que le cœur a validé au jalon visuel, au pixel près à chaque zoom. La caméra se pilote à la souris, au trackpad et au clavier. Un clic sur un agent ouvre sa fenêtre, un double-clic son terminal. Un post-it se glisse du tableau sur un agent de la scène, même hors champ. La mini-carte, les flèches de bord, la barre d'état et le plateau d'attente font voler la caméra. Les agents arrivent par l'ascenseur et les meubles d'un nouvel îlot tombent dans la poussière. La vue Liste reste disponible par ⌘L et reste le chemin VoiceOver principal.

**Architecture:** le cœur décide, SpriteKit affiche. `ScenePlanner` (cœur, tâche 4) transforme un `SceneInput` en un **plan de nœuds** à identifiant stable : pour chaque nœud, le sprite (clé du catalogue, image d'un personnage ou image composée), la position et l'ancre entières en texels, l'ordre de dessin et la cible d'un clic ; le sol, les ombres et les murs forment un **fond cuit** par le cœur. `SceneCompositor` rend ce même plan en logiciel : c'est la **référence**, déjà figée par les empreintes golden. Côté app, `WorldScene` réconcilie ses `SKSpriteNode` par identifiant (diff calculé par le cœur), `SpriteRegistry` fournit les textures (atlas du cœur, filtrage `.nearest`) et `WorldCamera` applique les règles de caméra du cœur (zooms, recalage au pixel physique, vols). Hit-test, résolution des clics et des dépôts, flèches de bord, mini-carte, défilement automatique, trajets et événements d'arrivée sont des fonctions pures du cœur, testées sous Linux. Un **banc de captures** (`PixelOpenSpace --snapshot`, tâche 1) lance l'app sur un état temporaire isolé, charge 20 agents simulés sur 6 projets, capture la fenêtre et la scène en PNG à chaque zoom, compare la scène à la référence logicielle, puis quitte : chaque tâche d'app regarde son propre résultat avec ces images.

**Tech Stack:** Swift 6.2 (mode de langage 6, concurrence stricte), swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), SpriteKit, SwiftUI et AppKit (macOS 14+), XcodeGen ; aucune dépendance nouvelle.

**Spec:** `docs/PROPOSITION.md` : section 8 « Étape 3 » (périmètre, tâches, tests, critère de fin) ; 3.8 (`WorldLayout`, `IsoMath`) ; **3.9 en entier** (scène, vue, caméra, résolution des clics, table des cibles de dépôt, défilement automatique, plateau d'attente, flèches de bord, budgets d'énergie, caméra et souris) ; 3.10 (atlas, `SpriteRegistry`) ; 3.12 (clic de notification) ; 3.13 ; 3.16 (⌘L, ⌘B, ⌘+ ⌘− ⌘0, ↩) ; 4.1 (types) ; maquettes 6(a), 6(d), 6(e), 6(e′), 6(k), 6(o), 6(q), 6(r) ; section 7 (direction artistique, déjà réalisée dans le cœur), **7.3 (règles pixel parfait 1 à 6)**, 7.4.4 (animations et déclencheurs), 7.6 (atlas et manifeste), 7.9 (accessibilité). Lire aussi `docs/jalon-visuel/README.md` (décisions du 2026-10-01 et défauts restants), `docs/superpowers/plans/2026-10-01-jalon-visuel.md` (conventions des sprites), `docs/ASSETS.md`, `docs/ETAPE-2B.md`, et le code existant cité dans chaque tâche.

## Global Constraints

- **État réel de l'utilisateur intouchable.** Ne jamais écrire dans `~/Library/Application Support/PixelOpenSpace` ni dans les préférences `fr.vv2.pixelopenspace` ; ne jamais y lire de contenu (seul contrôle permis : `find … -newer <marqueur>`, en lecture des dates seulement, tâche 1). Ne jamais lancer, ouvrir ni modifier la copie `build/Demo` (l'utilisateur la teste). Ne jamais modifier `Config/Local.xcconfig`.
- **Lancer l'app : seulement par le banc de captures**, `Tools/snapshot.sh <dossier> [scénario]` (après la tâche 1). Il exécute le binaire de `build/DerivedData` avec `--snapshot`, sur un état temporaire isolé, et l'app quitte d'elle-même. Jamais `open`, jamais le binaire sans `--snapshot`, jamais `--demo` (réservé à l'utilisateur). Jamais de vrai `claude` ; `fake-claude` reste réservé aux tests du cœur.
- Dossier des captures : hors du dépôt, `"$TMPDIR/pos-snapshots/tache-<n>"`, vidé avant chaque passage. Les captures ne sont jamais commitées.
- **Build de l'app** (toute tâche qui touche `App/`) : `xcodegen generate && xcodebuild -project PixelOpenSpace.xcodeproj -scheme PixelOpenSpace -configuration Debug -derivedDataPath build/DerivedData -skipPackagePluginValidation build` doit finir par `** BUILD SUCCEEDED **`, sans nouvel avertissement de concurrence.
- **Vérification par les images** : après le build, chaque tâche d'app lance les scénarios qu'elle cite, lit `report.txt`, puis ouvre les PNG avec l'outil Read et décrit dans son message de commit (corps) ce qu'elle y a vérifié. Une capture de scène ne s'écarte pas de sa référence logicielle de plus de 1 par canal : la ligne `BILAN` de `report.txt` annonce « écarts hors tolérance 0 ».
- Le cœur (`Core/`) compile et passe ses tests **sous Linux et macOS** : Foundation seulement, jamais AppKit, SpriteKit, CoreGraphics ni ImageIO dans `Core/Sources` ; types publics `Sendable` ; fonctions pures (dates, identifiants et aléa fournis par l'appelant ; ni `Date()`, ni `UUID()`, ni générateur non semé) ; sorties triées (jamais l'ordre d'un `Dictionary` ou d'un `Set`).
- `cd Core && swift build && swift test` reste vert (1 113 tests au départ, plus les nouveaux), en swift-testing comme les fichiers existants ; suites rapides en debug ; tout aléa des tests est semé par `SplitMix64` (déjà défini dans le module de test).
- **Signatures publiques du cœur** : on ajoute (paramètres avec valeur par défaut, surcharges, nouveaux types), on ne retire ni ne renomme rien, sauf mention explicite d'une tâche. Les tâches d'une même vague doivent compiler ensemble après fusion.
- **Empreintes golden et images du jalon** (`Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt`, `docs/jalon-visuel/*.png`) : seules les tâches 2 et 6 les régénèrent. Pour toute autre tâche, un échec de `GoldenTests` signifie que le rendu a changé : corriger le code, jamais ce fichier.
- **Pixel parfait** (7.3) : l'app ne place que des positions et des ancres entières en texels, reçues du plan du cœur ; aucun `SKAction.move` brut (règle 1, une action maison recale chaque image) ; caméra recalée sur la grille des pixels physiques à chaque image (règle 2) ; aucun miroir à l'exécution (règle 3 sans objet : les miroirs sont des images de l'atlas) ; textures en filtrage `.nearest` ; au repos, seulement les zooms vue d'ensemble (0,5 pt par texel, Retina seulement), ×1, ×2 et ×3.
- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `@MainActor` pour toute l'UI. Aucune logique métier dans les vues : l'app traduit des entrées en appels au cœur, à `AppModel` et à `WorkbenchState`.
- Interface en **français** ; code, identifiants et commentaires en **anglais**, au ton du code existant.
- **Jamais de tiret cadratin** (U+2014) nulle part : code, commentaires, chaînes, docs, messages de commit. Contrôle avant chaque commit : `grep -rn "$(printf '\342\200\224')" App Core/Sources Core/Tests docs Tools README.md` (le motif est écrit en octal) ne doit rien afficher.
- `project.yml` et `Core/Package.swift` ne changent pas (les nouveaux fichiers de `App/Sources` sont repris par `xcodegen generate`).
- Un commit par tâche, message impératif en anglais. Pas de push.

## Review Focus

1. **Au pixel près, à chaque zoom.** La scène SpriteKit égale sa référence logicielle (±1 par canal) en vue d'ensemble, à ×1, ×2 et ×3, et après des positions de caméra fractionnaires. Contrôles : scénarios `zooms` et `fractional` du banc ; tests `CameraMathTests.snappedAlignsTexelsOnPhysicalPixels`, `ScenePlanTests.renderFromPlanIsUnchanged`.
2. **Une seule source pour les positions.** L'app ne calcule aucune position de sprite : tout vient de `ScenePlanner`. Les identifiants de nœuds sont stables : un changement d'état ne touche que les nœuds de cet agent, un nouvel agent n'en déplace aucun. Tests : `ScenePlanTests.stateChangeOnlyUpdatesThatAgent`, `addingAnAgentMovesNothing`, `unchangedInputGivesEmptyDiff`.
3. **Rien ne bouge jamais.** Ni îlot, ni annexe, ni poste, quand un projet ou un agent est ajouté, retiré ou archivé. `workspace.json` passe en version 2 (annexes persistantes, apparences générées) : une copie plus ancienne de l'app, dont `build/Demo`, l'ouvrira en lecture seule. Tests : `WorldLayoutPropertyTests.noIslandEverMoves` (annexes comprises), `PersistenceTests.workspaceV1MigratesToV2`.
4. **Isolation du banc.** `--snapshot` et `--demo` n'écrivent que dans un dossier temporaire et un domaine de préférences jetable ; ils ne démarrent ni serveur de hooks, ni session, ni recherche de `claude`, ni notifications ; `--snapshot` quitte seul (chien de garde de 120 s). Contrôle : tâche 1, étape 6.
5. **Règles de clic.** Un double-clic sur un agent n'ouvre que le terminal, sans fenêtre qui clignote ; un clic sur un poste libre propose, ne crée jamais directement ; un double-clic sur un poste ou un agent ne centre pas. Tests : `ClickResolverTests` (une fonction par règle de 3.9).
6. **Dépôt d'un post-it.** Chaque ligne de la table de 3.9 (même projet, attente, occupé, autre projet avec confirmation, hors ligne, orphelin interdit, poste libre, sol d'un îlot) et le cas « cible hors champ au début du glisser ». Tests : `DropResolverTests` ; scénario `dragdrop` ; checklist manuelle.
7. **Énergie.** Rien n'est recalculé à chaque image au repos (un plan inchangé donne un diff vide), 0 image par seconde fenêtre masquée, 30 au repos, 60 pendant une interaction. Tests : `ScenePlanTests.unchangedInputGivesEmptyDiff` ; checklist Instruments.

## Décisions et précisions (à lire avant toute tâche)

1. **Le plan du cœur est la seule source de vérité de la scène.** Tout ce que `SceneCompositor` dessine aujourd'hui passe par un plan public (tâche 4) : nœuds à identifiant stable, sprite, position d'ancre en texels (repère de `IsoMath`, y vers le haut), ancre en pixels depuis le coin haut-gauche de l'image, couche, ordre de dessin, décalage d'horloge, cible de clic. `SceneCompositor` rend ce plan (référence, golden inchangé) ; `WorldScene` affiche les mêmes nœuds.
2. **Fond cuit.** Le sol, toutes les ombres posées (meubles, plantes, personnages assis) et les pans de mur (segments, fenêtres, coin) sont rendus par le cœur en une image, exactement comme aujourd'hui (règle 4 de 7.3 : ombres opaques dans un seul calque, 30 % appliqués une fois). L'app l'affiche en tuiles d'au plus 1024 × 1024 texels et la fait recuire hors du fil principal quand le diff le demande. Restent des nœuds : le mur de liège et ses mini post-its, l'ascenseur et son voyant, tout le mobilier, les personnages, les overlays.
3. **Référence et tolérance.** Une capture de scène est comparée à `SceneCompositor` sur le même `SceneInput`, recadrée sur la zone visible et agrandie au plus proche ; les pixels transparents de la référence (hors du monde) sont ignorés ; tolérance de 1 par canal. Un flou, un décalage d'un texel ou une texture mal découpée dépassent largement cette tolérance.
4. **De jour seulement.** Le mode nuit (voile, lumières additives, étoiles, suivi de l'apparence de macOS) appartient à l'étape 4 (section 8) : la scène de l'étape 3 est toujours de jour. Le cœur garde son rendu de nuit et le plan sait le décrire.
5. **Miroirs dans l'atlas.** Les sprites dérivés par miroir (`derivation: .mirror` ou `.mirrorReshaded`) sont rangés dans l'atlas comme des images à part entière : aucun `xScale = −1` à l'exécution. Écart assumé avec 7.6 (« un miroir ne prend aucune place ») : quelques dizaines de kilo-octets contre une règle de moins à tenir.
6. **Remplacement des sprites par des PNG (7.7)** : étape 4, comme le dit la section 8 (tâches de l'étape 4), malgré la mention de l'étape 3 dans `docs/ASSETS.md` ; la tâche 13 corrige ce fichier. L'étape 3 écrit déjà l'atlas et `manifest.json` (`sprite-export --atlas`), qui serviront de gabarit.
7. **Fenêtre agent.** Panneau SwiftUI simple (habillage rétro en 9-slice : étape 4). Elle affiche l'attente (outil et résumé, question et options, message MCP) avec « Ouvrir le terminal ». « Refuser (Échap) » et les boutons d'option lus à l'écran arrivent à l'étape 5, avec les actions de notification (3.12).
8. **Le tableau reste à droite.** La maquette 6(k) met le tableau à gauche ; la barre latérale des projets occupe déjà la gauche (décision du 2026-10-01, commit bef01b4). Le tableau garde sa place de l'étape 2b, à droite de la scène ; ⌘B passe de latéral à plein écran (6(c)), puis masqué.
9. **Glisser-déposer : le repli de S8.** `WorldView` s'enregistre pour le type exporté `fr.vv2.pixelopenspace.task-card` et lit l'identifiant de la carte dans le presse-papiers du glisser ; si la donnée n'est pas encore lisible pendant le survol, la carte glissée est connue par `WorkbenchState.draggedCard`, posé par le tableau au début du glisser. Aucune vue SwiftUI superposée à la scène n'intercepte le survol, le défilement ni le pincement ; seuls de petits contrôles (flèches de bord, mini-carte, contrôle de zoom) reçoivent les événements dans leur cadre.
10. **Protocole « 3 s » sans `fake-claude`.** `fake-claude` ne sait pas encore rejouer un écran. Le protocole utilise le mode `--demo` (tâche 1) : 20 agents simulés sur 6 projets, un panneau « Nouvel essai » qui met 2 agents au hasard en attente. Les tests d'interface `xcodebuild` avec `fake-claude` sont hors de ce plan.
11. **`workspace.json` version 2.** `Project.annexSlots` (slots des annexes, gardés à vie comme `Project.slot`) et une apparence générée pour chaque agent (`AgentLook.generated(for:)`, déterministe depuis l'identifiant) ; la migration v1 → v2 donne une apparence générée aux agents qui ont encore l'apparence par défaut (personne n'a pu en choisir une : l'éditeur arrive à l'étape 6).
12. **Contrôle de zoom dans la barre d'état** (à droite, en mode scène), comme 6(k) et 6(q) : une barre d'outils SwiftUI n'apparaît pas dans les fenêtres du banc, la barre d'état si.
13. **Barre d'état en mode scène** : un clic sur un compteur fait voler la caméra vers le premier agent de cet état, puis vers le suivant à chaque clic ; en vue Liste, il filtre comme à l'étape 2. Plateau d'attente : un clic fait voler la caméra (mode scène) et ouvre la fenêtre de l'agent (3.9).
14. **Crochets du banc.** Le banc (tâche 1) définit d'avance tout le vocabulaire des prises (`SnapshotStep`) ; chaque fonction enregistre le crochet de son étape dans ses propres fichiers, quand elle se crée et seulement si le banc est actif. Une étape sans crochet est notée « non prise en charge » dans le rapport, la prise est faite quand même. Aucune tâche ultérieure n'a donc besoin de modifier les fichiers du banc.
15. **Marge de caméra.** 48 pt autour du monde : la pancarte de SITE, qui touchait le bord de la vue d'ensemble du jalon, garde sa marge dans l'app.
16. **Repères (convention partagée par les tâches 3 et 4).** Scène : texels, y vers le haut, sommet haut de la tuile (0, 0) à l'origine (`IsoMath.toScene`). Canevas d'un rectangle de tuiles R (origine (i0, j0), taille W × D, `SceneCompositor.canvasSize`) : x vers la droite, y vers le bas, `canvasX = sceneX + 32·(D − i0 + j0)`, `canvasY = 96 − 16·(i0 + j0) − sceneY`. Pour R = `layout.bounds` (origine (0, 0)), le monde occupe en scène x ∈ [−32·D, 32·W] et y ∈ [−16·(W + D), 96].
17. **Rythme d'animation.** Horloge de 24 ticks par seconde (7.3) ; une animation SpriteKit est une suite de `setTexture` et d'attentes de `hold / 24` s, jamais `animate(with:timePerFrame:)`. Dans le banc, tout est figé sur la frame 0 (la pose clé), comme la référence.

## Vagues

| Vague | Tâches (en parallèle) | Utilise |
|---|---|---|
| 1 | 1 banc de captures et mode démo (app) ; 2 défauts restants du jalon (cœur) ; 3 caméra, navigation et atlas (cœur) ; 4 plan de scène public (cœur) | le code existant |
| 2 | 5 monde : annexes, apparences, événements, trajets (cœur) ; 6 règles d'interaction (cœur) ; 7 scène SpriteKit et caméra (app) ; 8 fenêtre agent (app) | 1, 2, 3, 4 |
| 3 | 9 souris, trackpad et clavier (app) ; 10 repères et accessibilité (app) ; 11 la scène vit (app) | 5, 6, 7, 8 |
| 4 | 12 glisser-déposer et tableau (app) ; 13 guide et contrôle d'ensemble (docs) | toutes |

Les fichiers des tâches d'une même vague sont disjoints. Fichiers partagés, et la seule tâche qui les modifie dans chaque vague :

| Fichier | V1 | V2 | V3 | V4 |
|---|---|---|---|---|
| `App/Sources/AppMain/PixelOpenSpaceApp.swift`, `AppEnvironment.swift`, `.github/workflows/app.yml`, `App/README.md` | 1 | | | |
| `App/Sources/UI/Main/RootView.swift`, `UI/Support/WorkbenchState.swift` | | 7 | | 12 |
| `App/Sources/Commands/AppCommand.swift`, `CommandCenter.swift`, `Model/ModelTypes.swift`, `UI/Commands/*` | | 7 | | |
| `App/Sources/Model/AppModel.swift`, `AppModel+Engine.swift` | | | 10 | |
| `App/Sources/Model/AppModel+Intents.swift` | | | 9 | 12 |
| `App/Sources/UI/Status/WaitingTrayView.swift` | | 8 | 10 | 12 |
| `App/Sources/UI/Status/StatusBarView.swift` | | | 10 | |
| `App/Sources/World/WorldView.swift` | | 7 (crée) | 9 | 12 |
| `App/Sources/World/WorldScene.swift` | | 7 (crée) | 11 | 12 |
| `App/Sources/World/WorldSceneCoordinator.swift` | | 7 (crée) | 11 | |
| `App/Sources/World/WorldAreaView.swift` | | 7 (crée) | 10 | |
| `App/Sources/World/HUD/MinimapView.swift`, `EdgeArrowsView.swift` | | | 10 (crée) | 12 |
| `Core/Sources/PixelCore/World/SceneCompositor.swift`, `SceneModel.swift` | 4 | | | |
| `Core/Sources/PixelCore/World/ScenePlanner.swift` | 4 (crée) | 6 | | |
| golden, `docs/jalon-visuel/` | 2 | 6 | | |
| `Core/Sources/sprite-export/main.swift` | 3 | | | |
| `Core/Sources/PixelCore/Model/Workspace.swift`, `Persistence/*`, `World/WorldLayout.swift` | | 5 | | |

## Carte des fichiers

Cœur (`Core/Sources/PixelCore/`) :
- Tâche 1 : `World/ShowcaseWorkspace.swift`.
- Tâche 2 : `Assets/Sprites/OverlaySprites.swift`, `Assets/Sprites/DeskItemSprites.swift`, `Assets/Sprites/FurnitureSprites.swift` (si la veste est retouchée), `Assets/Characters/CharacterParts.swift`, `Assets/Characters/CharacterPoses.swift` (si besoin).
- Tâche 3 : `World/Camera.swift`, `World/CameraFlight.swift`, `World/EdgeArrows.swift`, `World/Minimap.swift`, `World/AutoScroll.swift`, `Assets/AtlasPacker.swift`, `Assets/SpriteManifest.swift`, `Assets/AtlasExport.swift` ; exécutable `Core/Sources/sprite-export/main.swift` (option `--atlas`).
- Tâche 4 : `World/ScenePlan.swift`, `World/ScenePlanner.swift` (nouveaux), `World/SceneCompositor.swift`, `World/SceneModel.swift`.
- Tâche 5 : `Model/Workspace.swift`, `Model/LookGenerator.swift` (nouveau), `Persistence/WorkspaceOps.swift`, `Persistence/WorkspaceValidator.swift`, `Persistence/Migrator.swift`, `Persistence/Codecs.swift`, `World/WorldLayout.swift`, `World/WorldEvents.swift` et `World/WalkPath.swift` (nouveaux).
- Tâche 6 : `World/SceneHitTest.swift`, `World/ClickResolver.swift`, `World/DropResolver.swift`, `State/AnnouncementBatcher.swift` (nouveaux), `World/ScenePlanner.swift`.

Tests (`Core/Tests/PixelCoreTests/`) :
- Tâche 1 : `ShowcaseWorkspaceTests.swift`.
- Tâche 2 : `OverlaySpriteTests.swift`, `CharacterSpriteTests.swift`, `FurnitureSpriteTests.swift` ; `Fixtures/golden/sprites.txt`.
- Tâche 3 : `CameraMathTests.swift`, `CameraFlightTests.swift`, `EdgeArrowsTests.swift`, `MinimapTests.swift`, `AutoScrollTests.swift`, `AtlasPackerTests.swift`, `SpriteManifestTests.swift`.
- Tâche 4 : `ScenePlanTests.swift`, `SceneExtrasTests.swift` (nouveaux), `SceneCompositorTests.swift`.
- Tâche 5 : `LookGeneratorTests.swift`, `WorldEventsTests.swift`, `WalkPathTests.swift` (nouveaux), `WorldLayoutTests.swift`, `WorldLayoutPropertyTests.swift`, `WorkspaceOpsTests.swift`, `PersistenceTests.swift`.
- Tâche 6 : `SceneHitTestTests.swift`, `ClickResolverTests.swift`, `DropResolverTests.swift`, `AnnouncementBatcherTests.swift` (nouveaux), `ScenePlanTests.swift` ; `Fixtures/golden/sprites.txt`.

App (`App/Sources/`) :
- Tâche 1 : `AppMain/AppEntry.swift`, `Snapshot/SnapshotOptions.swift`, `Snapshot/SnapshotEnvironment.swift`, `Snapshot/SnapshotHooks.swift`, `Snapshot/SnapshotScenarios.swift`, `Snapshot/SnapshotRunner.swift`, `Snapshot/SnapshotImages.swift`, `Snapshot/DemoMode.swift` (nouveaux) ; `AppMain/PixelOpenSpaceApp.swift`, `AppMain/AppEnvironment.swift`.
- Tâche 7 : `World/SpriteRegistry.swift`, `World/WorldStage.swift`, `World/WorldCamera.swift`, `World/WorldInteractionState.swift`, `World/WorldScene.swift`, `World/WorldSceneNodes.swift`, `World/WorldView.swift`, `World/WorldViewRepresentable.swift`, `World/WorldAreaView.swift`, `World/WorldSceneCoordinator.swift`, `World/WorldSnapshotHooks.swift`, `World/EmptyWorldCard.swift` (nouveaux) ; `UI/Main/RootView.swift`, `UI/Support/WorkbenchState.swift`, `Commands/AppCommand.swift`, `Commands/CommandCenter.swift`, `Model/ModelTypes.swift`, `UI/Commands/CommandAvailability.swift` (si besoin).
- Tâche 8 : `UI/AgentWindow/AgentWindowController.swift`, `UI/AgentWindow/AgentWindowView.swift`, `UI/AgentWindow/AgentWaitSection.swift`, `UI/AgentWindow/AgentQueueSection.swift`, `UI/AgentWindow/AgentPortraitView.swift`, `UI/Support/PixelImage+CGImage.swift` (nouveaux) ; `UI/Status/WaitingTrayView.swift`, `UI/Agents/AgentCardView.swift`.
- Tâche 9 : `World/Input/WorldInputController.swift`, `World/Input/WorldClickPerformer.swift`, `World/Input/WorldContextMenu.swift`, `World/Input/NewAgentPopover.swift`, `World/Input/HoverCardView.swift` (nouveaux) ; `World/WorldView.swift`, `Model/AppModel+Intents.swift`.
- Tâche 10 : `World/HUD/MinimapView.swift`, `World/HUD/EdgeArrowsView.swift`, `World/HUD/ZoomControl.swift`, `World/HUD/SpriteImage.swift`, `World/HUD/WorldFlights.swift`, `World/WorldAccessibility.swift` (nouveaux) ; `World/WorldAreaView.swift`, `UI/Status/StatusBarView.swift`, `UI/Status/WaitingTrayView.swift`, `Model/AppModel.swift`, `Model/AppModel+Engine.swift`.
- Tâche 11 : `World/Animation/SnappedMove.swift`, `World/Animation/ArrivalAnimator.swift`, `World/Animation/FurnitureDropAnimator.swift`, `World/Animation/TransitionPlayer.swift` (nouveaux) ; `World/WorldScene.swift`, `World/WorldSceneCoordinator.swift`.
- Tâche 12 : `World/Drop/WorldDropController.swift`, `World/Drop/DropFeedbackView.swift`, `World/Drop/PostitFlight.swift`, `UI/Board/BoardFullScreenView.swift` (nouveaux) ; `World/WorldView.swift`, `World/WorldScene.swift`, `UI/Main/RootView.swift`, `UI/Support/WorkbenchState.swift`, `UI/Board/BoardPanelView.swift`, `UI/Board/TaskCardView.swift`, `UI/Status/WaitingTrayView.swift`, `World/HUD/MinimapView.swift`, `World/HUD/EdgeArrowsView.swift`, `Model/AppModel+Intents.swift`.

Outils, CI et docs : `Tools/snapshot.sh` et `.github/workflows/app.yml` (tâche 1) ; `docs/jalon-visuel/` (tâches 2 et 6) ; `docs/ETAPE-3.md`, `README.md`, `docs/ASSETS.md` (tâche 13) ; `App/README.md` (tâche 1).

---

### Task 1: Banc de captures (`--snapshot`) et mode démo, sur un état isolé (vague 1)

**Files:**
- Create: `App/Sources/AppMain/AppEntry.swift`, `App/Sources/Snapshot/SnapshotOptions.swift`, `App/Sources/Snapshot/SnapshotEnvironment.swift`, `App/Sources/Snapshot/SnapshotHooks.swift`, `App/Sources/Snapshot/SnapshotScenarios.swift`, `App/Sources/Snapshot/SnapshotRunner.swift`, `App/Sources/Snapshot/SnapshotImages.swift`, `App/Sources/Snapshot/DemoMode.swift`, `Core/Sources/PixelCore/World/ShowcaseWorkspace.swift`, `Tools/snapshot.sh`
- Modify: `App/Sources/AppMain/PixelOpenSpaceApp.swift` (retirer `@main`), `App/Sources/AppMain/AppEnvironment.swift`, `.github/workflows/app.yml`, `App/README.md`
- Test: `Core/Tests/PixelCoreTests/ShowcaseWorkspaceTests.swift`

**Interfaces:**
- Consumes: `Showcase` (ses membres internes `Member`, `Activity`, `runtime(_:)`, `looks`, `uuid(_:)`, `question`, `now`, accessibles depuis le même module), `SceneInput.make(workspace:runtimes:extras:boardCardHues:now:reduceMotion:)`, `SceneCompositor.render`, `PixelImage.pngData`, `TaskBoardState`, `RankKey`, `TaskBoardValidator`, `WorkspaceValidator`, `BoardQuery` ; côté app `AppEnvironment`, `AppDirectories(home:temporaryDirectory:uid:)`, `AppModel` (`commit`, `commitBoard`, `storeRuntime`, `now`, `hookServerState`, `claude`, `select(agent:)`), `WorkbenchState(model:commands:presenter:)`, `RootView`, `CommandCenter`, `AppCommand`.
- Produces (cœur, utilisé par les tâches 7 à 13 à travers le banc) :

```swift
/// The simulated open space of the snapshot and demo modes: mockup 6(q)'s 6 projects and 20 agents, with every
/// state of an agent, and a board whose post-its feed the queues. Fixed ids and dates (Showcase.now).
public struct ShowcaseWorkspace: Sendable {
    public var workspace: Workspace
    public var runtimes: [AgentID: AgentRuntime]
    public var board: TaskBoardState
    /// Matches the board: queue sizes, the card stuck on each monitor (current card's project hue, 10 = paper).
    public var extras: [AgentID: AgentExtras]
    /// Cards of "À faire", "En cours", "À valider", by column then rank: their project hue, 10 = paper.
    public var boardCardHues: [Int]
    public var now: Date
    /// Agents with a running process (never Kiwi, offline): the ones a demo trial may put in a wait.
    public var liveAgents: [AgentID] { get }
    public func sceneInput(reduceMotion: Bool = false) -> SceneInput
    public func agentID(named name: String) -> AgentID?
    public func projectID(named name: String) -> ProjectID?
    public func cardID(titled title: String) -> TaskCardID?
    /// Runtimes where exactly `picks` wait (reason k cycles a fixed list: permission Bash, question, permission Edit,
    /// MCP message; since 5 + 17·k seconds); Nova, Sol and Ivo, who wait in `runtimes`, work instead.
    /// Precondition: every pick is in `liveAgents`.
    public func runtimes(waiting picks: [AgentID]) -> [AgentID: AgentRuntime]
}
public enum DemoActivity: Hashable, Sendable { case working(ToolKind), thinking, idle(minutes: Int), done }
extension Showcase {
    /// The app's simulated open space (table below).
    public static func appWorkspace() -> ShowcaseWorkspace
    /// An empty workspace (first launch, 6(r)), same clock.
    public static func emptyWorkspace() -> ShowcaseWorkspace
    /// The runtime of a live agent doing `activity` at `now` (demo animation).
    public static func demoRuntime(_ activity: DemoActivity, now: Date) -> AgentRuntime
}
```

Distribution simulée (projets créés dans cet ordre, slots 0 à 5 ; apparences de `Showcase.looks`) :

| Projet (teinte) | Agents, poste par poste |
|---|---|
| API (Lagune, 4) | Nova : attend une permission (Bash « rm -rf dist », depuis 42 s) ; Bip : travaille (Bash), 2 sous-agents ; Lune : réfléchit ; Kiwi : hors ligne (session fermée) ; Oslo : tour terminé |
| INFRA (Menthe, 3) | Zéphyr : erreur (serveurs surchargés) ; Ada : travaille (Edit) ; Rio : limite d'usage, reprise dans 40 min ; Sol : attend une réponse à une question (depuis 2 min 10) |
| SITE (Tomate, 0) | Pixou : travaille (Edit) ; Tao : au repos depuis 12 min (endormi) ; Mika : attend une tâche de fond |
| DATA (Indigo, 5) | Plume : réfléchit, sans nouvelles, mode dégradé ; Galet : au repos depuis 2 min, brouillon, mode `bypassPermissions` ; Brume : démarre |
| MOBILE (Framboise, 7) | Comète : travaille (sous-agent), 1 sous-agent ; Nuage : au repos depuis 6 min ; Pépin : travaille (MCP « notes ») |
| DOCS (Olive, 2) | Ivo : attend une permission (Edit « README.md », depuis 5 s) ; Cajou : tour terminé |

Tableau simulé (identifiants fixes, rangs par `RankKey.spread`) : **À faire** « Doc des erreurs 401 » (API, Nova, file #1), « Pagination /users » (API, non assigné, priorité haute), « Tri des colonnes » (API, non assigné, basse), « Rotation des logs » (INFRA, non assigné), « Menu mobile » (SITE, Pixou, file #1), « Logo du pied de page » (SITE, Pixou, file #2), « Index des tables » (DATA, non assigné), « Vérifier les liens » (sans projet) ; **En cours** « Refonte du header » (SITE, Pixou), « Cache des builds » (API, Bip), « Migration Terraform » (INFRA, Ada), « Notifications push » (MOBILE, Comète), « Synchro des notes » (MOBILE, Pépin), « Recherche plein texte » (DATA, Plume) ; **À valider** « README d'installation » (API, Oslo), « Guide de contribution » (DOCS, Cajou) ; **Fait** « Lint CI » (API), « Nettoyage des logs » (INFRA), « Page 404 » (SITE). Les cartes en cours ont une livraison confirmée ; aucune réparation du validateur n'est nécessaire.

- Produces (app) :

```swift
// AppEntry.swift: the only @main. Parses the command line, then runs the snapshot or demo mode, or the normal app.
@main enum AppEntry { static func main() }   // usage error: French message on stderr, exit(1)

// SnapshotOptions.swift
struct SnapshotOptions: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case snapshot(output: URL, scenarios: [SnapshotScenario.ID]), demo }
    var mode: Mode
    var windowSize: CGSize        // --size 1440x900 (default)
    var keepState: Bool           // --keep-state: leave the temporary state folder, its path in the report
    /// nil when neither --snapshot nor --demo is given (normal launch). Unknown arguments starting with "-" that
    /// AppKit or Xcode add (-NSDocumentRevisionsDebugMode, -ApplePersistenceIgnoreState, -psn_…) are ignored.
    static func parse(_ arguments: [String]) throws -> SnapshotOptions?
}

// AppEnvironment.swift (modified): one environment per run mode.
enum AppRunMode: Sendable { case normal, isolated }
// `static let shared` keeps building the normal environment; new `init(directories: AppDirectories, mode: AppRunMode)`.
// isolated: prepareForLaunch() and start() do nothing (no notification delegate, hook server, sessions, clock, claude).

// SnapshotHooks.swift: how features plug into a shot (décision 14).
enum SnapshotBoardMode: String, Sendable { case hidden, side, full }
enum SnapshotHover: Hashable, Sendable { case agent(String), freeDesk(project: String, deskIndex: Int), none }
enum SnapshotDropSpot: Hashable, Sendable {
    case agent(String), island(String), freeDesk(project: String, deskIndex: Int), edgeArrow(agent: String),
         trayRow(agent: String), minimap(agent: String)
}
enum SnapshotStep: Hashable, Sendable {
    case listView(Bool), board(SnapshotBoardMode), zoom(SceneZoom), fitAll, focusIsland(String), focusAgent(String),
         focusHall, cameraNudge(dx: Double, dy: Double), select(String?), hover(SnapshotHover),
         openAgentWindow(String), dragHover(card: String, over: SnapshotDropSpot), arrival(agent: String, progress: Double),
         islandDrop(project: String, progress: Double)
    enum Kind: String, CaseIterable, Sendable {
        case listView, board, zoom, fitAll, focus, cameraNudge, select, hover, agentWindow, dragHover, arrival, islandDrop
    }
    var kind: Kind { get }
}
/// What the scene shows, for the window shot and the comparison with the software reference.
struct SceneCapture {
    var image: CGImage              // the SKView's drawing, HUD hidden, one pixel per physical pixel
    var input: SceneInput           // what the scene was planned from
    var overview: Bool
    var visibleCanvasRect: PixelRect   // texels of the reference canvas (whole world) the image covers
    var pixelsPerTexel: Int         // 1 (overview on Retina), 2, 4 or 6 on Retina
    var stats: [String: Int]        // nodes, atlasPages, dynamicPages, composedTextures, backgroundTiles
}
@MainActor protocol SceneCaptureProviding: AnyObject {
    func captureScene() async -> SceneCapture?
    /// Shows `image` in place of the Metal drawing while the runner draws the window (cacheDisplay cannot read it),
    /// under the SwiftUI overlays; returns the undo.
    func showStill(_ image: CGImage) -> @MainActor () -> Void
}
@MainActor final class SnapshotHooks {
    static let shared = SnapshotHooks()
    private(set) var isEnabled: Bool
    func enable()
    /// Features register in their own files when they are created, only when isEnabled (owner: "tâche 7"…).
    func register(_ kind: SnapshotStep.Kind, owner: String, _ handler: @escaping @MainActor (SnapshotStep) async -> Bool)
    func registerScene(_ provider: SceneCaptureProviding)   // held weakly
    func handler(for kind: SnapshotStep.Kind) -> (@MainActor (SnapshotStep) async -> Bool)?
    var sceneProvider: SceneCaptureProviding? { get }
}
```

Qui enregistre quel crochet (contrat ; avant la tâche concernée, l'étape est « non prise en charge ») :

| `Kind` | Tâche | Repli du banc sans crochet |
|---|---|---|
| `listView`, `zoom`, `fitAll`, `focus`, `cameraNudge`, et `registerScene` | 7 | aucun |
| `agentWindow` | 8 | aucun |
| `hover` | 9 | aucun |
| `arrival`, `islandDrop` | 11 | aucun |
| `dragHover`, `board` | 12 | `board(.hidden / .side)` : préférence `boardPanelVisible` du domaine jetable |
| `select` | banc | `model.select(agent:)` |

Scénarios (`SnapshotScenario`, identifiants en minuscules ; fenêtre de 1440 × 900 pt sauf `--size`) :

| Scénario | Prises (nom : étapes) |
|---|---|
| `overview` | `tout-voir` : `listView(false)`, `board(.side)`, `fitAll` |
| `zooms` | `listView(false)`, `board(.hidden)`, `focusIsland("API")`, puis `ensemble` `zoom(.overview)`, `x1` `zoom(.x1)`, `x2` `zoom(.x2)`, `x3` `zoom(.x3)` |
| `fractional` | `listView(false)`, `board(.hidden)`, `zoom(.x2)`, `focusAgent("Nova")`, puis `d1` `cameraNudge(0.25, 0)`, `d2` `(0.5, 0.5)`, `d3` `(0.75, 0.25)`, `d4` `(1.5, 0.75)`, `x3` `zoom(.x3)` + `cameraNudge(0.33, 0.66)` |
| `list` | `liste` : `listView(true)`, `board(.side)` |
| `empty` | le banc remplace la distribution par `Showcase.emptyWorkspace()` (et la remet après) : `monde-vide` `listView(false)` ; `liste-vide` `listView(true)` |
| `select` | `listView(false)`, `zoom(.x2)`, `focusAgent("Nova")`, puis `selection` `select("Nova")`, `survol-agent` `hover(.agent("Bip"))`, `survol-poste` `hover(.freeDesk("API", 5))` |
| `navigation` | `listView(false)`, `board(.side)`, puis `loin` `zoom(.x3)` + `focusIsland("DOCS")`, `hall` `zoom(.x1)` + `focusHall` |
| `agentWindow` | `nova` `openAgentWindow("Nova")`, `sol` `openAgentWindow("Sol")`, `brume` `openAgentWindow("Brume")` |
| `dragdrop` | `listView(false)`, `board(.side)`, `zoom(.x2)`, `focusIsland("API")`, puis `bip`, `sol-autre-projet`, `kiwi-hors-ligne` (`dragHover("Pagination /users", .agent(…))`), `ilot` `.island("API")`, `poste-libre` `.freeDesk("API", 5)`, `fleche` `.edgeArrow(agent: "Ivo")`, `plateau` `.trayRow(agent: "Sol")`, `mini-carte` `.minimap(agent: "Ivo")` |
| `board` | `plein-ecran` : `board(.full)` |
| `arrival` | `listView(false)`, `zoom(.x2)`, `focusIsland("DATA")`, puis `brume-0`, `brume-40`, `brume-80`, `brume-100` (`arrival("Brume", 0 / 0.4 / 0.8 / 1)`), `chute-mobile` `focusIsland("MOBILE")` + `islandDrop("MOBILE", 0.5)` |
| `demo` | `demo` : la fenêtre et le panneau du mode démo, sans interaction |
| `selftest` | aucune fenêtre : contrôle de l'outil de comparaison (ci-dessous) |
| `all` | tous les scénarios ci-dessus, dans cet ordre |

Comportement :
- **Entrée** : `AppEntry.main()` lit `CommandLine.arguments` ; `--snapshot <dossier> [--scenario <id,id…>] [--size LxH] [--keep-state]` ou `--demo [--size LxH]` ; sinon `PixelOpenSpaceApp.main()` (rien ne change pour un lancement normal : `AppEnvironment.shared` n'est jamais évalué en mode isolé, et inversement).
- **Isolation** (`SnapshotEnvironment`) : dossier `$TMPDIR/PixelOpenSpace-snapshot-<pid>-<uuid>` en 0700, utilisé comme `home` de `AppDirectories` (le support, `run/` et le chemin du socket tombent dedans) ; domaine de préférences `fr.vv2.pixelopenspace.snapshot.<pid>` donné à toute la hiérarchie par `.defaultAppStorage(_:)` et prérempli (`welcomeShown = true`, `boardPanelVisible = true`, largeur du tableau 340), effacé à la sortie (`removePersistentDomain(forName:)`) ; dossier temporaire supprimé à la sortie sauf `--keep-state`. Le modèle reçoit la distribution simulée (`commit`, `commitBoard`, `storeRuntime`), `now = Showcase.now`, `hookServerState = .running` et un `claude` trouvé, pour l'affichage seulement : aucun serveur, aucune session, aucune recherche, aucune horloge n'est démarré. Avant d'écrire le code, auditer `grep -rn "UserDefaults\|AppStorage\|NSHomeDirectory\|AppEnvironment.shared\|WorkbenchState.shared" App/Sources` et traiter chaque occurrence atteignable.
- **Application** : `NSApplication` sans scène SwiftUI, politique `.accessory` pour `--snapshot` (pas d'icône dans le Dock, jamais active), `.regular` pour `--demo`. La fenêtre principale est une `NSWindow` (`isRestorable = false`) dont la vue est un `NSHostingView` de `RootView` avec ses environnements. En `--snapshot`, chaque fenêtre de l'app est posée sur l'écran principal avec `alphaValue = 0` et `ignoresMouseEvents = true`, jamais clé ni principale : rien ne s'affiche ni ne prend le focus, et l'échelle d'affichage est celle de l'écran (2 sur un Mac Retina).
- **Prise** : pour chaque étape, le crochet (ou le repli du banc) puis un temps de pose (mise en page, 0,3 s, deux tours de boucle). Captures : chaque fenêtre visible de l'app (principale, panneaux de la tâche 8) en `window-<scénario>-<prise>[-<n>].png`, par `bitmapImageRepForCachingDisplay(in:)` et `cacheDisplay(in:to:)` à l'échelle d'affichage ; si un fournisseur de scène existe : `captureScene()`, puis `showStill` pendant la capture de la fenêtre, puis `scene-…png`, `reference-…png`, `diff-…png`. Sans fournisseur, les prises de scène écrivent `reference-<scénario>-<prise>.png` : le monde entier au zoom de la prise, rendu par le cœur sur `showcase.sceneInput()`. Si `cacheDisplay` laisse vides certaines vues SwiftUI, essayer `layer.render(in:)` et le noter dans le rapport.
- **Comparaison** (`SnapshotImages`) : référence = `SceneCompositor.render(capture.input, options: RenderOptions(zoom: capture.overview ? .overview : .x1))`, recadrée sur `visibleCanvasRect`, agrandie au plus proche par `pixelsPerTexel` ; un pixel compte comme écart si un canal diffère de plus de 1 et que la référence est opaque ; `diff-…png` montre la référence assombrie de moitié avec les écarts en magenta.
- **Rapport** : `report.txt` en français (échelle d'affichage, une ligne par fichier écrit, écarts par prise, étapes non prises en charge avec la tâche propriétaire, statistiques de scène), terminé par une ligne `BILAN : écarts hors tolérance N · étapes non prises en charge M` ; `stats.json` (mêmes données). Codes de sortie : 0 terminé (les écarts sont dans le rapport), 1 ligne de commande invalide, 2 écriture impossible, 3 chien de garde (120 s, le rapport dit ce qui manque).
- **`selftest`** : compare une référence à elle-même (0 écart attendu) et à une copie décalée d'un texel (des écarts attendus) ; écrit « outil de comparaison : OK » ou la raison de l'échec.
- **Mode démo** (`DemoMode`, réservé à l'utilisateur, décision 10) : même environnement isolé, fenêtre visible ; une barre de menus minimale construite depuis `AppCommand.allCases` (titres et raccourcis de `AppCommand.shortcut`, actions par `CommandCenter.perform`) plus « Quitter » (⌘Q) qui nettoie l'état temporaire ; un panneau flottant « Démo » : « Nouvel essai » (tire 2 agents distincts au hasard parmi `liveAgents` avec `SystemRandomNumberGenerator` et applique `runtimes(waiting:)`), « Révéler » (qui attend et quoi, pour vérifier la réponse dite à voix haute), compteur d'essais, interrupteur « Animer » (toutes les 4 s, 3 agents vivants qui n'attendent pas changent d'activité par `demoRuntime`, pour les mesures d'images par seconde), mention « Agents simulés : aucun terminal, aucun claude ». L'horloge du modèle avance chaque seconde depuis `Showcase.now` (seulement `model.now`, jamais `tick`).
- **`Tools/snapshot.sh <dossier> [scénario]`** (bash 3.2) : trouve `build/DerivedData/Build/Products/Debug/PixelOpenSpace.app/Contents/MacOS/PixelOpenSpace` depuis la racine du dépôt où se trouve le script, échoue en français s'il manque (« construis d'abord l'app »), n'utilise jamais `build/Demo`, crée le dossier, lance `"$BIN" --snapshot "$OUT" --scenario "${2:-all}" -ApplePersistenceIgnoreState YES` et rend son code de sortie.
- **CI** (`app.yml`, après le contrôle de `pixel-hook`) : `Tools/snapshot.sh build/snapshots all` avec `continue-on-error: true` (machines virtuelles sans vraie accélération graphique : scènes possiblement noires, la référence reste le cœur), puis publication de `build/snapshots` en artefact `snapshots`.
- **`App/README.md`** : section « Banc de captures et mode démo » (commandes, scénarios, lecture du rapport, isolation).

- [ ] **Step 1: Write the failing tests.** `ShowcaseWorkspaceTests` : `twentyAgentsOnSixProjects` ; `everyStateIsPresent` (les 10 `AgentStateKind`, un agent endormi, une question, les badges `stale`, `degraded`, `draft`, `unsafe`, des sous-agents, par `AgentPresenter.scene`) ; `boardIsValid` (`TaskBoardValidator.validate` et `WorkspaceValidator` ne signalent rien ; au plus une carte en cours par agent ; file de Nova 1, de Pixou 2 ; `extras` égal à ce que donne `BoardQuery`) ; `waitingOnlyThePicked` (2 agents choisis attendent, et eux seuls) ; `offlineAgentIsNeverLive` ; `emptyWorkspaceHasNoProject` ; `deterministic` (deux constructions égales).
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter ShowcaseWorkspaceTests` → échec de compilation.
- [ ] **Step 3: Implement** `ShowcaseWorkspace.swift` (extension de `Showcase` dans un fichier à part, sans modifier `Showcase.swift`), puis `cd Core && swift test` → vert.
- [ ] **Step 4: Implement the app side** : `AppEntry`, retrait de `@main`, `AppEnvironment(directories:mode:)`, puis les fichiers de `Snapshot/`, le script, la CI et la section du README.
- [ ] **Step 5: Build** (commande des contraintes globales) → `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Isolation.** Noter les copies de l'app déjà ouvertes (`pgrep -lf PixelOpenSpace`), `touch "$TMPDIR/pos-marker"`, puis `rm -rf "$TMPDIR/pos-snapshots/tache-1" && time Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-1" all` → code 0 en moins de 60 s ; `report.txt` donne le dossier d'état et le domaine de préférences utilisés, tous deux temporaires. Ensuite, ces commandes n'affichent rien : `ls -d "$TMPDIR"/PixelOpenSpace-snapshot-* 2>/dev/null` ; `find "$HOME/Library/Preferences" -name 'fr.vv2.pixelopenspace.snapshot*'` ; `pgrep -f 'PixelOpenSpace --snapshot'` ; `find "$HOME/Library/Application Support/PixelOpenSpace" "$HOME/Library/Preferences/fr.vv2.pixelopenspace.plist" -newer "$TMPDIR/pos-marker"` (si une autre copie de l'app tournait pendant le passage, ce dernier contrôle peut montrer ses propres écritures : le noter dans le commit).
- [ ] **Step 7: Look at the images.** `report.txt` : tous les scénarios, les étapes non prises en charge attendues à ce stade (celles des tâches 7 à 12), « outil de comparaison : OK ». Ouvrir (outil Read) `window-list-liste.png` (20 agents, plateau d'attente Nova, Sol, Ivo, tableau latéral garni), `reference-zooms-x1.png`, `reference-zooms-ensemble.png`, `window-empty-liste-vide.png`, `window-demo-demo.png`.
- [ ] **Step 8: Run** `cd Core && swift test` → vert ; contrôle du tiret cadratin.
- [ ] **Step 9: Commit.** `git add App Core Tools .github && git commit -m "App step 3: snapshot harness and demo mode on an isolated state"`

### Task 2: Défauts restants du jalon visuel (un « ! » qui se lit comme un « ! ») et validation du jalon (vague 1)

**Files:**
- Modify: `Core/Sources/PixelCore/Assets/Sprites/OverlaySprites.swift` (`ov.bang`, `ov.bang~xl`, `ov.bang.halo`, nouvelle variante `ov.edgeArrow~diagonal`), `Core/Sources/PixelCore/Assets/Sprites/DeskItemSprites.swift` (`lamp.desk`), `Core/Sources/PixelCore/Assets/Characters/CharacterParts.swift` (yeux fermés de `sleep`, mèches des coupes courtes vues de dos), `CharacterPoses.swift` et `Assets/Sprites/FurnitureSprites.swift` (veste) seulement si nécessaire
- Modify (sorties) : `Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt`, `docs/jalon-visuel/README.md` et ses 15 PNG, `docs/ASSETS.md` si une description change
- Test: `Core/Tests/PixelCoreTests/OverlaySpriteTests.swift`, `CharacterSpriteTests.swift`, `FurnitureSpriteTests.swift`
- **Ne pas toucher** : `World/` (compositeur, plan, scènes de démonstration), `ContactSheet.swift`, `MilestoneExport.swift`, l'exécutable `sprite-export`.

**Interfaces:**
- Consumes: les conventions du plan du jalon (`docs/superpowers/plans/2026-10-01-jalon-visuel.md`, « Conventions communes »), `OverlayArt`, `SpriteLint`, `PreviewWriter`.
- Produces : mêmes clés qu'avant, plus `ov.edgeArrow~diagonal` (16 × 16, ancre (8, 8), 2 frames à 4 fps, pointe vers le haut à droite, « ! » ink sur l'axe ; avec `ov.edgeArrow` et des rotations de 90°, l'app obtient les 8 directions sans rotation à 45°).

Défauts à corriger (README du jalon, « Restants ») et règles :
1. **« ! » (`ov.bang`, 12 × 24, ancre (6, 24) ; `ov.bang~xl` = ×2 exact)** : se lit aujourd'hui comme une ampoule (tête large et arrondie, col étroit, halo rond). Nouveau dessin : une barre droite et anguleuse qui s'affine vers le bas (sommet à angles vifs, jamais arrondi), au plus 6 px de large contour compris, puis un vide d'au moins 2 rangées, puis un point carré de 4 × 4 à 6 × 5 px. Jaune d'attente, contour `alertOrange`, reflet `chalk` sur le bord gauche (lumière en haut à gauche) ; un contour extérieur `ink` de 1 px est permis pour le contraste sur les sols clairs. Rebond inchangé (décalages 0, 2, 4, 2).
2. **Halo (`ov.bang.halo`, 32 × 32, ancre (16, 16), 2 frames à 4 fps)** : plus d'anneau rond. Un losange iso qui pulse (marches 2:1, le contour s'élargit de 4 px par rangée jusqu'au milieu), en jaune plein et orange en pointillé, comme aujourd'hui.
3. Repli si le dessin 1 et 2 évoque encore une ampoule à l'œil en vue d'ensemble : un « ! » `ink` sur un panneau jaune en losange (contour orange) ; le noter dans le README et adapter le test 1.
4. **Yeux fermés de `sleep`** (vers le spectateur) : un trait horizontal de 2 px par œil au lieu d'un point.
5. **Cheveux courts vus de dos** (`hairStyle` courts, toutes couleurs, nettement pour le gris `hairColor` 3) : des mèches de 2 px en ton d'ombre sur la masse, lisibles à ×1.
6. **`lamp.desk`** : à ×1, se détache du pied du moniteur (bras et pied d'une autre valeur que le pied du moniteur) ; de jour, `~on` diffère de `~off` d'au moins 8 pixels par direction (abat-jour éclairé, ampoule visible).
7. **Veste sur la chaise** : à juger à l'œil à ×1 ; retouche facultative (col plus contrasté).
8. Restent acceptés tels quels : l'orage de Zéphyr qui chevauche le bureau voisin ; la pancarte de SITE au bord de l'image (marge de caméra de l'app, décision 15). Les plaques des agents urgents en vue d'ensemble sont l'affaire de la tâche 6 (compositeur), pas de cette tâche.

- [ ] **Step 1: Write the failing tests.** `OverlaySpriteTests` : `bangReadsAsAnExclamationMark` (frame 0 de `ov.bang` : deux blocs opaques verticaux séparés par au moins 2 rangées vides ; la rangée du haut de la barre est la plus large ; les largeurs ne croissent jamais vers le bas ; largeur maximale ≤ 6 ; point entre 4 × 3 et 6 × 5 ; barre au moins 3 fois plus haute que le point) ; `haloIsAnIsoDiamond` (chaque frame : contour extérieur dont la largeur varie de 4 px par rangée, symétrique) ; `edgeArrowHasADiagonal` (masque de `~diagonal` symétrique par rapport à la diagonale montante : `m[x][y] == m[15 − y][15 − x]` ; distinct des 4 rotations de la flèche droite) ; les tests existants (`bangIsYellowWithOrangeOutline`, `bangXLIsTwiceTheSize`, `stateShapesAreDistinct`, `alertYellowOnlyWhereAllowed`, `everySpriteIsLintClean`) restent verts. `CharacterSpriteTests` : `sleepingEyesAreClosedLines` (dans le `SlotCanvas` de `sleep@se#0` et `sleep@sw#0`, deux composantes `eye` de 2 × 1) ; `shortHairFromBehindHasStrands` (dans `sitIdle@ne#0` des coupes courtes, au moins 3 pixels de `hairShade` isolés dans la masse des cheveux). `FurnitureSpriteTests` : `lampOnAndOffDifferByDay` (au moins 8 pixels différents, chaque direction).
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "OverlaySpriteTests|CharacterSpriteTests|FurnitureSpriteTests"`.
- [ ] **Step 3: Implement**, avec des aperçus : `cd Core && PIXEL_PREVIEW_DIR="$TMPDIR/pos-preview-t2" swift test --filter preview`, puis ouvrir les PNG (outil Read).
- [ ] **Step 4: Golden et rendu**, depuis la racine du dépôt : `swift run --package-path Core sprite-export --golden-out Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt`, puis `swift run --package-path Core -c release sprite-export --out "$PWD/docs/jalon-visuel"` ; déterminisme : `shasum docs/jalon-visuel/*.png`, second rendu, mêmes empreintes.
- [ ] **Step 5: Review the renders** (outil Read) : `vue-ensemble-jour.png` (les « ! » de Nova, Sol et Ivo se lisent comme des points d'exclamation, pas des ampoules), `ilot-x1-jour.png`, `ilot-x3-jour.png`, `planche-3-ecrans-overlays.png`, `planche-5-personnage.png`, `planche-2-mobilier-decor.png`. Recommencer les étapes 3 à 5 tant que le « ! » évoque une ampoule.
- [ ] **Step 6: README du jalon.** En tête : « **Jalon validé le 2026-10-01.** » ; nouvelle section « Troisième rendu (2026-10-01) » (ce qui a changé et pourquoi) ; chaque question encore ouverte cochée « validé tel quel le 2026-10-01 » (palette, orientation des rangées, pas des postes, nuit : pour l'étape 4, visages de la rangée B, démarrage : signe « démarre » gardé, l'arrivée par l'ascenseur s'y ajoute à l'étape 3), sauf « Texte en vue d'ensemble » : « plaques des agents urgents ×2, comme les pancartes (étape 3, tâche 6) » ; table « Restants » vidée dans « Corrigés » (les deux points acceptés y restent avec leur raison) ; écarts de taille éventuels ajoutés à « Tailles modifiées ».
- [ ] **Step 7: Run** `cd Core && swift build && swift test` → vert ; contrôle du tiret cadratin.
- [ ] **Step 8: Commit.** `git add Core docs && git commit -m "Visual milestone: readable waiting sign, last fixes, milestone validated"`

### Task 3: Caméra au pixel près, aides à la navigation et atlas (cœur, vague 1)

**Files:**
- Create: `Core/Sources/PixelCore/World/Camera.swift`, `World/CameraFlight.swift`, `World/EdgeArrows.swift`, `World/Minimap.swift`, `World/AutoScroll.swift`, `Assets/AtlasPacker.swift`, `Assets/SpriteManifest.swift`, `Assets/AtlasExport.swift`
- Modify: `Core/Sources/sprite-export/main.swift` (option `--atlas <dossier>`)
- Test: `Core/Tests/PixelCoreTests/CameraMathTests.swift`, `CameraFlightTests.swift`, `EdgeArrowsTests.swift`, `MinimapTests.swift`, `AutoScrollTests.swift`, `AtlasPackerTests.swift`, `SpriteManifestTests.swift`

**Interfaces:**
- Consumes: `SceneZoom`, `GridRect`, `SceneCompositor.canvasSize(for:)`, `AgentID`, `SpriteDef`, `SpriteKey`, `SpriteCatalog.all`, `PixelImage`, `PixelRect`, `PixelPoint`, `PNGEncoder`.
- Produces (utilisé par les tâches 6, 7, 9, 10, 12) :

```swift
// World/Camera.swift
public struct SceneVector: Hashable, Sendable { public var x: Double; public var y: Double; public init(_ x: Double, _ y: Double) }
/// Axis-aligned box, y up (scene texels) or view points (origin bottom-left, AppKit).
public struct SceneBox: Hashable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double)
    public var width: Double { get }; public var height: Double { get }; public var center: SceneVector { get }
    public func contains(_ p: SceneVector) -> Bool
    public func contains(_ b: SceneBox) -> Bool
}
public struct ViewMetrics: Hashable, Sendable {
    public var width: Double, height: Double      // points
    public var backingScale: Int                  // 1 or 2
    public init(width: Double, height: Double, backingScale: Int)
}
public struct CameraPose: Hashable, Sendable {
    public var zoom: SceneZoom
    public var center: SceneVector               // scene texels: what sits at the middle of the view
    public init(zoom: SceneZoom, center: SceneVector)
}
public enum CameraMath {
    public static let margin = 48.0               // points kept around the world (décision 15)
    public static let keyboardStep = 64.0, keyboardFastFactor = 4.0
    public static func pointsPerTexel(_ zoom: SceneZoom) -> Double            // 0.5, 1, 2, 3
    /// SKCameraNode scale: 1 / pointsPerTexel.
    public static func cameraScale(_ zoom: SceneZoom) -> Double
    /// The overview only with backingScale ≥ 2 (1 physical pixel per texel), then x1, x2, x3.
    public static func availableZooms(backingScale: Int) -> [SceneZoom]
    /// The world canvas in scene coordinates (décision 16): x ∈ [−32·(D − i0 + j0), …], y ∈ […, 96 − 16·(i0 + j0)].
    public static func worldBox(for rect: GridRect) -> SceneBox
    /// Texels per physical pixel: 1 / (pointsPerTexel · backingScale).
    public static func pixelStep(_ zoom: SceneZoom, backingScale: Int) -> Double
    /// Rule 2 of 7.3: the centre floored to the physical-pixel grid (multiple of pixelStep), plus half a step on an
    /// axis whose size in physical pixels is odd, so that every integer texel edge lands on a pixel edge.
    public static func snapped(_ pose: CameraPose, view: ViewMetrics) -> CameraPose
    /// Keeps the world in view with `margin`; a world smaller than the view on an axis is centred on that axis.
    public static func clamped(_ pose: CameraPose, world: SceneBox, view: ViewMetrics) -> CameraPose
    public static func visibleBox(_ pose: CameraPose, view: ViewMetrics) -> SceneBox
    public static func viewPoint(of scene: SceneVector, pose: CameraPose, view: ViewMetrics) -> SceneVector
    public static func scenePoint(atView point: SceneVector, pose: CameraPose, view: ViewMetrics) -> SceneVector
    /// "Tout voir" (3.9): the largest available zoom whose view (minus margins) holds the whole world, centred; else
    /// x1 centred on the world with `needsMinimap`.
    public static func fitAll(world: SceneBox, view: ViewMetrics) -> (pose: CameraPose, needsMinimap: Bool)
    /// Changes the zoom keeping the scene point under `viewPoint` (nil: the view's centre) where it is, then clamps
    /// and snaps.
    public static func zoomed(_ pose: CameraPose, to zoom: SceneZoom, keeping viewPoint: SceneVector?,
                              world: SceneBox, view: ViewMetrics) -> CameraPose
    /// Next or previous available zoom (delta ±1), clamped to the available list.
    public static func step(_ zoom: SceneZoom, by delta: Int, backingScale: Int) -> SceneZoom
    public static func panned(_ pose: CameraPose, byViewPoints delta: SceneVector, world: SceneBox,
                              view: ViewMetrics) -> CameraPose
    /// Launch: `defaultZoom` (AppSettings: 0 = overview, falls back to x1 without Retina), centred on `focus` or on
    /// the world.
    public static func initialPose(defaultZoom: Int, world: SceneBox, focus: SceneVector?, view: ViewMetrics) -> CameraPose
}
public struct PinchAccumulator: Hashable, Sendable {
    public static let threshold = 0.35
    public init()
    /// Adds a magnification delta (NSEvent.magnification); returns +1 or −1 when the sum crosses ±threshold (the
    /// sum then restarts from zero), else 0. Never a fractional zoom.
    public mutating func add(_ magnification: Double) -> Int
    public mutating func reset()
}

// World/CameraFlight.swift
public struct CameraFlight: Hashable, Sendable {
    public static let duration = 0.4
    /// duration 0 (Reduce Motion): finished at once.
    public init(from: SceneVector, to: SceneVector, start: Double, duration: Double = CameraFlight.duration)
    /// Cubic ease-in-out, unsnapped (the scene snaps every frame).
    public func position(at time: Double) -> SceneVector
    public func isFinished(at time: Double) -> Bool
}

// World/EdgeArrows.swift
public struct EdgeArrowTarget: Hashable, Sendable { public var id: AgentID; public var point: SceneVector; public var priority: Int
                                                    public init(id: AgentID, point: SceneVector, priority: Int) }
public struct EdgeArrow: Hashable, Sendable {
    public var id: AgentID
    public var position: SceneVector   // view points, origin bottom-left, multiples of 2 (2 pt per texel UI)
    public var direction: Int          // 0 up, then clockwise by 45°: 1 up-right, 2 right … 7 up-left
}
public enum EdgeArrows {
    public static let inset = 20.0, spacing = 36.0
    /// One arrow per target outside the visible box: where the ray from the view's centre to the target crosses the
    /// rect inset by `inset`; direction = nearest 45°; arrows closer than `spacing` along the border are pushed
    /// apart (higher priority keeps its place, then lower id); sorted by priority, then id.
    public static func layout(_ targets: [EdgeArrowTarget], pose: CameraPose, view: ViewMetrics) -> [EdgeArrow]
}

// World/Minimap.swift
public struct MinimapLayout: Hashable, Sendable {
    public var width: Double, height: Double            // points, multiples of 2
    public var world: SceneBox
    /// Minimap points, origin top-left (SwiftUI), y down, rounded to multiples of 2.
    public func point(of scene: SceneVector) -> SceneVector
    public func scenePoint(at minimap: SceneVector) -> SceneVector
    /// The visible box in minimap points (y down: minY is the top edge), clipped to the minimap.
    public func viewport(pose: CameraPose, view: ViewMetrics) -> SceneBox
}
public enum Minimap {
    public static let maxWidth = 220.0, maxHeight = 140.0
    public static func layout(world: SceneBox, maxWidth: Double = maxWidth, maxHeight: Double = maxHeight) -> MinimapLayout
}

// World/AutoScroll.swift
public enum AutoScroll {
    public static let band = 48.0, fastBand = 16.0, speed = 200.0, fastSpeed = 600.0
    /// Camera velocity in view points per second while dragging at `pointer` (view points, origin bottom-left):
    /// toward each edge closer than `band` (speed), or `fastBand` (fastSpeed); zero elsewhere.
    public static func velocity(pointer: SceneVector, view: ViewMetrics) -> SceneVector
}

// Assets/AtlasPacker.swift
public struct AtlasEntry: Hashable, Sendable { public var page: Int; public var rect: PixelRect; public var anchor: PixelPoint }
public struct AtlasAnimation: Hashable, Codable, Sendable { public var frames: [String]; public var holds: [Int]; public var loops: Bool }
public struct Atlas: Sendable {
    public var pageSize: Int
    public var pages: [PixelImage]                      // transparent background, pixels (0, 0, 0, 0)
    public var entries: [String: AtlasEntry]            // by frame name ("desk~light@ne#0")
    public var animations: [String: AtlasAnimation]     // by SpriteKey.name, sprites of more than one frame
    public func entry(_ key: SpriteKey, frame: Int) -> AtlasEntry?
}
public enum AtlasPacker {
    /// Shelf packing of every frame (mirrors included, décision 5), sorted by height, width (both descending), then
    /// name; `padding` px around each frame filled by extruding its edge pixels; deterministic.
    public static func pack(_ defs: [SpriteDef], pageSize: Int = 2048, padding: Int = 2) -> Atlas
}
// Assets/SpriteManifest.swift (7.6; holds instead of fps: écart, exact at 24 ticks/s)
public struct SpriteManifest: Codable, Equatable, Sendable {
    public var format: String                 // "pixelopenspace-atlas"
    public var version: Int                   // 1
    public var theme: String                  // "day"
    public var pages: [Page]; public struct Page: Codable, Equatable, Sendable { public var file: String; public var size: [Int] }
    public var sprites: [String: Sprite]; public struct Sprite: Codable, Equatable, Sendable {
        public var page: Int; public var rect: [Int]; public var anchor: [Int]; public var mask: Bool }
    public var animations: [String: AtlasAnimation]
    public var mirrors: [String: String]      // derived sprite name → source name
    public var tinted: [String]               // ids generated per project hue
    public init(atlas: Atlas, defs: [SpriteDef], theme: String = "day")
    public func encoded() throws -> Data      // sorted keys, same bytes every time
}
// Assets/AtlasExport.swift
public enum AtlasExport {
    /// "atlas-0.png"… and "manifest.json" for SpriteCatalog.all, in that order.
    public static func files() throws -> [(name: String, bytes: [UInt8])]
}
```

`sprite-export --atlas <dossier>` écrit ces fichiers (une ligne par fichier, comme le reste de l'outil) et aucune autre image.

- [ ] **Step 1: Write the failing tests.** `CameraMathTests` : `pointsPerTexelAndScale` ; `overviewOnlyOnRetina` ; `worldBoxMatchesCanvas` (décision 16, pour 12×15, 24×24, 36×24 : largeur et hauteur égales à `canvasSize`) ; `snappedAlignsTexelsOnPhysicalPixels` (200 poses et tailles de vue semées, paires et impaires, chaque zoom, échelle 1 et 2 : le bord gauche et le bord bas de la vue tombent sur un multiple de `pixelStep`) ; `snappedIsIdempotent` ; `clampedKeepsTheWorldInView` ; `smallWorldIsCentred` ; `fitAllPicksTheLargestZoom` (monde 36×24 dans 1470 × 830 pt Retina → vue d'ensemble ; dans 3000 × 2000 → ×1 ; 1090 × 830 sans Retina → ×1 et `needsMinimap`) ; `zoomKeepsThePointUnderTheCursor` (à un pas de grille près) ; `stepStaysInAvailableZooms` ; `pannedMovesByViewPoints` ; `viewSceneRoundTrip` ; `initialPoseUsesDefaultZoom`. `CameraFlightTests` : départ, arrivée, mi-parcours symétrique, monotone, durée 0. `PinchAccumulator` : sous le seuil rien, au-delà un pas puis remise à zéro, signe. `EdgeArrowsTests` : cible visible sans flèche ; 8 directions sur 8 cibles autour de la vue ; position sur le rectangle intérieur ; écartement de deux cibles proches ; ordre ; multiples de 2. `MinimapTests` : rapport d'aspect gardé, taille dans les bornes, aller-retour scène ↔ mini-carte, viewport découpé. `AutoScrollTests` : 47 pt → 200 pt/s vers le bord ; 15 pt → 600 ; 49 pt → 0 ; coin → deux composantes. `AtlasPackerTests` : chaque frame du catalogue a une entrée ; entrées sans chevauchement (marges comprises) et dans leur page ; pixels recopiés à l'identique ; marges égales aux pixels du bord ; déterministe ; le catalogue tient en au plus 3 pages de 2048. `SpriteManifestTests` : aller-retour JSON ; octets identiques sur deux encodages ; miroirs listés ; animations égales aux `holds` des définitions.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "CameraMathTests|CameraFlightTests|EdgeArrowsTests|MinimapTests|AutoScrollTests|AtlasPackerTests|SpriteManifestTests"`.
- [ ] **Step 3: Implement**, puis l'option `--atlas` de `sprite-export` ; essai : `swift run --package-path Core sprite-export --atlas "$TMPDIR/pos-atlas"` et ouvrir `atlas-0.png` (outil Read).
- [ ] **Step 4: Run** `cd Core && swift build && swift test` → vert ; contrôle du tiret cadratin.
- [ ] **Step 5: Commit.** `git add Core && git commit -m "Core step 3: pixel-exact camera math, navigation aids and sprite atlas"`

### Task 4: Plan de scène public : nœuds à identifiant stable, fond cuit, diff (cœur, vague 1)

**Files:**
- Create: `Core/Sources/PixelCore/World/ScenePlan.swift`, `Core/Sources/PixelCore/World/ScenePlanner.swift`
- Modify: `Core/Sources/PixelCore/World/SceneCompositor.swift` (le constructeur de plan interne part dans `ScenePlanner.swift` ; le compositeur rend le plan public), `Core/Sources/PixelCore/World/SceneModel.swift` (`SceneInput` : nouveaux champs, extras tirés du tableau)
- Test: `Core/Tests/PixelCoreTests/ScenePlanTests.swift`, `SceneExtrasTests.swift` (nouveaux), `SceneCompositorTests.swift` (adapté si ses tests lisent le plan interne)
- **Ne pas modifier** le golden ni `docs/jalon-visuel/` : le rendu doit rester identique octet pour octet.

**Interfaces:**
- Consumes: tout `World/` et `Assets/` existants (`SceneCompositor`, `SceneInput`, `WorldLayoutResult`, `HUDSprites`, `CharacterSprites.canvas`, `SpriteCatalog`, `MonitorSprites`, `FurnitureSprites`, `WallSprites`, `SceneryKit`), `BoardQuery`, `TaskBoardState`.
- Produces (utilisé par les tâches 5, 6, 7, 9 à 12) :

```swift
// World/ScenePlan.swift
/// What a click on a point of the scene means (3.9).
public enum SceneHitTarget: Hashable, Sendable {
    case agent(AgentID)
    case freeDesk(ProjectID, deskIndex: Int)
    case islandSign(ProjectID, part: Int)
    case islandFloor(ProjectID, part: Int)    // the rug and the island plant
    case corkWall
    case elevator
    case hallProp(DecorKind)
    case floor(GridPoint)                     // hall or corridor, nothing on it
}
/// Drawing passes, back to front. background: baked (décision 2); wall: cork wall, its cards, elevator and LED;
/// world: furniture, characters, signs, marks; light and wallLight: additive, at night only; overlay: never veiled.
public enum SceneLayer: Int, CaseIterable, Comparable, Sendable { case background, wall, world, wallLight, light, overlay }
public struct SceneNodeID: Hashable, Comparable, Sendable, CustomStringConvertible { public let rawValue: String }
public enum SceneSprite: Hashable, Sendable {
    /// A catalog sprite: `frame` nil = animated with the sprite's holds (frame 0 in a still render).
    case sprite(SpriteKey, frame: Int?)
    /// The look's sheet (CharacterSprites), animated.
    case character(look: AgentLook, hue: Int, animation: CharacterAnimation, facing: Facing)
    /// A composed image (sign, name plate, clipped light): textures are cached by `PixelImage.fingerprint`.
    case image(PixelImage, name: String)
}
public struct SceneNode: Hashable, Sendable {
    public var id: SceneNodeID
    public var layer: SceneLayer
    public var sprite: SceneSprite
    public var position: ScenePoint            // the anchor, scene texels, y up (décision 16)
    public var anchor: PixelPoint              // px from the top-left of the image
    public var width: Int, height: Int
    public var order: Int                      // painter's order inside its layer, 0…n−1
    public var tickOffset: Int                 // animation clock offset (subagent minis)
    public var tile: GridPoint?
    public var target: SceneHitTarget?         // nil: not clickable (lights, marks)
}
/// The baked part (décision 2): floor tiles, shadows (applied once at 30 %), wall pieces. Hashable to know when to
/// bake again.
public struct SceneBackground: Hashable, Sendable { /* placements: key, frame, canvas origin; implementation detail */ }
public struct WorldScenePlan: Equatable, Sendable {
    public var rect: GridRect                  // the canvas rect: crop or layout.bounds
    public var canvasWidth: Int, canvasHeight: Int
    public var background: SceneBackground
    public var nodes: [SceneNode]              // sorted by (layer, order)
    public var veilAlpha: UInt8?               // night only
    /// Seat tile centre of every agent shown (camera flights, edge arrows, accessibility frames).
    public var agentSeats: [AgentID: ScenePoint]
    /// Rug of every island part, as a GridRect, and its sign tile.
    public var islands: [IslandFrame]; public struct IslandFrame: Hashable, Sendable {
        public var projectID: ProjectID; public var part: Int; public var rug: GridRect; public var sign: GridPoint }
    public func canvasPoint(_ p: ScenePoint) -> PixelPoint     // décision 16
    public func scenePoint(_ p: PixelPoint) -> ScenePoint
    public func diff(from old: WorldScenePlan?) -> ScenePlanDiff
}
public struct ScenePlanDiff: Equatable, Sendable {
    public var added: [SceneNode]; public var updated: [SceneNode]; public var removed: [SceneNodeID]
    public var backgroundChanged: Bool
    public var isEmpty: Bool { get }
}
public struct ScenePlanOptions: Hashable, Sendable {
    public var overview: Bool; public var night: Bool; public var reduceTransparency: Bool; public var crop: GridRect?
    /// 7.9: the XL "!" at every zoom, every overlay on its frame 0 (no bounce).
    public var reduceMotion: Bool
    public init(overview: Bool = false, night: Bool = false, reduceTransparency: Bool = false, crop: GridRect? = nil,
                reduceMotion: Bool = false)
    public init(_ render: RenderOptions)
}
// World/ScenePlanner.swift
public enum ScenePlanner { public static func plan(_ scene: SceneInput, options: ScenePlanOptions) -> WorldScenePlan }
// World/SceneCompositor.swift (additions; render(_:options:) keeps its signature and its bytes)
extension SceneCompositor {
    public static func render(_ plan: WorldScenePlan, tick: Int, zoom: SceneZoom) -> PixelImage
    /// The background alone at 1 pixel per texel (canvasWidth × canvasHeight).
    public static func background(_ plan: WorldScenePlan) -> PixelImage
}
// World/SceneModel.swift (additions)
public struct SceneInput {
    // … existing properties, then these new ones, with their default in every init (nothing drawn differs when they
    // keep it):
    public var selectedAgent: AgentID?          // ov.selection under its seat
    public var hovered: SceneHitTarget?         // agent: its name plate; free desk: floor.hover on desk and seat
    public var dropTarget: SceneHitTarget?      // agent: floor.dropTarget on the seat; free desk: on desk and seat;
                                                // island: floor.hover on every rug tile
    public var hiddenAgents: Set<AgentID>       // avatar, its shadow, overlays and plate left out (arrival walk)
}
extension SceneInput {
    /// Layout, presentations and post-its from the board: queued = cards in the agent's queue (instructions do not
    /// count), cardOnScreenHue = hue of the project of its current card (10 without project), boardCardHues = cards
    /// of "À faire", "En cours", "À valider" by column then rank.
    public static func make(workspace: Workspace, runtimes: [AgentID: AgentRuntime], board: TaskBoardState, now: Date,
                            reduceMotion: Bool = false, selectedAgent: AgentID? = nil, hovered: SceneHitTarget? = nil,
                            dropTarget: SceneHitTarget? = nil, hiddenAgents: Set<AgentID> = []) -> SceneInput
}
```

Identifiants des nœuds (stables tant que l'objet existe) : `wall:board`, `wall:board/card/<k>`, `wall:board/more`, `wall:elevator` (frame 0 fixe), `wall:elevator/led`, `wall:<ne|nw>/<start>/star/<k>` (nuit) ; `hall:<kind>/<i>,<j>` ; `island:<projectID>/<part>/sign`, `…/plant`, `…/hover/<i>,<j>` ; `post:<projectID>/<deskIndex>/<rôle>` pour `chair`, `desk`, `monitor`, `screen`, `keyboard`, `lamp`, `mug`, `papers`, `postit`, `queue`, `cone`, `glow`, `hover`, `drop` ; `agent:<agentID>/<rôle>` pour `avatar`, `mini/<k>`, `selection`, `halo`, `overlay`, `bubble`, `badge/<kind>`, `queueBadge`, `nameplate`, `launching`. Cibles : tout nœud d'un poste occupé et de son agent → `.agent` ; d'un poste libre → `.freeDesk` ; pancarte → `.islandSign` ; plante d'îlot → `.islandFloor` ; mur de liège et ses cartes → `.corkWall` ; ascenseur → `.elevator` ; accessoires du hall → `.hallProp` ; lumières et marques au sol → `nil`.

Règles : `ScenePlanner.plan` produit les placements de l'ancien constructeur, dans le même ordre (le compositeur ne change que de représentation) ; `render(_ scene:options:)` = `render(ScenePlanner.plan(scene, options: ScenePlanOptions(options)), tick: options.tick, zoom: options.zoom)` ; `render(plan)` = fond, couche `wall`, couche `world`, puis la nuit le voile, les lumières (`wallLight` découpées comme aujourd'hui derrière le monde) et enfin `overlay`. Le mur de liège, ses cartes et l'ascenseur deviennent des nœuds (pas cuits), à la même place ; une pièce de mur qui, dans l'ordre d'origine, se dessine après eux et les recouvre en partie devient elle aussi un nœud de la couche `wall`, dans le même ordre, pour que le rendu reste identique. Les lumières murales sont émises déjà découpées (images composées), pour que l'app n'ait aucun masque à calculer.

- [ ] **Step 1: Write the failing tests.** `ScenePlanTests` : `renderFromPlanIsUnchanged` (`GoldenTests` passe, et `render(plan)` égale `render(scene, options:)` pour les deux distributions, la vue d'ensemble, ×1 à ×3, jour et nuit, un recadrage) ; `backgroundPlusNodesEqualsRender` (de jour, le fond puis les couches `wall`, `world`, `overlay` rasterisés à la main donnent l'image du compositeur) ; `nodeIDsAreUnique` ; `stateChangeOnlyUpdatesThatAgent` (Nova passe d'attente à travail : le diff ne touche que des nœuds `agent:<Nova>` et `post:<API>/0`) ; `addingAnAgentMovesNothing` (aucun nœud existant ne change de position ; seuls des ajouts, le poste libre suivant et un fond à recuire si le tapis grandit) ; `unchangedInputGivesEmptyDiff` ; `targetsFollowTheRules` ; `canvasSceneRoundTrip` (décision 16) ; `selectionHoverDropTargetDrawTheirMarks` ; `hiddenAgentLeavesOnlyItsChair` ; `reduceMotionUsesXLBangOnFrameZero` ; `elevatorAndCorkWallAreNodes`. `SceneExtrasTests` : files, carte à l'écran, teintes du mur de liège depuis un tableau construit dans le test ; `make(…board…)` sans tableau égal à l'ancien `make` sans extras.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "ScenePlanTests|SceneExtrasTests"`.
- [ ] **Step 3: Implement.** Déplacer `ScenePlanBuilder` dans `ScenePlanner.swift` en lui faisant produire des `SceneNode` (identifiant, rôle, cible) et le `SceneBackground` ; le compositeur garde ses constantes de placement (`overlayLift`, `headShift`, `nameplateDrop`…) et les expose au planificateur en `internal`.
- [ ] **Step 4: Same bytes.** `cd Core && swift test` → vert (golden compris) ; puis `swift run --package-path Core -c release sprite-export --out "$TMPDIR/pos-t4-render"` et `for f in docs/jalon-visuel/*.png; do cmp "$f" "$TMPDIR/pos-t4-render/$(basename "$f")"; done` → aucune différence.
- [ ] **Step 5: Commit.** `git add Core && git commit -m "Core step 3: public scene plan with stable node ids, baked background and diff"`

### Task 5: Monde qui ne bouge jamais : annexes persistantes, apparences, événements, trajets (cœur, vague 2)

**Files:**
- Create: `Core/Sources/PixelCore/Model/LookGenerator.swift`, `Core/Sources/PixelCore/World/WorldEvents.swift`, `Core/Sources/PixelCore/World/WalkPath.swift`
- Modify: `Core/Sources/PixelCore/Model/Workspace.swift`, `Persistence/WorkspaceOps.swift`, `Persistence/WorkspaceValidator.swift`, `Persistence/Migrator.swift`, `Persistence/Codecs.swift`, `World/WorldLayout.swift`
- Test: `Core/Tests/PixelCoreTests/LookGeneratorTests.swift`, `WorldEventsTests.swift`, `WalkPathTests.swift` (nouveaux), `WorldLayoutTests.swift`, `WorldLayoutPropertyTests.swift`, `WorkspaceOpsTests.swift`, `PersistenceTests.swift`

**Interfaces:**
- Consumes: `Workspace`, `Project`, `Agent`, `AgentLook`, `CharacterPalette`, `NameGenerator.seed(for:)`, `WorldLayout`, `SceneInput` et `WorldLayoutResult` (tâche 4), `IsoMath`.
- Produces (utilisé par les tâches 7, 9, 11, 12) :

```swift
// Model/Workspace.swift
public struct Project { …; /// Slots of parts 1, 2… (annexes), allocated once and kept for life like `slot`.
                         public var annexSlots: [Int] }        // decoded with [] when absent
// Workspace.currentSchemaVersion = 2 (Migrator.workspaceSteps: v1 → v2)
// Model/LookGenerator.swift
extension AgentLook {
    /// Deterministic from the id (seeded like NameGenerator): every skin, haircut, hair colour; half of the agents
    /// wear their project's colour (outfitPaletteIndex nil), the others a neutral outfit (10…15); half an accessory.
    public static func generated(for id: AgentID) -> AgentLook
}
// Persistence/WorkspaceOps.swift (additions)
extension Workspace {
    /// deskIndex nil: the lowest free desk (as before); given: that desk if it is free (≥ 0), else nil.
    /// look nil: AgentLook.generated(for: id). Allocates an annex slot when the agent's part has none yet, and when
    /// its part becomes full (the next part's free desk): the lowest slot used by no live project and no annex.
    @discardableResult public mutating func addAgent(to projectID: ProjectID, name: String? = nil,
        permissionMode: PermissionMode? = nil, model: String? = nil, worktree: String? = nil, id: AgentID = AgentID(),
        deskIndex: Int? = nil, look: AgentLook? = nil, now: Date) -> AgentID?
    /// Main slots and annex slots of the live projects.
    public var usedSlots: Set<Int> { get }
}
// World/WorldEvents.swift
public enum WorldEvent: Hashable, Comparable, Sendable {
    case islandAppeared(ProjectID, part: Int)                 // furniture falls (tâche 11)
    case desksAppeared(ProjectID, part: Int, deskIndices: [Int])   // the rug grew: its new desks fall
    case agentArrived(AgentID)                                // avatar appears (offline or absent → live): elevator
    case agentLeft(AgentID)                                   // avatar disappears (live → offline or removed)
    case turnCelebrated(AgentID)                              // kind becomes .done: celebrate once
    case cardReceived(AgentID)                                // its queue or its card on screen grew: grab
}
public enum WorldEvents {
    /// nil old: [] (launch: nothing animates). Sorted.
    public static func between(_ old: SceneInput?, _ new: SceneInput) -> [WorldEvent]
}
// World/WalkPath.swift
public enum WalkPath {
    /// Floor tile in front of the elevator doors (layout.elevator.origin).
    public static func door(_ layout: WorldLayoutResult) -> GridPoint
    /// Desks, seats, signs, island plants, hall props: what nobody walks through.
    public static func blockedTiles(_ layout: WorldLayoutResult) -> Set<GridPoint>
    /// Shortest 4-neighbour path from `from` to `to` inside the bounds, through unblocked tiles (`to` may be a seat);
    /// neighbours tried in the order +i, +j, −i, −j; nil when unreachable.
    public static func route(from: GridPoint, to: GridPoint, layout: WorldLayoutResult) -> [GridPoint]?
}
```

Règles : `WorldLayout.compute` place l'annexe de la partie p dans `annexSlots[p − 1]` quand il existe, sinon comme aujourd'hui (fichier ancien ou réparé) ; `addProject` saute aussi les slots d'annexe ; archiver un projet libère tous ses slots ; retirer un agent ne libère rien (append-only, 3.8). `WorkspaceValidator` : un slot d'annexe en double (avec un slot principal ou une autre annexe) est retiré, avec un message. Migration v1 → v2 (`Migrator` pour le JSON, puis une passe typée dans `Codecs` quand `migratedFrom == 1`) : `annexSlots = []`, puis chaque agent dont l'apparence vaut `AgentLook()` reçoit `generated(for:)`.

- [ ] **Step 1: Write the failing tests.** `LookGeneratorTests` : déterministe ; sur 200 identifiants semés, toutes les peaux, au moins 5 coupes, au moins 6 couleurs, les deux sortes de tenues, avec et sans accessoire ; valeurs dans les bornes de `CharacterPalette`. `WorkspaceOpsTests` : `addAgentAtAGivenDesk` (libre : accepté ; occupé : nil) ; `newAgentGetsAGeneratedLook` ; `annexSlotIsAllocatedOnceAndKept` ; `addProjectSkipsAnnexSlots` ; `archiveFreesAnnexSlots`. `WorldLayoutTests` : `annexUsesItsPersistedSlot`. `WorldLayoutPropertyTests` : les séquences semées montent jusqu'à 20 agents par projet ; `noIslandEverMoves` couvre les annexes ; `existingDesksNeverMove`. `PersistenceTests` : `workspaceV1MigratesToV2` (fixture JSON v1 écrite dans le test : apparences par défaut → générées, `annexSlots` vides, `schemaVersion` 2) ; `annexSlotDuplicateIsRepaired`. `WorldEventsTests` : une fonction par cas, plus `launchGivesNoEvent` et `sorted`. `WalkPathTests` : depuis la porte, chaque siège de la vue d'ensemble du jalon est atteint ; chemin contigu ; jamais par une tuile bloquée ; plus court (comparé à un BFS de référence écrit dans le test) ; déterministe ; inaccessible → nil.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "LookGeneratorTests|WorldEventsTests|WalkPathTests|WorldLayout|WorkspaceOpsTests|PersistenceTests"`.
- [ ] **Step 3: Implement** (lire d'abord `WorkspaceOps.swift`, `WorkspaceValidator.swift`, `Migrator.swift`, `Codecs.swift`).
- [ ] **Step 4: Run** `cd Core && swift build && swift test` → vert, golden compris (les scènes de démonstration fixent leurs apparences à la main et n'ont pas d'annexe) ; contrôle du tiret cadratin.
- [ ] **Step 5: Commit.** `git add Core && git commit -m "Core step 3: persistent annex slots, generated looks, world events and walk paths"`

### Task 6: Règles d'interaction : hit-test par masque, clics, dépôts, annonces ; plaques ×2 en vue d'ensemble (cœur, vague 2)

**Files:**
- Create: `Core/Sources/PixelCore/World/SceneHitTest.swift`, `World/ClickResolver.swift`, `World/DropResolver.swift`, `Core/Sources/PixelCore/State/AnnouncementBatcher.swift`
- Modify: `Core/Sources/PixelCore/World/ScenePlanner.swift` (plaques des agents urgents ×2 en vue d'ensemble) ; sorties : `Fixtures/golden/sprites.txt`, `docs/jalon-visuel/vue-ensemble-jour.png`, `vue-ensemble-nuit.png`, une ligne de `docs/jalon-visuel/README.md`
- Test: `Core/Tests/PixelCoreTests/SceneHitTestTests.swift`, `ClickResolverTests.swift`, `DropResolverTests.swift`, `AnnouncementBatcherTests.swift` (nouveaux), `ScenePlanTests.swift`

**Interfaces:**
- Consumes: tâche 4 (`WorldScenePlan`, `SceneNode`, `SceneSprite`, `SceneHitTarget`), tâche 3 (`SceneVector`), `SpriteCatalog`, `CharacterSprites.canvas`, `PixelImage.alphaMask`, `IsoMath.toGrid`, `Workspace`, `AgentRuntime`, `TaskBoardState`, `TaskCard`, `BoardQuery`, `TaskLifecycle.confirmation(for:state:context:)`.
- Produces (utilisé par les tâches 9, 10 et 12) :

```swift
// World/SceneHitTest.swift
public struct SceneHitTester: Sendable {
    public init(plan: WorldScenePlan)
    /// The target under a scene point (texels, y up): nodes with a target, from the top (overlay, then world, then
    /// wall, by descending order), whose opaque pixel covers the texel (frame shown at `tick`: catalog frames,
    /// character frames composed and cached, composed images); else the tile under the point: a rug →
    /// islandFloor, the hall or a corridor → floor(tile); outside the world → nil.
    public mutating func target(at point: SceneVector, tick: Int = 0) -> SceneHitTarget?
}
// World/ClickResolver.swift (3.9, one rule, tested)
public enum ClickInput: Hashable, Sendable {
    case down(SceneHitTarget?, clickCount: Int, time: Double)
    case rightDown(SceneHitTarget?)
    case timer(time: Double)
}
public enum ClickAction: Hashable, Sendable {
    case select(AgentID), clearSelection, openAgentWindow(AgentID), openTerminal(AgentID),
         offerNewAgent(ProjectID, deskIndex: Int), centerIsland(ProjectID, part: Int),
         contextMenu(SceneHitTarget?), wakeAt(Double)
}
public struct ClickResolver: Hashable, Sendable {
    public init(doubleClickInterval: Double)
    public mutating func handle(_ input: ClickInput) -> [ClickAction]
}
// World/DropResolver.swift (the table of 3.9)
public struct DropContext: Sendable {
    public var workspace: Workspace; public var runtimes: [AgentID: AgentRuntime]; public var board: TaskBoardState
    public var home: String                       // to abbreviate paths with "~"
    public init(workspace: Workspace, runtimes: [AgentID: AgentRuntime], board: TaskBoardState, home: String)
}
public enum DropAction: Hashable, Sendable {
    case assign(TaskCardID, AgentID)              // confirmation across projects asked by the app (TaskLifecycle)
    case assignOffline(TaskCardID, AgentID)       // assign, then offer "Relancer la session"
    case launchNewAgent(TaskCardID, ProjectID, deskIndex: Int)
    case firstFreeAgent(TaskCardID, ProjectID)
    case none
}
public struct DropDecision: Hashable, Sendable {
    public var accepted: Bool                     // false: forbidden cursor
    public var feedback: String                   // French, what will happen ("Donner à Nova · file #2")
    public var highlight: SceneHitTarget?         // SceneInput.dropTarget
    public var action: DropAction
}
public enum DropResolver { public static func decide(card: TaskCard, over target: SceneHitTarget?, context: DropContext) -> DropDecision }
// State/AnnouncementBatcher.swift (7.9)
public enum AnnouncementKind: Int, Comparable, Sendable { case waiting = 0, error = 1 }   // waiting first
public struct AnnouncementBatcher: Hashable, Sendable {
    public init(window: Double = 2)
    /// Returns the time of the next flush when this opens a batch, nil otherwise.
    public mutating func add(_ kind: AnnouncementKind, agentName: String, time: Double) -> Double?
    /// One French sentence for the batch: "Nova attend ta réponse", "3 agents attendent ta réponse",
    /// "Nova attend ta réponse ; Zéphyr est en erreur"; nil when empty.
    public mutating func flush(time: Double) -> String?
}
```

Règles de `ClickResolver` (un test chacune) : clic sur un agent → `select` tout de suite et `wakeAt(t + intervalle)` ; au réveil sans second clic → `openAgentWindow` ; second clic dans l'intervalle → `openTerminal` seulement (aucune fenêtre) ; clic sur un poste libre → `offerNewAgent` (jamais de création) ; double-clic sur un poste libre ou un agent → rien d'autre ; double-clic sur le sol ou la pancarte d'un îlot → `centerIsland` ; clic sur le sol vide, le mur de liège, l'ascenseur ou un accessoire du hall → `clearSelection` ; clic droit → `contextMenu` ; tout nouveau clic annule une fenêtre en attente.

Règles de `DropResolver` (table de 3.9 ; une ligne de test chacune) : carte hors d'« À faire » → refusé, « Remets-la d'abord à faire. » ; agent de l'app, même projet, libre → « Donner à Nova · file #n » (n = sa file + 1) ; en attente → « Donner à Nova · sera livré après ton accord » ; occupé → « Donner à Nova · en file #n » ; autre projet → « Donner à Sol · autre projet : ~/dev/infra » (chemin abrégé, la confirmation C3 reste celle de l'app) ; hors ligne → `assignOffline`, « hors ligne : sera livré après relance » ; orphelin (`offline(.orphanElsewhere)`) → refusé, « terminal hors de l'app » ; poste libre → `launchNewAgent`, « Nouvel agent avec ce post-it » ; sol ou pancarte d'un îlot → `firstFreeAgent`, « Premier agent libre de API » ; ailleurs → aucune opération.

Plaques ×2 : en vue d'ensemble, les plaques des agents urgents sont dessinées ×2 (`overviewSignScale`), au-dessus de la tête, sans chevaucher le « ! » ni l'orage.

- [ ] **Step 1: Write the failing tests.** `SceneHitTestTests` : un pixel opaque de l'avatar de Nova → `.agent(Nova)` ; un pixel transparent du cadre de l'avatar, au-dessus du sol d'un îlot → `.islandFloor` ; le « ! » → l'agent ; un poste libre → `.freeDesk` ; la pancarte ; le mur de liège ; le hall → `.floor` ; hors du monde → nil ; l'objet le plus proche gagne là où deux se chevauchent. `ClickResolverTests` et `DropResolverTests` : une fonction par règle. `AnnouncementBatcherTests` : regroupement sur 2 s, pluriel, attentes avant erreurs, rien après un vidage. `ScenePlanTests` : `overviewNameplatesAreDoubled`.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "SceneHitTestTests|ClickResolverTests|DropResolverTests|AnnouncementBatcherTests|ScenePlanTests"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Golden et rendu** (commandes de la tâche 2, étape 4) ; seules les lignes des deux scènes de vue d'ensemble et ces deux PNG doivent changer (`git diff --stat`) ; ouvrir `vue-ensemble-jour.png` (outil Read) : NOVA, SOL, IVO et ZÉPHYR lisibles. Dans le README du jalon, la ligne « Texte en vue d'ensemble » devient « fait (étape 3, tâche 6) ».
- [ ] **Step 5: Run** `cd Core && swift build && swift test` → vert ; contrôle du tiret cadratin.
- [ ] **Step 6: Commit.** `git add Core docs && git commit -m "Core step 3: mask hit-testing, click and drop rules, grouped announcements, doubled overview name plates"`

### Task 7: Scène SpriteKit, caméra et vue Liste ⌘L (app, vague 2)

**Files:**
- Create: `App/Sources/World/SpriteRegistry.swift`, `WorldStage.swift`, `WorldCamera.swift`, `WorldInteractionState.swift`, `WorldScene.swift`, `WorldSceneNodes.swift`, `WorldView.swift`, `WorldViewRepresentable.swift`, `WorldAreaView.swift`, `WorldSceneCoordinator.swift`, `WorldSnapshotHooks.swift`, `EmptyWorldCard.swift` (tous dans `App/Sources/World/`)
- Modify: `App/Sources/UI/Main/RootView.swift`, `UI/Support/WorkbenchState.swift`, `Commands/AppCommand.swift`, `Commands/CommandCenter.swift`, `Model/ModelTypes.swift`, `UI/Commands/CommandAvailability.swift` si besoin

**Interfaces:**
- Consumes: tâche 1 (`SnapshotHooks`, `SceneCaptureProviding`, `SceneCapture`, `SnapshotStep`), tâche 3 (`CameraMath`, `CameraPose`, `ViewMetrics`, `SceneVector`, `SceneBox`, `CameraFlight`, `AtlasPacker`, `Atlas`), tâche 4 (`ScenePlanner`, `WorldScenePlan`, `ScenePlanDiff`, `SceneNode`, `SceneSprite`, `SceneCompositor.background`, `SceneInput.make(…board…)`), `SpriteCatalog.all`, `CharacterSprites.sheet`, `AppModel`, `WorkbenchState`, `AgentBoardView`, `EmptyWorkspaceView`.
- Produces (utilisé par les tâches 9 à 12) :

```swift
@MainActor final class SpriteRegistry {
    init()                                                        // packs SpriteCatalog.all into SKTextures, .nearest
    func texture(_ key: SpriteKey, frame: Int) -> SKTexture?
    /// Frames and holds at 24 ticks/s (setTexture + wait, décision 17), repeated when the sprite loops; nil for one frame.
    func action(_ key: SpriteKey, tickOffset: Int) -> SKAction?
    /// Character sheets composed off the main actor (CharacterSprites.sheet), packed into dynamic pages.
    func prepare(characters: Set<CharacterRef>) async
    func characterTexture(_ ref: CharacterRef, frame: Int) -> SKTexture?
    func characterAction(_ ref: CharacterRef) -> SKAction?
    func texture(for image: PixelImage) -> SKTexture              // composed images, cached by fingerprint (512 at most)
    var stats: [String: Int] { get }                              // atlasPages, dynamicPages, composedTextures
}
struct CharacterRef: Hashable, Sendable { var look: AgentLook; var hue: Int; var animation: CharacterAnimation; var facing: Facing }
enum CameraTarget: Hashable { case agent(AgentID), island(ProjectID, part: Int), hall, point(SceneVector), all }
@MainActor @Observable final class WorldCamera {
    private(set) var pose: CameraPose                             // snapped
    private(set) var view: ViewMetrics
    private(set) var world: SceneBox
    var availableZooms: [SceneZoom] { get }
    var visibleBox: SceneBox { get }
    var needsMinimap: Bool { get }                                // the world is not entirely visible
    func viewPoint(of scene: SceneVector) -> SceneVector
    func scenePoint(atView point: SceneVector) -> SceneVector
    func setZoom(_ zoom: SceneZoom, about viewPoint: SceneVector?, animated: Bool)
    func zoomIn(about viewPoint: SceneVector?)
    func zoomOut(about viewPoint: SceneVector?)
    func fitAll(animated: Bool)
    func pan(byViewPoints delta: SceneVector)                     // immediate, snapped at the next frame
    func fly(to target: CameraTarget)                             // CameraFlight; instant with Reduce Motion
    func center(on target: CameraTarget)                          // instant
}
@MainActor @Observable final class WorldInteractionState {
    var hovered: SceneHitTarget?        // written by task 9
    var dropTarget: SceneHitTarget?     // written by task 12
    var hiddenAgents: Set<AgentID> = [] // written by task 11
}
/// One per main window: what every scene feature reaches.
@MainActor final class WorldStage {
    let camera: WorldCamera; let interaction: WorldInteractionState; let registry: SpriteRegistry
    private(set) var plan: WorldScenePlan?; private(set) var input: SceneInput?
    weak var view: WorldView?; weak var scene: WorldScene?
    private(set) var coordinator: WorldSceneCoordinator?          // created with the stage, started by WorldAreaView
}
final class WorldScene: SKScene {
    func apply(_ plan: WorldScenePlan, diff: ScenePlanDiff)       // reconciliation by node id
    var cameraNode: SKCameraNode { get }
    var hudLayer: SKNode { get }                                  // child of the camera, hidden during captures
    var isFrozen: Bool                                            // snapshots: no actions, frame 0 everywhere
    func node(for id: SceneNodeID) -> SKSpriteNode?
}
final class WorldView: SKView {
    weak var stage: WorldStage?
    func noteInteraction()                                        // 60 fps for one second
}
@MainActor final class WorldSceneCoordinator {
    init(model: AppModel, workbench: WorkbenchState, stage: WorldStage)
    func start(); func stop()
    func replanNow()                                              // synchronous (snapshots)
}
// WorkbenchState: enum MainView: String { case scene, list }; var mainView; weak var worldStage: WorldStage?
// AppCommand: .toggleListView (⌘L, "Vue Liste ou open space"), .zoomIn (⌘+), .zoomOut (⌘−), .fitAll (⌘0, "Tout voir"),
//             menu Présentation; zoom commands available in scene mode only (WorkbenchState.isAvailable).
// UIRequest: .toggleListView, .zoomIn, .zoomOut, .fitAll.
```

Comportement :
- **Atlas et textures** : `AtlasPacker.pack(SpriteCatalog.all)` une fois au premier affichage ; chaque page devient une `SKTexture(data:size:flipped:)` en `.nearest` (vérifier l'orientation des rangées), chaque frame une `SKTexture(rect:in:)` en `.nearest` ; pixels transparents à (0, 0, 0, 0). Planches de personnages par `(apparence, teinte)` préparées avant le premier `apply` qui en a besoin.
- **Nœuds** (`WorldSceneNodes`) : un `SKSpriteNode` par `SceneNode` : texture (frame donnée, sinon frame 0 et action d'animation sauf `isFrozen`), `anchorPoint = (ax / w, 1 − ay / h)`, `position = (x, y)` du plan, `zPosition = base de la couche + order`, `ignoresSiblingOrder = true`. Une mise à jour change la texture, l'action ou la position du nœud existant (même identifiant), jamais un retrait suivi d'un ajout.
- **Fond** : `SceneCompositor.background(plan)` calculé hors du fil principal quand `diff.backgroundChanged` (et au premier plan), découpé en tuiles d'au plus 1024 × 1024 texels, couche `background`. Couleur autour du monde : `Palette.color(.shade)`.
- **Caméra** : `SKCameraNode`, `scene.scaleMode = .resizeFill` (1 unité de scène = 1 pt à l'échelle 1), échelle `CameraMath.cameraScale(zoom)` ; dans `didFinishUpdate`, avance le vol en cours, `clamped`, `snapped`, puis pose la caméra ; `WorldCamera` publie la pose seulement quand elle change. Pose initiale : `CameraMath.initialPose(defaultZoom: settings.defaultZoom, …)`. Le plan est demandé avec `overview: pose.zoom == .overview` et `reduceMotion` (réglage de l'app ou d'Accessibilité de macOS), jamais de nuit (décision 4).
- **Coordinateur** : observe (`withObservationTracking`) `model.workspace`, `runtimes`, `board`, `selectedAgentID`, `now`, `settings`, `stage.interaction` et la vue d'ensemble ; regroupe les changements en un seul recalcul par image ; `SceneInput.make(workspace:runtimes:board:now:reduceMotion:selectedAgent:hovered:dropTarget:hiddenAgents:)`, `ScenePlanner.plan`, `diff(from:)`, `apply` seulement si le diff n'est pas vide.
- **Énergie** (3.9) : `preferredFramesPerSecond` 30 au repos, 60 pendant une seconde après `noteInteraction()` ou pendant un vol, 15 quand l'app n'est pas active ; `isPaused` quand la fenêtre est masquée (`occlusionState`) ou la vue hors fenêtre ; rien dans `update(_:)` hors d'un vol ou d'un déplacement. Désactivé pendant une capture.
- **RootView** : `workArea` montre `WorldAreaView` (mode scène, par défaut) ou `AgentBoardView` (vue Liste), avec le tableau latéral et les toasts dans les deux cas ; `@AppStorage("mainView")` ; nouvelles requêtes d'UI ; `WorkbenchState.reveal(_:)` fait voler la caméra en mode scène (clic de notification, ⌘', ⌥⌘→), et fait défiler la liste sinon. Monde vide (6(r)) : la scène montre le hall et le mur de liège vide, `EmptyWorldCard` au centre (« Dépose ici un dossier de code pour créer ton premier îlot, ou [+ Projet ⌥⌘N] »).
- **Crochets du banc** (`WorldSnapshotHooks`, enregistrés à la création de la scène) : `listView`, `zoom`, `fitAll`, `focus` (îlot, agent, hall, par nom), `cameraNudge` (décalage non recalé en points, recalé à l'image suivante), et `registerScene` : capture hors écran par `SKRenderer` sur la même scène et la même caméra, à l'échelle d'affichage, couche HUD masquée (repli : `texture(from:crop:)`, noté dans `stats`), `showStill` par une `NSImageView` posée dans la `WorldView`. En mode capture : `isFrozen`, `replanNow()` à chaque étape.

- [ ] **Step 1:** lire `RootView.swift`, `WorkbenchState.swift`, `AppCommand.swift`, `CommandCenter.swift`, `CommandAvailability.swift`, `ModelTypes.swift`, `AgentBoardView.swift`, `EmptyWorkspaceView.swift`, les fichiers `Snapshot/` de la tâche 1 et les interfaces publiques des tâches 3 et 4.
- [ ] **Step 2:** implémenter dans l'ordre : `SpriteRegistry`, `WorldScene` et `WorldSceneNodes`, `WorldCamera`, `WorldView`, `WorldViewRepresentable`, `WorldAreaView`, coordinateur, crochets du banc, puis `RootView`, `WorkbenchState`, commandes.
- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Captures.** `Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-7" zooms,fractional,overview,list,empty` (le banc accepte une liste séparée par des virgules) → `BILAN : écarts hors tolérance 0` ; ouvrir (outil Read) `scene-zooms-x1.png`, `scene-zooms-x3.png`, `diff-fractional-d2.png`, `window-overview-tout-voir.png`, `window-list-liste.png`, `window-empty-monde-vide.png`. Noter dans le commit le nombre de nœuds et de pages d'atlas de `stats.json`.
- [ ] **Step 5:** `cd Core && swift test` toujours vert ; contrôle du tiret cadratin.
- [ ] **Step 6: Commit.** `git add App && git commit -m "App step 3: SpriteKit open space, pixel-exact camera, list view toggle"`

### Task 8: Fenêtre agent (app, vague 2)

**Files:**
- Create: `App/Sources/UI/AgentWindow/AgentWindowController.swift`, `AgentWindowView.swift`, `AgentWaitSection.swift`, `AgentQueueSection.swift`, `AgentPortraitView.swift`, `App/Sources/UI/Support/PixelImage+CGImage.swift`
- Modify: `App/Sources/UI/Status/WaitingTrayView.swift`, `App/Sources/UI/Agents/AgentCardView.swift`

**Interfaces:**
- Consumes: `AppModel` (`display(for:)`, `accessibilityLabel(for:)`, `giveInstruction(to:text:)`, `resumeQueue`, `setQueuePaused`, `interrupt`, `relaunch`, `queue(of:)`, `currentCard(of:)`, `cardToDecide(of:)`, `effectiveModel(of:)`, `names(of:)`), `WorkbenchState` (`showTerminal`, `requestCloseSession`, `requestSendAnyway`, `requestTask`), `AgentActions`, `PermissionModeInfo`, `AgentPresenter`, `CharacterSprites.canvas`, `ResolvedLook`, tâche 1 (`SnapshotHooks`).
- Produces (utilisé par les tâches 9, 10 et 12) :

```swift
@MainActor final class AgentWindowController {
    static let shared: AgentWindowController
    /// One NSPanel per agent at most, reused; several agents at once; closes when the agent is removed.
    func show(_ agentID: AgentID, model: AppModel, workbench: WorkbenchState)
    func close(_ agentID: AgentID)
    func isShowing(_ agentID: AgentID) -> Bool
}
extension PixelImage { func cgImage() -> CGImage? }               // UI/Support/PixelImage+CGImage.swift
```

Contenu (maquettes 6(d), 6(e), 6(e′), interface SwiftUI simple, décision 7) :
- **En-tête** : portrait (frame de l'animation de l'état, tournée vers le spectateur, agrandie ×2 en `.interpolation(.none)` ; animée par `TimelineView` à sa cadence, figée avec « Réduire les animations »), « Nova · API » (titre du panneau), état et durée (« TRAVAILLE : Bash · depuis 4 min 12 s »), tâche en cours, modèle, mode de permission, session (8 premiers caractères) et nombre de sessions.
- **Attente** (section affichée seulement quand l'agent attend) : permission (outil, résumé de `tool_input` en chasse fixe), question (en-tête, texte, options en liste, « une seule réponse » ou « plusieurs réponses »), dialogue MCP (serveur et message), lancement silencieux (« Regarde le terminal ») ; bouton « Ouvrir le terminal ⌘T » ; mention « L'app ne répond jamais à ta place. »
- **Donner une consigne** : champ et « Envoyer ↩ » (`giveInstruction`), avec « Occupé : la consigne passera en tête de file. » quand l'agent travaille.
- **File** : post-its et consignes dans l'ordre (`queue(of:)`), « ↑ », « ↓ », « Retirer » (`requestTask(.reorderQueue / .unassign)`), « Mettre en pause » / « Reprendre la file ».
- **Boutons** selon la table de 6(d) (Terminal ⌘T, Interrompre ⌘., Relancer la session, Reprendre la file, Continuer la tâche, Envoyer quand même, Fermer), grisés avec la raison en infobulle (`AgentActions`).
- **Clavier** : ⌘W ferme ; ⌘T terminal ; Échap interrompt seulement si l'agent travaille, après un toast « Interruption dans 1,5 s » annulable (5.8), sinon ferme.
- **Points d'entrée de cette tâche** : un clic sur une ligne du plateau d'attente ouvre la fenêtre (le vol de caméra s'y ajoute à la tâche 10) ; le menu contextuel d'une carte d'agent de la vue Liste gagne « Ouvrir la fenêtre de l'agent ». `WaitingTrayView` et `AgentCardView` créent `AgentWindowController.shared` à leur apparition ; il enregistre alors le crochet `agentWindow` du banc.
- Accessibilité : chaque section est un groupe étiqueté ; le portrait est décoratif (`accessibilityHidden`).

- [ ] **Step 1:** lire `AgentCardView.swift`, `AgentCardButtons.swift`, `AgentActions.swift`, `WaitingTrayView.swift`, `GiveInstructionSheet.swift`, `PermissionModeInfo.swift`, `StateStyle.swift`, `AgentPresenter.swift` (cœur).
- [ ] **Step 2:** implémenter.
- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Captures.** `Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-8" agentWindow,list` ; ouvrir les fenêtres de Nova (permission Bash, file d'un post-it), Sol (question et options), Brume (démarre) et la liste (outil Read).
- [ ] **Step 5:** contrôle du tiret cadratin. **Commit.** `git add App && git commit -m "App step 3: agent window"`

### Task 9: Souris, trackpad et clavier dans la scène (app, vague 3)

**Files:**
- Create: `App/Sources/World/Input/WorldInputController.swift`, `WorldClickPerformer.swift`, `WorldContextMenu.swift`, `NewAgentPopover.swift`, `HoverCardView.swift`
- Modify: `App/Sources/World/WorldView.swift`, `App/Sources/Model/AppModel+Intents.swift`

**Interfaces:**
- Consumes: tâche 7 (`WorldStage`, `WorldCamera`, `WorldInteractionState`, `WorldView.noteInteraction()`), tâche 6 (`SceneHitTester`, `ClickResolver`, `ClickAction`), tâche 3 (`CameraMath`, `PinchAccumulator`), tâche 8 (`AgentWindowController`), tâche 5 (`Workspace.addAgent(…deskIndex:…)`), `AgentActions`, `WorkbenchState`, `AppModel`.
- Produces : `AppModel.addAgent(projectID:name:model:permissionMode:worktree:launch:initialPrompt:deskIndex:)` (nouveau paramètre `deskIndex: Int? = nil`, utilisé aussi par la tâche 12) ; crochet `hover` du banc.

Comportement (3.9, « Caméra et souris » et « Résolution des clics ») :
- **Trackpad** : deux doigts (`hasPreciseScrollingDeltas`) → déplacement ; pincement → `PinchAccumulator`, un pas de zoom autour du curseur, jamais d'échelle fractionnaire au repos.
- **Souris** : molette → un pas de zoom par cran autour du curseur ; ⇧ + molette → déplacement horizontal ; glisser sur le sol vide (cible nil, `.floor`, `.islandFloor`) au-delà de 3 pt → déplacement ; bouton du milieu, ou Espace maintenu + glisser → déplacement ; glisser depuis un agent ou un poste ne déplace pas.
- **Clics** : la cible vient de `SceneHitTester` au point de scène sous le curseur ; `ClickResolver(doubleClickInterval: NSEvent.doubleClickInterval)` ; `WorldClickPerformer` exécute : `select` → `model.select(agent:)` ; `openAgentWindow` → `AgentWindowController.shared.show` ; `openTerminal` → `workbench.showTerminal(for:focus: true)` ; `offerNewAgent` → `NewAgentPopover` (« Nouvel agent ici ? », nom du projet, [Créer ↩] crée et lance l'agent à ce poste, [Annuler]) ancré sur le poste ; `centerIsland` → vol ; `clearSelection` → `model.select(agent: nil)` ; `contextMenu` → `WorldContextMenu`.
- **Menu contextuel** natif (mêmes commandes que les menus) : agent → Ouvrir la fenêtre, Ouvrir le terminal ⌘T, Donner une consigne…, Interrompre ⌘., Relancer la session, Fermer la session, Renommer…, Retirer l'agent… (grisés selon `AgentActions`, confirmations de `WorkbenchState`) ; poste libre → Nouvel agent ici… ; îlot → Nouvel agent dans API…, Centrer l'îlot, Renommer le projet… ; sol → Tout voir ⌘0, Vue Liste ⌘L.
- **Survol** : zone de suivi (`mouseMoved`) → `interaction.hovered` (agent ou poste libre ; le plan montre la plaque de nom ou `floor.hover`) ; après 0,3 s immobile, `HoverCardView` (sous-vue de la `WorldView` qui laisse passer les événements) : « Nova · API · ATTEND TA RÉPONSE (!) », « Bash : rm -rf dist · depuis 42 s », « clic : fenêtre · double : terminal » ; poste libre : « Poste libre · clic : nouvel agent ici ».
- **Clavier** (focus dans la scène, `acceptsFirstResponder`) : flèches → déplacement de `CameraMath.keyboardStep` (⇧ : ×4) ; ⌘= → zoom avant (alias de ⌘+) ; ↩ ou Espace relâché sans glisser → fenêtre de l'agent sélectionné ; Échap → désélectionner.
- Chaque entrée appelle `noteInteraction()`.
- Crochet `hover` du banc : pose `interaction.hovered` et la carte de survol sur la cible nommée.

- [ ] **Step 1:** lire les fichiers de `App/Sources/World/` (tâche 7), `AppModel+Intents.swift`, `AgentActions.swift`, `WorkbenchState.swift`.
- [ ] **Step 2:** implémenter.
- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Captures.** `Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-9" select,zooms` → `BILAN : écarts hors tolérance 0` ; ouvrir `window-select-selection.png` (anneau sous Nova), `window-select-survol-agent.png` (plaque et carte de survol de Bip), `window-select-survol-poste.png` (outil Read). Les gestes réels sont dans la checklist manuelle.
- [ ] **Step 5:** contrôle du tiret cadratin. **Commit.** `git add App && git commit -m "App step 3: mouse, trackpad and keyboard in the scene"`

### Task 10: Repères : mini-carte, flèches de bord, zoom, vols depuis la barre d'état et le plateau, accessibilité de la scène (app, vague 3)

**Files:**
- Create: `App/Sources/World/HUD/MinimapView.swift`, `EdgeArrowsView.swift`, `ZoomControl.swift`, `SpriteImage.swift`, `WorldFlights.swift`, `App/Sources/World/WorldAccessibility.swift`
- Modify: `App/Sources/World/WorldAreaView.swift`, `App/Sources/UI/Status/StatusBarView.swift`, `App/Sources/UI/Status/WaitingTrayView.swift`, `App/Sources/Model/AppModel.swift`, `App/Sources/Model/AppModel+Engine.swift`

**Interfaces:**
- Consumes: tâche 7 (`WorldStage`, `WorldCamera`, `CameraTarget`, `WorkbenchState.mainView`, `worldStage`), tâche 3 (`EdgeArrows`, `EdgeArrowTarget`, `Minimap`, `MinimapLayout`), tâche 6 (`AnnouncementBatcher`), tâche 8 (`AgentWindowController`, `PixelImage.cgImage()`), `SpriteCatalog`, `HUDSprites.nameplate`, `StatusSummary`, `AgentPresenter.accessibilityLabel`.
- Produces (utilisé par la tâche 12) :

```swift
/// A Core sprite frame as a SwiftUI image at the UI scale (2 pt per texel, 7.3), never smoothed; rotations by
/// multiples of 90° only.
struct SpriteImage: View { init(_ key: SpriteKey, frame: Int = 0, quarterTurns: Int = 0) }
struct MinimapView: View { init(stage: WorldStage) }             // agent dots expose their AgentID to the drop task
struct EdgeArrowsView: View { init(stage: WorldStage) }
@MainActor enum WorldFlights {
    /// Next agent of `kind` after the selection (waiting: tray order; others: urgency, then sidebar order); selects it
    /// and flies the camera there; nil when none.
    @discardableResult static func flyToNext(_ kind: AgentStateKind, model: AppModel, stage: WorldStage) -> AgentID?
    static func fly(to agentID: AgentID, model: AppModel, stage: WorldStage)
}
```

Comportement :
- **Mini-carte** (6(a), bas à droite de la scène) : affichée tant que le monde n'est pas entièrement visible ; cadre `minimap.frame` en 9-slice, îlots en blocs du ton clair de leur projet, un point `minimap.dot.<état>` par agent (glyphe, jamais la couleur seule), rectangle `minimap.viewport` ; clic → vol, glisser → déplacement immédiat ; libellé VoiceOver « Mini-carte ».
- **Flèches de bord** (3.9, 6(k)) : pour chaque agent en attente hors du champ (`EdgeArrows.layout`), un petit bouton SwiftUI : `ov.edgeArrow` ou `ov.edgeArrow~diagonal` tourné de 90° × n selon la direction, et la plaque du nom (« SOL ») ; clic → vol vers l'agent ; libellé VoiceOver « Sol attend, hors champ ».
- **Contrôle de zoom** (décision 12) : segments « ½ | ×1 | ×2 | ×3 » dans la barre d'état, en mode scène ; « ½ » absent sans écran Retina ; reflète `camera.pose.zoom`.
- **Barre d'état** (décision 13) : en mode scène, un clic sur un compteur → `WorldFlights.flyToNext(kind)` ; en vue Liste, filtre comme avant.
- **Plateau d'attente** : clic sur une ligne → en mode scène, vol vers l'agent puis sa fenêtre ; en vue Liste, sa fenêtre (tâche 8).
- **Accessibilité** (7.9) : `WorldAccessibility` donne à la `WorldView`, par `setAccessibilityChildren`, un `NSAccessibilityElement` par îlot (« Îlot API, 5 agents dont 1 en attente ») contenant un élément par agent (rôle bouton, libellé `AgentPresenter.accessibilityLabel`, cadre à l'écran recalculé quand la caméra ou le plan changent, au plus 5 fois par seconde ; un agent hors champ prend le cadre de sa flèche de bord ou du bord de la vue ; action « appuyer » → fenêtre de l'agent ; focus → vol) ; libellé de la vue « Open space, 20 agents. Vue Liste : ⌘L » ; rotor personnalisé « Agents en attente » (`NSAccessibilityCustomRotor`, ordre du plateau).
- **Annonces** : l'effet `.announce` du réducteur et le passage d'un agent en erreur passent par un `AnnouncementBatcher` gardé dans `AppModel` (`@ObservationIgnored`) : une annonce regroupée et priorisée toutes les 2 s au plus.

- [ ] **Step 1:** lire `WorldAreaView.swift`, `WorldCamera.swift`, `StatusBarView.swift`, `WaitingTrayView.swift`, `AppModel+Engine.swift` (effet `.announce`).
- [ ] **Step 2:** implémenter.
- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Captures.** `Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-10" navigation,overview,list,zooms` → `BILAN : écarts hors tolérance 0` (la couche HUD est masquée des captures de scène) ; ouvrir `window-navigation-loin.png` (flèches vers Nova et Sol, mini-carte avec son rectangle), `window-navigation-hall.png`, `window-overview-tout-voir.png` (contrôle de zoom), `window-list-liste.png` (outil Read). VoiceOver : checklist manuelle.
- [ ] **Step 5:** contrôle du tiret cadratin. **Commit.** `git add App && git commit -m "App step 3: minimap, edge arrows, zoom control, camera flights and scene accessibility"`

### Task 11: La scène vit : arrivée par l'ascenseur, départ, célébration, meubles qui tombent (app, vague 3)

**Files:**
- Create: `App/Sources/World/Animation/SnappedMove.swift`, `ArrivalAnimator.swift`, `FurnitureDropAnimator.swift`, `TransitionPlayer.swift`
- Modify: `App/Sources/World/WorldScene.swift`, `App/Sources/World/WorldSceneCoordinator.swift`

**Interfaces:**
- Consumes: tâche 5 (`WorldEvents.between`, `WorldEvent`, `WalkPath`), tâche 7 (`WorldScene`, `WorldStage`, `WorldInteractionState.hiddenAgents`, `SpriteRegistry`, `CharacterRef`), tâche 4 (identifiants `wall:elevator`, `post:…`, `agent:…/avatar`), `IsoMath`, `CharacterAnimation`.
- Produces (utilisé par la tâche 12) :

```swift
/// Rule 1 of 7.3: moves a node along scene points, its position recomputed and rounded to whole texels every frame.
enum SnappedMove { static func along(_ points: [CGPoint], speed: CGFloat /* texels per second */) -> SKAction
                   static func fall(from height: CGFloat, duration: TimeInterval) -> SKAction }   // ease-in
@MainActor final class TransitionPlayer {
    /// Plays a one-shot animation on the agent's avatar (celebrate, grab, wave, stretch, coffee), then gives the node
    /// back to the plan's animation.
    func play(_ animation: CharacterAnimation, agent: AgentID)
}
```

Comportement (7.4.4, 6(o)) :
- Le coordinateur calcule `WorldEvents.between(ancien, nouveau)` à chaque plan appliqué et les passe à la scène.
- **Arrivée** (`agentArrived`) : l'agent entre dans `hiddenAgents` (le plan retire son avatar, son ombre et ses overlays) ; les portes de l'ascenseur s'ouvrent (frames 0 à 5 du nœud `wall:elevator`, 12 fps), `fx.ding` ; un avatar temporaire marche (`walk`, direction de chaque pas) le long de `WalkPath.route(door → siège)` à 2,5 tuiles par seconde, positions recalées à chaque image, profondeur `IsoMath.depth(i:j:layer: .character)` ; ombre `shadow.char` à 30 % qui le suit ; au siège, `sitDown`, puis l'agent quitte `hiddenAgents` et le plan reprend la main ; les portes se referment. Sans chemin, l'agent apparaît directement.
- **Départ** (`agentLeft`) : `wave`, `sitDown` à l'envers (`standUp`), marche vers l'ascenseur, portes.
- **Célébration** (`turnCelebrated`) : `celebrate` une fois, puis l'animation du plan.
- **Au repos** (non endormi) : toutes les 45 à 90 s au hasard, `stretch` ou `coffee` une fois.
- **Îlot qui apparaît** (`islandAppeared`, `desksAppeared`) : bureau, chaise, moniteur et lampe de chaque nouveau poste tombent de 48 texels en 0,35 s (`SnappedMove.fall`), décalés de 0,08 s d'un poste à l'autre ; `fx.dust` à l'atterrissage.
- « Réduire les animations » : aucune marche, aucune chute, aucun étirement ; changements instantanés.
- Crochets du banc `arrival(agent, progress)` et `islandDrop(project, progress)` : posent la scène à cette fraction de l'animation, figée.

- [ ] **Step 1:** lire `WorldScene.swift`, `WorldSceneCoordinator.swift`, `SpriteRegistry.swift`, et les interfaces de la tâche 5.
- [ ] **Step 2:** implémenter.
- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Captures.** `Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-11" arrival,zooms` → les prises de `zooms` restent à 0 écart ; ouvrir `window-arrival-brume-0.png` à `-brume-100.png` (sortie de l'ascenseur, marche sur les couloirs, jamais à travers un bureau, assise) et `window-arrival-chute-mobile.png` (outil Read).
- [ ] **Step 5:** contrôle du tiret cadratin. **Commit.** `git add App && git commit -m "App step 3: elevator arrivals, departures, celebrations and falling furniture"`

### Task 12: Glisser un post-it sur la scène, tableau latéral et plein écran (app, vague 4)

**Files:**
- Create: `App/Sources/World/Drop/WorldDropController.swift`, `DropFeedbackView.swift`, `PostitFlight.swift`, `App/Sources/UI/Board/BoardFullScreenView.swift`
- Modify: `App/Sources/World/WorldView.swift`, `App/Sources/World/WorldScene.swift`, `App/Sources/UI/Main/RootView.swift`, `App/Sources/UI/Support/WorkbenchState.swift`, `App/Sources/UI/Board/BoardPanelView.swift`, `App/Sources/UI/Board/TaskCardView.swift`, `App/Sources/UI/Status/WaitingTrayView.swift`, `App/Sources/World/HUD/MinimapView.swift`, `App/Sources/World/HUD/EdgeArrowsView.swift`, `App/Sources/Model/AppModel+Intents.swift`

**Interfaces:**
- Consumes: tâche 6 (`DropResolver`, `DropContext`, `DropDecision`, `DropAction`, `SceneHitTester`), tâche 3 (`AutoScroll`), tâche 7 (`WorldStage`, `WorldCamera`, `WorldInteractionState.dropTarget`), tâche 9 (`AppModel.addAgent(…deskIndex:)`), tâche 10 (`WorldFlights`, `MinimapView`, `EdgeArrowsView`), tâche 11 (`SnappedMove`, `TransitionPlayer`), `CardDragPayload`, `UTType.pixelTaskCard`, `WorkbenchState.requestTask`, `AppModel.launchNewAgent(with:)`, `firstFreeAgent(for:)`.
- Produces : `WorkbenchState.draggedCard: TaskCardID?` ; `enum BoardMode: String { case side, full, hidden }` et `WorkbenchState.boardMode` (`@AppStorage("boardMode")`, repris de `boardPanelVisible` au premier lancement) ; `AppModel.launchNewAgent(with:deskIndex:)` ; crochets `dragHover` et `board` du banc.

Comportement (3.9 « Glisser-déposer » et 6(k), décisions 8 et 9) :
- **Source** : le post-it du tableau pose `workbench.draggedCard` au début du glisser (`onDrag`, même type exporté et même donnée que `CardDragPayload`, pour que les cibles existantes du tableau et des cartes d'agent continuent de fonctionner) et l'efface à la fin ; l'aperçu reste le post-it du tableau, quel que soit le zoom.
- **Cible scène** (`WorldView`) : `registerForDraggedTypes` du type `fr.vv2.pixelopenspace.task-card` ; `draggingEntered`/`draggingUpdated` → cible de `SceneHitTester` → `DropResolver.decide` → `interaction.dropTarget` (anneau `floor.dropTarget` ou îlot en surbrillance, dessinés par le plan), bulle `DropFeedbackView` près du curseur (texte de la décision), opération `.copy` ou aucune (curseur interdit) ; `draggingExited` efface ; `performDragOperation` exécute l'action : `assign` → `workbench.requestTask(.assign)` (la confirmation inter-projets C3 reste celle du tableau) ; `assignOffline` → idem, puis un toast qui propose de relancer la session ; `launchNewAgent` → `launchNewAgent(with:deskIndex:)` ; `firstFreeAgent` → l'agent de `firstFreeAgent(for:)`, sinon un nouvel agent.
- **Défilement automatique** pendant le glisser : `AutoScroll.velocity` → `camera.pan` à chaque image, `noteInteraction()`.
- **Cible hors champ au début du glisser** : survoler 0,5 s une ligne du plateau d'attente, une flèche de bord ou un point de la mini-carte fait voler la caméra vers l'agent (le glisser continue) ; lâcher dessus donne le post-it à cet agent (même décision que sur l'agent).
- **Après un dépôt réussi sur la scène** (`PostitFlight`) : un `desk.postit` de la teinte du projet vole du point de dépôt jusqu'au bureau (`SnappedMove`), l'agent joue `grab` (`TransitionPlayer`), puis `fx.pinDrop` ; rien de tout cela avec « Réduire les animations ».
- **Tableau** : ⌘B passe de latéral à plein écran, puis masqué, puis latéral (titre de la commande inchangé dans les menus, aide mise à jour) ; en plein écran, `BoardFullScreenView` remplace la scène ou la liste : barre de filtres, quatre colonnes côte à côte (6(c)), en réutilisant `BoardColumnView` ; le tableau latéral reste à droite.
- Crochets du banc : `dragHover(card, spot)` simule le survol (cible, anneau, bulle, surbrillance du plateau, de la flèche ou de la mini-carte) sans session de glisser ; `board(mode)`.

- [ ] **Step 1:** lire `TaskCardView.swift`, `BoardPanelView.swift`, `BoardColumnView.swift`, `CardDragPayload.swift`, `AgentCardView.swift` (cible existante), `RootView.swift`, `WorkbenchState.swift`, et les fichiers des tâches 7, 9, 10, 11 cités.
- [ ] **Step 2:** implémenter.
- [ ] **Step 3: Build** → `** BUILD SUCCEEDED **`.
- [ ] **Step 4: Captures.** `Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-12" dragdrop,board,zooms,list` → les prises de `zooms` restent à 0 écart ; ouvrir chaque `window-dragdrop-*.png` (anneau sous Bip et « Donner à Bip · en file #1 » ; halo et « autre projet » sur Sol ; « hors ligne » sur Kiwi ; îlot API en surbrillance et « Premier agent libre de API » ; poste libre et « Nouvel agent avec ce post-it » ; flèche, ligne du plateau et point de mini-carte en surbrillance) et `window-board-plein-ecran.png` (outil Read). Le glisser réel à la souris est dans la checklist manuelle.
- [ ] **Step 5:** contrôle du tiret cadratin. **Commit.** `git add App && git commit -m "App step 3: drag post-its onto the scene, board side panel and full screen"`

### Task 13: Guide de l'étape 3 et contrôle d'ensemble (vague 4)

**Files:**
- Create: `docs/ETAPE-3.md`
- Modify: `README.md`, `docs/ASSETS.md`
- **Aucune modification** de `App/`, `Core/`, `Tools/` ni de la CI : un défaut trouvé est noté dans le guide (« Limites connues »), pas corrigé ici.

Contenu de `docs/ETAPE-3.md` (français, ton de `docs/ETAPE-2B.md`) : ce qui est livré, tâche par tâche ; se déplacer (tableau des gestes de 3.9 et des raccourcis ⌘L, ⌘B, ⌘+ ⌘− ⌘0, flèches, ↩) ; règles de clic ; glisser un post-it sur la scène (table des cibles et de leurs messages) ; repères (mini-carte, flèches de bord, barre d'état, plateau) ; fenêtre agent ; arrivées et animations ; accessibilité (vue Liste, rotor, annonces) ; `workspace.json` version 2 et lecture seule pour une copie plus ancienne (décision 11) ; le **mode démo** pour le protocole « 3 s » et les mesures (commande exacte : le binaire de `build/DerivedData` avec `--demo`, et ce que fait chaque bouton du panneau) ; le banc de captures pour qui veut regarder les images ; la **checklist manuelle** de ce plan, à cocher ; limites connues ; ce qui reste (hors de ce plan, étapes 4 et suivantes). `README.md` : état du projet. `docs/ASSETS.md` : l'atlas et `manifest.json` (`sprite-export --atlas`), le remplacement par des PNG à l'étape 4 (décision 6), `PixelFont` utilisée aussi dans l'app.

- [ ] **Step 1: Build** sans rien modifier (commande des contraintes globales) → `** BUILD SUCCEEDED **` ; `cd Core && swift test` → vert (noter le nombre de tests).
- [ ] **Step 2: Captures complètes.** `Tools/snapshot.sh "$TMPDIR/pos-snapshots/tache-13" all` ; relever dans `report.txt` les écarts (attendu : 0) et les étapes non prises en charge (attendu : seulement celles de la tâche 12, qui se déroule en parallèle) ; relever dans `stats.json` le nombre de nœuds et de pages d'atlas de la prise `overview` (20 agents) ; ouvrir au moins une image par scénario (outil Read).
- [ ] **Step 3: Write** `docs/ETAPE-3.md`, `README.md`, `docs/ASSETS.md`.
- [ ] **Step 4:** contrôle du tiret cadratin. **Commit.** `git add docs README.md && git commit -m "Step 3 guide and final checks"`

---

## Après la fusion de la vague 4 (orchestrateur)

Construire l'app, puis `Tools/snapshot.sh "$TMPDIR/pos-snapshots/final" all` : `BILAN : écarts hors tolérance 0 · étapes non prises en charge 0` ; regarder les images de `dragdrop` et `board`, qui n'existaient pas encore quand la tâche 13 a écrit le guide, et ajuster le guide si besoin. `cd Core && swift test` vert.

## Checklist manuelle (sur ton Mac)

Ce qui demande un humain, une vraie souris ou Instruments (critère de fin de la section 8) :

- [ ] **60 fps et budgets** (spike S11) : 20 agents sur 5 ou 6 projets (de vraies sessions si possible ; sinon `--demo` avec « Animer »). Dans Instruments : 60 fps pendant un déplacement, un pincement ou un vol ; au repos, au plus 5 % de CPU et 400 Mo de mémoire résidente pour l'app (hors processus `claude`) ; 0 image par seconde fenêtre masquée ; 15 au plus app inactive.
- [ ] **Protocole « 3 s »** : `--demo`, fenêtre sur la scène au zoom par défaut ; dix fois « Nouvel essai », dire à voix haute qui attend et quoi, puis « Révéler ». Réussi si tu réponds en moins de 3 s dans 9 essais sur 10.
- [ ] **Glisser-déposer à la vraie souris** : post-it sur un agent libre du même projet (il part), occupé (file), en attente (« après ton accord »), d'un autre projet (confirmation), hors ligne (proposition de relance), sur un poste libre (nouvel agent avec le post-it en premier prompt), sur le sol d'un îlot (premier agent libre) ; **cible hors du champ au début du glisser** : par le défilement au bord, par une flèche de bord, par une ligne du plateau d'attente, par la mini-carte.
- [ ] **Aucun flou** sur ton écran Retina : chaque zoom, un déplacement lent, un pincement, un vol de caméra ; sur un écran externe non Retina, la vue d'ensemble n'est pas proposée.
- [ ] **Gestes** : deux doigts, pincement par paliers, molette, ⇧ + molette, glisser sur le sol, bouton du milieu, Espace + glisser, flèches et ⇧ + flèches, ⌘+ ⌘− ⌘0, ⌘L, ⌘B (latéral, plein écran, masqué).
- [ ] **Clics** : un clic sur un agent ouvre sa fenêtre après un court délai ; un double-clic n'ouvre que le terminal ; un poste libre propose « Nouvel agent ici ? » ; un double-clic sur un îlot le centre ; un clic droit ouvre le menu.
- [ ] **Arrivées** : un nouvel agent sort de l'ascenseur et marche jusqu'à son poste ; un nouveau projet fait tomber ses meubles dans la poussière ; une fin de tour confirmée fait célébrer l'agent.
- [ ] **VoiceOver (rapide)** : la vue Liste (⌘L) reste complète ; dans la scène, le rotor « Agents en attente » ; trois attentes simultanées donnent une seule annonce.
- [ ] **Copie de démonstration** : après le premier lancement de la nouvelle app, `build/Demo` ouvre `workspace.json` en lecture seule (attendu, décision 11).

## Hors de ce plan

- **Étape 4** : mode nuit (voile, lumières additives, étoiles, suivi de l'apparence de macOS), remplacement des sprites par des PNG (7.7), fenêtres rétro en 9-slice, sons, palette finale.
- **Étape 5** : « Refuser (Échap) » et réponses rapides de la fenêtre agent, actions de notification, palette ⌘K, restauration de la caméra et des fenêtres, visiteurs externes (contour pointillé), checklist VoiceOver et clavier des contrôles rétro, réglages « Différencier sans couleur » (glyphes XL) et « Augmenter le contraste » (contours de 2 px).
- **Étape 6** : éditeur d'apparence, mode édition du décor, « Réorganiser l'open space ».
- **Tests d'interface `xcodebuild` avec `fake-claude`** (6 sessions, permissions, tours) : demandent que `fake-claude` rejoue un écran de Claude Code ; à cette étape, le banc de captures et les tests du cœur les remplacent.
- Le tableau à gauche de la scène (6(k)) : il reste à droite (décision 8).
