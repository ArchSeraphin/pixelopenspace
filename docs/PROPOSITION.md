# Pixel Open Space : Proposition technique et design (étape 1)

> **Statut** : proposition à valider. Ce document ne contient **aucun code de l'app** : seulement des esquisses de types et de signatures pour fixer le vocabulaire.
> **Date** : 2026-09-30. **Base factuelle** : documentation officielle de Claude Code (URLs citées en ligne), code source de SwiftTerm, documentation Apple, et projets existants analysés (section 1 et 10).
> **Convention** : ⚠️ *à vérifier* signale un point non confirmé par la doc officielle ou contradictoire entre sources. Chacun est soit couvert par un « spike » de l'étape 2, soit posé comme question (section 11).
> **Révision 2** (après relecture critique et contre-vérification de la doc) : livraison gardée en deux phases, `Stop` traité comme provisoire, attentes suivies par `tool_use_id`, table du cycle de vie des post-its (4.3b), propriétaires uniques des faits (4.2), quitter/planter/relancer (2.5), limites d'usage, placement « append-only », maquettes (k)–(s), couverture de la spec (0.4).

**Sommaire** : [0. En bref (et couverture de la spec, 0.4)](#0-en-bref) · [1. Vérifications dans la doc officielle](#1-ce-que-jai-vérifié-dans-la-documentation-officielle) · [2. Architecture](#2-vue-densemble-de-larchitecture) · [3. Modules](#3-modules-en-détail) · [4. Modèle de données et machine à états](#4-modèle-de-données) · [5. Intégration Claude Code](#5-intégration-claude-code-en-pratique) · [6. Maquettes](#6-maquettes-ascii) · [7. Direction artistique et sprites](#7-direction-artistique-et-liste-des-sprites) · [8. Plan de livraison](#8-plan-de-livraison) · [9. Dépôt](#9-structure-du-dépôt) · [10. Risques](#10-risques-et-mitigations) · [11. Questions](#11-questions-ouvertes-pour-toi)

---

## 0. En bref

### 0.1 Noms proposés (originaux, sans lien avec une marque)

| Nom | Idée | Remarque |
|---|---|---|
| **Pixel Open Space** *(nom de travail, = nom du dépôt)* | Dit exactement ce que c'est | Descriptif, un peu long pour la barre de menus |
| **Plateau** | « Le plateau » = l'étage de bureaux en open space | Court, français, sonne bien en icône de barre de menus |
| **Mezzanine** | Un étage en plus qui s'agrandit au fil des projets | Évoque l'espace qui grandit |

Aucun des noms n'utilise « Claude », « Anthropic », « Code », « Hotel » ou un terme dérivé d'un jeu existant. La doc officielle interdit d'utiliser « Claude Code » ou « Anthropic » dans le nom ou le logo d'un produit tiers ; dire en texte que l'app « fait tourner Claude Code » reste permis (https://code.claude.com/docs/en/legal-and-compliance.md). Il faut vérifier la disponibilité du nom retenu avant toute diffusion. **Dans la suite, j'utilise « Pixel Open Space ».**

### 0.2 TL;DR

1. App macOS 14+ native : SwiftUI pour les panneaux, SpriteKit (dans un `SKView` enveloppé, pas `SpriteView`) pour l'open space isométrique, SwiftTerm pour de vrais terminaux PTY où tourne `claude` en mode interactif, avec ton authentification habituelle.
2. Projet = îlot coloré ; session `claude` = agent assis à un poste ; tâche = post-it sur un grand tableau de liège ; état de la session = animation de l'avatar.
3. L'état temps réel vient des **hooks officiels**, injectés **par session** au lancement (`claude --settings <fichier généré par l'app>`). **Aucun fichier de configuration Claude n'est modifié** pour les sessions lancées par l'app.
4. Chaque hook appelle un mini-binaire embarqué `pixel-hook`. Il relaie le JSON vers un **socket Unix local** (permissions 0600), sans port réseau ni trafic sortant, et sort toujours avec le code 0.
5. `waiting_input` est détecté **immédiatement** via l'événement `PermissionRequest`. Le `Notification` de type `permission_prompt` n'arrive qu'après environ 6 s. Les attentes sont suivies **une par `tool_use_id`** (outils parallèles, sous-agents) : l'agent attend tant qu'il reste au moins une attente ouverte.
6. Chaque agent a une identité stable côté app (`AgentID` + variable `PIXEL_AGENT_ID` dans l'environnement du PTY), qui survit aux changements de `session_id` (`/clear`, `/resume`). Un événement n'est attribué à un agent que s'il vient **de son processus** (`claude_pid`).
7. Un post-it s'envoie par une **livraison gardée en deux phases** : l'app vérifie l'état, l'absence de tout nouvel événement et l'écran (zone de saisie visible, aucun dialogue) **avant** d'écrire le texte, puis **à nouveau avant** l'Entrée, écrite séparément ; au moindre doute, elle abandonne. La réception est vérifiée par `UserPromptSubmit`. Si l'agent est occupé, le post-it attend dans une file gérée par l'app ; il ne part jamais pendant une attente.
8. Un `Stop` n'est qu'une fin de tour **provisoire** : un autre hook `Stop` (dont `/goal`) peut relancer le tour. Il n'est confirmé qu'après une fenêtre de calme ; s'il signale des tâches de fond ou des crons, l'agent passe en « attend une tâche de fond » et rien n'est envoyé automatiquement.
9. **Durée de vie** : les sessions `claude` vivent aussi longtemps que l'app. Fermer la fenêtre ne quitte pas ; quitter demande confirmation si des agents travaillent ou attendent. Après un crash, les processus orphelins sont détectés et une session encore détenue par un processus vivant n'est jamais reprise.
10. Le cœur (modèle, machines à états, file, layout iso, générateur de sprites, compositeur de scène, persistance JSON) vit dans un package Swift `PixelCore`, testé sous Linux **et** macOS. L'app est générée par XcodeGen, et une CI macOS la compile et la teste.

### 0.3 Décisions à valider avant de coder

Coche ou corrige chaque ligne ; ma recommandation est en gras.

1. **Nom** : garder « Pixel Open Space » comme nom de travail, trancher plus tard ? → **Oui.**
2. **Distribution** : app **non sandboxée**, hors Mac App Store. Un processus enfant hérite du sandbox, ce qui empêcherait `claude` de fonctionner normalement (https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app). → **Oui, non sandboxée, signée avec ton identité « Apple Development » (gratuite) ; notarisation seulement si tu la partages.**
3. **Toolchain** : SwiftTerm « 2.0 » (branche `main`) exige swift-tools 6.2, donc **Xcode 26 ou plus récent** sur ton Mac. La cible de déploiement reste macOS 14. → **Oui : Xcode 26 est un prérequis ferme.** Les chemins critiques (lecture de l'écran, drapeau de collage entre crochets, fin d'écriture) reposent sur l'API 2.0 ; un repli sur `v1.20.0` n'est **pas** étudié (⚠️ API équivalentes non vérifiées) et demanderait une nouvelle revue (question 11.1).
4. **SwiftTerm** : épingler la révision `main` `a2706d2` (API 2.0 : parsing hors thread principal, `pasteText`, `terminalStateSnapshot`, exit codes normalisés) plutôt que le tag `v1.20.0`. Tous les appels passent par un adaptateur `TerminalHost`, pour absorber les changements d'API. → **`main` épinglée.**
5. **Hooks** : injection **par session** via `--settings` (fichier 0600 généré dans Application Support). L'installation globale (`~/.claude/settings.json`), avec consentement, sauvegarde et désinstallation, ne sert **que** pour voir les sessions lancées hors de l'app, et arrive à l'étape 5. → **Oui.**
6. **Transport des hooks** : hook de type `command` → `pixel-hook` → socket Unix, plutôt que des hooks `http` vers un serveur local (justification en 5.3). → **Oui.**
7. **Persistance** : fichiers JSON `Codable` versionnés dans `~/Library/Application Support/PixelOpenSpace/`, pas SwiftData (justification en 3.14). → **Oui.**
8. **Rendu** : `SKView` sous-classé dans un `NSViewRepresentable`, au lieu de `SpriteView`. `SpriteView` n'expose pas le `SKView` : pas de destination de glisser-déposer, pas de contrôle de la molette ni du pincement. → **Oui.**
9. **Cycle de vie des tâches** : file par agent côté app ; **1 post-it par tour** ; enchaînement automatique après un `Stop` **confirmé** (réglable) ; livraison seulement si toutes les gardes passent (5.6) ; jamais d'envoi pendant `waiting_input`, une tâche de fond ou une pause de quota ; passage « À valider » → « Fait » uniquement sur ton clic ; transitions complètes en 4.3b. → **Oui.**
10. **Mode par défaut des nouveaux agents** : `--permission-mode default`. `bypassPermissions` n'est proposé que par agent, avec un avertissement rouge. L'app **n'approuve jamais rien automatiquement**. → **Oui.**
11. **Vue agents officielle** : mettre `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` dans l'environnement des sessions intégrées, pour qu'un `←` sur un prompt vide ne déplace pas la session hors de notre PTY (https://code.claude.com/docs/en/agent-view.md, https://code.claude.com/docs/en/env-vars.md). Un réglage permet de le désactiver. → **Oui par défaut.**
12. **Deux agents sur le même dépôt** : proposer l'option `--worktree <nom>` par agent (https://code.claude.com/docs/en/worktrees.md). → **Option par agent, désactivée par défaut au MVP.**
13. **Langue** : UI en français, chaînes externalisées dans un String Catalog ; code et identifiants en anglais. → **Oui.**
14. **Gamification et sons** : gamification active mais discrète ; sons 8 bits actifs à volume bas **uniquement** pour « attend ta réponse » et « tour terminé », les autres désactivés par défaut. Tout se désactive dans les réglages. → **Oui.**
15. **Trafic** : l'app n'envoie rien hors de ta machine (ni télémétrie, ni vérification de mise à jour). La variable `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` (qui coupe aussi certaines fonctions de Claude Code) n'est **pas** forcée : c'est une option (https://code.claude.com/docs/en/env-vars.md). → **Option désactivée par défaut.**
16. **Polices** : Silkscreen (HUD et étiquettes, grille stricte de 8 px) + Pixelify Sans (titres), toutes deux sous licence OFL 1.1, livrées avec leur `OFL.txt`. → **Oui.**
17. **Identifiant de bundle** : reverse-DNS d'un domaine à toi (ex. `tld.tondomaine.pixelopenspace`). → **À me donner.**
18. **Notifications au premier plan** : quand un agent se met à attendre, une notification macOS part **toujours**, même app au premier plan (bannière + son bas, anti-rebond 1 s) ; « tour terminé » seulement en arrière-plan. Un réglage masque les détails (commande, chemin) sur l'écran verrouillé. C'est l'interprétation retenue pour le critère d'acceptation 3. → **Oui** (sinon : « ! » + son suffisent au premier plan ?).
19. **Durée de vie des sessions** : les processus `claude` vivent aussi longtemps que l'app (pas de propriétaire de PTY détaché au MVP). Un helper de connexion ou `dtach` garderait les sessions à travers un redémarrage de l'app, au prix d'un second processus à signer, d'une IPC PTY et de plus de cas d'orphelins : étudié plus tard seulement. → **Oui.**
20. **Version minimale de Claude Code** : **v2.1.234**, vérifiée par `claude --version` au lancement (`prompt_id` et `last_assistant_message` : v2.1.196 ; types `quota_auto_resume_*` : v2.1.234, https://code.claude.com/docs/en/hooks.md). En dessous : avertissement, et les fonctions concernées se désactivent. → **Oui.**

### 0.4 Couverture de ta spec

Liste reconstruite à partir des exigences de ta spec telles que je les ai comprises (question 11.16). Statut : **✔** couvert · **≈** adapté, avec la raison · **→** reporté.

| Exigence | Où | Étape | Vérification | Statut |
|---|---|---|---|---|
| App macOS native : SwiftUI, SpriteKit, vrais terminaux | 0.2, 3.1, 3.9 | 2a, 3 | CI macOS + checklist | ✔ |
| Projet = îlot coloré ; session = agent à un poste | 3.8, 7 | 3 | jalon visuel | ✔ |
| États temps réel par les hooks officiels, en moins de 1 s | 1, 4.3, 5.2 | 2a | critère 2 (p95 < 150 ms) | ✔ |
| `waiting_input` immédiat, avec notification | 4.3 (T8), 3.12 | 2a | critère 3 | ✔ (interprétation : décision 18) |
| Voir qui attend quoi en moins de 3 s | 3.9 (plateau, flèches, plaques), 6(a) | 3 | protocole « 3 s » | ✔ |
| Lisible avec 10 à 20 agents sur 5 projets ou plus | 3.8 (emprise), 6(q) | 3 | scénario 20 agents / 6 projets | ✔ |
| Tableau de post-its à 4 colonnes, cycle automatique | 3.5, 4.3b | 2b | critère 4 + tests de propriétés | ✔ |
| Glisser un post-it sur un agent | 3.9 (cibles), 6(k) | 2b (liste), 3 (scène) | test cible hors champ | ✔ |
| File si occupé, envoi automatique sur `Stop` | 3.6, 5.6, 4.3 | 2b | critère 4 + S3b | ≈ file côté app, `Stop` confirmé, livraison gardée |
| Modèles de prompt par post-it | 3.5, 6(l) | 2b | tests `PromptComposer` | ✔ |
| Afficher la question de Claude, réponses rapides | 5.8, 6(e), 6(e′) | 2a (texte), 5 (boutons) | S7 | ≈ boutons seulement si le dialogue est reconnu |
| Interrompre un agent | 5.8, 4.3 (T22) | 2a | manuel | ✔ |
| Reprendre les sessions après relance | 2.5, 6(p) | 2b | critère 5 | ✔ |
| Sessions lancées hors de l'app | 5.7, 5.9 | 5 | manuel | ✔ (optionnel, avec consentement) |
| Source unique de vérité | 2.1, 4.2 | 2a | tests de propriétés | ✔ |
| Iso 2:1, pixel parfait, lumière en haut à gauche, contours teintés, palette centrale | 7.1 à 7.5 | jalon visuel, 4 | tests palette, luminance, captures | ✔ |
| Mode nuit avec lampes allumées | 7.8 | 4 | captures jour/nuit | ✔ |
| Plantes et machine à café dans le décor de base | 7.4.9 | 3 | jalon visuel | ✔ |
| Mini-carte | 3.9, 6(a), 7.4.10 | 3 | - | ✔ (points avec glyphes) |
| Mini-avatar de l'agent sur le post-it | 7.4.10 (`portrait.mini`) | 4 | - | ✔ |
| Déplacement à la souris, zoom, double-clic sur un îlot pour centrer | 3.9 | 3 | tests UI | ✔ |
| Raccourci ou menu pour chaque action | 3.16 | 5 | test `AppCommand` | ✔ |
| Accessibilité, jamais la couleur seule | 7.9 | 3 à 5 | checklists | ✔ |
| Consomme peu au repos | 3.9 (budgets) | 3 | S11 + Instruments | ✔ chiffré |
| Gamification discrète : XP, badges, décor à débloquer | 3.11, 7.4.9, 6(s) | 6 | tests `ProgressRules` | ✔ |
| Sons 8 bits | 3.17, 7.11 | 4 | manuel | ✔ |
| Modules nommés (`AssetFactory`, `GameProgress`…) | 2.1 (correspondance) | - | - | ≈ répartis entre plusieurs types |
| Vérifier chaque point dans la doc officielle | 1 | 1 | - | ✔ |
| Originalité, aucune ressemblance avec un jeu existant | 7.10 | 3, 4 | revue visuelle | ✔ |
| Import GitHub, statistiques | 8 (étape 7) | 7 | - | → bonus |

---

## 1. Ce que j'ai vérifié dans la documentation officielle

Légende du verdict : **✔ confirmé** · **≠ différent de ta spec** · **? non documenté** (⚠️ à vérifier).

| # | Point (hypothèse de ta spec) | Verdict | Source | Conséquence pour l'app |
|---|---|---|---|---|
| 1 | Événements « session start, prompt soumis, pre/post tool use, notification, fin de tour, fin de session » | ✔ (noms exacts : `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, `StopFailure`, `SessionEnd`) | https://code.claude.com/docs/en/hooks.md | Mapping direct vers la machine à états (4.3) |
| 2 | Une notification « waiting for user » signale l'attente | **≠** Il existe un événement dédié, `PermissionRequest`, au moment exact où une permission est demandée. `Notification` porte un `notification_type` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`, `agent_needs_input`…) ; `permission_prompt` ne part qu'**après ~6 s** d'attente et `idle_prompt` **~60 s** après la fin d'une réponse | https://code.claude.com/docs/en/hooks.md | `waiting_input` est piloté par `PermissionRequest` (immédiat) ; `Notification` sert de rattrapage |
| 3 | `PermissionRequest` couvre toutes les attentes | **≠** Il ne se déclenche pas pour les demandes réseau du sandbox. Les questions de Claude passent par l'outil documenté `AskUserQuestion` (`tool_input.questions` : 1 à 4 questions, `header`, `options`, `multiSelect`) et les dialogues MCP par `Elicitation` (`mcp_server_name`, `message`, `requested_schema`). `PermissionDenied` ne concerne **que** les refus du mode auto, pas un refus manuel | https://code.claude.com/docs/en/hooks.md | Règles supplémentaires : `PreToolUse(AskUserQuestion)` et `Elicitation` → `waiting_input`, avec la question décodée (5.8) ; un refus manuel se détecte par `PostToolBatch` ou l'écran (4.3, T12b et T28) |
| 4 | Chaque événement porte le `session_id` | ✔ Champs communs : `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `prompt_id` (UUID du prompt en cours, **absent avant la première saisie**, v2.1.196+), plus `agent_id`/`agent_type` quand l'événement vient d'un sous-agent | https://code.claude.com/docs/en/hooks.md | Corrélation par `PIXEL_AGENT_ID` + `claude_pid` d'abord, `session_id` ensuite ; `prompt_id` relie un `Stop` à la carte livrée |
| 5 | Les hooks se configurent dans les settings utilisateur ou projet | ✔ Emplacements : `~/.claude/settings.json`, `.claude/settings.json`, `.claude/settings.local.json`, `--settings`, plugins. **Les hooks de tous les niveaux se cumulent** | https://code.claude.com/docs/en/settings.md | L'app peut **ajouter** ses hooks sans toucher aux tiens |
| 6 | Il faut écrire dans un fichier de settings | **≠** `claude --settings <fichier\|json>` vaut « pour cette session uniquement, n'écrit dans aucun fichier », et se place au-dessus des fichiers utilisateur, projet et local. La doc dit que ce JSON est fusionné « selon les mêmes règles » que les autres niveaux ; aucune source ne le teste explicitement pour les hooks (⚠️ spike S1) | https://code.claude.com/docs/en/settings.md, https://code.claude.com/docs/en/cli-reference.md | Voie principale : zéro modification de tes fichiers. Repli : `--plugin-dir` (hooks d'un plugin chargés à côté des settings) |
| 7 | Transport « HTTP local ou socket Unix » | ✔ en partie : il existe des hooks `type: "http"` (POST JSON) et `type: "command"` (JSON sur stdin). Pas de socket Unix natif, il faut une commande relais. **`SessionStart` n'accepte que `command` et `mcp_tool`**, pas `http`. `async` n'existe que pour les hooks `command`. Tous les hooks correspondants tournent **en parallèle** ; un handler identique défini dans plusieurs fichiers ne tourne qu'une fois | https://code.claude.com/docs/en/hooks.md | Choix : hook `command` + `pixel-hook` + socket Unix (5.3) ; dédoublonnage côté app (5.7) |
| 8 | Les hooks voient les variables d'environnement de la session | ✔ « A hook process inherits the parent environment » (sauf `OTEL_*` et les variables retirées par `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`). `CLAUDE_PROJECT_DIR` et `CLAUDE_CODE_SESSION_ID` sont fournis | https://code.claude.com/docs/en/hooks.md, https://code.claude.com/docs/en/env-vars.md | `PIXEL_AGENT_ID` et `PIXEL_HOOK_TOKEN` injectés dans l'env du PTY arrivent au helper |
| 9 | Un hook en échec ne bloque pas Claude | ✔ Exit 0 = succès ; **exit 2 = blocage** ; tout autre code, un timeout ou une commande introuvable = erreur non bloquante. **Attention** : sur exit 0, le stdout est injecté dans le contexte de Claude pour les événements qui le permettent (par ex. `SessionStart`) | https://code.claude.com/docs/en/hooks.md | `pixel-hook` : **jamais de stdout**, jamais d'exit 2, toujours exit 0 |
| 10 | Changer les hooks demande un redémarrage | **≠** Les fichiers de settings sont surveillés et rechargés à chaud, hooks compris, sans demande d'approbation | https://code.claude.com/docs/en/settings.md | L'installation globale (étape 5) prend effet en quelques secondes dans les sessions ouvertes : le dialogue de consentement doit le dire |
| 11 | Hooks d'un dossier projet | ✔ Les hooks de `.claude/settings.json` (partagé) ne tournent qu'une fois le dossier approuvé (« trust »). `.claude/settings.local.json` tourne tout de suite | https://code.claude.com/docs/en/settings.md | L'installation « projet » vise uniquement `settings.local.json`, jamais le fichier partagé. Au premier lancement dans un dossier, Claude peut attendre une confirmation de confiance dans le terminal |
| 12 | Options `--resume <id>`, `--continue`, modèle, mode de permission | ✔ `--resume/-r <id\|nom>`, `--continue/-c`, `--model <alias\|id>`, `--permission-mode default\|acceptEdits\|plan\|auto\|dontAsk\|bypassPermissions`, `--name/-n`, `--fork-session`, `--worktree/-w`, `--settings`, `--plugin-dir` | https://code.claude.com/docs/en/cli-reference.md | Lignes de commande exactes en 5.1 |
| 13 | `--session-id <uuid>` pour une nouvelle session | ✔ « Use a specific session ID for the conversation (must be a valid UUID) ». `-v`/`--version` existe aussi | https://code.claude.com/docs/en/cli-reference.md | Utilisé, mais **l'app n'en dépend pas** : le vrai `session_id` est appris par `SessionStart` (contrôle rapide S2) |
| 14 | Le `session_id` est stable | **?** Non documenté. `SessionStart.source` vaut `startup\|resume\|clear\|compact\|fork` et `SessionEnd.reason` vaut `clear\|resume\|logout\|prompt_input_exit\|other`. Des projets tiers observent qu'un `/clear` produit `SessionEnd(clear)` puis `SessionStart(clear)` **avec un nouvel id** | https://code.claude.com/docs/en/hooks.md | `AgentID` stable côté app + historique des `session_id` par agent (4.1) |
| 15 | L'historique se lit dans `~/.claude/projects/` | ✔ mais **le format est interne** : `~/.claude/projects/<cwd encodé>/<session-id>.jsonl` ; « internal to Claude Code and changes between versions ». Nom de dossier = chemin dont les caractères non alphanumériques deviennent `-` (au-delà de 200 caractères : tronqué + hash). Rétention par défaut : 30 jours (`cleanupPeriodDays`) | https://code.claude.com/docs/en/sessions.md | Lecture seule et tolérante, `cwd` lu dans les enregistrements (jamais décodé depuis le nom de dossier). Fonction « bonus », jamais critique |
| 16 | Envoyer une tâche = écrire le texte + CR | ✔ Entrée soumet ; Ctrl+J ou `\`+Entrée insère un saut de ligne. Un collage de plus de 800 caractères ou de plus de 3 lignes se replie en `[Pasted text #N]` et Claude est prévenu qu'un collage peut contenir des instructions que tu n'as pas écrites | https://code.claude.com/docs/en/terminal-config.md, https://code.claude.com/docs/en/interactive-mode.md | Texte court : saisi. Texte long : une phrase d'amorce **saisie** + corps **collé**. Entrée toujours dans une écriture séparée (5.6) |
| 17 | « Mettre en file si occupé » | **≠** Claude Code a déjà sa propre file : un message tapé pendant que Claude travaille lui est transmis **dans le même tour**, dès la fin des appels d'outils | https://code.claude.com/docs/en/interactive-mode.md | La file des post-its est **côté app** : on n'écrit jamais dans un PTY occupé |
| 18 | « Auto-send on Stop » | **≠** `Stop` ne se déclenche **pas** après une interruption ; une erreur d'API déclenche `StopFailure` (`error_type`). Surtout, **`Stop` ne signifie pas toujours « fini »** : un autre hook `Stop` peut bloquer l'arrêt (`decision: "block"`, c'est ce que fait `/goal`), et l'entrée de `Stop` porte `stop_hook_active`, `last_assistant_message`, `background_tasks` et `session_crons` pour distinguer « fini » de « en pause, sera réveillée » | https://code.claude.com/docs/en/hooks.md, https://code.claude.com/docs/en/goal.md | `Stop` = fin **provisoire**, confirmée après une fenêtre de calme ; tâches de fond ou crons → état `waitingBackground`, sans envoi automatique (4.3) |
| 19 | Interrompre = Échap | ✔ avec nuances : Échap arrête la réponse en cours et garde le travail fait, **mais envoie aussitôt les messages en file** ; si un élément du pied de page est sélectionné, il le désélectionne au lieu d'interrompre ; sur un dialogue, Échap = Non ; pendant l'attente d'une limite d'usage, Échap sur un prompt vide **annule la reprise automatique**. Ctrl+C interrompt, ou vide la saisie puis quitte au 2e appui ; **Ctrl+D** deux fois en moins de 800 ms quitte | https://code.claude.com/docs/en/interactive-mode.md | Bouton « Interrompre » = un seul octet `ESC`, dont l'effet est **vérifié** (5.8) ; jamais pendant une attente ni une pause de quota ; l'app n'envoie jamais Ctrl+C ni Ctrl+D |
| 20 | Répondre aux permissions depuis l'app | ? Le dialogue affiche des options numérotées ou Oui/Non, navigables aux flèches, validées par Entrée ; Échap = Non. Le rendu exact n'est pas spécifié. Voie officielle alternative : un hook `PermissionRequest` peut renvoyer `decision.behavior: allow\|deny` | https://code.claude.com/docs/en/interactive-mode.md, https://code.claude.com/docs/en/hooks.md | Réponses rapides limitées et prudentes au MVP (5.8) ; mode « décision par hook » en option à l'étape 7 |
| 21 | Il n'existe pas d'outil officiel multi-sessions | **≠** La « vue agents » (`claude agents`, research preview) affiche l'état des sessions ; `claude agents --json` en est la lecture supportée. Mais « Interactive sessions you have open in other terminals don't appear until you background them », et `CLAUDE_CODE_DISABLE_AGENT_VIEW` coupe la vue agents et les agents d'arrière-plan | https://code.claude.com/docs/en/agent-view.md | Complémentaire (voir ci-dessous) ; **pas** une source d'état pour les sessions de l'app, qui sont interactives et ont la vue agents désactivée (4.4) |
| 22 | Canaux pour injecter des messages | ✔ existe, mais en research preview : serveur MCP `claude/channel` ; un serveur maison exige `--dangerously-load-development-channels` ; une organisation Team ou Enterprise peut les bloquer | https://code.claude.com/docs/en/channels.md | Amélioration possible plus tard (étape 7), pas au MVP |
| 23 | Claude Code notifie le terminal | ≠ `preferredNotifChannel: "auto"` n'envoie de notification qu'à iTerm2, Ghostty et Kitty, **rien ailleurs** ; `terminal_bell` envoie `BEL` | https://code.claude.com/docs/en/settings-reference.md | Les notifications macOS viennent de nos hooks. `BEL` reste un signal de secours |
| 24 | L'app GUI trouve `claude` | ≠ Installation native dans `~/.local/bin/claude` (lien symbolique vers `~/.local/share/claude/versions/`), cask Homebrew `claude-code`, ou npm. Une app lancée depuis le Finder n'hérite pas du `PATH` du shell | https://code.claude.com/docs/en/setup.md | `ClaudeLocator` + résolution de l'environnement via le shell de connexion (3.1) |
| 25 | Variables d'environnement à nettoyer | ✔ `CLAUDECODE=1` est posé dans les processus lancés par Claude Code | https://code.claude.com/docs/en/env-vars.md | Retirée de l'env du PTY (utile si l'app a elle-même été lancée depuis une session Claude) |
| 26 | Terminal plein écran | ✔ Le mode fullscreen de Claude Code utilise l'écran alternatif (pas d'historique de défilement côté terminal). Les variables `CLAUDE_CODE_NO_FLICKER` et `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN` choisissent le rendu | https://code.claude.com/docs/en/fullscreen.md | On respecte ton réglage ; option pour forcer le mode classique (question 11.11) |
| 27 | Premier prompt au lancement | ✔ `claude "query"` démarre une session interactive avec un prompt initial | https://code.claude.com/docs/en/cli-reference.md | Le 1er post-it d'un agent neuf passe en argument, ce qui supprime la course « TUI pas encore prête » |
| 28 | Politiques gérées | ✔ `disableAllHooks`, `allowManagedHooksOnly`, `allowedHttpHookUrls` peuvent bloquer nos hooks | https://code.claude.com/docs/en/hooks.md, https://code.claude.com/docs/en/settings.md | Si aucun `SessionStart` n'arrive dans les 15 s → **mode dégradé** annoncé (4.4) |
| 29 | Le transcript reflète l'instant présent | ≠ `transcript_path` « is written asynchronously and may lag » | https://code.claude.com/docs/en/hooks.md | L'état ne se lit jamais dans le JSONL, seulement dans les hooks |
| 30 | Événements de sous-agents | ✔ Les sous-agents déclenchent les mêmes `PreToolUse` et `PostToolUse`, avec `agent_id`/`agent_type` ; `SubagentStart` et `SubagentStop` existent | https://code.claude.com/docs/en/hooks.md | Ces événements ne changent pas l'état principal ; mini-avatar « sous-agent » |
| 31 | Hooks qui « travaillent » | ✔ `WorktreeCreate` et `WorktreeRemove` **remplacent** le comportement git par défaut | https://code.claude.com/docs/en/hooks.md | L'app ne s'y abonne **jamais** (sinon `claude -w` casse) |
| 32 | Ordre des événements | **≠** « `PostToolUse` fires once per tool, which means it fires concurrently when Claude makes parallel tool calls » ; `PostToolBatch` part une fois le lot entier résolu. `PermissionRequest` porte `tool_use_id` (et `agent_id` dans un sous-agent) | https://code.claude.com/docs/en/hooks.md | Aucun ordre global supposé : attentes et outils suivis par `tool_use_id` (4.1, 4.3) |
| 33 | Limites d'usage | ✔ `StopFailure.error_type` : `rate_limit`, `overloaded`, `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `billing_error`, `server_error`, `unknown`… ; `Notification` `quota_auto_resume_fired` / `_stale` / `_disabled` (v2.1.234+). Avec un abonnement claude.ai, Claude Code **attend la réinitialisation et reprend seul** la tâche (`autoContinueAtUsageLimit`) | https://code.claude.com/docs/en/hooks.md, https://code.claude.com/docs/en/interactive-mode.md | État `quotaPaused` distinct de l'erreur, bannière globale, aucune livraison ni `ESC` pendant l'attente (4.3, 5.6) |
| 34 | Inventaire des événements | ✔ La doc liste aussi `Setup`, `UserPromptExpansion`, `PostToolBatch`, `MessageDisplay`, `TaskCreated`, `TaskCompleted`, `TeammateIdle`, `InstructionsLoaded`, `ConfigChange`, `CwdChanged`, `DirectoryAdded`, `FileChanged`, `PreModelSwitch`, `PostModelSwitch`. `SessionEnd` : budget partagé de 1,5 s | https://code.claude.com/docs/en/hooks.md | Abonnés en plus : `PostToolBatch` (lève les attentes d'un lot) et `CwdChanged` (dossier de reprise). `UserPromptExpansion` ignoré : nos envois ne commencent jamais par `/` (5.6) |

**Écarts entre les sources de recherche**, tranchés ici et à confirmer par les spikes de l'étape 2 :
- **Réponse de `Stop`** : le champ documenté est `last_assistant_message` (v2.1.196+). Par tolérance, le décodeur accepte aussi l'ancien `assistant_message` vu dans une source tierce.
- **`PostToolUseFailure`** : une source propose d'en faire l'état `error`. Je m'en écarte : un outil qui échoue (tests rouges, `grep` vide) est normal. Il produit seulement une petite bouffée de fumée, sans changer d'état.
- **Suggestions de recherche écartées**, avec leur raison :
  - rediriger `CLAUDE_CONFIG_DIR` par îlot : on perdrait ton authentification, tes settings et ton historique ;
  - détourner la `statusLine` comme battement de cœur : c'est un réglage unique, on écraserait le tien ;
  - interroger `claude agents --json`, même en mode dégradé : il ne liste pas les sessions interactives ouvertes ailleurs, et nos sessions ont la vue agents désactivée (décision 11).

**Où se place l'app face à la vue agents officielle.** `claude agents` est une TUI, pensée d'abord pour les sessions en arrière-plan, qui résume chaque ligne avec un modèle de classe Haiku (https://code.claude.com/docs/en/agent-view.md). Pixel Open Space apporte trois choses de plus : une carte **visuelle et spatiale** par projet, **les terminaux intégrés** eux-mêmes (on tape dedans) et **un tableau de tâches** qui pilote les agents. Les deux se complètent : l'app ne lit pas la vue agents, et tu peux continuer à l'utiliser dans ton terminal habituel pour tes sessions d'arrière-plan.

---

## 2. Vue d'ensemble de l'architecture

### 2.1 Couches et modules

```text
┌────────────────────────────── PixelOpenSpace.app (macOS 14+, non sandboxée) ────────────────────────────────────┐
│                                                                                                                 │
│   SwiftUI : StatusBar · Sidebar · BoardView · AgentWindow · TerminalPanel · Settings · Palette ⌘K · MenuBar     │
│        │ observe                             ▲ intents (CommandCenter)             │ observe                    │
│        ▼                                     │                                     ▼                            │
│   ┌────────── AppModel  (@Observable @MainActor) ────────────────────────────────────────────┐                  │
│   │ WorkspaceStore · TaskStore (← TaskLifecycle.reduce) · ProgressStore · SettingsStore      │                  │
│   │ runtime: [AgentID: AgentRuntime]  ← modifié UNIQUEMENT via AgentStateMachine.reduce      │                  │
│   └─────▲─────────────────────▲──────────────────▲─────────────────────▲─────────────────────┘                  │
│         │ AgentInput          │ AgentInput       │ effets              │ snapshot                               │
│   ┌─────┴────────────┐  ┌─────┴─────────┐  ┌─────┴────────────┐  ┌─────┴─────────────────┐                      │
│   │ SessionManager   │  │ HookServer    │  │ TaskDispatcher   │  │ WorldSceneCoordinator │── SKView (WorldView) │
│   │ TerminalHost×N   │  │ (actor,       │  │ (file par agent, │  │ → WorldScene (nœuds   │   + SpriteRegistry   │
│   │ (SwiftTerm, PTY) │  │  socket Unix) │  │  livraison)      │  │   indexés par ID)     │                      │
│   └─────┬────────────┘  └─────▲─────────┘  └──────────────────┘  └───────────────────────┘                      │
│         │ PTY                 │ JSON (une connexion par événement)                                              │
│   PersistenceStore (actor) · SessionDiscovery (actor) · HooksInstaller · NotificationBridge · SoundPlayer       │
└─────────┼─────────────────────▲─────────────────────────────────────────────────────────────────────────────────┘
          ▼                     │
   `claude` (TUI) ──hooks─────► `pixel-hook` (binaire embarqué, toujours exit 0, sans stdout) ──► hook.sock (0600)

┌──────────────────── Package SwiftPM (compile et se teste sous Linux ET macOS) ─────────────────────────┐
│ PixelCore  : Model · HookEvent/HookDecoder · AgentStateMachine · AgentPresenter · TaskLifecycle        │
│              TaskQueue/DispatchPolicy · PromptComposer/PromptSanitizer/DeliveryPlan · LaunchPlanner    │
│              HookSettingsBuilder · SettingsPatcher · TranscriptScanner · ScreenPatterns · IsoMath      │
│              WorldLayout · SceneCompositor · Palette · PixelImage/PixelMap · SpriteCatalog             │
│              AtlasPacker · SpriteManifest · PNGEncoder · ProgressRules · Codecs/Migrator               │
│ PixelIPC   : UnixSocketServer / UnixSocketClient / LineFramer (Darwin + Glibc)                         │
│ pixel-hook : exécutable (stdin → socket)         sprite-export : exécutable (atlas PNG + manifeste)    │
│ fake-claude: rejoue des fixtures JSONL de hooks via pixel-hook (sans TUI) : CI sans compte             │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Règle d'or** : le modèle est la **seule source de vérité**. La scène SpriteKit et les vues SwiftUI ne font qu'observer. Une transition d'état ne passe que par une fonction pure (`AgentStateMachine.reduce`, `TaskLifecycle.reduce`), qui renvoie un nouvel état et une liste d'**effets** (notifier, jouer un son, déplacer un post-it, envoyer le suivant…). La couche app exécute ensuite ces effets. Chaque fait a **un seul propriétaire** (table en 4.2) : les deux réducteurs ne se modifient jamais l'un l'autre, ils se parlent par effets (`cardEvent`, `pumpQueue`). Toute la logique métier se teste ainsi sans Xcode.

**Correspondance avec les modules nommés dans ta spec** :

| Module de la spec | Types de la proposition | Fichiers |
|---|---|---|
| `SessionManager` | `SessionManager`, `TerminalHost`, `TerminalPresenter`, `ClaudeLocator`, `LaunchPlanner` | `App/Sessions/`, `PixelCore/Launch/` |
| `HookServer` | `HookServer`, `pixel-hook`, `HookDecoder`, `UnixSocketServer` | `App/Hooks/`, `PixelCore/Hooks/`, `PixelIPC/` |
| `AgentStateMachine` | `AgentStateMachine`, `AgentRuntime`, `AgentPresenter`, `ScreenPatterns` | `PixelCore/State/` |
| `TaskStore` / cycle des post-its | `TaskStore`, `TaskLifecycle`, `TaskDispatcher`, `DispatchPolicy`, `DeliveryPlan` | `App/Model/`, `App/Tasks/`, `PixelCore/Tasks/` |
| `AssetFactory` | `SpriteCatalog` + `PixelImage`/`Draw` (génération), `AtlasPacker` (atlas), `SpriteRegistry` (textures) | `PixelCore/Assets/`, `App/World/` |
| `GameProgress` | `ProgressState`, `ProgressRules` (Core) + `ProgressStore` (App) | `PixelCore/Game/`, `App/Model/` |
| Monde isométrique | `WorldLayout`, `IsoMath`, `SceneCompositor` (Core) ; `WorldScene`, `WorldView`, `WorldSceneCoordinator` (App) | `PixelCore/World/`, `App/World/` |
| Persistance | `PersistenceStore`, `Codecs`, `Migrator`, `WorkspaceValidator` | `App/System/`, `PixelCore/Persistence/` |

### 2.2 Flux : lancer une session

```
Utilisateur : clic sur un poste vide / « + Agent » / ⌘K « Nouvel agent »
 1. CommandCenter.newAgent(project) → WorkspaceStore crée Agent(id: AgentID(), deskIndex: premier libre)
 2. LaunchPlanner.plan(request) [PixelCore, pur] → LaunchPlan{executable, args, env, cwd}
      - executable = chemin absolu de `claude` (ClaudeLocator)
      - args = ["--settings", hooksSettingsPath, "--session-id", uuid?, "--name", "api-nova",
                "--model", …, "--permission-mode", …, (premier post-it en argument positionnel)]
      - env  = env résolu du shell de connexion − {CLAUDECODE, TERM_PROGRAM*, …}
               + {PIXEL_AGENT_ID, PIXEL_HOOK_TOKEN, PIXEL_HOOK_SOCKET, TERM, COLORTERM, LANG}
 3. SessionManager crée TerminalHost(agentID) → LocalProcessTerminalView(frame: .zero, 120×36)
    → startProcess(executable:args:environment:execName:"claude", currentDirectory: projet)
 4. reduce(.processStarted(pid, startTime)) → phase .launching ; effet recordProcess (pid + heure de départ
    persistés, pour détecter les orphelins) ; l'avatar sort de l'ascenseur, écran en `screen.boot` (étape 3+)
 5. `claude` démarre → hook SessionStart → pixel-hook → socket → HookServer → reduce(.hook(SessionStart))
    (accepté seulement si claude_pid == pid du PTY) → phase .idle (ou .thinking si un prompt initial a été
    passé) ; SessionRef (id, source, cwd) ajouté à l'historique
 6. Pas de SessionStart après 15 s → runtime.hookHealth = .degraded → bandeau « mode dégradé » (4.4)
```

### 2.3 Flux : recevoir un événement de hook

```
claude ──(stdin JSON)──► pixel-hook
   pixel-hook : lit stdin jusqu'à EOF (au-delà de 4 Mo : lu et jeté), tronque les gros champs, enveloppe :
     {"v":1,"agent":"$PIXEL_AGENT_ID","token":"$PIXEL_HOOK_TOKEN","claude_pid":…, "ts_ns":…, "hook":{…}}
   → connect(PIXEL_HOOK_SOCKET), write, close  (échéance 300 ms) → exit 0, aucune sortie
HookServer (actor, thread d'accept dédié)
   → vérifie uid du pair (getpeereid) + jeton (comparaison à temps constant) + taille
   → HookDecoder.decode (tolérant : événement inconnu → .other(name), champs inconnus ignorés)
   → dédoublonne (session_id, événement, tool_use_id, fenêtre de 50 ms) ; incrémente le compteur atomique de l'agent
   → AsyncStream<HookEnvelope> → @MainActor
AppModel (MainActor) : regroupe les événements par tranche de 16 ms, puis pour chacun :
   agent = envelope.agentID, SEULEMENT si claude_pid == pid du PTY de cet agent
           (sinon : claude imbriqué lancé par l'agent → ignoré, jamais adopté)
        ?? agentParSessionID ?? visiteurExterne(claude_pid, cwd)
   (runtime', effets) = AgentStateMachine.reduce(runtime, .hook(event), now)
   effets → NotificationBridge / SoundPlayer / TaskLifecycle.reduce / TaskDispatcher / ProgressStore
   WorldSceneCoordinator voit le changement (withObservationTracking) → réconcilie les nœuds à la frame suivante
```

### 2.4 Flux : envoyer un post-it

```
Glisser le post-it sur un agent  (ou « Donner à… », ou « premier agent libre du projet »)
 1. TaskLifecycle.reduce(.assign(card, agent)) → card.assignee = agent, card.queueRank = fin de file
    (la file d'un agent n'est pas stockée : elle se déduit des cartes, 4.2) → effet pump(agent)
 2. TaskDispatcher.pump(agent) : DispatchPolicy.nextDelivery(…) [pur] décide :
      - phase .idle ou .done confirmé, aucune attente, hooks sains, zone de saisie vide à l'écran,
        file non en pause → livrer
      - sinon → rester en file (badge « en file #n » sur le post-it et le poste, cause affichée)
 3. PromptComposer (template) → PromptSanitizer → DeliveryPlan (gardes + écritures + délais) [pur]
 4. reduce(.deliveryStarted) → livraison gardée en deux phases (5.6) :
      garde G → write(texte) → fin d'écriture → délai 120 ms–1 s → garde G + préfixe visible → write("\r")
      Une garde échoue → abandon : reduce(.deliveryAborted) → carte « échec d'envoi », file en pause
 5. Hook UserPromptSubmit dont le prompt commence par notre texte (fenêtre de 3 s)
      → TaskLifecycle : À faire → En cours ; delivery.promptID = prompt_id ; agent → .thinking
    Pas de hook → gardes rejouées → au plus un « \r » de secours, sinon « échec d'envoi »
 6. Hook Stop (même prompt_id) → .done **provisoire** → fenêtre de calme (3 s + écran au repos)
      → Stop confirmé : carte → À valider ; animation de satisfaction ; après 1,5 s, pump(agent)
      → Stop avec tâches de fond ou crons : .waitingBackground, rien n'est envoyé (4.3)
 7. Clic « Valider » sur le post-it → Fait → ProgressStore : +XP, badges
```

### 2.5 Flux : quitter, planter, relancer

**Règle** : une session `claude` vit aussi longtemps que l'app (décision 19). Fermer une PTY envoie SIGHUP au processus, et un outil en cours (npm install, migration) serait tué avec lui.

```
Fermer la dernière fenêtre (⌘W) : applicationShouldTerminateAfterLastWindowClosed = false
 → l'app reste dans le Dock et la barre de menus ; les sessions continuent
Quitter (⌘Q) : applicationShouldTerminate → .terminateLater si un agent est thinking / working /
               waitingInput / waitingBackground / quotaPaused → feuille de sortie (maquette 6(p)) :
   [Attendre la fin des tours] : plus aucune livraison ; l'app quitte d'elle-même quand tous sont au repos
   [Quitter quand même]       : fermeture des PTY (SIGHUP) → SIGTERM au groupe après 2 s → SIGKILL après 5 s
   [Annuler]
 → sinon, quitte directement ; PersistenceStore.flush()

Démarrage : PersistenceStore charge workspace.json, tasks.json, progress.json, settings.json
            (migrations si schemaVersion < courant ; fichier corrompu → mis de côté + dernière sauvegarde)
 → orphelins : pour chaque Agent.lastProcess (pid + heure de départ), le processus vit-il encore
   (même pid ET même heure de départ, via sysctl KERN_PROC) ? Cas d'un crash de l'app.
     oui → bannière « Nova : une session tourne encore hors de l'app » : [Terminer] [Laisser tourner]
           « Laisser tourner » : ses hooks sont refusés (jeton régénéré) ; le poste affiche « session
           détenue par un autre processus » ; Relancer est désactivé tant que ce pid vit
 → tous les agents sont en .offline(.appRelaunched) : chaise vide avec la veste, écran et lampe éteints,
   plaque « OFF » (7.4.10), jamais confondu avec un agent endormi
 → bannière « 6 sessions peuvent être relancées » : [Tout relancer] [Choisir…] [Plus tard] (maquette 6(p))
 → reprendre un agent = LaunchPlanner(.resume(sessions.last)) → `claude --resume <id> …` lancé dans
   SessionRef.cwd (worktree ou dossier changé) ; dossier disparu → proposer un fork dans le dossier du projet
   Jamais de --resume d'un session_id détenu par un processus vivant (orphelin, ou « Copier la commande »)
   (le transcript a pu être purgé au-delà de cleanupPeriodDays : erreur → proposer « nouvelle session »)
 → l'avatar ressort de l'ascenseur et se rassoit ; le tour interrompu ne reprend PAS tout seul :
   chaque post-it « En cours » (drapeau sessionLost) propose [Continuer la tâche] (envoie une consigne
   de reprise) ou [Remettre à faire] (4.3b, C14/C15)
```

### 2.6 Modèle de concurrence

| Élément | Isolation | Détail |
|---|---|---|
| `AppModel`, stores, `SessionManager`, `TerminalHost`, `TaskDispatcher`, `WorldScene` | `@MainActor` | Swift 6, concurrence stricte. `SKNode` est déjà `@MainActor` |
| Parsing des PTY | Threads d'E/S de SwiftTerm (branche `main` : un thread gather + un thread parse par session) | Ne touche jamais au modèle. `setProcessOutputHandler` ne fait que dater l'activité ; le MainActor en tire au plus une entrée `outputActivity` par seconde et par agent |
| `HookServer` | `actor` + thread d'accept bloquant | Produit un `AsyncStream<HookEnvelope>` consommé sur le MainActor, regroupé par frame (16 ms) |
| `PersistenceStore` | `actor` | Écritures regroupées (500 ms), atomiques ; un seul écrivain |
| `SessionDiscovery` | `actor` | Scan des JSONL en arrière-plan, priorité `.utility` |
| Minuteries (vérification d'envoi, fenêtre de calme, obsolescence, sommeil) | `Task` sur MainActor avec une horloge injectable (`any Clock`) | Entrée `tick` du modèle à **1 Hz** seulement ; les animations dérivées (étirement, clignements) sont des `SKAction`, pas des ticks. Tests déterministes avec une horloge simulée |
| Pont Observation → SpriteKit | `withObservationTracking` réarmé par un `Task { @MainActor }` | `onChange` se déclenche une seule fois, sur *willSet* ; on relit le modèle à la frame suivante. `Observations` (macOS 26) n'est pas disponible en cible 14 |

---

## 3. Modules en détail

Chaque fiche donne la responsabilité, une esquisse d'API (signatures indicatives, non compilées), les algorithmes clés et les modes de défaillance. Préfixe **[Core]** = dans `PixelCore` (pur, testé sous Linux) ; **[App]** = cible macOS.

### 3.1 SessionManager, TerminalHost, ClaudeLocator [App] + LaunchPlanner [Core]

**Responsabilité** : cycle de vie des processus `claude` dans des PTY, envoi d'octets, interruption. Un `TerminalHost` par agent vit aussi longtemps que le processus, **même quand aucune fenêtre ne l'affiche**.

```swift
// [Core] pur : construit argv/env ; testé exhaustivement
enum LaunchMode: Codable { case new(initialPrompt: String?), resume(sessionID: String),
                           continueLast, fork(fromSessionID: String) }
struct LaunchRequest { var agent: Agent; var project: Project; var mode: LaunchMode
                       var claude: ClaudeInstall; var baseEnv: [String: String]
                       var hookSettingsPath: String; var hookSocketPath: String; var hookToken: String
                       var options: LaunchOptions /* disableAgentView, extraEnv, forceClassicRenderer… */ }
struct LaunchPlan: Equatable { var executable: String; var args: [String]; var env: [String]; var cwd: String }
enum LaunchPlanner { static func plan(_ r: LaunchRequest) throws -> LaunchPlan }

// [App]
@MainActor final class SessionManager {
    func launch(_ agentID: AgentID, mode: LaunchMode) throws
    func host(for agentID: AgentID) -> TerminalHost?
    func write(_ steps: [DeliveryStep], to agentID: AgentID) async -> DeliveryOutcome
    func interrupt(_ agentID: AgentID)                    // un octet ESC
    func sendKeys(_ keys: QuickKeys, to agentID: AgentID) // réponses rapides (5.8)
    func close(_ agentID: AgentID, force: Bool)           // SIGTERM → attente → SIGKILL sur le groupe
}
@MainActor final class TerminalHost: LocalProcessTerminalViewDelegate {
    let agentID: AgentID
    let view: AgentTerminalView                    // sous-classe de LocalProcessTerminalView
    private(set) var life: Life                    // .idle/.running(pid)/.exited(Int32?)/.failed
    var onInput: (AgentInput) -> Void              // émet seulement : outputActivity, userKeystroke(KeyClass), bell
    var bracketedPasteMode: Bool { view.terminalStateSnapshot().bracketedPasteMode }
    func visibleLines() -> [String]                // terminalStateSnapshot().visibleRows
}
// Aucun état métier dans TerminalHost : ni horodatage d'activité, ni « brouillon ». Les lignes visibles
// passent par ScreenPatterns.parse(lines, version) [Core, pur, versionné] → entrée .screen(ScreenFacts)
struct ScreenFacts: Equatable { var inputBox: InputBoxState   // .empty / .draft(prefix) / .unknown
                                var dialogVisible: Bool; var spinnerVisible: Bool; var quotaLine: String? }
```

**Points clés**
- **Trouver `claude`** (`ClaudeLocator`) :
  1. chemin saisi dans les réglages ;
  2. cache (chemin + version) ;
  3. `PATH` obtenu du shell de connexion : `pw_shell -i -l -c` qui affiche `env` entre deux marqueurs aléatoires, stdin sur `/dev/null`, échéance 10 s, variable marqueur `PIXEL_RESOLVING_ENVIRONMENT=1` pour que tes rc puissent sauter le travail lourd (méthode de VS Code) ;
  4. chemins connus : `~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.claude/local/claude`.

  Le chemin retenu est vérifié avec `--version` (✔ documenté, https://code.claude.com/docs/en/cli-reference.md), qui donne aussi la version comparée au minimum de la décision 20. En cas d'échec, une feuille d'accueil explique comment installer ou indiquer le chemin (maquette 6(r)).
- **Environnement** : jamais `environment: nil`. Le défaut de SwiftTerm ne contient **pas** de `PATH`, et l'outil Bash de Claude comme ses hooks en ont besoin. On part de l'environnement résolu, on retire `CLAUDECODE`, `TERM_PROGRAM*`, `ITERM_*`, `KITTY_*`, `GHOSTTY_*`, `PWD`, `OLDPWD`, `SHLVL`, `_`, `DYLD_*`, puis on ajoute `TERM=xterm-256color`, `COLORTERM=truecolor`, `LANG` (si aucune locale) et les trois variables `PIXEL_*`. On ne se fait **pas** passer pour iTerm via `TERM_PROGRAM` : Claude Code adapte son comportement au terminal, et `/terminal-setup` écrirait dans des fichiers de configuration.
- **Démarrage détaché** : `init(frame: .zero, font:, options: TerminalOptions(cols: 120, rows: 36, scrollback: 2_000))`. Le processus démarre sans fenêtre, avec une taille de PTY correcte. Police et options sont fixées **avant** `startProcess` : les changer après provoque un DECSTR.
- **Re-parentage** : un `TerminalContainer: NSView` héberge la vue existante. `dismantleNSView` la **détache sans jamais terminer le processus**. Les passes de layout minuscules (moins de 320×160 pt) sont ignorées, pour éviter une rafale de SIGWINCH. SwiftUI peut appeler `makeNSView` du nouvel hôte **avant** `dismantleNSView` de l'ancien : un `TerminalPresenter` (MainActor) accorde donc l'attachement **exclusif**. Un hôte qui n'a pas le jeton affiche un espace réservé (« Terminal ouvert dans une autre fenêtre ») ; le transfert n'a lieu qu'après le détachement effectif. Test : bascules rapides panneau ↔ fenêtre détachée ↔ fermeture.
- **Fin de vie** : `terminate()` → `processTerminated` → `removeFromSuperview()` → `updateUiClosed()`, relancé tant qu'il renvoie `false`. `processDelegate` étant `weak`, le `TerminalHost` est retenu fortement par le `SessionManager`.
- **Clavier** : `optionAsMetaKey = false` par défaut (réglable). Sur un clavier AZERTY, `{ [ | ~` passent par Option.

**Défaillances** : binaire introuvable (feuille d'accueil) · exec impossible (exit 127 → `.error(.launchFailed)`) · connexion à Claude ou confiance du dossier demandées dans la TUI (l'agent reste `.launching`, puis une attente `.terminal` s'ouvre après 8 s de silence : « Regarde le terminal ») · crash (code ≠ 0 → `.error(.crashed)`).

### 3.2 HookServer [App] + PixelIPC [Core-IPC] + `pixel-hook` [exécutable]

**Responsabilité** : recevoir chaque événement de hook de façon sûre et rapide, et ne jamais gêner Claude.

```swift
// [PixelIPC] Darwin + Glibc : testable sous Linux (SO_PEERCRED au lieu de getpeereid)
final class UnixSocketServer { init(path: String, mode: mode_t = 0o600) throws
                               func start(onMessage: @Sendable (Data, PeerCredentials) -> Void); func stop() }
enum UnixSocketClient { static func sendOnce(_ data: Data, to path: String, deadline: Duration) -> Bool }

// [Core]
struct HookEnvelope: Sendable { var v: Int; var agentID: AgentID?; var token: String?
                                var claudePID: Int32?; var timestampNs: UInt64; var event: HookEvent }
enum HookDecoder { static func decodeEnvelope(_ data: Data) throws -> HookEnvelope }

// [App]
actor HookServer { init(socketPath: String, token: String)
                   var events: AsyncStream<HookEnvelope> { get }
                   func start() throws; func stop() }
```

**`pixel-hook`** : exécutable Swift de moins de 1 Mo, embarqué dans `Contents/Helpers/`.
1. Lit stdin **jusqu'à EOF** : les 4 premiers Mo sont gardés, le reste est lu et jeté (ne jamais fermer stdin tôt, ce qui donnerait un EPIPE à Claude). En mode « installation globale » (argument `--pixel-open-space-managed`), sort aussitôt si `PIXEL_AGENT_ID` est défini : la session vient de l'app (ou d'un `claude` imbriqué lancé par un agent) et ses hooks passent déjà par `--settings`.
2. Tronque à 4 Ko les champs volumineux (`tool_output`, `tool_response`, `assistant_message`, `last_assistant_message`, `prompt`), et ajoute `prompt_len`.
3. Ajoute `agent` (`$PIXEL_AGENT_ID`), `token` (`$PIXEL_HOOK_TOKEN`, ou le fichier `run/token` pour les sessions lancées hors de l'app), `claude_pid` et `ts_ns`.
   - `claude_pid` = premier ancêtre qui n'est pas un shell. On remonte `getppid()` en sautant `sh`, `bash`, `zsh`, `dash` et `fish`. Pour une session de l'app, il doit être égal au pid du PTY (le chemin de `claude` est lancé par `execve`, et le lanceur npm `#!/usr/bin/env node` garde le même pid) : c'est ce qui écarte les `claude` imbriqués (5.7).
   - `ts_ns` = horloge monotone.
4. Se connecte au socket (`$PIXEL_HOOK_SOCKET`, sinon le chemin par défaut) avec une échéance de 300 ms, écrit une ligne JSON, ferme.
5. **Sortie : code 0, stdout vide, stderr vide**, en toutes circonstances : app fermée, socket absent, JSON invalide.

Mode debug : la variable `PIXEL_HOOK_DEBUG=1` écrit un journal dans `logs/`.

**Serveur** :
- dossier `run/` en 0700, socket en 0600 ;
- vérification que l'uid du pair est le nôtre, et du jeton (comparaison à temps constant) ;
- 1 Mo au plus par message, 200 événements par seconde au plus par agent (au-delà, les événements sont écartés) ;
- un socket orphelin (aucun serveur ne répond) est supprimé au démarrage ; si une autre instance répond, l'app se met au premier plan et quitte ;
- chemin par défaut `~/Library/Application Support/PixelOpenSpace/run/hook.sock`, environ 70 octets. S'il dépasse 100 octets (`sun_path` est limité à 104 octets), repli sur `$TMPDIR/pos-<uid>/hook.sock`.

**Ordre des événements** : les hooks sont **synchrones** (pas d'`async: true`), donc Claude attend la fin de `pixel-hook`, environ 5 à 15 ms (⚠️ à mesurer), avant de continuer. Cela ordonne les événements **d'un même outil**, pas ceux d'outils parallèles ni des sous-agents : `PostToolUse` part en concurrence pour des appels parallèles (https://code.claude.com/docs/en/hooks.md). Le réducteur ne suppose donc **aucun ordre global** : attentes et outils en vol sont indexés par `tool_use_id` (4.3). Le serveur trie aussi par `ts_ns`, agent par agent, dans une fenêtre de 16 ms, et dédoublonne (5.7).

### 3.3 HooksInstaller [App] + SettingsPatcher [Core]

**Responsabilité** : installation **optionnelle** (étape 5) des hooks dans `~/.claude/settings.json` (portée utilisateur) ou `<projet>/.claude/settings.local.json` (portée projet locale), uniquement pour voir les sessions lancées **hors** de l'app. Jamais dans le `.claude/settings.json` partagé d'un projet.

```swift
// [Core] parseur maison qui garde la position de chaque valeur ; les modifications sont des insertions et
// suppressions de plages de texte : tout le reste du fichier (espaces, indentation, ordre) reste identique à l'octet
enum SettingsPatcher {
    static let marker = "--pixel-open-space-managed"         // argument sentinelle dans la commande
    static func install(into: OrderedJSON, handler: HookHandlerSpec, events: [HookEventName]) throws -> OrderedJSON
    static func uninstall(from: OrderedJSON) -> OrderedJSON  // retire UNIQUEMENT les entrées sentinelles
    static func status(of: OrderedJSON) -> InstallStatus     // .absent / .installed(version) / .partial / .foreign
}
@MainActor final class HooksInstaller {
    func preview(_ scope: InstallScope) throws -> InstallPreview   // diff lisible avant/après + chemin de sauvegarde
    func install(_ preview: InstallPreview) throws -> BackupRef
    func uninstall(_ scope: InstallScope) throws
    func restore(_ backup: BackupRef) throws                       // action explicite, avec diff affiché
}
enum InstallScope: Codable { case user, projectLocal(ProjectID) }
```

**Algorithme d'écriture** (garde-fous inspirés des incidents de projets tiers : écrasement du fichier, perte de hooks existants) :
1. Résoudre les liens symboliques et écrire à la cible (compatible dotfiles « stow »).
2. Lire le fichier. S'il n'est pas du JSON valide, **refuser** et expliquer.
3. Copier le fichier dans `backups/claude-settings/<horodatage>-<portée>.json`.
4. Appliquer `SettingsPatcher.install`.
5. Écrire dans un fichier temporaire du **même dossier**, avec le même mode.
6. Relire la cible : si son empreinte a changé depuis l'étape 2, recommencer (3 essais, 100 ms d'écart).
7. `rename` atomique.

La désinstallation ne retire que nos entrées sentinelles. Elle ne restaure **jamais** automatiquement une ancienne sauvegarde, pour ne pas perdre tes modifications faites depuis. Test strict : installer puis désinstaller redonne le fichier **identique octet pour octet**, sans exception de reformatage. Le texte du dialogue de consentement est en 6(g).

### 3.4 SessionDiscovery [App actor] + TranscriptScanner [Core]

**Responsabilité** : proposer les sessions passées (« Reprendre une ancienne conversation », étape 5). Elle ne sert **pas** à connaître l'état des sessions vivantes.

```swift
struct DiscoveredSession: Codable, Hashable { var sessionID: String; var cwd: String?; var title: String?
    var firstPrompt: String?; var startedAt: Date?; var lastActivity: Date; var sizeBytes: Int; var transcriptPath: String }
enum TranscriptScanner {        // [Core] tolérant : lignes invalides ignorées, dernière ligne partielle ignorée
    static func summarize(head: Data, tail: Data, fileName: String, mtime: Date, size: Int) -> DiscoveredSession }
actor SessionDiscovery {
    func scan(root: URL = ~/.claude/projects, olderThan: Date? = nil) async -> [DiscoveredSession]
}
```

**Algorithme**
1. Lister `~/.claude/projects/*/*.jsonl`, ou `$CLAUDE_CONFIG_DIR/projects` si tu as défini cette variable.
2. `sessionID` = nom du fichier.
3. Lire les 64 premiers Ko et les 64 derniers Ko. Extraire le premier champ `cwd` trouvé, les horodatages et, **s'ils existent**, les enregistrements de titre (`custom-title`, `ai-title`, observés, non documentés).
4. Rattacher chaque session à un projet par chemin standardisé (liens résolus).

Le nom du dossier n'est **jamais** décodé : la conversion n'est pas réversible au-delà de 200 caractères (https://code.claude.com/docs/en/sessions.md). La lecture est **strictement en lecture seule**.

Les échantillons de JSONL servent de *fixtures* de test. Si aucun champ exploitable n'est trouvé, la session s'affiche comme « session sans titre », sans erreur.

### 3.5 TaskStore [App] + modèle de carte [Core]

**Responsabilité** : **seul propriétaire** des post-its, des consignes ad hoc en file et des modèles de prompt ; filtres, recherche, import d'une liste collée. Toute modification de colonne, d'assignation ou de rang passe par `TaskLifecycle.reduce` (4.3b) ; seuls le texte, les tags et la priorité s'éditent directement.

```swift
@MainActor @Observable final class TaskStore {
    private(set) var board: TaskBoardState       // cards, instructions (consignes ad hoc), templates
    func apply(_ input: TaskInput)                 // → TaskLifecycle.reduce → effets (pump, notify, XP…)
    func create(title: String, projectID: ProjectID?) -> TaskCardID                 // ⌘N → apply(.create)
    func createMany(fromPastedLines: String, projectID: ProjectID?) -> [TaskCardID]   // 1 ligne = 1 post-it
    func edit(_ id: TaskCardID, _ e: CardTextEdit)  // titre, description, tags, priorité, modèle
    func queue(of agent: AgentID) -> [QueueItem]    // dérivé : consignes puis cartes todo ∧ assignee == agent, par queueRank
    func filtered(_ f: BoardFilter) -> [Column: [TaskCard]]        // projet, état, tags, texte (FuzzyMatcher)
}
```

**Modèles de prompt** : chaque post-it peut choisir un modèle (sinon celui de l'agent, puis du projet) ; l'éditeur montre l'**aperçu du prompt composé** exactement tel qu'il sera tapé (maquette 6(l)). Les modèles se gèrent dans le même panneau (créer, dupliquer, supprimer, défaut par projet).

**Import collé** : on coupe par lignes, en retirant les puces `-`, `*`, `•`, `1.` et `[ ]`, et en ignorant les lignes vides. Une ligne indentée sous une autre s'ajoute à la description de la précédente.

**Priorité** : la punaise est rouge, jaune ou verte, et s'affiche aussi en toutes lettres au survol et pour VoiceOver.

### 3.6 TaskDispatcher [App] + TaskQueue / DispatchPolicy / DeliveryPlan [Core]

**Responsabilité** : la file de chaque agent, la décision de livrer, la livraison vérifiée, et l'enchaînement après `Stop`.

```swift
enum QueueItem: Codable, Hashable { case card(TaskCardID), instruction(InstructionID) } // dérivé, jamais stocké
enum DeliveryDecision: Equatable { case deliver(QueueItem), wait(WaitCause), none }
enum WaitCause: Equatable { case busy, waitingInput, waitingBackground, quotaPaused, draftInInputBox,
                            screenUnknown, paused, offline, hooksUnhealthy, cooldown }
enum DispatchPolicy {   // [Core] pur
    static func nextDelivery(agent: Agent, runtime: AgentRuntime, queue: [QueueItem], now: Date,
                             settings: DispatchSettings) -> DeliveryDecision
    static func firstFreeAgent(in project: ProjectID, agents: [Agent], runtimes: [AgentID: AgentRuntime]) -> AgentID?
}
enum DeliveryGuard: Equatable { case beforeText, beforeEnter(prefix: String), beforeRetryEnter(prefix: String) }
enum DeliveryStep: Equatable { case check(DeliveryGuard), write([UInt8]), awaitWriteCompletion,
                               sleep(milliseconds: Int), expectPromptSubmit(prefix: String, within: Int) }
enum DeliveryPlan {     // [Core] pur
    static func make(_ prompt: SanitizedPrompt, bracketedPaste: Bool) -> [DeliveryStep]
    static func evaluate(_ g: DeliveryGuard, runtime: AgentRuntime, hookSeqAtStart: UInt64,
                         hookSeqNow: UInt64, screen: ScreenFacts) -> GuardVerdict }   // .pass / .abort(reason)
@MainActor final class TaskDispatcher { func pump(_ agent: AgentID) }   // lit, décide, exécute ; n'écrit l'état
                                        // que par AgentInput (deliveryStarted / deliveryAborted) et TaskInput
```

**« Premier agent libre du projet »** : on prend un agent `.idle` ou `.done` dont la file est vide ; s'il y en a plusieurs, celui qui est inactif depuis le plus longtemps. Sinon, la file la plus courte. S'il n'y a aucun agent en ligne, l'app propose « Lancer un nouvel agent avec ce post-it », qui passe le post-it en argument positionnel.

**Règles** :
- 1 élément de file par tour ;
- délai de grâce de 1,5 s après un `Stop` **confirmé** (4.3, T13b), pour voir l'animation et te laisser intervenir ;
- après une interruption ou un échec d'envoi, la file se met **en pause** jusqu'à ce que tu la relances ;
- aucune livraison automatique si la zone de saisie du terminal n'est pas vide **à l'écran** (brouillon) ou si l'écran n'est pas reconnu : le poste et la barre d'état l'affichent (« ✎ brouillon »), et « Envoyer quand même » ne lève **que** cette garde-là, jamais celles d'état, d'événements ou de dialogue ;
- aucune livraison pendant `waitingBackground` ou `quotaPaused` (4.3).

La séquence octet par octet et les gardes sont en 5.6.

### 3.7 AgentStateMachine + AgentPresenter [Core]

**Responsabilité** : réducteur pur `(AgentRuntime, AgentInput) → (AgentRuntime, [AgentEffect])`, et projection pure état → pose, animation et overlays.

```swift
enum AgentInput: Equatable { case processStarted(pid: Int32, startTime: Date), processExited(code: Int32?)
    case processFailedToStart(String), hook(HookEvent, seq: UInt64), screen(ScreenFacts)
    case userInterrupt, userKeystroke(KeyClass), outputActivity, bell, tick
    case deliveryStarted(PendingDelivery), deliveryAborted(DeliveryAbort)
    case acknowledged /* l'utilisateur a regardé l'agent */ }
enum AgentEffect: Equatable { case notify(NotificationKind), playSound(SoundID), cardEvent(TaskInput)
    case pumpQueue(after: Duration), setQueuePaused(Bool), recordSession(SessionRef), recordProcess(ProcessStamp)
    case updateSessionCwd(String), endSession(sessionID: String, reason: String?), globalIssue(GlobalIssue)
    case announce(String) /* VoiceOver */, resampleScreen, reconcile }
enum AgentStateMachine { static func reduce(_ r: AgentRuntime, _ i: AgentInput, now: Date) -> (AgentRuntime, [AgentEffect]) }
struct AgentPresentation: Equatable { var pose: Pose; var overlay: Overlay?; var screen: ScreenState
    var toolIcon: ToolKind?; var label: String /* texte d'accessibilité */ ; var urgency: Int /* 0…3 */ }
enum AgentPresenter { static func present(_ r: AgentRuntime, now: Date, reduceMotion: Bool) -> AgentPresentation }
```

La table complète des transitions est en 4.3 (agents) et 4.3b (post-its). Les tests couvrent chaque transition, les gardes, et des scénarios rejoués depuis des journaux d'événements réels (fichiers `.jsonl` de fixtures capturés lors des spikes), y compris dans un ordre mélangé pour les outils parallèles.

### 3.8 WorldLayout + IsoMath [Core]

**Responsabilité** : fonction **pure et déterministe** qui prend projets, agents et décor, et renvoie les placements sur la grille. SpriteKit ne fait que dessiner le résultat.

```swift
struct GridPoint: Hashable, Codable { var i: Int; var j: Int }
struct GridSize: Hashable, Codable { var w: Int; var d: Int }       // w le long de i, d le long de j
enum Facing: String, Codable { case ne, nw, se, sw }                // se/sw = vers le spectateur
struct WorldInput { var projects: [Project]; var agents: [Agent]; var decor: [DecorItem]; var config: LayoutConfig }
struct WorldLayoutResult: Equatable { var islands: [IslandPlacement]; var props: [PropPlacement]
                                      var corridors: [GridRect]; var bounds: GridRect; var boardWall: GridRect; var elevator: GridRect }
enum WorldLayout { static func compute(_ input: WorldInput) -> WorldLayoutResult }
enum IsoMath { static func toScene(_ p: GridPoint) -> CGPoint   // sx = (i − j)·32, sy = −(i + j)·16 (y vers le haut)
               static func toGrid(_ s: CGPoint) -> (Double, Double)
               static func depth(_ i: Double, _ j: Double, layer: Layer) -> CGFloat } // band + (i+j)·10 + layer
```

**Algorithme**
- **Îlot** = rangée double de postes dos à dos, en mode « bench ».
  - Un poste occupe 1×2 tuiles : le bureau devant, la chaise et l'avatar derrière.
  - La rangée A regarde vers le nord-ouest : on voit l'**écran** allumé et le dos de l'avatar. La rangée B regarde vers le sud-est : on voit le **visage**.
  - Capacité **exacte** : `cap = 4 · ⌈(agents + 1) / 4⌉`, soit 4 postes pour 0 à 3 agents, 8 pour 4 à 7. Il reste toujours au moins un poste libre, et un îlot ne grandit que par paliers de 4.
  - Taille de l'îlot = `(2·⌈cap/2⌉ + 2) × 7` tuiles, pancarte et bordure comprises : 6×7 (cap 4), 10×7 (cap 8).
- **Placement « append-only »** : l'open space est une grille de **slots** de taille fixe, réservée pour un îlot de 8 postes (10×7 tuiles + couloirs de 2 = pas de 12×9 tuiles).
  - Les slots sont numérotés une fois pour toutes, en carré croissant : (0,0), (1,0), (0,1), (1,1), (2,0), (2,1), (0,2)… Ce numérotage ne dépend pas du nombre de projets.
  - Un projet reçoit le premier slot libre à sa création et **le garde** : `Project.slot` est persisté. Ajouter un projet ou un agent ne déplace **jamais** un îlot existant ; un îlot qui passe de 4 à 8 postes grandit dans son propre slot.
  - Au-delà de 7 agents, le projet reçoit un **îlot annexe** (« API · 2 ») dans le prochain slot libre.
  - Un projet archivé libère son slot, réutilisé par le projet suivant. Rien n'est compacté automatiquement ; « Réorganiser l'open space » est une commande explicite du mode édition.
- **Hall et murs** : le hall (ascenseur, machine à café, plante) et le **mur de liège** occupent une bande fixe de 6 tuiles le long du mur du fond (j = 0), avant les slots. Les deux murs du fond couvrent le bord arrière de l'emprise : quand une rangée de slots s'ajoute, le mur latéral s'allonge de 9 tuiles (segments + une fenêtre toutes les 3 tuiles). Hall, mur de liège et ascenseur ne bougent jamais. Les bords avant n'ont pas de mur.
- **Stabilité** : un agent garde son `deskIndex` persisté. Ajouter un agent ne déplace aucun autre agent de son îlot.
- **Emprise** (1 texel = 1 pt à ×1 ; largeur = (W + D)·32, hauteur = (W + D)·16 + 96 de murs) :

  | Projets (≤ 7 agents chacun) | Slots | Emprise W×D (tuiles) | ×1 (pt) | Vue d'ensemble 0,5 pt/texel |
  |---|---|---|---|---|
  | 3 (ex. 5 ou 20 agents) | 2×2 | 24×24 | 1536×864 | 768×432 |
  | 5–6 (ex. 10 ou 20 agents) | 3×2 | 36×24 | 1920×1056 | 960×528 |
  | 8 | 3×3 | 36×33 | 2208×1200 | 1104×600 |

  Un MacBook Air 13" offre environ 1470×830 pt de scène, 1090×830 avec le tableau latéral : **×1 ne suffit pas dès 3 projets**. D'où le niveau « vue d'ensemble » (3.9) et la maquette 6(q).
- **Tests** (propriétés) : déterminisme, aucun chevauchement, tout agent a un poste, invariance des postes existants quand un agent est ajouté, **aucun îlot existant ne bouge quand un projet ou un agent est ajouté ou archivé**, bornes qui englobent tout.

### 3.9 WorldScene, WorldView, CameraController [App]

**Responsabilité** : dessiner l'open space et traduire la souris, le trackpad et le glisser-déposer en *intents*. Aucune logique métier.

```swift
final class WorldView: SKView, NSDraggingDestination {  // enveloppée par WorldViewRepresentable (NSViewRepresentable)
    override func scrollWheel(with: NSEvent); override func magnify(with: NSEvent)
    override func mouseDown(with: NSEvent) /* clickCount */; override func mouseMoved(with: NSEvent)
    override func rightMouseDown(with: NSEvent) /* menu contextuel natif */
    override func viewDidChangeBackingProperties(); override func viewDidChangeEffectiveAppearance()
    func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation   // survol d'un agent → surbrillance
    func performDragOperation(_ s: NSDraggingInfo) -> Bool         // post-it lâché → CommandCenter.assign
}
@MainActor final class WorldScene: SKScene {
    func apply(_ snapshot: WorldSnapshot)          // réconciliation par ID : ajoute / met à jour / retire des nœuds
    func node(at viewPoint: CGPoint) -> HitTarget? // agent, poste vide, îlot, mur de liège, décor
    func focus(on target: FocusTarget, animated: Bool)
}
struct WorldSnapshot: Equatable { var layout: WorldLayoutResult; var agents: [AgentID: AgentPresentation]
                                  var projects: [ProjectID: ProjectVisual]; var boardCount: Int; var night: Bool }
```

- **Pixel parfait** (règles détaillées en 7.3) :
  - 1 texel = 1 point de scène. Niveaux de zoom : **vue d'ensemble** 0,5 pt par texel (= 1 pixel physique par texel sur Retina, donc net ; niveau absent sur un écran non Retina), puis ×1, ×2, ×3 (2, 4 ou 6 pixels physiques sur Retina), avec `camera.setScale(1/zoom)`.
  - La position de la caméra est ramenée à la grille des pixels physiques, parité comprise (7.3).
  - Les nœuds sont positionnés en texels entiers, **à chaque frame** y compris pendant un déplacement, et les points d'ancrage choisis pour que `ancre × taille` soit entier.
  - Pendant un pincement, le zoom s'accumule puis passe au palier suivant au-delà d'un seuil : il n'y a jamais d'échelle fractionnaire au repos.
- **Profondeur** : `zPosition = bande + (i + j)·10 + couche`, avec `ignoresSiblingOrder = true`. La bande du sol est basse et celle des overlays haute. Les meubles de plusieurs tuiles sont découpés en bandes d'une tuile à la génération.
- **Hit-test au pixel près** : on prend les candidats de `nodes(at:)` par z décroissant et on teste le masque alpha conservé côté CPU. SpriteKit, lui, ne teste que les rectangles englobants.
- **Résolution des clics** (une seule règle, testée) :
  - clic sur un agent : sélection immédiate ; la fenêtre agent ne s'ouvre qu'après `NSEvent.doubleClickInterval` sans second clic, donc un double-clic ouvre **seulement** le terminal, sans fenêtre qui clignote ;
  - clic sur un poste libre : petit popover « Nouvel agent ici ? [Créer ↩] », jamais de création directe ;
  - double-clic sur le sol ou la pancarte d'un îlot : centrer l'îlot. Un double-clic sur un poste ou un agent ne centre pas ;
  - clic droit : menu contextuel natif (mêmes commandes que ⌘K).
- **Glisser-déposer** : charge `Transferable` + `CodableRepresentation` d'un UTI exporté `…pixelopenspace.postit` (déclaré dans Info.plist). La destination est AppKit, sur `WorldView`. ⚠️ Lire un `Transferable` SwiftUI depuis `draggingPasteboard` est le point du spike S8 ; **repli concret** : `WorldView` enregistre elle-même l'UTI (`registerForDraggedTypes`) et décode le payload `Codable` (JSON) depuis le presse-papiers, sans vue SwiftUI superposée (qui volerait survol, défilement et pincement).

  | Cible sous le curseur | Opération | Curseur / retour | Résultat |
  |---|---|---|---|
  | Agent de l'app, même projet | copier | anneau `floor.dropTarget` + infobulle « Donner à Nova · file #2 » | `assign` ; livraison si les gardes passent, sinon en file |
  | Agent en attente (`!`) ou occupé | copier | idem + « sera livré après ton accord » ou « en file #n » | `assign`, reste en file |
  | Agent d'un autre projet | copier | halo orange + « autre projet : ~/dev/site » | feuille de confirmation (4.3b, C3) |
  | Agent hors ligne | copier | « hors ligne : sera livré après relance » | `assign` + proposition « Relancer la session » |
  | Agent externe (pointillés) ou orphelin | interdit | curseur interdit + « terminal externe » | rien |
  | Poste libre | copier | poste en surbrillance + « Nouvel agent avec ce post-it » | crée l'agent, post-it en prompt positionnel |
  | Sol d'un îlot | copier | îlot en surbrillance + « premier agent libre » | `DispatchPolicy.firstFreeAgent` |
  | Ligne du plateau d'attente ou de la mini-carte | copier | ligne en surbrillance | comme la cible agent |
  | Ailleurs | aucune | - | rien |

  **Défilement automatique** : à moins de 48 pt d'un bord de la scène pendant un glisser, la caméra glisse vers ce bord (200 pt/s, 600 pt/s à moins de 16 pt) ; survoler une ligne du plateau d'attente 0,5 s fait voler la caméra vers l'agent. Un seul post-it par glisser au MVP ; l'aperçu du glisser a la taille du post-it du tableau, quel que soit le zoom.
- **Plateau d'attente** (objectif « qui attend quoi en moins de 3 s ») :
  - dès qu'au moins un agent attend, « (!) N ATTENDENT » ouvre un **plateau persistant** sous la barre d'état : une ligne par attente, `agent · projet · outil · résumé · depuis`, triée par ancienneté. Clic sur une ligne : vol de caméra + fenêtre agent ; c'est aussi une cible de dépôt ;
  - un agent en attente hors du champ affiche une **flèche de bord** (`ov.edgeArrow`, avec « ! ») à l'endroit où il se trouve ; clic = vol de caméra ;
  - chaque poste a une **plaque de nom** (`desk.nameplate`), toujours visible pour un agent en attente, en erreur ou hors ligne, au survol pour les autres.
- **Énergie**, budgets mesurés sur un Mac M1 avec 20 agents au repos (spike S11, Instruments) :
  - ≤ 5 % CPU et ≤ 400 Mo de mémoire résidente pour l'app (hors processus `claude`) ;
  - 0 fps quand la fenêtre est masquée (`occlusionState`), ≤ 15 fps quand l'app n'est pas active, 30 fps au repos au premier plan, 60 fps pendant une interaction ;
  - pas de surcharge de `update(_:)` : tout passe par des `SKAction` et des événements du modèle, dont le `tick` est à 1 Hz ;
  - ⚠️ non vérifié : que SwiftTerm cesse de dessiner une vue hors écran, et le coût de 20 TUI qui animent leur spinner (S11).
- **Caméra et souris** :
  - trackpad : deux doigts = déplacement ; pincement = zoom ;
  - souris : molette = zoom ; ⇧+molette = déplacement horizontal ; **glisser sur le sol vide**, bouton du milieu, ou Espace + glisser = déplacement ;
  - clavier (focus dans la scène) : flèches = déplacement, ⇧+flèches = pas ×4 ; ⌘+ / ⌘− = zoom ; ⌘0 = **Tout voir** : le plus grand zoom entier qui fait tout tenir, sinon la vue d'ensemble, sinon ×1 centré avec la mini-carte ;
  - vol de caméra vers un agent (barre d'état, plateau, notification) : `SKAction` ease-in-out de 0,4 s, position recalée sur la grille à chaque frame.

### 3.10 AssetFactory (SpriteCatalog, AtlasPacker, SceneCompositor) / SpriteRegistry [Core + App]

**Responsabilité** : générer tous les sprites **par programme**, les ranger en atlas, gérer le remplacement par tes PNG, et produire les variantes teintées par projet et par apparence d'agent. L'« AssetFactory » de ta spec est répartie entre ces types.

```swift
// [Core]
struct RGBA8: Hashable { var r, g, b, a: UInt8 }
struct PixelImage { let width: Int, height: Int; var pixels: [RGBA8]   // rangées de haut en bas
                    func mirrored() -> PixelImage; func alphaMask() -> BitMask }
struct PixelMap { init(_ ascii: String, legend: [Character: PaletteRole]) }  // DSL « grille ASCII → rôles »
enum Draw { static func isoBox(footprint: GridSize, height: Int, ramp: Ramp, outline: OutlineStyle) -> PixelImage
            static func isoDiamond(w: Int, h: Int, fill: RGBA8) -> PixelImage; static func line2to1(…) }
struct SpriteDef { var id: SpriteID; var anchor: (Int, Int); var frames: [PixelImage]; var holds: [Int] /* ticks à 24/s */
                   var derivation: Derivation? }  // .mirror (sprites sans faces ombrées) · .mirrorReshaded (personnages)
enum SpriteCatalog { static func all(for theme: Theme) -> [SpriteDef]
                     static func agentSheet(look: AgentLook) -> [SpriteDef] }   // composé à la demande
enum AtlasPacker { static func pack(_ defs: [SpriteDef], pageSize: Int = 2048, padding: Int = 2) -> [AtlasPage] }
struct SpriteManifest: Codable { … }  // voir 7.6
enum SceneCompositor {  // rendu logiciel de la scène entière (WorldLayout + sprites) en PixelImage : PNG sous Linux
    static func render(_ layout: WorldLayoutResult, agents: [AgentID: AgentPresentation], zoom: Int, night: Bool) -> PixelImage }
// [App]
@MainActor final class SpriteRegistry { func texture(_ id: SpriteID, frame: Int = 0) -> SKTexture
                                        func animation(_ id: SpriteID) -> SKAction; func reloadOverrides() }
```

Côté app, chaque page d'atlas devient une `SKTexture(data:size:)` en filtrage `.nearest`, et les sous-textures sont découpées par `SKTexture(rect:in:)`, avec `.nearest` réappliqué sur chacune. Les pages sont préchargées au lancement. `SceneCompositor` produit les mêmes images sans GPU : c'est lui qui rend les captures de validation sous Linux (jalon visuel, section 8), les captures SpriteKit de la CI macOS ne sont qu'un contrôle en plus. Détails, liste complète et format en section 7.

### 3.11 GameProgress (ProgressState, ProgressRules, ProgressStore) [Core règles + App store]

```swift
struct ProgressState: Codable { var userXP: Int; var badges: [BadgeID: Date]; var unlocked: Set<DecorKind>
                                var daily: [DayKey: DayStats]; var agentXP: [AgentID: Int] }
enum ProgressRules { static func onCardValidated(_ p: ProgressState, card: TaskCard, agent: AgentID?, now: Date,
                                                 context: ProgressContext) -> (ProgressState, [ProgressEvent])
                     static func level(forXP: Int) -> Int   // seuil(n) = 25·n·(n+1) : 50, 150, 300, 500…
                     static func evaluateBadges(_ p: ProgressState, context: ProgressContext) -> [BadgeID] }
```

**XP** : +10 par post-it validé, +5 si la priorité est haute. L'XP n'est attribuée qu'une fois par carte, **uniquement** sur ton clic « Valider » et seulement si la carte a été livrée à un agent au moins une fois ; rouvrir puis revalider une carte ne redonne rien et ne retire rien (4.3b). Affichage : niveau et barre d'XP dans la barre d'outils, badges dans une petite vitrine (maquette 6(s)).

**Badges** : « Première tâche », « 5 agents en parallèle », « 10 post-its vidés dans la journée », etc. ; conditions exactes dans le tableau de 7.4.9.

Tout se désactive dans les réglages, et l'app reste utilisable sans le jeu.

### 3.12 NotificationBridge [App]

- Le délégué est défini dans `applicationWillFinishLaunching` (`@NSApplicationDelegateAdaptor`). `willPresent` renvoie `[.banner, .list, .sound]`.
- L'autorisation est demandée **en contexte**, la première fois qu'un agent attend, avec une explication à l'écran. En cas de refus, il reste le badge du Dock (`NSApp.dockTile.badgeLabel`, sans permission) et l'icône de barre de menus.
- Une notification par agent et par type, avec l'identifiant `agent-<id>-waiting`. Le même identifiant remplace la notification précédente au lieu de s'empiler. `threadIdentifier` = projet ; `userInfo` = `agentID`.
- **Attente** : notification **toujours** envoyée, même app au premier plan (décision 18), avec un anti-rebond de 1 s. **Tour terminé** : seulement si l'app n'est pas au premier plan ou si l'agent n'est pas visible.
- **Problèmes globaux** (limite d'usage, compte déconnecté) : **une** notification pour tous les agents, pas une par agent.
- Réglage « Masquer les détails dans les notifications » : la commande et le chemin sont remplacés par « Nova attend ta réponse », utile avec l'écran verrouillé et le Centre de notifications.
- Clic sur la notification : `NSApp.activate()`, puis `model.focusRequest = .agent(id)`. La fenêtre principale observe ce champ et fait voler la caméra jusqu'à l'agent.
- Les actions « Ouvrir le terminal » et « Refuser (Échap) » arrivent à l'étape 5.
- ⚠️ `UNUserNotificationCenter` exige un vrai bundle `.app`. Le niveau `.timeSensitive` demande un entitlement dont les conditions ne sont pas vérifiées : on reste sur `.active`.

### 3.13 MenuBar et Dock [App]

La fenêtre principale peut être fermée sans quitter (2.5) : la barre de menus reste alors le point d'entrée. `MenuBarExtra` en style `.window`. Son libellé est une icône pixel (un petit bureau) suivie du nombre d'agents en attente, ou de rien quand personne n'attend. Le menu déroulant liste d'abord les agents en attente, puis ceux qui travaillent, puis ceux qui ont fini (maquette 6(i)). Le badge du Dock affiche le nombre d'agents en attente. ⚠️ Un libellé `MenuBarExtra` n'accepte peut-être que `Image` + `Text` : on reste dans ce cadre.

### 3.14 Persistance [Core codecs + App actor]

**Choix : JSON `Codable` versionné, pas SwiftData.**
- **Testable sous Linux** : SwiftData n'existe que sur les plateformes Apple, or l'IA qui écrit le code n'a pas de Mac.
- **Lisible et comparable** : tu peux ouvrir les fichiers et les comparer (diff) pour déboguer.
- **Volumes minuscules** : quelques centaines d'objets.
- **Un seul écrivain** : pas besoin de `NSFileCoordinator`.
- **Migrations explicites** : `Migrator.migrate(json, from: v)` pas à pas, avec tests.

```swift
actor PersistenceStore { func load() async throws -> PersistedState
                         func scheduleSave(_ part: PersistedPart)   // regroupé 500 ms, Data.write(options: .atomic)
                         func flush() async }                        // appelé à la fermeture de l'app
```

Sauvegardes tournantes : 5 par fichier, au plus une par jour. Un fichier illisible est renommé `*.corrupt-<horodatage>.json`, l'app recharge la dernière sauvegarde et t'avertit. L'arborescence des fichiers est en 4.5.

### 3.15 Settings [App] + AppSettings [Core]

Les réglages vivent dans le fichier `state/settings.json`, décrit par la struct `AppSettings`, et non dans `UserDefaults`. C'est plus facile à tester et à comparer. Seule la géométrie des fenêtres reste gérée par SwiftUI. La liste des champs est en 4.1 et l'écran en 6(h).

### 3.16 CommandCenter : raccourcis, menus, palette ⌘K [App]

Toutes les actions passent par `CommandCenter` (`func perform(_ c: AppCommand)`). Le menu, la palette, la scène et les boutons appellent la même fonction, ce qui garantit qu'**aucune action n'existe seulement dans le jeu**. `AppCommand` est un `enum` exhaustif ; un test vérifie que **chaque cas** figure dans au moins un menu **et** dans la palette ⌘K (le raccourci est facultatif).

| Groupe | Action | Raccourci | Menu |
|---|---|---|---|
| Fichier | Nouveau post-it (titre, puis Entrée) | ⌘N (remplace `CommandGroup(replacing: .newItem)`, donc pas de « Nouvelle fenêtre ») | Fichier |
| | Nouvel agent dans le projet sélectionné | ⇧⌘N | Fichier |
| | Nouveau projet (sélecteur de dossier) ; ou dépôt d'un dossier sur la fenêtre | ⌥⌘N | Fichier |
| Tableau (focus) | Sélectionner un post-it | ↑ ↓ ← → | - |
| | Changer de colonne · réordonner | ⌘← / ⌘→ · ⌘↑ / ⌘↓ | Tâche |
| | Modifier · supprimer | ↩ · ⌘⌫ | Tâche |
| | Donner à… · au premier agent libre | ⌘D · ⇧⌘D | Tâche |
| | Valider · renvoyer avec une précision (↺) | ⌘↩ · ⌥⌘↩ | Tâche |
| Agents | Agent suivant · précédent (tous états) | ⌥⌘→ · ⌥⌘← | Aller |
| | Agent en attente suivant · précédent | ⌘' · ⇧⌘' (Tab reste réservé à l'accès clavier complet de macOS) | Aller |
| | Ouvrir la fenêtre de l'agent sélectionné | ↩ ou Espace (focus dans la scène) | Agent |
| | Ouvrir son terminal | ⌘T (onglets de fenêtre désactivés : `allowsAutomaticWindowTabbing = false`) | Agent |
| | Interrompre | ⌘. ; Échap dans la fenêtre agent **seulement si l'agent travaille** (5.8) | Agent |
| | Envoyer quand même (brouillon) | ⇧⌘↩ | Agent |
| | Relancer la session · reprendre la file · continuer la tâche | ⇧⌘R · menu · menu | Agent |
| | Mettre la file en pause · dupliquer · fermer la session | menu et ⌘K | Agent |
| Présentation | Afficher/masquer le tableau (panneau latéral ou plein écran) | ⌘B | Présentation |
| | Aller au projet n | ⌘1 … ⌘9 | Aller |
| | Zoom + / − · Tout voir | ⌘+ (ou ⌘=) / ⌘− · ⌘0 | Présentation |
| | Vue Liste (accessible, sans scène) | ⌘L | Présentation |
| | Mode édition du décor | ⇧⌘E (⌘E reste « Rechercher la sélection ») | Présentation |
| App | Palette de commandes · réglages | ⌘K · ⌘, | Aller · App |

Déplacement de la caméra à la souris et au clavier : voir 3.9. **AZERTY** : ⌘., ⌘' et ⌘1…⌘9 sont vérifiés sur un clavier français dans la checklist manuelle de l'étape 5 (⌘. se tape ⇧⌘; en AZERTY ; s'il gêne, ⌃⌘I est l'alternative réglable).

**Palette ⌘K** : correspondance approximative (`FuzzyMatcher` dans Core) sur les commandes, agents, projets et post-its. Les agents en attente apparaissent en premier.

### 3.17 SoundPlayer [Core synthèse + App lecture]

Les sons sont synthétisés en Swift pur au lancement (onde carrée à bande limitée, enveloppe ADSR), stockés dans des `AVAudioPCMBuffer` et joués par `AVAudioPlayerNode`.
- Le moteur audio démarre à la première lecture et se met en pause après 2 s de silence.
- Chaque lecture vérifie d'abord l'indicateur `muted`.
- Délai minimum de 10 s entre deux lectures d'un même son pour un même agent.
- Le moteur redémarre après un changement de périphérique audio (`AVAudioEngineConfigurationChange`).

### 3.18 Stores et coordinateurs [App]

- **`WorkspaceStore`** (`@Observable @MainActor`) : projets (avec leur slot), agents, historique des sessions, dernier processus, décor. Écrit par les commandes et par les effets `recordSession`, `recordProcess`, `updateSessionCwd`, `setQueuePaused`. Les visiteurs externes n'y sont **pas** persistés (5.7).
- **`ProgressStore`** : `ProgressState` ; n'applique que `ProgressRules`, sur l'effet de validation d'une carte.
- **`SettingsStore`** : `AppSettings`, lu par tous, écrit seulement par l'écran Réglages.
- **`WorldSceneCoordinator`** : construit le `WorldSnapshot` à partir des stores (`WorldLayout.compute` + `AgentPresenter.present`) et le passe à `WorldScene.apply` à la frame suivante ; il ne garde aucun état métier.
- **`TerminalPresenter`** : attribue à chaque `TerminalHost` un seul hôte d'affichage à la fois (3.1).

---

## 4. Modèle de données

### 4.1 Types (esquisses, `PixelCore/Model`)

```swift
// Identifiants typés (évite de confondre un AgentID et un ProjectID)
struct ProjectID: Hashable, Codable, Sendable { let raw: UUID }
struct AgentID:   Hashable, Codable, Sendable { let raw: UUID }       // stable, ≠ session_id de Claude
struct TaskCardID: Hashable, Codable, Sendable { let raw: UUID }
struct PromptTemplateID: Hashable, Codable, Sendable { let raw: UUID }
struct InstructionID: Hashable, Codable, Sendable { let raw: UUID }

struct Project: Codable, Identifiable, Sendable {
    let id: ProjectID
    var name: String                    // pancarte : 10 caractères affichés, puis « … »
    var path: String                    // chemin absolu standardisé (symlinks résolus)
    var hueIndex: Int                   // index dans Palette.projectHues (0…9)
    var order: Int                      // ordre de ⌘1…⌘9 et de la barre latérale (ne déplace pas l'îlot)
    var slot: Int                       // slot du monde attribué à la création, gardé à vie (3.8)
    var defaults: AgentDefaults         // modèle, mode de permission, template par défaut
    var createdAt: Date
    var archived: Bool
}
struct AgentDefaults: Codable, Sendable { var model: String?; var permissionMode: PermissionMode; var templateID: PromptTemplateID? }
enum PermissionMode: String, Codable, Sendable { case `default`, acceptEdits, plan, auto, dontAsk, bypassPermissions }

struct Agent: Codable, Identifiable, Sendable {
    let id: AgentID
    var projectID: ProjectID
    var name: String                    // généré (« Nova », « Bip », « Pixou »…), modifiable
    var deskIndex: Int                  // poste dans l'îlot, stable
    var look: AgentLook
    var model: String?                  // nil → défaut du projet → défaut de Claude
    var permissionMode: PermissionMode
    var worktree: String?               // nom passé à --worktree, optionnel
    var sessions: [SessionRef]          // journal (append seulement, écrit par effet) ; cible de reprise = le dernier
    var lastProcess: ProcessStamp?      // pid + heure de départ du dernier processus : détection des orphelins (2.5)
    var queuePaused: Bool               // la file elle-même n'est PAS stockée ici : elle se déduit des cartes (4.2)
    var origin: AgentOrigin             // toujours .app pour un agent persisté (les visiteurs externes restent en mémoire)
    var createdAt: Date
}
struct AgentLook: Codable, Hashable, Sendable { var skin: Int; var hairStyle: Int; var hairColor: Int
                                                var outfit: OutfitColor /* .project | .palette(Int) */; var accessory: Accessory? }
enum AgentOrigin: Codable, Sendable { case app, external(firstSeenPID: Int32?) }
struct ProcessStamp: Codable, Hashable, Sendable { var pid: Int32; var startedAt: Date }

struct SessionRef: Codable, Hashable, Sendable {
    var sessionID: String
    var cwd: String                     // dossier réel (worktree, CwdChanged) : --resume est lancé ici
    var startedAt: Date
    var source: SessionSource           // startup | resume | clear | compact | fork | unknown
    var endedAt: Date?
    var endReason: String?              // clear | resume | logout | prompt_input_exit | other | processExit
    var transcriptPath: String?
    var model: String?
}
enum SessionSource: String, Codable, Sendable { case startup, resume, clear, compact, fork, unknown }

// ---- État d'exécution (non persisté ; modifié uniquement par AgentStateMachine.reduce) ----
enum AgentPhase: Equatable, Sendable {   // stocké
    case offline(OfflineReason)         // pas de processus : .notStarted / .closedByUser / .appRelaunched / .exited / .orphanElsewhere
    case launching
    case idle
    case thinking
    case working(ToolKind)
    case done                           // tour terminé ; provisoire tant que pendingStop != nil
    case waitingBackground(tasks: Int, crons: Int)   // Stop avec tâches de fond ou crons : jamais d'envoi auto
    case quotaPaused(resetAt: Date?, autoResume: Bool) // limite d'usage : Claude Code reprendra (ou non) tout seul
    case error(AgentError)              // .api(type) / .account(type) / .crashed(Int32?) / .launchFailed(String)
}
enum AgentState: Equatable, Sendable {   // DÉRIVÉ, affiché : waitingInput si au moins une attente est ouverte
    case phase(AgentPhase), waitingInput(WaitReason /* la plus ancienne */, count: Int)
}
enum AgentStateKind: String, Sendable { case offline, launching, idle, thinking, working, waitingInput,
                                             waitingBackground, quotaPaused, done, error }   // compteurs, urgence
enum OfflineReason: String, Codable, Sendable { case notStarted, closedByUser, appRelaunched, exited, orphanElsewhere }
enum CardFlag: String, Codable, Sendable { case interrupted, deliveryFailed, turnFailed, sessionLost }
enum WaitKey: Hashable, Sendable { case tool(toolUseID: String), elicitation(String), notification(String), terminal }
enum WaitReason: Equatable, Sendable {
    case permission(tool: String, summary: String)   // PermissionRequest (immédiat)
    case question([AskedQuestion])                   // PreToolUse(AskUserQuestion) : questions, options, multiSelect
    case elicitation(server: String?, message: String)  // Elicitation (MCP)
    case notification(type: String)                  // Notification (rattrapage : permission_prompt, agent_needs_input,
                                                     //   quota_auto_resume_stale « appuie sur Entrée »…)
    case terminal                                    // heuristique : lancement silencieux (confiance dossier, login…)
}
struct PendingWait: Equatable, Sendable { var reason: WaitReason; var subagentID: String?; var since: Date }
enum ToolKind: Equatable, Sendable { case read, edit, bash, search, web, subagent, mcp(String), other(String)
    static func from(toolName: String) -> ToolKind }  // Read→read ; Edit/Write/NotebookEdit→edit ; Bash→bash ;
                                                        // Grep/Glob→search ; WebFetch/WebSearch→web ; Agent/Task→subagent ; mcp__x__y→mcp(x)
enum HookHealth: Equatable, Sendable { case unknown(since: Date), healthy, degraded }   // remplace hooksHealthy + degraded
struct AgentRuntime: Equatable, Sendable {
    var phase: AgentPhase
    var phaseSince: Date
    var pendingWaits: [WaitKey: PendingWait]      // plusieurs attentes possibles (outils parallèles, sous-agents)
    var inFlightTools: [String: ToolKind]         // tool_use_id → outil, principal et sous-agents
    var pid: Int32?                               // pid du PTY : seul claude_pid accepté pour cet agent
    var currentSessionID: String?                 // session vivante ; l'historique est Agent.sessions
    var currentPromptID: String?
    var lastHookAt: Date?
    var hookSeq: UInt64                           // n° du dernier événement accepté : garde « rien de nouveau » (5.6)
    var lastOutputAt: Date?
    var screen: ScreenFacts?                      // dernier relevé d'écran (zone de saisie, dialogue, spinner, quota)
    var hookHealth: HookHealth
    var pendingStop: PendingStop?                 // Stop reçu, pas encore confirmé (T13)
    var pendingDelivery: PendingDelivery?         // livraison en cours (entrées deliveryStarted / deliveryAborted)
    var interruptRequestedAt: Date?
    var activeSubagents: Int
    var acknowledgedWaiting: Bool                 // l'utilisateur a vu l'attente → « ! » moins envahissant
    var stale: Bool                               // aucune nouvelle depuis longtemps
    var state: AgentState { get }                 // dérivé de phase + pendingWaits
}
struct PendingStop: Equatable, Sendable { var at: Date; var promptID: String?; var stopHookActive: Bool
                                          var backgroundTasks: Int; var sessionCrons: Int }
struct PendingDelivery: Equatable, Sendable { var item: QueueItem; var prefix: String; var startedAt: Date
                                              var hookSeqAtStart: UInt64; var retried: Bool }

// ---- Tâches ----
enum Column: String, Codable, CaseIterable, Sendable { case todo, inProgress, review, done }  // À faire, En cours, À valider, Fait
enum Priority: Int, Codable, Sendable { case low = 0, normal = 1, high = 2 }               // punaise verte, jaune, rouge
struct TaskCard: Codable, Identifiable, Sendable {
    let id: TaskCardID
    var title: String
    var details: String                 // description courte
    var projectID: ProjectID?           // couleur du post-it = teinte du projet (neutre si nil)
    var column: Column
    var rank: String                    // ordre d'affichage dans la colonne
    var priority: Priority
    var tags: [String]
    var assignee: AgentID?              // SEULE source de l'assignation
    var queueRank: String?              // rang dans la file de l'assignee ; non nil ⇔ column == .todo ∧ assignee != nil
    var templateID: PromptTemplateID?
    var delivery: DeliveryInfo?         // tentative en cours ou dernière ; les précédentes vont dans history
    var flags: Set<CardFlag>            // .interrupted, .deliveryFailed, .turnFailed, .sessionLost
    var history: [CardEvent]            // (date, de, vers, par), lisible dans le détail du post-it
    var external: ExternalRef?          // plus tard : issue GitHub (numéro, URL) ; carte « externe » (5.5)
    var createdAt: Date; var updatedAt: Date
}
struct DeliveryInfo: Codable, Sendable { var sessionID: String?; var promptID: String?   // l'agent = assignee
                                         var sentAt: Date; var confirmedAt: Date?; var turnEndedAt: Date? }
struct QueuedInstruction: Codable, Identifiable, Sendable {   // consigne ad hoc (« Donner une consigne », ↺, reprise)
    let id: InstructionID; var agentID: AgentID; var text: String; var cardID: TaskCardID?; var createdAt: Date }
struct PromptTemplate: Codable, Identifiable, Sendable {
    let id: PromptTemplateID
    var name: String                    // « Corriger un bug »
    var body: String                    // « Corrige le bug suivant et ajoute un test : {description} »
}   // variables : {titre} {description} {projet} {chemin} {tags} {priorite}

// ---- Événements de hook (décodés, tolérants) ----
struct HookEvent: Equatable, Sendable {
    var name: HookEventName             // enum + .other(String)
    var sessionID: String
    var promptID: String?               // documenté (v2.1.196+), absent avant la première saisie
    var cwd: String?
    var transcriptPath: String?
    var permissionMode: String?
    var subagentID: String?             // champ agent_id (présent si l'événement vient d'un sous-agent)
    var payload: HookPayload
}
enum HookPayload: Equatable, Sendable {
    case sessionStart(source: String?, model: String?)
    case sessionEnd(reason: String?)
    case userPromptSubmit(promptHead: String, promptLength: Int)
    case preToolUse(tool: String, toolUseID: String?, summary: String)   // résumé : commande Bash, chemin de fichier…
    case askUserQuestion(toolUseID: String?, questions: [AskedQuestion]) // PreToolUse(AskUserQuestion), tool_input décodé
    case postToolUse(tool: String, toolUseID: String?, failed: Bool)
    case postToolBatch
    case permissionRequest(tool: String, toolUseID: String?, summary: String)
    case permissionDenied(tool: String?, toolUseID: String?)            // mode auto uniquement
    case notification(type: String?, message: String?)
    case stop(messageHead: String?, stopHookActive: Bool, backgroundTasks: Int, sessionCrons: Int)
    case stopFailure(errorType: String?, message: String?)             // rate_limit, overloaded, authentication_failed…
    case subagent(started: Bool, type: String?)
    case elicitation(server: String?, id: String?, message: String), elicitationResult(id: String?)
    case compact(pre: Bool)
    case cwdChanged(String)
    case other
}
struct AskedQuestion: Equatable, Sendable { var header: String; var question: String
                                            var options: [String]; var multiSelect: Bool }

// ---- Monde ----
struct DecorItem: Codable, Identifiable, Sendable { let id: UUID; var kind: DecorKind; var tile: GridPoint
                                                    var facing: Facing; var anchor: DecorAnchor /* .hall | .island(ProjectID) */ }
enum DecorKind: String, Codable, CaseIterable, Sendable { case plantSmall, coffeeMachine /* base */, cactus, espressoMachine,
    floorLamp, plantBig, posterMountain, posterWave, posterRobot, aquarium, rug, bookshelf, sofa, arcade, waterCooler }
struct IslandPlacement: Equatable, Sendable { var projectID: ProjectID; var origin: GridPoint; var size: GridSize
                                              var sign: GridPoint; var desks: [DeskPlacement] }
struct DeskPlacement: Equatable, Sendable { var index: Int; var deskTile: GridPoint; var seatTile: GridPoint
                                            var facing: Facing; var agentID: AgentID? }

// ---- Progression & réglages ----
enum BadgeID: String, Codable, CaseIterable, Sendable { case firstTask, fiveParallel, tenInADay, threeIslands,
                                                          earlyBird, zeroWait, hundredTasks, nightOwl }
struct AppSettings: Codable, Sendable {
    var schemaVersion: Int
    var claudePathOverride: String?
    var defaultModel: String?; var defaultPermissionMode: PermissionMode
    var disableAgentViewInEmbedded: Bool          // true
    var forceClassicRenderer: Bool                // false (respecte ton réglage)
    var disableNonessentialTraffic: Bool          // false
    var extraEnv: [String: String]
    var autoChainQueue: Bool                      // true
    var sendGraceSeconds: Double                  // 1.5
    var stopQuietWindowSeconds: Double            // 3 (doublée si stop_hook_active)
    var quickAnswerHeuristics: Bool               // true (réponses rapides par touches, voir 5.8)
    var notifications: NotificationPrefs          // attente: toujours ; fin de tour: si app en arrière-plan ;
                                                  // hideDetails: false (écran verrouillé)
    var sounds: SoundPrefs                        // attente+fin: on (30 %), autres: off
    var gamificationEnabled: Bool                 // true
    var nightMode: NightMode                      // .followSystem | .alwaysDay | .alwaysNight
    var defaultZoom: Int                          // 2 (0 = vue d'ensemble)
    var reduceMotion: Bool                        // suit Accessibilité macOS par défaut
    var terminal: TerminalPrefs                   // police, taille, optionAsMeta(false), scrollback(2000)
    var eventLogEnabled: Bool                     // false : journal local des hooks pour débogage
}
```

### 4.2 Relations et propriétaires

```
Project 1 ──── * Agent 1 ──── * SessionRef          (journal des session_id, avec cwd)
   │                 ▲
   │                 └──(assignee, queueRank)── TaskCard   ◄── la file d'un agent se DÉDUIT de là
   └──── * TaskCard (projectID, facultatif)       QueuedInstruction ──(agentID)──► Agent
DecorItem ──► .hall ou .island(ProjectID)            ProgressState ──► agentXP[AgentID]
```

**Un fait = un propriétaire = un seul chemin d'écriture** :

| Fait | Propriétaire | Modifié uniquement par | Dérivés (jamais stockés ailleurs) |
|---|---|---|---|
| Projets, slot, teinte, ordre | `WorkspaceStore` | commandes | îlots (`WorldLayout`) |
| Agent (nom, poste, apparence, modèle, mode, worktree) | `WorkspaceStore` | commandes | - |
| Journal des sessions, dernier processus | `WorkspaceStore` | effets `recordSession`, `endSession`, `updateSessionCwd`, `recordProcess` émis par `AgentStateMachine.reduce` | cible de reprise = `sessions.last` |
| File en pause | `Agent.queuePaused` | commandes « Mettre en pause / Reprendre la file », effet `setQueuePaused` | - |
| Phase, attentes, outils en vol, session vivante, `Stop` provisoire, livraison en cours, santé des hooks, relevé d'écran | `AgentRuntime` | `AgentStateMachine.reduce` (entrées `AgentInput`, y compris `deliveryStarted` / `deliveryAborted`) | `state`, `AgentPresentation`, compteurs |
| Colonne, assignation, rang de file, drapeaux, livraison et historique d'une carte ; consignes en file | `TaskStore` | `TaskLifecycle.reduce` (entrées `TaskInput`, dont les effets `cardEvent` de l'agent) | file d'un agent = consignes, puis cartes `todo ∧ assignee == a`, par `queueRank` |
| Texte, tags, priorité, modèle d'une carte ; modèles de prompt | `TaskStore` | éditeur de post-it | prompt composé |
| XP, badges, déblocages | `ProgressStore` | `ProgressRules`, sur l'effet de validation | niveau |
| Réglages | `SettingsStore` | écran Réglages | - |
| Écran et octets du terminal | SwiftTerm (`TerminalHost`) | le PTY | `ScreenFacts` (entrée `.screen`) |

Invariants vérifiés par `WorkspaceValidator` au chargement **et** par des tests de propriétés sur les réducteurs :
- un agent appartient à un projet existant ; deux projets n'ont pas le même slot ;
- `deskIndex` est unique dans un îlot ;
- `queueRank != nil` ⇔ `column == .todo ∧ assignee != nil` ;
- au plus une carte « En cours » par agent.

### 4.3 Machine à états des agents (`AgentStateMachine.reduce`)

Conventions :
- « principal » signifie que l'événement **ne vient pas** d'un sous-agent (`subagentID == nil`) ;
- **acceptation** : pour un agent de l'app, un événement n'est accepté que si `claude_pid` = `runtime.pid`. Un `claude` imbriqué lancé par l'agent hérite de `PIXEL_AGENT_ID` : ses événements sont ignorés. Un nouveau `session_id` n'est adopté que par un `SessionStart` de ce processus (T2, T3), jamais implicitement ;
- tout événement accepté met à jour `lastHookAt`, incrémente `hookSeq` et passe `hookHealth` à `.healthy` ;
- l'état affiché est **dérivé** : `waitingInput` dès que `pendingWaits` n'est pas vide, sinon la phase ;
- aucun ordre n'est supposé entre outils : attentes et outils en vol sont appariés par `tool_use_id`.

| # | Entrée | Garde | Nouvelle phase | Effets et champs |
|---|---|---|---|---|
| T1 | `processStarted(pid, start)` | - | `launching` | `pid` ; `recordProcess` |
| T2 | `hook SessionStart(source)` | principal | `idle`, ou `thinking` si un prompt initial a été passé | `recordSession(id, source, cwd)` ; la carte initiale passe « En cours » au `UserPromptSubmit` correspondant, ou dès ce `SessionStart` si ce hook ne part pas pour un prompt positionnel (⚠️ S3) |
| T3 | `hook SessionStart(compact \| clear \| resume)` | principal | inchangée (`clear` → `idle`) | nouvelle `SessionRef` seulement si l'id change |
| T4 | `hook UserPromptSubmit` | principal | `thinking` | `pendingStop = nil` ; toutes les attentes levées ; si `pendingDelivery` et que le prompt commence par son préfixe : `cardEvent(deliveryConfirmed(promptID))`, `pendingDelivery = nil` ; `acknowledged` |
| T5 | `hook PreToolUse(AskUserQuestion)` | - | inchangée | attente `.tool(id)` = `.question(questions)` ; `notify(.waiting)`, `playSound(.alert)`, `announce` |
| T6 | `hook PreToolUse(tool)` | principal | `working(ToolKind(tool))` | `inFlightTools[id]` ; `pendingStop = nil` (voir T13c) |
| T7 | `hook PreToolUse / PostToolUse` | sous-agent | inchangée | `inFlightTools` mis à jour ; activité (garde le poste animé) |
| T8 | `hook PermissionRequest(tool, id)` | principal **ou** sous-agent | inchangée | attente `.tool(id)` = `.permission` ; `notify(.waiting)`, `playSound(.alert)`, `announce`, badge Dock |
| T9 | `hook Notification(permission_prompt \| agent_needs_input \| elicitation_dialog)` | aucune attente ouverte | inchangée | attente `.notification(type)` (**rattrapage**, si `PermissionRequest` a été manqué) ; notifier |
| T10 | `hook Notification(idle_prompt)` | phase ∈ {`thinking`, `working`} | `idle` | `reconcile` (un `Stop` a été manqué) |
| T11 | `hook Elicitation(id)` | - | inchangée | attente `.elicitation(id)` = `.elicitation(server, message)` ; notifier |
| T12 | `hook PostToolUse / PostToolUseFailure / PermissionDenied` (même `tool_use_id`) ; `ElicitationResult` | - | principal : `thinking` (affichage lissé sur 300 ms) | retire l'attente et l'outil de même id ; si `failed` : effet visuel « bouffée de fumée » |
| T12b | `hook PostToolBatch` | - | inchangée | retire toutes les attentes `.tool` de ce même agent (principal ou sous-agent) : couvre un refus manuel, qui ne produit ni `PostToolUse` ni `PermissionDenied` (⚠️ S5) |
| T13 | `hook Stop(stopHookActive, bg, crons)` | principal | `done`, affiché tout de suite | `pendingStop` rempli ; attentes et outils principaux vidés ; **aucun effet sur la carte ni la file** |
| T13b | `tick` ou `screen` | `pendingStop` ∧ aucun événement principal depuis 3 s (6 s si `stopHookActive`) ∧ écran : zone de saisie visible, pas de spinner | `bg > 0` ou `crons > 0` → `waitingBackground(bg, crons)` ; sinon `done` confirmé | `pendingStop = nil`. Si `bg > 0` : `cardEvent(turnWaitingBackground)`. Sinon : `cardEvent(turnCommitted(promptID))`, `playSound(.done)`, `notify(.done)` si l'app est en arrière-plan, et `pumpQueue(after: 1.5 s)` **seulement si** `crons == 0` |
| T13c | événement principal autre que `Notification` | `pendingStop ≠ nil`, ou `Stop` confirmé et même `prompt_id` sans `UserPromptSubmit` | selon la ligne concernée | le tour continuait (hook `Stop` bloquant, `/goal`) : `pendingStop = nil` ; si le `Stop` avait déjà été confirmé : `cardEvent(turnReopened(promptID))` |
| T14 | `hook StopFailure(rate_limit)` | - | `quotaPaused(resetAt, autoResume: true)` (`resetAt` lu à l'écran, ⚠️ S5) | attentes levées ; `globalIssue(.quota)` : **une** bannière pour tous ; la carte reste « En cours », étiquette « en pause : quota » |
| T14b | `hook StopFailure(authentication_failed \| oauth_org_not_allowed \| account_on_hold \| billing_error)` | - | `error(.account(type))` | `globalIssue(.account)` : **un** bandeau et **une** notification pour tous les agents |
| T14c | `hook StopFailure(autre type)` | - | `error(.api(type))` | `cardEvent(turnFailed)` ; notifier |
| T14d | `hook Notification(quota_auto_resume_fired)` | phase = `quotaPaused` | `thinking` | le tour repris par Claude Code se termine par un `Stop` normal (T13) ; `globalIssue` levé quand plus aucun agent n'est en pause |
| T14e | `hook Notification(quota_auto_resume_stale \| _disabled)` | phase = `quotaPaused` | `_stale` : inchangée + attente `.notification` (« Limite réinitialisée : appuie sur Entrée dans le terminal ») ; `_disabled` : `quotaPaused(autoResume: false)` | la carte propose « Continuer la tâche » |
| T15 | `hook SubagentStart / SubagentStop` | - | inchangée | `activeSubagents ± 1` (mini-avatar) |
| T16 | `hook PreCompact / PostCompact` | - | inchangée | overlay « range son bureau » |
| T17 | `hook SessionEnd(reason ∈ {clear, resume})` | - | inchangée | `endSession` (le `SessionStart` suivant portera le nouvel id) |
| T18 | `hook SessionEnd(autre)` | - | inchangée | `endSession` ; on attend la fin du processus |
| T19 | `processExited(0)` | - | `offline(.exited)` | attentes, outils, `pendingStop`, `pendingDelivery` vidés ; `cardEvent(sessionLost)` |
| T20 | `processExited(≠0 ou signal)` | - | `error(.crashed(code))` | idem T19 ; notifier |
| T21 | `processFailedToStart` | - | `error(.launchFailed)` | - |
| T22 | `userInterrupt` (bouton, ⌘., Échap dans la fenêtre agent) | phase ∈ {`thinking`, `working`} ∧ aucune attente ∧ aucune livraison en cours | inchangée | `interruptRequestedAt` ; `setQueuePaused(true)` ; `cardEvent(interrupted)` : la carte **reste En cours**. `SessionManager.interrupt` n'écrit l'octet `ESC` que si cette garde passe |
| T22b | `tick` ou `screen` | `interruptRequestedAt` ∧ aucune sortie PTY depuis 1 s ∧ aucun `PreToolUse` depuis ∧ écran : zone de saisie visible, pas de spinner | `idle` | `interruptRequestedAt = nil`. Si Échap a envoyé des messages en file, le `UserPromptSubmit` qui suit applique T4 |
| T22c | `tick` | `interruptRequestedAt` depuis plus de 3 s, sans effet (spinner, `PreToolUse`) | inchangée | « L'interruption n'a pas pris : ouvre le terminal » ; **pas** de second `ESC` (Échap Échap ouvre le retour arrière) |
| T23 | `userKeystroke(k)` | - | inchangée | attente ouverte : `acknowledgedWaiting = true` (« ! » plus discret), touche ignorée pour le brouillon ; sinon `resampleScreen` (relevé 300 ms plus tard) |
| T24 | `acknowledged` (fenêtre agent ou terminal ouverts) | `done` confirmé | `idle` | - |
| T24b | `tick` | `done` confirmé depuis 10 min | `idle` | l'écran garde une petite coche (`screen.done`) jusqu'au tour suivant ; la carte reste « À valider » |
| T25 | `tick` | `launching` depuis > 8 s ∧ aucune sortie depuis 3 s | inchangée | attente `.terminal` : « Regarde le terminal » |
| T26 | `tick` | `launching` depuis > 15 s ∧ aucun hook | inchangée | `hookHealth = .degraded`, bandeau (4.4) |
| T27 | `tick` | `thinking`/`working` ∧ aucun hook depuis 10 min ∧ aucune sortie depuis 2 min | inchangée | `stale = true` (« ? »), `reconcile` |
| T28 | `screen(facts)` | - | inchangée | `screen = facts` ; une attente `.notification` ou `.terminal` est levée si aucun dialogue n'est visible depuis 2 s et que la zone de saisie l'est |
| T29 | `hook CwdChanged(cwd)` | principal | inchangée | `updateSessionCwd(cwd)` |
| T30 | `deliveryStarted(p)` | phase ∈ {`idle`, `done` confirmé} ∧ aucune attente ∧ `pendingStop == nil` | inchangée | `pendingDelivery = p` (sinon refus : le dispatcher n'écrit rien) |
| T31 | `deliveryAborted(raison)` | `pendingDelivery ≠ nil` | inchangée | `pendingDelivery = nil` ; `cardEvent(deliveryFailed(raison))` ; `setQueuePaused(true)` |

**Détecter `waiting_input`** : trois sources, par ordre de priorité.
1. `PermissionRequest` : immédiat, une attente par `tool_use_id`, sous-agents compris.
2. `PreToolUse(AskUserQuestion)` et `Elicitation` : immédiats, avec la question décodée.
3. `Notification(permission_prompt | agent_needs_input | elicitation_dialog)` : rattrapage, environ 6 s plus tard.

**Lever une attente** : l'attente d'id X est levée par ce qui résout X : `PostToolUse`, `PostToolUseFailure` ou `PermissionDenied` du même `tool_use_id`, `ElicitationResult`, `PostToolBatch` du même agent. Toutes les attentes sont levées par `UserPromptSubmit`, `Stop`, `StopFailure`, une interruption confirmée ou la fin du processus. Une attente de rattrapage (`notification`, `terminal`) est levée par tout événement principal hors `Notification`, ou par l'écran (T28). **Une frappe seule ne lève jamais l'attente** : elle l'atténue (T23). Tests dédiés : deux outils parallèles dont un seul attend, sous-agent en attente pendant que le principal travaille, refus manuel.

**États dérivés, pour l'affichage uniquement** (`AgentPresenter`) :
- **endormi** : `idle` depuis plus de 10 min ;
- **étirement ou café** : animation d'inactivité tirée au hasard, de façon déterministe à partir de l'ID de l'agent, toutes les 45 à 90 s ;
- **`done`** : `celebrate` une seule fois, puis `sitIdle` avec `ov.check` ;
- **« ? »** : `stale` ;
- **hors ligne** et **lancement** : jamais confondus avec « endormi » : chaise vide avec la veste, écran et lampe éteints, plaque « OFF » ; puis écran `screen.boot` et arrivée par l'ascenseur. Le texte d'infobulle et de VoiceOver le dit (« Oslo, hors ligne, peut être relancé »), et la barre d'état les compte (`⏻`, `⏏`).

**Urgence**, pour la barre d'état, le plateau d'attente et la mini-carte : `waitingInput` = 3, `error` = 2, `done`, `waitingBackground` et `quotaPaused` = 1, tout le reste = 0.

### 4.3b Cycle de vie des post-its (`TaskLifecycle.reduce`)

Réducteur pur `(TaskBoardState, TaskInput) → (TaskBoardState, [TaskEffect])`. Ses entrées viennent de tes actions ou des effets `cardEvent` de l'agent assigné. « Assignée en file » = `todo ∧ assignee ≠ nil ∧ queueRank ≠ nil`.

| # | Entrée | Garde | Colonne et champs | Effets |
|---|---|---|---|---|
| C1 | `create` (⌘N, collage de liste) | - | `todo`, non assignée | - |
| C2 | `assign(agent)` | `todo` ; même projet ; agent de l'app | `assignee = agent`, `queueRank` = fin de file | `pump(agent)` |
| C3 | `assign(agent)` d'un autre projet | confirmation « Nova travaille dans ~/dev/site » | comme C2 ; `projectID` = projet de l'agent (noté dans l'historique) | `pump(agent)` |
| C4 | `unassign` · `reassign(b)` · réordonner | `todo` | `assignee = nil` ou `b` ; `queueRank` recalculé | `pump(b)` |
| C5 | `assign`, `reassign` ou glisser vers « En cours » d'une carte `inProgress`, `review` ou `done` | - | refusé (curseur interdit + explication : « glisse-la sur un agent » ou « remets-la d'abord à faire ») | - |
| C6 | `deliveryStarted` | carte en tête de file | inchangée ; `delivery = {sessionID, sentAt}` | - |
| C7 | `deliveryConfirmed(promptID)` | `delivery` en attente | **`inProgress`** ; `queueRank = nil` ; `delivery.promptID` | - |
| C8 | `deliveryFailed(raison)` | - | reste `todo`, en tête ; drapeau `deliveryFailed` | notifier (la file de l'agent est déjà en pause, T31) |
| C9 | `retry` (bouton « Réessayer ») | drapeau `deliveryFailed` | drapeau retiré | reprise de la file, `pump` |
| C10 | `turnCommitted(promptID)` | `inProgress` ∧ même `promptID` (ou premier `Stop` après C7) | **`review`** ; `turnEndedAt` | - |
| C11 | `turnWaitingBackground` | `inProgress` | inchangée ; étiquette « tâche de fond en cours » | - |
| C12 | `turnReopened(promptID)` | `review` ∧ même `promptID` ∧ pas encore validée | **`inProgress`** | - |
| C13 | `turnFailed` · `interrupted` · `sessionLost` | `inProgress` | inchangée ; drapeau correspondant | actions proposées : « Continuer la tâche », « Remettre à faire », « Marquer à valider » |
| C14 | `continueTask` | `inProgress` avec drapeau ∧ agent vivant | drapeaux retirés | consigne « Continue la tâche : <titre> » **en tête de file** de l'assignee ; reprise de la file ; `pump` |
| C15 | `putBack` (« Remettre à faire », glisser vers « À faire ») | `inProgress` ou `review` | `todo`, non assignée, drapeaux retirés ; `delivery` versée à l'historique | si l'agent travaille encore sur ce tour, il n'est **pas** interrompu, et son `Stop` n'affectera plus la carte |
| C16 | `markForReview` (glisser vers « À valider ») | `inProgress` | `review` | - |
| C17 | `resend(précision)` (↺) | `review` | inchangée jusqu'au `deliveryConfirmed` de la précision, puis `inProgress` (nouveau `promptID`) | consigne « précision » en tête de file du **même agent** ; si sa session a changé depuis la livraison, avertissement ; agent hors ligne : « Relancer la session » d'abord |
| C18 | `validate` (⌘↩, glisser vers « Fait ») | `review` ; depuis `todo` ou `inProgress` : confirmation « Marquer fait » | `done` | effet de validation → `ProgressRules` : XP **une seule fois par carte**, et seulement si elle a été livrée au moins une fois |
| C19 | `reopen` | `done` | `todo`, non assignée | aucune XP retirée ni redonnée |
| C20 | `delete` | `inProgress` : confirmation | supprimée | comme C15 pour le tour en cours |

Invariants, un test de propriétés chacun (séquences aléatoires d'entrées) : au plus une carte `inProgress` par agent (« Reprendre la file » exige d'abord de trancher une carte interrompue) ; `queueRank ≠ nil` ⇔ `todo ∧ assignee ≠ nil` ; un `Stop` ne déplace que la carte dont le `promptID` correspond ; une carte `done` ne reçoit jamais de livraison ; l'XP d'une carte n'est comptée qu'une fois ; une carte « externe » (import GitHub) n'est jamais livrée sans ta confirmation.

### 4.4 Replis quand les hooks manquent (mode dégradé)

On passe en mode dégradé si aucun hook n'arrive dans les 15 s qui suivent le lancement. Causes possibles : politique gérée (`allowManagedHooksOnly`, `disableAllHooks`), `--settings` ignoré, ou helper manquant. Le poste affiche alors un petit panneau « mode dégradé » et **l'envoi automatique est coupé** pour cet agent (garde G1, 5.6). `claude agents --json` n'est **pas** une source ici : il ne liste pas les sessions interactives, et la vue agents est désactivée dans nos sessions (1, ligne 21). Les signaux sont combinés par ordre de fiabilité :

1. **Cycle de vie du processus** (fiable) : `processTerminated`, `processFailedToStart`.
2. **Activité du PTY** : de la sortie dans les 1,5 dernières secondes → `working` ; silence → `idle`. Pas de distinction `thinking`/`working`.
3. **`BEL`** : `bell(source: Terminal)` est surchargée dans `AgentTerminalView`. Cela n'a un effet que si tu as réglé `preferredNotifChannel: "terminal_bell"`. On peut aussi le passer dans le `--settings` de l'app ; c'est un réglage scalaire, pour cette session seulement.
4. **Motifs d'écran** (`ScreenPatterns`) : les lignes visibles sont lues à 1 Hz pour reconnaître le dialogue de permission, le spinner, la zone de saisie et la ligne de limite d'usage. Ces motifs sont **versionnés par version de Claude Code et désactivables**. Leur fragilité est documentée : l'interface de Claude Code change, et plusieurs projets tiers se sont cassés sur ces motifs. Les mêmes motifs servent aux gardes de livraison (5.6) en mode normal.

### 4.5 Fichiers et versionnage

```
~/Library/Application Support/PixelOpenSpace/
├── state/
│   ├── workspace.json      { "schemaVersion": 1, "projects": [...], "agents": [...], "decor": [...] }
│   ├── tasks.json          { "schemaVersion": 1, "cards": [...], "templates": [...] }
│   ├── progress.json       { "schemaVersion": 1, "userXP": 0, "badges": {...}, "unlocked": [...], "daily": {...} }
│   └── settings.json       { "schemaVersion": 1, ... AppSettings ... }
├── backups/
│   ├── state/2026-09-30/workspace.json …          (5 rotations max par fichier)
│   └── claude-settings/2026-09-30T10-12-03Z-user.json   (avant toute installation globale)
├── run/                    (0700)
│   ├── hook.sock           (0600, recréé à chaque lancement)
│   ├── token               (0600, jeton des sessions externes ; régénéré à chaque lancement)
│   └── hooks-settings.json (0600, passé à --settings ; régénéré à chaque lancement)
├── bin/pixel-hook          (copie stable, uniquement si installation globale ; sort aussitôt si PIXEL_AGENT_ID est défini)
├── Sprites/                (tes PNG de remplacement, voir 7.7)
└── logs/                   (journal local des hooks si activé ; rotation 7 jours)
```

**Versionnage** : chaque fichier porte un `schemaVersion`. Au chargement, `Migrator` applique les migrations `v → v+1` une par une. Chaque migration a sa fixture de test (JSON de la version n → résultat attendu en n+1). Un fichier dont la version est **plus récente** que l'app est ouvert en lecture seule, avec un avertissement : on ne l'écrase jamais.

---

## 5. Intégration Claude Code en pratique

### 5.1 Lignes de commande exactes

Toutes les options viennent de https://code.claude.com/docs/en/cli-reference.md. L'app lance `claude` **sans shell intermédiaire** : `execve` avec un chemin absolu et un tableau d'arguments, ce qui évite tout problème d'échappement.

**Nouvel agent** :
```text
executable : /Users/toi/.local/bin/claude                       (résolu par ClaudeLocator)
arguments  : --settings "/Users/toi/Library/Application Support/PixelOpenSpace/run/hooks-settings.json"
             --session-id 3f0c7e9a-5b1d-4c62-9e0f-2a7d1b8c4e55     (UUID valide, documenté ; contrôle rapide S2)
             --name api-nova                                       (titre du terminal + reprise par nom)
             --model sonnet                                        (si défini pour l'agent ou le projet)
             --permission-mode default                             (défaut de l'app)
             [--worktree nova]                                     (option par agent)
             ["Corrige le bug suivant et ajoute un test : …"]      (1er post-it, prompt positionnel)
cwd        : /Users/toi/dev/api
env        : PATH=<PATH du shell de connexion> HOME USER SHELL LANG=fr_FR.UTF-8
             TERM=xterm-256color COLORTERM=truecolor
             PIXEL_AGENT_ID=9c1d…  PIXEL_HOOK_TOKEN=<32 octets aléatoires hex>  PIXEL_HOOK_SOCKET=<…/run/hook.sock>
             CLAUDE_CODE_DISABLE_AGENT_VIEW=1                       (décision 11)
             [CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1]           (option, décision 15)
             [CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1]               (option « rendu classique »)
retiré     : CLAUDECODE, TERM_PROGRAM*, ITERM_*, KITTY_*, GHOSTTY_*, DYLD_*, PWD, OLDPWD, SHLVL, _
```

**Autres modes** :

| Mode | Arguments ajoutés (en plus de `--settings`, `--name`, du modèle et du mode) | Quand |
|---|---|---|
| Reprendre | `--resume <dernier session_id de l'agent>`, lancé dans `SessionRef.cwd` | Relance de l'app, bouton « Relancer la session ». Refusé si un processus vivant détient encore cet id (2.5) ; dossier disparu → fork dans le dossier du projet |
| Continuer | `--continue` | Seulement pour un agent sans historique connu. Avec plusieurs agents dans le même dossier, « la plus récente conversation du dossier » est ambiguë : l'app préfère `--resume` |
| Dupliquer | `--resume <id> --fork-session` | « Dupliquer l'agent » : un nouveau poste part du même contexte, avec un nouvel id |
| Modèle | `--model opus\|sonnet\|haiku\|<id complet>` | Par agent ; le menu propose les alias de la doc et un champ libre |
| Permissions | `--permission-mode default\|acceptEdits\|plan\|auto\|dontAsk\|bypassPermissions` | Par agent. `bypassPermissions` demande une confirmation explicite, et le poste affiche un panneau « sans garde-fou » |

Le bouton « Copier la commande » du panneau agent donne l'équivalent shell (avec `cd` vers le bon dossier), **sans le jeton**, pour déboguer dans ton propre terminal. Si la session tourne encore dans l'app, il avertit : deux processus sur la même conversation écriraient dans le même transcript.

### 5.2 Hooks injectés (`run/hooks-settings.json`, régénéré à chaque lancement de l'app)

```json
{
  "hooks": {
    "SessionStart":       [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "SessionEnd":         [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "UserPromptSubmit":   [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PreToolUse":         [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PostToolUse":        [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PostToolBatch":      [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PermissionRequest":  [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PermissionDenied":   [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "Notification":       [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "Stop":               [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "StopFailure":        [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "SubagentStart":      [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "SubagentStop":       [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "Elicitation":        [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "ElicitationResult":  [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PreCompact":         [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "PostCompact":        [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }],
    "CwdChanged":         [{ "hooks": [{ "type": "command", "command": "'/Applications/Pixel Open Space.app/Contents/Helpers/pixel-hook'", "timeout": 3 }] }]
  }
}
```

- **Forme « shell »** avec chemin entre apostrophes, parce que le chemin du bundle contient des espaces. `HookSettingsBuilder` échappe le chemin en POSIX (chaque `'` devient `'\''`), avec des tests sur des chemins à espaces, apostrophes et accents. La forme « exec » (`command` + `args`) est décrite par une seule source (⚠️) : on ne l'utilise pas.
- **`matcher` omis** = « tous » (✔ « `"*"`, `""`, or omitted : Match all », https://code.claude.com/docs/en/hooks.md). Le type de `Notification` est filtré côté app, pas par `matcher`, pour ne rien rater si de nouveaux types apparaissent.
- **Jamais** `WorktreeCreate`/`WorktreeRemove`, qui remplacent le comportement git. On écarte aussi `MessageDisplay` (trop bavard), `FileChanged`, `ConfigChange`, `InstructionsLoaded`, `PreModelSwitch`, `PostModelSwitch`, `Setup`, `UserPromptExpansion` (nos envois ne commencent jamais par `/`), `TaskCreated`, `TaskCompleted`, `TeammateIdle` et `DirectoryAdded`, dont on n'a pas besoin.
- **Synchrone** (pas d'`"async": true`), ce qui ordonne les événements d'un même outil (pas ceux d'outils parallèles, 3.2). `timeout: 3` n'est qu'un plafond : `pixel-hook` rend la main en quelques millisecondes, bien en deçà du budget de 1,5 s partagé par les hooks `SessionEnd`.
- **Aucun effet sur le comportement de Claude** : aucune sortie, donc aucune décision et aucun contexte injecté.
- **Repli si le spike S1 montre que `--settings` remplace tes hooks** au lieu de s'y ajouter : même contenu dans un plugin généré (`run/plugin/.claude-plugin/plugin.json` + `run/plugin/hooks/hooks.json`), chargé par `--plugin-dir` (https://code.claude.com/docs/en/plugins/overview.md). ⚠️ Le modèle de confiance des hooks de plugin n'est pas documenté.

### 5.3 Pourquoi un hook `command` + `pixel-hook` + socket Unix (et pas des hooks `http`)

| Critère | Hook `http` → 127.0.0.1 | Hook `command` → `pixel-hook` → socket Unix (**choisi**) |
|---|---|---|
| Support de `SessionStart` | ✗ `SessionStart` n'accepte que `command` et `mcp_tool` (doc) | ✔ `command` est accepté pour tous les événements |
| Transmission de `PIXEL_AGENT_ID` et du jeton | Seulement via les en-têtes + `allowedEnvVars`, eux-mêmes restreignables par `httpHookAllowedEnvVars` en politique gérée | Héritage direct de l'environnement (✔ doc) |
| Restrictions de politique | `allowedHttpHookUrls` peut bloquer l'URL | Seules `disableAllHooks` et `allowManagedHooksOnly` s'appliquent (communes aux deux) |
| Surface d'attaque | Port TCP local, joignable par tout processus et par une page web (CSRF, DNS rebinding) : il faut filtrer `Origin`/`Host` | Fichier 0600 dans un dossier 0700, uid du pair vérifié, aucun port |
| « Local Network » (macOS 15+) | Le loopback est exempté selon Apple, mais le port reste à découvrir | Sans objet |
| App fermée | Échec de connexion, « erreur non bloquante », peut-être affichée | `pixel-hook` sort silencieusement en code 0 |
| Coût | Aucun processus lancé | Un processus Swift par événement (~5–15 ms, ⚠️ S9), acceptable même avec 20 agents |
| Ordre | Synchrone (bloque jusqu'à la réponse) | Synchrone ; appariement par `tool_use_id` dans les deux cas |

### 5.4 Comportement de `pixel-hook` (pseudo-code)

```text
main:
  si argv contient --pixel-open-space-managed et $PIXEL_AGENT_ID est défini :
      drainer stdin ; exit 0                          # installation globale : session de l'app ou claude imbriqué
  deadline = now + 300 ms
  raw = read(stdin jusqu'à EOF ; garder 4 Mo, jeter le reste)   # en cas d'échec : exit 0
  hook = parse JSON (sinon {"_unparsed": true, "len": n})
  tronquer : tool_output, tool_response, assistant_message, last_assistant_message → 4 Ko ; prompt → 4 Ko (+ prompt_len)
  env = { agent: $PIXEL_AGENT_ID?, token: $PIXEL_HOOK_TOKEN ?? lire(App Support/run/token)?,
          claude_pid: premier ancêtre non-shell, ts_ns: horloge monotone, v: 1 }
  socket = $PIXEL_HOOK_SOCKET ?? chemin par défaut
  sendOnce(json(env + {hook}) + "\n", socket, deadline)    # ignore toute erreur
  exit 0                                                   # jamais de stdout ni de stderr
```

### 5.5 Sécurité et confidentialité

- **Aucune écoute réseau** : ni port TCP ni Bonjour. Seul le socket Unix existe, en 0600 dans un dossier 0700, avec vérification de l'uid du pair.
- **Modèle de menace, honnêtement** : la vraie frontière est **ton uid** (socket 0600 dans un dossier 0700, uid du pair vérifié). Le jeton par lancement de l'app (32 octets aléatoires, transmis par l'environnement du PTY, jamais par argv) n'ajoute rien contre un processus de ton propre compte, qui peut lire l'environnement d'un autre de tes processus (`ps -E`) ou `run/token` : il sert seulement à écarter les événements d'un lancement précédent de l'app (processus orphelins, 2.5). Comparé à temps constant. Les sessions externes lisent le jeton dans `run/token` (0600).
- **Aucun trafic sortant de l'app** : ni télémétrie, ni rapport de crash, ni vérification de mise à jour. Le seul trafic est celui de `claude` lui-même vers son fournisseur, comme dans ton terminal habituel. L'import GitHub de l'étape 7 passera par **ton** `gh` local, à ta demande explicite.
- **Jamais d'approbation automatique** : ni confiance de dossier, ni serveur MCP, ni permission. Plusieurs outils tiers le font ; c'est un anti-modèle.
- **Nettoyage** : les post-its sont purgés des caractères de contrôle (5.6), ce qui empêche un titre piégé d'injecter des séquences clavier dans le terminal.
- **Texte venu d'ailleurs** : une issue importée de GitHub (étape 7) est un texte non fiable qui deviendra un prompt, peut-être pour un agent en mode `auto` ou `bypassPermissions` (injection de prompt). Ces cartes portent la marque « externe », ne sont **jamais** livrées automatiquement, et la première livraison demande un aperçu du prompt composé et ta confirmation.
- **Notifications** : le réglage « Masquer les détails » évite d'afficher commandes et chemins sur l'écran verrouillé (3.12).
- **Journaux locaux** désactivés par défaut. Une fois activés, ils sont tronqués et effacés par rotation au bout de 7 jours.
- **Info.plist** : `NSLocalNetworkUsageDescription` est présent. Si **Claude** contacte une machine de ton réseau local (serveur de dev, base de données), macOS attribue la demande à notre app, puisque `claude` en est un processus enfant. La même attribution vaut probablement pour les accès à Documents et Bureau (⚠️ non confirmé par une source Apple).

### 5.6 Envoyer un post-it dans le PTY : livraison gardée

**Gardes** (`DeliveryPlan.evaluate`, pur, testé). Une garde qui échoue = **abandon**, jamais « on essaie quand même » :
- **G1 état** : processus vivant, `hookHealth == .healthy`, phase `idle` ou `done` confirmé, aucune attente ouverte, aucun `Stop` provisoire, ni `waitingBackground` ni `quotaPaused`, file non en pause.
- **G2 rien de nouveau** : aucun événement de hook accepté pour cet agent depuis le début de la livraison (`hookSeq`). Le `HookServer` tient aussi un compteur atomique par agent, relu **juste avant chaque écriture**, pour fermer la course avec un événement reçu mais pas encore traité par le MainActor. Un `PermissionRequest`, `PreToolUse` ou `UserPromptSubmit` arrivé entre-temps fait donc échouer la garde.
- **G3 écran** : un relevé de moins de 100 ms (`ScreenFacts`) montre la zone de saisie, **vide** avant le texte (sinon : brouillon) et **contenant notre préfixe** avant l'Entrée, sans motif de dialogue, de spinner ni de ligne « Usage limit reached ». Écran non reconnu (motifs d'une autre version de Claude Code) → échec, avec le bandeau « Envoi automatique suspendu : écran non reconnu ».
- **G4 calme** : aucune sortie PTY depuis 300 ms. Si la TUI redessine en permanence une ligne d'état, G3 suffit : le silence du PTY ne bloque jamais la file à lui seul.

« Envoyer quand même » ne lève que la partie « zone de saisie vide » de G3 ; il ne contourne jamais G1, G2 ni la détection de dialogue.

**Nettoyage** (`PromptSanitizer`, pur, testé) :
1. `CRLF` et `CR` deviennent `LF`. Les tabulations deviennent deux espaces, car une tabulation peut déclencher la complétion.
2. On retire `ESC`, les caractères C0 (sauf `LF`), `DEL` et les C1. Retirer `ESC` supprime du même coup toute séquence `ESC[201~` capable de fermer un collage.
3. On retire les caractères Unicode invisibles : largeur nulle, contrôles bidi, BOM. Claude Code les enlève lui-même à l'appui sur Entrée, puis remet le texte nettoyé dans la zone de saisie et **attend un second Entrée** (https://code.claude.com/docs/en/terminal-config.md).
4. Si le texte commence par `!` (mode shell, exécuté **sans** approbation), `/` (commande), `?` (aide) ou `@` (complétion de chemin), on le préfixe par « Tâche : » (https://code.claude.com/docs/en/interactive-mode.md).
5. On retire les sauts de ligne finaux. Au-delà de 16 Ko, l'app demande confirmation.

**Plan d'envoi** (`DeliveryPlan`, en deux phases) :

| Étape | Écriture PTY | Détail |
|---|---|---|
| 0 | - | `reduce(.deliveryStarted)` (T30) ; mémorise `hookSeq` |
| 1 | **Garde `beforeText`** : G1 à G4 | Échec → `deliveryAborted` : carte « échec d'envoi », file en pause ; rien n'a été écrit |
| 2 | **Texte court** (≤ 800 caractères et ≤ 3 lignes) : le texte **saisi**, lignes séparées par `LF` (= Ctrl+J = saut de ligne) | Envoyé comme une frappe, sans marqueurs de collage. Claude le traite comme un message que tu as tapé |
| 2 | **Texte long** : une phrase d'amorce **saisie**, « Réalise la tâche décrite dans le texte collé ci-dessous. », puis `ESC[200~` + corps + `ESC[201~` | Seulement si `bracketedPasteMode` est vrai (lu dans SwiftTerm). La doc prévient qu'un collage replié est présenté à Claude comme un texte que tu n'as peut-être pas écrit : l'amorce saisie l'autorise explicitement à le suivre |
| 3 | Attente de la fin d'écriture (`LocalProcess.send(data:completion:)`), puis délai d | d = 120 ms (< 500 o), 250 ms (< 2 Ko), 500 ms (< 16 Ko), 1 s au-delà. Un bug connu perd le collage si une touche arrive dans le même bloc que la fin du collage (issue anthropics/claude-code #91205) |
| 4 | **Garde `beforeEnter`** : G1, G2 (aucun événement depuis l'étape 0), G3 (notre préfixe visible dans la zone de saisie, aucun dialogue) | Échec → abandon **sans Entrée**. Le texte reste dans la zone de saisie : la carte indique « texte laissé dans le terminal, vérifie-le », et la zone passe en « brouillon », ce qui bloque toute autre livraison automatique. L'app n'efface jamais rien (pas de Ctrl+U) |
| 5 | `\r` **seul, dans une écriture distincte** | - |
| 6 | Attente de `UserPromptSubmit`, 3 s au plus | Son `prompt` doit commencer par les 40 premiers caractères normalisés du texte envoyé : la carte passe alors « En cours » (C7) |
| 7 | Sinon : **garde `beforeRetryEnter`** (G1, G2, G3 avec le préfixe toujours visible) | Réussie → **un seul** `\r` de plus, puis 3 s d'attente. Sinon, ou toujours rien : `deliveryAborted`, carte `deliveryFailed` dans « À faire », notification |

**Pourquoi deux gardes** : une Entrée isolée qui tomberait sur un dialogue de permission validerait l'option en surbrillance (« 1. Oui »), et des chiffres ou `y`/`n` tapés pourraient choisir une option ; ce serait une approbation automatique, que la décision 10 interdit. Or une session au repos peut démarrer un tour seule : tâche de fond qui se termine, `/loop` ou cron, reprise après une limite d'usage, hook `Stop` bloquant ou `/goal`. Claude Code n'ouvre pas de dialogue sans avoir d'abord émis un `PreToolUse` ou un `PermissionRequest`, que notre hook synchrone reçoit **avant** l'affichage : G2 le voit. La fenêtre de course restante est celle entre la relecture du compteur atomique et l'appel à `write`. Le spike S3b provoque exprès ces cas pendant une livraison.

Points non confirmés, couverts par les spikes S3 et S3b :
- ⚠️ Claude Code active-t-il toujours le collage entre crochets (DECSET 2004) ?
- ⚠️ Un `LF` brut insère-t-il vraiment un saut de ligne ? Un outil basé sur tmux a observé des lignes fusionnées.
- ⚠️ Quel délai minimal fonctionne ?
- ⚠️ `UserPromptSubmit` se déclenche-t-il pour le prompt positionnel, et pour un tour relancé par un cron ou une tâche de fond ?
- ⚠️ Motifs de la zone de saisie, du spinner et des dialogues pour ta version de Claude Code (`ScreenPatterns`).

Si le collage entre crochets est inactif, un texte long est **refusé** (« trop long pour un envoi sûr »), avec le bouton « Ouvrir le terminal ». Jamais d'envoi à l'aveugle.

**Sémantique de la file** :
- **Ordre** : consignes ad hoc d'abord, puis post-its en FIFO, réordonnables par glisser dans la fenêtre agent. 1 élément par tour. Délai de grâce de 1,5 s après un `Stop` **confirmé**, avec enchaînement automatique (réglable).
- **Pas d'envoi** pendant `waitingInput`, `waitingBackground`, `quotaPaused`, `error`, `offline`, en mode dégradé, ni quand la zone de saisie n'est pas vide à l'écran.
- **Consigne ad hoc** (« Donner une consigne ») :
  - agent libre : envoi immédiat, par la même livraison gardée ;
  - agent occupé : placée **en tête** de file ;
  - bouton secondaire « Glisser dans le tour en cours » : il écrit dans le PTY occupé en utilisant la file native de Claude Code, qui transmet le message « dans le même tour », après les appels d'outils en cours (https://code.claude.com/docs/en/interactive-mode.md). **Interdit** pendant une attente, quand un dialogue ou la ligne de limite d'usage est à l'écran, ou si l'écran n'est pas reconnu. G2 et G3 (zone de saisie visible, spinner permis) sont vérifiées avant le texte **et** avant l'Entrée. L'infobulle précise qu'Échap enverrait aussitôt ce message en file.
- **Interruption** : la file se met en pause. La carte **reste « En cours »** avec le drapeau « interrompue » et trois actions : « Continuer la tâche », « Remettre à faire », « Marquer à valider » (4.3b, C13 à C16). Rien n'est renvoyé automatiquement.
- **Limite d'usage** : pendant `quotaPaused`, rien n'est livré et « Interrompre » est désactivé (Échap sur un prompt vide annulerait la reprise automatique). La file repart d'elle-même après le premier tour confirmé qui suit `quota_auto_resume_fired`.
- **L'app n'envoie jamais** de flèches (`←` sur un prompt vide met la session en arrière-plan : https://code.claude.com/docs/en/agent-view.md), ni Ctrl+C, ni Ctrl+D, ni Ctrl+U, ni de touche de navigation hors des réponses rapides.

### 5.7 Changements de `session_id`, processus imbriqués et sessions externes

- **Sessions lancées par l'app** : la corrélation se fait par `PIXEL_AGENT_ID` **et** un `claude_pid` égal au pid du PTY. L'`AgentID` reste le même quels que soient `/clear`, `/resume` dans la TUI, `/compact` ou un fork. Chaque `SessionStart` **de ce processus** dont l'id est nouveau ajoute une `SessionRef` avec sa `source` et son `cwd`. « Relancer la session » utilise le **dernier** id, dans son dossier. L'historique complet s'affiche dans la fenêtre agent.
- **Processus imbriqués** : `PIXEL_AGENT_ID`, `PIXEL_HOOK_TOKEN` et `PIXEL_HOOK_SOCKET` sont hérités par tout ce que lance l'outil Bash de l'agent, y compris un `claude` ou `claude -p` imbriqué (script, Agent SDK). S'il charge des hooks (installation globale, `settings.local.json` du projet), ses événements portent l'`AgentID` du parent mais un autre `claude_pid` : ils sont **ignorés**, jamais adoptés, et « Relancer » ne peut donc pas reprendre la mauvaise conversation.
- **Doublons** : une fois l'installation globale active, une session de l'app recevrait chaque événement deux fois, car l'entrée globale a une autre commande (copie dans `bin/` + sentinelle) et la doc ne dédoublonne que des handlers identiques. Double protection : le `pixel-hook` global sort aussitôt quand `PIXEL_AGENT_ID` est défini (5.4), et le serveur dédoublonne par (`session_id`, événement, `tool_use_id`, fenêtre de 50 ms). Sinon : notifications, sons et envois en double.
- **Sessions externes** (installation globale, sans `PIXEL_AGENT_ID`) :
  - la corrélation se fait par `claude_pid`, fourni par `pixel-hook` et stable à travers `/clear`, puis par `session_id` ;
  - le projet est trouvé par `cwd` : on prend le projet dont le chemin est le plus long préfixe du `cwd`. Sinon, l'avatar va dans un îlot « Visiteurs » près de l'ascenseur ;
  - ces avatars ont un contour en pointillés et un panneau « terminal externe ». On ne peut **ni** y envoyer de post-it **ni** ouvrir leur terminal, puisque l'app ne possède pas leur PTY ;
  - l'app affiche seulement leur état et leurs notifications ;
  - **en mémoire seulement** : ils ne sont pas persistés, et leur poste disparaît 10 min après `SessionEnd` ou la fin du processus ;
  - la réutilisation d'un PID est détectée par un nouveau `SessionStart(startup)` ;
  - **limite** : au démarrage de l'app, une session externe qui attend déjà n'apparaît qu'à son prochain événement. L'app lit alors en lecture seule la fin des transcripts modifiés dans les 10 dernières minutes pour afficher un indice « peut-être en attente » (format interne, au mieux).

### 5.8 Interrompre et répondre vite

- **Interrompre** (bouton, ⌘., Échap dans la fenêtre agent) : seulement si l'agent travaille, sans attente ni pause de quota (T22). Écrit l'octet `0x1B` seul, puis **vérifie l'effet** (T22b) : PTY calme, aucun nouveau `PreToolUse`, zone de saisie revenue. `Stop` ne se déclenche pas dans ce cas (https://code.claude.com/docs/en/hooks.md). Deux pièges documentés (https://code.claude.com/docs/en/interactive-mode.md) : Échap envoie aussitôt les messages en file, donc un nouveau tour peut commencer (T4) ; et si un élément du pied de page est sélectionné, Échap le désélectionne sans interrompre. Au bout de 3 s sans effet, l'app le dit et propose le terminal, **sans** second `ESC` (T22c).
- **Échap dans la fenêtre agent** : n'interrompt que si l'agent travaille, avec l'indication « Échap : interrompre » visible et un toast « Interruption dans 1,5 s · [Annuler] » avant l'envoi de l'octet. Sinon, Échap ferme la fenêtre, comme partout sur macOS. Le bouton et ⌘. interrompent sans délai.
- **Permission en attente** : la fenêtre agent affiche, depuis `PermissionRequest`, l'outil et un résumé de `tool_input` (commande Bash, chemin du fichier, URL), ce qui est fiable. Les boutons proposés :
  - **« Refuser (Échap) »** : documenté, Échap équivaut à Non. L'octet n'est écrit que si le dialogue est visible à l'écran à cet instant.
  - **« Ouvrir le terminal »** : toujours présent, c'est la voie sûre.
  - **Boutons d'option**, par exemple « 1. Oui », « 2. Oui, et ne plus demander… », « 3. Non… » : seulement si les lignes visibles du terminal correspondent au motif `^\s*[❯>]?\s*([1-9])\.\s+(.+)$`. Chaque bouton reprend **le texte exact affiché par Claude** et envoie le chiffre correspondant, après avoir revérifié que le même dialogue est toujours affiché. C'est une heuristique versionnée et désactivable (⚠️ S7), car le rendu du dialogue n'est pas documenté.
  - **Jamais** d'approbation silencieuse, jamais de flèches.
- **Question de Claude** (`AskUserQuestion`) : la fenêtre agent affiche **la question elle-même**, décodée de `tool_input.questions` : en-tête, texte, options, choix multiple ou non (maquette 6(e′)). Des boutons d'option n'apparaissent qu'une fois que le spike S7 a confirmé la correspondance touches ↔ options de ce dialogue ; sinon, « Ouvrir le terminal ». **Dialogue MCP** (`Elicitation`) : le `message` du serveur est affiché, avec « Ouvrir le terminal ».
- **Plus tard (étape 7, optionnel)** : un mode « Décider depuis l'app » avec un hook `PermissionRequest` **bloquant**, qui renvoie `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`. C'est la voie **officielle** pour décider (https://code.claude.com/docs/en/hooks.md). En contrepartie, pendant l'attente du hook, le dialogue du terminal ne s'affiche probablement pas (⚠️). D'où un délai de 30 s, après lequel le hook rend la main au dialogue normal.

### 5.9 Installation globale optionnelle (consentement, sauvegarde, désinstallation)

1. Dans Réglages › Claude Code, « Voir aussi les sessions lancées hors de l'app… ».
2. Choix de la portée :
   - utilisateur : `~/.claude/settings.json` ;
   - projet local : `<projet>/.claude/settings.local.json`, normalement non versionné (⚠️ vérifie ton `.gitignore`).
3. Dialogue de consentement (maquette 6(g)), qui affiche **en clair et sans clic supplémentaire** trois choses :
   - **ce qui est écrit** : nombre d'entrées, chemin exact du fichier, chemin de la sauvegarde ;
   - **quelles données circulent** : nom de l'outil, extrait de la commande, dossier et identifiant de session, uniquement vers le socket local ;
   - **comment annuler**.

   Un diff avant/après est dépliable.
4. Installation : sauvegarde, puis écriture atomique (3.3), puis relecture et vérification de `status == .installed`. Les sessions ouvertes prennent en compte le changement en quelques secondes, car les settings sont rechargés à chaud.
5. Désinstallation : un bouton dans les réglages et une commande dans ⌘K. Seules les entrées portant la sentinelle `--pixel-open-space-managed` sont retirées.
6. Si tu supprimes l'app sans désinstaller, les hooks restent **inoffensifs** : le `pixel-hook` copié dans `bin/` ne trouve plus de socket et sort en code 0. Un `LISEZMOI.txt` dans `bin/` explique comment les retirer.

### 5.10 Découverte de l'historique : robustesse

- **Lecture seule, tolérante**, ligne par ligne. Une ligne invalide est ignorée, la dernière ligne partielle aussi : des corruptions (NUL, enregistrements entremêlés) sont connues (issues #81843, #49876).
- **Aucune dépendance au schéma** : seuls `cwd`, les horodatages et, *s'ils sont présents*, les titres sont exploités. Tout le reste est ignoré.
- **Jamais sur le chemin critique** : l'état vient des hooks, la reprise utilise `--resume <id>` que l'app connaît déjà. La découverte ne sert qu'à « Reprendre une ancienne conversation » et à peupler un nouveau projet.
- **Transcripts purgés** : au-delà de `cleanupPeriodDays` (30 jours par défaut), un `--resume` peut échouer. L'app le détecte (le processus sort vite sans `SessionStart`) et propose une nouvelle session.

### 5.11 Spikes de l'étape 2 (valider les points ⚠️ sur ton Mac)

Un script `Tools/spikes/run-spikes.sh` exécute ces tests avec ta vraie installation, dans un dossier jetable, et produit un rapport texte que tu me recolles. **Il ne modifie aucun de tes fichiers** : les hooks « déjà existants » simulés sont placés dans le `.claude/settings.local.json` d'un dossier projet jetable, jamais dans ton `~/.claude`.

**Ce que le script exécute, précisément** : il crée `$TMPDIR/pos-spikes-<date>/` (un dépôt git vide, deux fichiers texte) ; il lance `claude` dans une PTY pilotée par un petit programme Swift (celui de `fake-claude`, en mode enregistreur), avec les hooks de l'app pointés vers un journal ; il envoie des prompts courts et sans risque (« lis a.txt », « exécute `ls` », « crée b.txt ») en mode `default`, et capture les événements, les lignes d'écran et les délais. Rien ne tourne en `bypassPermissions`. **Coût estimé** : une trentaine de tours courts avec le modèle `haiku`, soit une petite fraction d'une session de travail ; S3b et S11 sont optionnels, car plus longs. **Repli manuel** si tu préfères ne pas le lancer : une checklist de 12 manipulations à faire dans ton terminal habituel avec `PIXEL_HOOK_DEBUG=1`, dont tu me colles le journal.

| Spike | Question | Décision qui en dépend |
|---|---|---|
| S1 | Les hooks passés par `--settings` **s'ajoutent-ils** à ceux des settings utilisateur ? | `--settings` ou repli `--plugin-dir` |
| S2 | Contrôle rapide : le `session_id` de `SessionStart` est-il bien celui passé par `--session-id` (documenté) ? | Aucune (l'app n'en dépend pas) |
| S3 | Saisie courte avec `LF`, amorce + collage entre crochets, délai minimal avant `\r`, `UserPromptSubmit` pour le prompt positionnel ; motifs `ScreenPatterns` (zone de saisie vide, brouillon, spinner, dialogue) ; **répondre à une permission par « 1 », puis vérifier que l'enchaînement automatique repart** | Paramètres de `DeliveryPlan`, gardes G3/G4 |
| S3b | **Livraison sous perturbation** : pendant une livraison, faire finir une tâche de fond (`run_in_background`), armer un `/loop` ou un cron, activer `/goal`, installer un hook `Stop` bloquant de test, provoquer une permission. Vérifier que les gardes abandonnent, qu'aucune Entrée ne tombe sur un dialogue, que `Stop` porte `background_tasks`/`session_crons` et qu'un tour relancé est bien détecté | Gardes G1/G2, T13 à T13c |
| S4 | `session_id` après `/clear`, `/compact`, `/resume`, `--resume`, `--fork-session` ; `cwd` avec `--worktree` | Tests de la machine à états, reprise |
| S5 | Champs réels de `PermissionRequest`, `Stop`, `StopFailure`, `Notification` ; événements après un **refus manuel** (`PostToolUseFailure` ? `PostToolBatch` ?) ; ligne de limite d'usage à l'écran | Décodeur, T12b, T14 |
| S6 | *(retiré : la doc répond déjà, `claude agents --json` ne liste pas les sessions interactives)* | - |
| S7 | Lignes visibles du dialogue de permission **et** du dialogue `AskUserQuestion` (captures) ; touches qui choisissent chaque option | Motifs des réponses rapides, boutons de question |
| S8 | Glisser un `Transferable` SwiftUI vers un `NSDraggingDestination` AppKit ; sinon, décodage direct de l'UTI par `WorldView` | Glisser-déposer vers la scène |
| S9 | Latence de `pixel-hook` (p50, p95) | Tolérance « < 1 s » |
| S10 | Les hooks de `--settings` tournent-ils **avant** l'acceptation de la confiance du dossier ? | T25/T26 |
| S11 | 20 sessions réelles au repos pendant 10 min, mesurées dans Instruments : CPU et mémoire de l'app, rendu de SwiftTerm hors écran, redessins de la TUI au repos | Budgets d'énergie (3.9), garde G4 |

---

## 6. Maquettes ASCII

Les maquettes sont en police à chasse fixe ; les libellés sont ceux prévus dans l'app. Les symboles ASCII (`(!)`, `[#]`…) remplacent ici les sprites.

### (a) Fenêtre principale : barre d'état, plateau d'attente, open space isométrique (3 îlots, disposition schématique), mini-carte (étape 3+)

```text
┌─ Pixel Open Space ───────────────────────────────────────────────────────────────────────────────┐
│ [+ Projet] [+ Agent] [▤ Tableau ⌘B] [⌘K Palette]     Zoom [ x1 |▸x2◂| x3 ]   [☾ Auto]  [⚙]       │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ (!) 2 ATTENDENT │ [#] 4 travaillent │ (…) 1 réfléchit │ [✓] 2 tours finis │ z 2 repos │ ✖ 1 ⏏ 1  │
│ ▾ EN ATTENTE   (!) Nova · API · Bash : rm -rf dist · 0:42     (!) Sol · INFRA · Question · 2:10  │
├──────────────────────────────────────────────────────────────────────────────────────────────────┤
│ ┌─────── MUR DE LIÈGE · 12 post-its ───────┐             ┌────┐ ascenseur   [café]   [plante]    │
│ │ ▪ ▪▪  ▪ ▪▪▪  ▪  ▪▪ ▪   ▪▪▪ ▪ ▪▪  ▪ ▪▪ ▪  │             │ ▒▒ │ Lou arrive → îlot SITE WEB       │
│ └──────────────────────────────────────────┘             └────┘                                  │
│                                                                                                  │
│                ╔═ API ═╗                                        ╔═ SITE WEB ═╗                   │
│                _.-'`'-._                                           _.-'`'-._                     │
│           _.-'`         `'-._                                 _.-'`         `'-._                │
│      _.-'` ▣Nova(!) ▣Bip[#]  `'-._                       _.-'` ▣Pixou[#] ▣Tao z  `'-._           │
│ _.-'`     ▣Lune(…)  ▣Kiwi[#]      `'-._             _.-'`       ▣Mika[✓]   ▣←Lou      `'-._      │
│ `'-._        ▣Oslo[✓]  ▣ ·        _.-'`             `'-._         ▣ ·    ▣ ·          _.-'`      │
│      `'-._     ▣ ·   ▣ ·     _.-'`                       `'-._     ▣ ·   ▣ ·     _.-'`           │
│           `'-._ ▫▫ file _.-'`                                 `'-._         _.-'`                │
│                `'-._.-'`                                           `'-._.-'`                     │
│                                                                                                  │
│                                                                                                  │
│                                         ╔═ INFRA ═╗                                              │
│                                          _.-'`'-._                                               │
│                                     _.-'`         `'-._                                          │
│                                _.-'` ▣Zéphyr✖ ▣Ada[#]  `'-._                                     │
│                           _.-'`      ▣Rio z    ▣Sol(!)      `'-._                                │
│                           `'-._         ▣ ·     ▣ ·         _.-'`                                │
│                                `'-._     ▣ ·   ▣ ·     _.-'`                                     │
│                                     `'-._         _.-'`                ┌ mini-carte ──────────┐  │
│ ┌ survol ───────────────────────────┐    `'-._.-'`                     │  ▦▦▦▦      ▦▦▦▦      │  │
│ │ Nova · API · ATTEND TA RÉPONSE (!)│                                  │  A !●…●✓   S ●z✓⏏    │  │
│ │ Bash : rm -rf dist · depuis 42 s  │                                  │       I ✖●z!         │  │
│ │ clic : fenêtre · double : terminal│                                  │  [▭ zone visible]    │  │
│ └───────────────────────────────────┘                                  └──────────────────────┘  │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Légende des marqueurs d'état (dans l'app, chaque état a **une forme, une animation et une couleur**, jamais la couleur seule) :
`(!)` attend ta réponse (gros « ! » jaune qui rebondit, avatar debout main levée) · `(…)` réfléchit (bulle « … ») · `[#]` travaille (tape, écran qui défile, icône de l'outil) · `[✓]` tour terminé, à regarder (coche verte, petite célébration ; à ne pas confondre avec la colonne « À valider » des post-its) · `z` au repos / endormi · `✖` erreur (nuage d'orage ou fumée) · `(⧗)` attend une tâche de fond · `(◷)` en pause : limite d'usage · `⏏` arrive (lancement, écran qui démarre) · `⏻` hors ligne (chaise vide, veste, écran et lampe éteints, plaque « OFF ») · `▣ ·` poste libre (clic = « Nouvel agent ici ? ») · `▣←Lou` poste réservé à un agent qui arrive · `▫▫` post-its en file posés sur le bureau.
La barre d'état est cliquable. Dès qu'un agent attend, la ligne « ▾ EN ATTENTE » (plateau d'attente, 3.9) liste **qui attend quoi et depuis quand** ; clic sur une entrée = vol de caméra + fenêtre agent ; ⌘' passe à l'attente suivante. Un agent en attente hors du champ est signalé par une flèche « ! » au bord de la scène. Chaque compteur (✖, ⏏, ⏻…) filtre les agents concernés ; les compteurs à zéro sont masqués. L'infobulle de survol répète l'état **en texte**. Sur la mini-carte, chaque point porte le glyphe de son état, jamais la couleur seule.

### (b) MVP de l'étape 2 : SwiftUI simple, sans graphismes (2a : agents, états, terminal ; 2b : + tableau)

```text
┌─ Pixel Open Space · MVP (étape 2) ───────────────────────────────────────────────────────────────┐
│ (!) 1 attend · [#] 3 travaillent · (…) 1 réfléchit · [✓] 1 tour fini · z 1 repos   ⌘K   ⌘B   ⚙   │
├────────────────┬────────────────────────────────────────────────┬────────────────────────────────┤
│ PROJETS        │ API · ~/dev/api                     [+ Agent]  │ TABLEAU     [Projet : tous ▾]  │
│ ■ API        2 │ ┌─────────────────────┐ ┌────────────────────┐ │ [Chercher…]         [+ ⌘N]     │
│ ■ Site web   2 │ │ Nova          (!)   │ │ Bip          [#]   │ │ À FAIRE (3)                    │
│ ■ Infra      2 │ │ ATTEND TA RÉPONSE   │ │ Bash · npm test    │ │ ┌────────────────────────────┐ │
│                │ │ Bash : rm -rf dist  │ │ depuis 2 min       │ │ │◉ Corriger le login    API  │ │
│ [+ Projet]     │ │ [Terminal] [Échap]  │ │ file : 1 post-it   │ │ └────────────────────────────┘ │
│                │ └─────────────────────┘ └────────────────────┘ │ ┌────────────────────────────┐ │
│ HORS LIGNE (0) │ SITE WEB · ~/dev/site               [+ Agent]  │ │◉ Pagination /users    API  │ │
│                │ ┌─────────────────────┐ ┌────────────────────┐ │ └────────────────────────────┘ │
│                │ │ Pixou         [#]   │ │ Tao           z    │ │ EN COURS (2)                   │
│                │ │ Edit · header.tsx   │ │ au repos 14 min    │ │ ┌────────────────────────────┐ │
│ HOOKS          │ │ ▣ Refonte du header │ │ file vide          │ │ │◉ Refonte header  SITE ☺Pix │ │
│ ● actifs 6/6   │ └─────────────────────┘ └────────────────────┘ │ └────────────────────────────┘ │
│                │ INFRA · ~/dev/infra                 [+ Agent]  │ À VALIDER (1)                  │
│                │ ┌─────────────────────┐ ┌────────────────────┐ │ ┌────────────────────────────┐ │
│                │ │ Ada           (…)   │ │ Sol          [✓]   │ │ │◉ MAJ Terraform INFRA [Ok]  │ │
│                │ │ réfléchit…          │ │ tour terminé       │ │ └────────────────────────────┘ │
│                │ └─────────────────────┘ └────────────────────┘ │ FAIT (5) ▸                     │
├────────────────┴────────────────────────────────────────────────┴────────────────────────────────┤
│ TERMINAL · Nova (API) · session 7d2f…        [Détacher ⤢]  [Interrompre ⌘.]  [Masquer ×]         │
│ ┌──────────────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ (interface de Claude Code telle quelle, rendue par SwiftTerm : couleurs, souris, clavier)    │ │
│ │ … ici, le dialogue de permission que Nova attend …                                           │ │
│ └──────────────────────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Ce MVP n'a pas de scène isométrique : des cartes d'agents regroupées par projet, avec état en icône SF Symbols + texte, un tableau à 4 colonnes et un terminal intégré. Glisser un post-it du tableau sur une carte d'agent l'assigne. La section « HORS LIGNE » liste les agents à relancer (bannière de 2.5) ; « Reprendre une ancienne conversation » (sessions passées découvertes sur disque) n'arrive qu'à l'étape 5. Tout ce qui est montré ici reste disponible plus tard comme **vue « Liste »** (⌘L), qui sert aussi de chemin principal pour VoiceOver.

### (c) Tableau de liège en plein écran (⌘B ; aussi en panneau latéral)

```text
┌─ Tableau de liège (⌘B) ──────────────────────────────────────────────────────────────────────────┐
│ Projet [Tous ▾]  État [Tous ▾]  Tags [#bug ×]   [Chercher : login          ]     [+ Post-it ⌘N]  │
├────────────────────────┬────────────────────────┬────────────────────────┬───────────────────────┤
│ À FAIRE             4  │ EN COURS            2  │ À VALIDER           2  │ FAIT              17  │
│ ┌──────────────────◉┐  │ ┌──────────────────◉┐  │ ┌──────────────────◉┐  │ ┌─────────────────◉┐  │
│ │ Corriger le login │  │ │ Refonte du header │  │ │ MAJ Terraform 1.9 │  │ │ README install   │  │
│ │ Le jeton OAuth    │  │ │ Nouveau logo +    │  │ │ Plan OK, 3 res.   │  │ │ ✓ validé 09:12   │  │
│ │ expire trop tôt.  │  │ │ menu mobile.      │  │ │ modifiées.        │  │ │ ☺ Bip  · API     │  │
│ │ #bug #auth    API │  │ │ #ui         SITE  │  │ │ #infra     INFRA  │  │ └──────────────────┘  │
│ │ ☺Nova · file #2   │  │ │ ☺Pixou · 6 min    │  │ │ ☺Rio · fini 2 min │  │ ┌─────────────────◉┐  │
│ └───────────────────┘  │ └───────────────────┘  │ │ [Valider ⌘↩] [↺]  │  │ │ Lint CI          │  │
│ ┌──────────────────◉┐  │ ┌──────────────────◉┐  │ └───────────────────┘  │ │ ✓ validé 08:47   │  │
│ │ Pagination /users │  │ │ Rotation des logs │  │ ┌──────────────────◉┐  │ └──────────────────┘  │
│ │ 20 par page.      │  │ │ (!) Sol attend    │  │ │ Doc de l'API      │  │          …            │
│ │ #api          API │  │ │ #infra     INFRA  │  │ │ #doc          API │  │                       │
│ │ non assigné       │  │ │ ☺Sol · 11 min     │  │ │ ☺Bip · fini 9 min │  │                       │
│ └───────────────────┘  │ └───────────────────┘  │ └───────────────────┘  │                       │
│  ↑ glisser un post-it  │                        │                        │                       │
│    sur un agent, ou    │                        │                        │                       │
│    clic droit ›        │                        │                        │                       │
│    « Donner à… »       │                        │                        │                       │
├────────────────────────┴────────────────────────┴────────────────────────┴───────────────────────┤
│ Coller une liste = un post-it par ligne · ⌘N nouveau · Entrée valide le titre · Échap annule     │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

`◉` = punaise : rouge (haute), jaune (normale), verte (basse). La couleur du post-it est celle du projet, et la priorité est aussi écrite au survol. Les post-its « À valider » portent le bouton **Valider** (⌘↩) et `↺` (« Renvoyer à l'agent avec une précision »). Au survol, un post-it frétille de 1 px ; au dépôt, la punaise s'enfonce (2 frames).

### (d) Fenêtre agent rétro (clic sur un avatar)

```text
╔═[▦]═ Nova · API ════════════════════════════════════════════════[×]═╗
║ ┌──────────┐  État    : [#] TRAVAILLE : Bash                        ║
║ │  avatar  │  Tâche   : Corriger le login OAuth                     ║
║ │  32×56   │  Depuis  : 4 min 12 s        Tour : 3 outils           ║
║ │  (anim.) │  Modèle  : sonnet            Permissions : default     ║
║ └──────────┘  Session : 7d2f…  (historique : 3 sessions ▸)          ║
╟─────────────────────────────────────────────────────────────────────╢
║ Donner une consigne                                                 ║
║ ┌───────────────────────────────────────────────────┐ ┌──────────┐  ║
║ │ ajoute aussi un test pour le refresh token_       │ │ Envoyer ↩│  ║
║ └───────────────────────────────────────────────────┘ └──────────┘  ║
║ Occupé : la consigne passera en tête de file. [Glisser dans le tour]║
╟─────────────────────────────────────────────────────────────────────╢
║ File de post-its (glisser pour réordonner)       [⏸ Mettre en pause]║
║  ▸ 1. ◉ Corriger le login OAuth            en cours                 ║
║    2. ◉ Pagination /users                  [↑] [↓] [Retirer]        ║
║    3. ◉ Doc des erreurs 401                [↑] [↓] [Retirer]        ║
╟─────────────────────────────────────────────────────────────────────╢
║ [Terminal ⌘T] [Interrompre ⌘.] [Relancer la session] [Fermer]       ║
╚═════════════════════════════════════════════════════════════════════╝
```

**Modèle de fenêtre** : un `NSPanel` réutilisable par agent (au plus un ouvert par agent, plusieurs agents à la fois), avec le comportement standard de macOS (déplacer, redimensionner, ⌘W, Mission Control) sous un habillage rétro : barre de titre à la couleur du projet, biseaux, boutons en relief qui s'enfoncent, bouton de fermeture pixel exposé à l'accessibilité comme un vrai bouton « Fermer ». L'avatar animé est rendu en `Image` pixel (`.interpolation(.none)`). Échap = Interrompre **seulement si l'agent travaille** (5.8), sinon Échap ferme ; ⌘T = terminal.

**Boutons actifs selon l'état** (les autres sont grisés, avec la raison en infobulle) :

| État | Terminal | Interrompre | Relancer la session | Reprendre la file | Continuer la tâche | Envoyer quand même | Fermer |
|---|---|---|---|---|---|---|---|
| `thinking` / `working` | ✔ | ✔ | - | si en pause | - | - | ✔ (confirmation) |
| `waitingInput` | ✔ | - (utiliser « Refuser ») | - | si en pause | - | - | ✔ (confirmation) |
| `idle` / `done` | ✔ | - | - | si en pause | si carte signalée | si brouillon | ✔ |
| `waitingBackground` | ✔ | - | - | - | - | ✔ (confirmation) | ✔ (confirmation) |
| `quotaPaused` | ✔ | - (annulerait la reprise auto) | - | - | si reprise auto désactivée | - | ✔ (confirmation) |
| `error` | ✔ | - | si processus terminé | - | si carte signalée | - | ✔ |
| `offline` | - | - | ✔ (sauf pid orphelin vivant) | - | après relance | - | - |

### (e) Agent en attente de permission, avec réponses rapides

```text
╔═[▦]═ Nova · API ════════════════════════════════════════════════[×]═╗
║  (!)  NOVA ATTEND TA RÉPONSE                        depuis 0 min 42 ║
║                                                                     ║
║  Claude veut utiliser l'outil : Bash                                ║
║  ┌───────────────────────────────────────────────────────────────┐  ║
║  │ rm -rf dist && npm run build                                  │  ║
║  └───────────────────────────────────────────────────────────────┘  ║
║  Options affichées dans le terminal (lues à l'écran, heuristique) : ║
║  ┌──────────────────────┐ ┌──────────────────────┐ ┌────────────┐   ║
║  │ 1. Oui               │ │ 2. Oui, ne plus      │ │ 3. Non…    │   ║
║  │                      │ │    demander pour …   │ │            │   ║
║  └──────────────────────┘ └──────────────────────┘ └────────────┘   ║
║  [Refuser (Échap)]                      [Ouvrir le terminal ⌘T] ◀── ║
║                                                                     ║
║  Options non reconnues ? Seuls « Refuser » et « Ouvrir le terminal »║
║  restent proposés. L'app ne répond jamais à ta place.               ║
╚═════════════════════════════════════════════════════════════════════╝
```

Le résumé de l'outil vient du hook `PermissionRequest` (fiable). Les boutons d'options ne s'affichent que si l'écran du terminal correspond au motif attendu (5.8) ; sinon il reste **Refuser (Échap)** et **Ouvrir le terminal**.

### (e′) Agent en attente d'une question (`AskUserQuestion`)

```text
╔═[▦]═ Sol · INFRA ═══════════════════════════════════════════════[×]═╗
║  (?)  SOL TE POSE UNE QUESTION                      depuis 2 min 10 ║
║                                                                     ║
║  Région de déploiement                     (une seule réponse)      ║
║  « Dans quelle région dois-je créer le bucket de logs ? »           ║
║   ○ eu-west-3 (Paris)                                               ║
║   ○ eu-central-1 (Francfort)                                        ║
║   ○ us-east-1                                                       ║
║                                                                     ║
║  Question et options lues dans le hook (fiable). Réponse dans le    ║
║  terminal ; des boutons apparaîtront quand S7 aura validé les       ║
║  touches de ce dialogue.                [Ouvrir le terminal ⌘T] ◀── ║
╚═════════════════════════════════════════════════════════════════════╝
```

Un dialogue MCP (`Elicitation`) s'affiche de la même façon, avec le nom du serveur et son `message`.

### (f) Terminal (panneau ancré sous l'open space, ou fenêtre séparée)

```text
┌─ Terminal · Nova · API ──────────────────────────────────────────────── [Ancrer] [─] [×] ─┐
│ ● travaille · Bash · 4 min      [Interrompre ⌘.]  [Copier la commande]  [Police −/+]      │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                           │
│   (vue LocalProcessTerminalView de SwiftTerm : c'est le vrai processus `claude`.          │
│    Tout ce que tu tapes ici va directement à Claude Code ; l'app ne fait qu'observer.)    │
│                                                                                           │
│   > …                                                                                     │
│                                                                                           │
├───────────────────────────────────────────────────────────────────────────────────────────┤
│ ✎ Zone de saisie non vide : le prochain post-it attend. [Envoyer quand même ⇧⌘↩]          │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

Double-clic sur un avatar : le terminal de l'agent s'ouvre dans le panneau du bas, ou dans sa propre fenêtre (« Détacher »). C'est **la même vue** SwiftTerm re-parentée, et le processus n'est jamais relancé. Le bandeau « Zone de saisie non vide » apparaît quand la zone de saisie de Claude Code, **lue à l'écran**, contient du texte que l'app ne doit pas écraser ; le même état s'affiche sur le poste (`✎`) et dans le plateau de la barre d'état, pour qu'une file bloquée ne passe jamais inaperçue.

### (g) Dialogue de consentement pour l'installation globale des hooks (étape 5)

```text
┌─ Voir les sessions lancées hors de Pixel Open Space ─────────────────────────┐
│                                                                              │
│  Pour afficher aussi les sessions `claude` que tu lances dans un autre       │
│  terminal, Pixel Open Space doit ajouter des hooks à ta configuration.       │
│                                                                              │
│  CE QUI SERA ÉCRIT                                                           │
│   • Fichier : /Users/toi/.claude/settings.json                               │
│   • 19 entrées « hooks », toutes marquées --pixel-open-space-managed         │
│   • Tes hooks et réglages existants ne sont pas modifiés                     │
│   • Sauvegarde préalable : …/PixelOpenSpace/backups/claude-settings/         │
│       2026-09-30T10-12-03Z-user.json                                         │
│   • Effet immédiat, y compris dans les sessions déjà ouvertes                │
│                                                                              │
│  QUELLES DONNÉES CIRCULENT                                                   │
│   • Nom de l'événement, outil utilisé, extrait de commande ou de chemin,     │
│     dossier et identifiant de session.                                       │
│   • Uniquement vers un fichier-socket local (0600) de cette app.             │
│     Rien ne quitte ta machine. Si l'app est fermée, rien n'est envoyé.       │
│                                                                              │
│  COMMENT ANNULER                                                             │
│   • Réglages › Claude Code › « Désinstaller les hooks » (retire uniquement   │
│     nos entrées), ou restaurer la sauvegarde ci-dessus.                      │
│                                                                              │
│  [▸ Voir le diff avant/après]                                                │
│                                                                              │
│         [ Annuler ]      [ Portée projet uniquement… ]      [ Installer ]    │
└──────────────────────────────────────────────────────────────────────────────┘
```

### (h) Réglages (onglet Claude Code)

```text
┌─ Réglages ─────────────────────────────────────────────────────────────────────────────┐
│ ┌──────────────┐                                                                       │
│ │▸ Général     │  CLAUDE CODE                                                          │
│ │  Claude Code │  Exécutable      [/Users/toi/.local/bin/claude    ] [Détecter] v2.x ✓ │
│ │  Terminal    │  Modèle défaut   [sonnet ▾]      Permissions défaut [default ▾]       │
│ │  Apparence   │  [✓] Désactiver la vue agents dans les sessions intégrées             │
│ │  Jeu & sons  │  [ ] Forcer le rendu classique (pas d'écran alternatif)               │
│ │  Notifs      │  [ ] Couper le trafic non essentiel de Claude Code                    │
│ │  Avancé      │  Variables en plus  [+]  (ex. NODE_OPTIONS=…)                         │
│ └──────────────┘                                                                       │
│                   HOOKS                                                                │
│                   Sessions de l'app : injectées par --settings  ● actives (6/6)        │
│                   Sessions externes : non installées  [Installer…]  [Voir le fichier]  │
│                                                                                        │
│                   ENVOI DES TÂCHES                                                     │
│                   [✓] Enchaîner automatiquement la file après un tour (délai 1,5 s)    │
│                   [✓] Réponses rapides aux permissions (heuristique d'écran)           │
│                   [ ] Journal local des hooks (débogage, 7 jours)                      │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

Autres onglets : **Général** (langue, dossier des données, reprise au lancement), **Terminal** (police, taille, Option = Méta, historique), **Apparence** (zoom par défaut, nuit : auto/jour/nuit, réduire les animations), **Jeu & sons** (gamification, volume, sons individuels), **Notifications** (attente : toujours ; fin de tour et erreurs : seulement si l'app est en arrière-plan ; masquer les détails sur l'écran verrouillé), **Avancé** (journal, remplacements de sprites, réinitialisation).

### (i) Menu de la barre de menus (`MenuBarExtra`)

```text
┌──────────────────────────────────────────────┐
│ Pixel Open Space              2 en attente   │
├──────────────────────────────────────────────┤
│ (!) Nova · API       Bash : rm -rf…   0:42   │
│ (!) Sol  · INFRA     Question          2:10  │
├──────────────────────────────────────────────┤
│ [#] Bip · API        npm test                │
│ [#] Pixou · SITE     Edit header.tsx         │
│ (…) Ada · INFRA      réfléchit               │
│ [✓] Mika · SITE      fini il y a 3 min       │
├──────────────────────────────────────────────┤
│ Ouvrir Pixel Open Space              ⌘O      │
│ Nouveau post-it…                     ⌘N      │
│ Sons  [✓]     Notifications  [✓]             │
│ Quitter                              ⌘Q      │
└──────────────────────────────────────────────┘
```

Le libellé de l'icône montre le nombre d'agents en attente (« ▣ 2 »), ou rien. Un clic sur une ligne active l'app, rouvre la fenêtre principale si elle était fermée, et fait voler la caméra vers l'agent. Chaque ligne porte le mini-portrait de l'agent (`portrait.mini`, 7.4.10).

### (j) Palette de commandes ⌘K

```text
┌──────────────────────────────────────────────────────────────────────┐
│ ⌘K  › nova_                                                          │
├──────────────────────────────────────────────────────────────────────┤
│ ▸ (!) Aller à Nova (API) : attend ta réponse               ↩         │
│       Ouvrir le terminal de Nova                           ⌘T        │
│       Interrompre Nova                                     ⌘.        │
│       Donner un post-it à Nova…                                      │
│       Renommer Nova…                                                 │
│   ─ Commandes ─────────────────────────────────────────────────────  │
│       Nouvel agent dans API                                ⇧⌘N       │
│       Installer les hooks globaux…                                   │
├──────────────────────────────────────────────────────────────────────┤
│ ↑↓ naviguer · ↩ exécuter · ⌘' : agent en attente suivant · Échap     │
└──────────────────────────────────────────────────────────────────────┘
```

### (k) Fenêtre principale avec le tableau en panneau latéral, pendant un glisser (étape 3)

```text
┌─ Pixel Open Space ─────────────────────────────────────────────────────────────────────────────────────┐
│ (!) 1 ATTEND │ [#] 1 travaille │ z 2 repos │ [✓] 1 tour fini              Zoom [ x1 |▸x2◂| x3 ]        │
├───────────────────────────────────┬────────────────────────────────────────────────────────────────────┤
│ TABLEAU (⌘B)   Projet [API ▾]     │                 ╔═ API ═╗                     ◀(!) Sol · INFRA     │
│ [Chercher…]      [+ Post-it ⌘N]   │                 _.-'`'-._                        (hors champ)      │
│ À FAIRE (3)                       │            _.-'`         `'-._                                     │
│ ┌─────────────────────────────┐   │       _.-'` ▣Nova[#]  ▣Bip z   `'-._                               │
│ │◉ Doc des erreurs 401   API  │   │  _.-'`    ▣Lune z   ▣Kiwi[✓]         `'-._                         │
│ │  ☺Nova · file #1            │   │  `'-._     ▣ ·      ░░░░░░░░ ┌────────────────────┐                │
│ └─────────────────────────────┘   │       `'-._  ▣ ·   ▣ ·  ↖─── │◉ Pagination /users │                │
│ ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐   │            `'-._          `'-└────────────────────┘                │
│   (place du post-it en cours      │                 `'-._.-'`      aperçu du glisser, taille           │
│    de glisser)                    │                                du tableau quel que soit le zoom    │
│ └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘   │  ┌ Donner à Kiwi · API ─────────────────────────┐                  │
│ ┌─────────────────────────────┐   │  │ libre : envoyé dès que les gardes passent    │                  │
│ │◉ Tri des colonnes      API  │   │  │ (écran vérifié, rien de nouveau depuis 1 s)  │                  │
│ │  non assigné                │   │  └──────────────────────────────────────────────┘                  │
│ └─────────────────────────────┘   │  ⇢ à moins de 48 pt d'un bord, la caméra glisse vers lui           │
│ EN COURS (1) · À VALIDER (1)      │  ◀(!) = flèche de bord : lâcher dessus vole vers Sol               │
│ FAIT (12) ▸        [⤢ Plein écran]│                                                                    │
└───────────────────────────────────┴────────────────────────────────────────────────────────────────────┘
```

C'est l'interaction principale : le tableau reste à gauche (⌘B le bascule entre panneau latéral, plein écran et masqué), la scène reste vivante à droite. Survoler un agent affiche l'anneau `floor.dropTarget` et une bulle qui dit **ce qui va se passer** (table des cibles en 3.9). Le post-it lâché s'envole vers le poste, l'agent l'attrape (`grab`) et le colle sur son écran.

### (l) Éditeur de post-it, choix du modèle et aperçu du prompt (étape 2b)

```text
╔═[▦]═ Post-it · API ══════════════════════════════════════════════[×]═╗
║ Titre        [Pagination /users                                 ]    ║
║ Description  ┌────────────────────────────────────────────────────┐  ║
║              │ 20 par page, paramètres page et per_page.          │  ║
║              └────────────────────────────────────────────────────┘  ║
║ Projet [API ▾]    Priorité (•) haute ( ) normale ( ) basse           ║
║ Tags   [#api ×] [+]                                                  ║
║ Modèle [Ajouter une fonctionnalité ▾]           [Gérer les modèles…] ║
║ Assigné  ☺ Nova · file #2          [Donner à… ⌘D]  [Retirer]         ║
╟──────────────────────────────────────────────────────────────────────╢
║ APERÇU DU PROMPT (exactement ce qui sera tapé dans le terminal)      ║
║ Ajoute la fonctionnalité suivante, avec ses tests : Pagination       ║
║ /users. 20 par page, paramètres page et per_page.                    ║
║ 112 caractères · saisie courte · aucun caractère retiré              ║
╟──────────────────────────────────────────────────────────────────────╢
║ Historique : créé 09:02 · donné à Nova 09:10     [Supprimer ⌘⌫]      ║
╚══════════════════════════════════════════════════════════════════════╝

┌─ Gérer les modèles ──────────────────────────────────────────────────┐
│ Corriger un bug              défaut du projet API       [Modifier]   │
│ Ajouter une fonctionnalité                              [Modifier]   │
│ Écrire la documentation                                 [Modifier]   │
│ Variables : {titre} {description} {projet} {chemin} {tags} {priorite}│
│ [+ Nouveau]  [Dupliquer]  [Supprimer]   Défaut du projet : [API ▾]   │
└──────────────────────────────────────────────────────────────────────┘
```

L'aperçu passe par le même `PromptComposer` → `PromptSanitizer` que la livraison : ce que tu lis est ce qui sera tapé. Un post-it « externe » (import GitHub) affiche en plus « Texte venu de GitHub : confirmation demandée avant le premier envoi ».

### (m) Ajouter un projet (dépôt d'un dossier ou « + Projet », étape 2a)

```text
┌─ Nouveau projet ─────────────────────────────────────────────────────┐
│ Dossier   /Users/toi/dev/api                             [Choisir…]  │
│ Nom       [API       ]   pancarte : 10 caractères au plus            │
│ Couleur   (P0) (P1) (P2) (P3) [P4] (P5) (P6) (P7) (P8) (P9)          │
│           aperçu : ╔═ API ═╗ sur moquette Lagune                     │
│ Défauts   [sonnet ▾]  permissions [default ▾]  prompt [aucun ▾]      │
│ Place     nouvel îlot dans le slot 4, rien d'autre ne bouge          │
│                                                                      │
│                            [ Annuler ]            [ Créer ↩ ]        │
└──────────────────────────────────────────────────────────────────────┘
```

Un dossier déjà suivi ouvre le projet existant au lieu d'en créer un second. Dans la barre latérale, le menu d'un projet propose : Renommer, Couleur, Monter / Descendre (ordre de ⌘1…⌘9, sans déplacer l'îlot), Archiver (libère le slot, garde les post-its, les agents doivent être fermés), Retirer (demande confirmation ; ne touche jamais au dossier).

### (n) Nouvel agent (étape 2a ; apparence à l'étape 6)

```text
┌─ Nouvel agent · API ─────────────────────────────────────────────────────────┐
│ Nom          [Nova      ] [↻ autre nom]      Apparence  [aperçu] [Modifier…] │
│ Modèle       [sonnet ▾]   (défaut du projet)                                 │
│ Permissions  (•) default  ( ) acceptEdits  ( ) plan  ( ) auto  ( ) dontAsk   │
│              ( ) bypassPermissions                                           │
│                  ⚠ AUCUN GARDE-FOU : Claude exécute tout sans demander.      │
│                  [ ] Je comprends le risque pour cet agent.                  │
│ Worktree     [ ] travailler dans une copie isolée (--worktree nova)          │
│ Premier post-it (facultatif)  [Pagination /users ▾]                          │
│ Poste        îlot API, poste 6 (premier libre)                               │
│                                                                              │
│                            [ Annuler ]            [ Lancer ↩ ]               │
└──────────────────────────────────────────────────────────────────────────────┘
```

Le bouton « Lancer » reste grisé tant que la case de risque n'est pas cochée pour `bypassPermissions`. Le premier post-it choisi part en prompt positionnel (1, ligne 27).

### (o) Limite d'usage, compte déconnecté, mode dégradé, états de poste (étapes 2a et 3)

```text
┌─ États particuliers : bannières (une seule à la fois, la plus grave) et postes ────┐
│ (◷) LIMITE D'USAGE ATTEINTE · reprise automatique vers 15 h 45 · 12 en pause       │
│     Rien ne sera envoyé d'ici là.                                     [Détails]    │
│ ✖  CLAUDE CODE N'EST PLUS CONNECTÉ · lance /login dans un terminal    [Terminal]   │
│ ⚠  MODE DÉGRADÉ · Lune : aucun hook depuis le lancement (politique gérée ?)        │
│     États approximatifs, envoi automatique coupé.        [Pourquoi ?] [Terminal]   │
│ ✎  ENVOI AUTO SUSPENDU · écran de Claude Code non reconnu     [Ouvrir le terminal] │
├────────────────────────────────────────────────────────────────────────────────────┤
│ (◷) Nova   horloge au-dessus, écran « 15:45 », bras croisés                        │
│ ✖  Zéphyr  nuage d'orage, écran rouge, toux ; survol : « erreur API : overloaded » │
│ (⧗) Bip    sablier, écran « 2 tâches de fond », pianote en attendant               │
│ ⚠  Lune    petit panneau « mode dégradé » posé sur le bureau                       │
│ ⏻  Oslo    chaise vide + veste, écran et lampe éteints, plaque « OFF · Relancer »  │
│ ⏏  Lou     sort de l'ascenseur ; son écran démarre (screen.boot)                   │
│ z  Tao     endormi : avatar affalé, « zzz », écran en veille bleue (≠ hors ligne)  │
└────────────────────────────────────────────────────────────────────────────────────┘
```

### (p) Quitter, puis relancer : feuille de sortie et choix des sessions (étape 2b)

```text
┌─ Quitter Pixel Open Space ? ─────────────────────────────────────────────┐
│ Quitter ferme les 9 sessions. 3 agents ne sont pas au repos :            │
│   [#] Bip · API       Bash : npm install            depuis 1 min         │
│   (!) Sol · INFRA     attend ta réponse             depuis 2 min         │
│   (◷) Nova · API      pause de quota, reprise vers 15 h 45               │
│ Un outil en cours (installation, migration) serait interrompu.           │
│                                                                          │
│ [ Annuler ]    [ Quitter quand même ]    [ Attendre la fin des tours ↩ ] │
└──────────────────────────────────────────────────────────────────────────┘

┌─ Relancer les sessions (Choisir…) ───────────────────────────────────────┐
│ [✓] Nova · API    « Corriger le login OAuth »   il y a 2 h   ~/dev/api   │
│       post-it en cours :  ( ) Continuer la tâche   (•) Remettre à faire  │
│ [✓] Bip · API     session 7d2f…                 il y a 2 h               │
│ [ ] Tao · SITE    transcript purgé : une nouvelle session sera créée     │
│ [-] Rio · INFRA   ⚠ tourne encore hors de l'app (pid 4312)               │
│                   [Terminer ce processus]   [Laisser tourner]            │
│                                                                          │
│ [ Plus tard ]                               [ Relancer 2 sessions ↩ ]    │
└──────────────────────────────────────────────────────────────────────────┘
```

« Attendre la fin des tours » suspend toute livraison et quitte quand chaque agent est au repos ; une attente (`!`) reste à traiter par toi. « Reprendre une ancienne conversation » (sessions trouvées sur disque) s'ajoute à cette feuille à l'étape 5.

### (q) Passage à l'échelle : 20 agents sur 6 projets (étape 3)

```text
┌─ Pixel Open Space · Tout voir (⌘0) → vue d'ensemble, 0,5 pt par texel ─────────────────┐
│ (!) 3 ATTENDENT │ [#] 9 │ (…) 2 │ [✓] 2 │ z 3 │ ✖ 1         Zoom [▸½◂| x1 | x2 | x3 ]  │
│ ▾ EN ATTENTE  Nova·API·Bash 0:42   Sol·INFRA·Question 2:10   Ivo·DOCS·Edit 0:05        │
├────────────────────────────────────────────────────────────────────────────────────────┤
│   [ascenseur ▒ café]   [mur de liège ▪▪▪▪▪▪▪▪▪▪▪▪]                                     │
│                               ╔API╗                                                    │
│                           ! # … # ✓                                                    │
│                 ╔INFRA╗                  ╔SITE╗                                        │
│                 ✖ # z !                  # z ✓                                         │
│                              ╔DATA╗                  ╔MOBILE╗                          │
│                              # # …                   # z #                             │
│                                             ╔DOCS╗                                     │
│                                             ! #                                        │
│                                                                                        │
│ Pastille d'état (glyphe + couleur) au-dessus de chaque poste ; « ! » en taille XL ;    │
│ noms toujours visibles pour les agents en attente, en erreur ou hors ligne.            │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

Emprise : 6 slots (3×2) = 1920×1056 pt à ×1, donc 960×528 pt en vue d'ensemble, qui tient dans la fenêtre d'un MacBook Air 13" tableau fermé (3.8). Disposition schématique : les slots suivent l'ordre fixe de 3.8. Ce scénario sert aussi au test de lisibilité en moins de 3 s et au test de performance de l'étape 3.

### (r) Premier lancement et monde vide (étape 2a, habillé à l'étape 3)

```text
┌─ Bienvenue dans Pixel Open Space ────────────────────────────────────────┐
│ 1. Claude Code      ✖ introuvable                                        │
│    Cherché : réglage, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin,   │
│    et le PATH de ton shell de connexion (zsh).                           │
│    [Indiquer le chemin…]   [Comment l'installer ↗]   [Réessayer]         │
│ 2. Version          -   (minimum 2.1.234, lue avec claude --version)     │
│ 3. Connexion        se fait dans le terminal au premier lancement ;      │
│    l'app ne voit ni ne stocke tes identifiants.                          │
│ 4. Premier dossier  Claude peut demander la confiance du dossier dans    │
│    le terminal : le poste affiche alors « Regarde le terminal ».         │
│ 5. Notifications    demandées la première fois qu'un agent attendra,     │
│    pour te prévenir même quand l'app est en arrière-plan.                │
│                                                                          │
│                                                   [ Continuer ↩ ]        │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│ [ascenseur]  [café]  [plante]        mur de liège (vide)                 │
│                                                                          │
│       ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐                  │
│         Dépose ici un dossier de code pour créer ton                     │
│         premier îlot, ou [+ Projet ⌥⌘N]                                  │
│       └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘                  │
└──────────────────────────────────────────────────────────────────────────┘
```

### (s) Mode édition, niveau et badges (étape 6)

```text
┌─ Mode édition du décor (⇧⌘E) ────────────────────────────────────────────────┐
│ Tiroir : [plante] [lampe sur pied] [tapis] [étagère] [aquarium : niveau 5]   │
│                                                                              │
│   ░░ fantôme de placement (vert : libre)     ▓▓ teinte rouge : occupé        │
│   R : pivoter · ⌫ : retirer · Échap : quitter   [Réorganiser l'open space…]  │
└──────────────────────────────────────────────────────────────────────────────┘

┌─ Progression ────────────────────────────────────────────────────────────────┐
│ Barre d'outils :   Niv. 3  [▰▰▰▱▱▱▱▱▱▱]  380 / 500 XP    Badges 3/8 ▸        │
├──────────────────────────────────────────────────────────────────────────────┤
│ [★] Première tâche           [★] 5 agents en parallèle                       │
│ [★] Trois îlots              [ ] 10 post-its dans la journée   7/10          │
│ [ ] Réveil matinal           [ ] Oiseau de nuit                              │
│ [ ] Zéro attente             [ ] Centurion                    37/100         │
└──────────────────────────────────────────────────────────────────────────────┘
```

Tout disparaît quand la gamification est désactivée ; le mode édition reste disponible pour le décor de base.

---

## 7. Direction artistique et liste des sprites

### 7.1 Palette (un seul fichier : `PixelCore/Assets/Palette.swift`)

**32 couleurs de base**, plus deux variantes alpha, plus une sous-palette de 10 teintes de projet déclinées chacune en 3 tons. Tout sprite généré ne peut utiliser **que** ces entrées, et un test vérifie chaque pixel. Les valeurs ci-dessous sont originales ; elles seront ajustées à l'œil sur la planche de contact (7.5).

| # | Rôle (`PaletteRole`) | Hex | Usage |
|---|---|---|---|
| 1 | `ink` | `#1C1B2E` | Contours des objets neutres, texte pixel (jamais du noir pur) |
| 2 | `shade` | `#2F2E4A` | Faces les plus sombres, intérieur des meubles |
| 3 | `slate` | `#4B4F6B` | Murs face droite, métal sombre, pieds de bureau |
| 4 | `stone` | `#7C8098` | Murs face gauche, plastique gris, écrans éteints |
| 5 | `mist` | `#B5B9CB` | Faces supérieures grises, ombre du biseau d'UI |
| 6 | `paper` | `#E8E4D8` | Papier, murs clairs, post-it neutre |
| 7 | `chalk` | `#FAF8F2` | Reflets, lumière du biseau d'UI, dessus des murs |
| 8–11 | `skin1…4` | `#F3CFAE` `#D9A27B` `#A8704E` `#6A4432` | Peaux (ombre = ton suivant) |
| 12 | `hairDark` | `#3B2A24` | Cheveux foncés (les autres cheveux réutilisent le bois, `stone`, `paper` et les teintes projet) |
| 13–15 | `woodDark/Mid/Light` | `#6E4631` `#A0683F` `#D09A63` | Bureaux, étagères, cadres |
| 16 | `cork` | `#C49A68` | Tableau de liège (moucheté de `woodMid`/`woodDark`) |
| 17–18 | `floorLight/Dark` | `#D7D0C0` `#B5AC98` | Parquet du hall, couloirs |
| 19–21 | `leafDark/leaf/leafLight` | `#2E6A45` `#4F9B55` `#92CD6E` | Plantes |
| 22–23 | `skyDay/skyNight` | `#62ACE3` `#27406E` | Fenêtres |
| 24–25 | `uiTitle/uiFace` | `#3F5BA9` `#D3CEC3` | Barre de titre par défaut, face des fenêtres rétro |
| 26 | `alertYellow` | `#FFD23F` | **Réservé dans la scène à `waiting_input`** (« ! », halo, écran qui clignote) |
| 27 | `alertOrange` | `#E3851C` | Contour du « ! », son reflet |
| 28 | `screenGlow` | `#58C8F2` | Écran qui travaille, lueur |
| 29 | `okGreen` | `#4CB963` | Coche « fini », voyants OK |
| 30 | `errorRed` | `#D6453D` | Éclair, voyant d'erreur |
| 31 | `thinkLilac` | `#A58BE6` | Bulle « … » |
| 32 | `lampWarm` | `#FFBE73` | Lampes et lumière de nuit |
| α1 | `shadow` | `ink` à 30 % | Ombres portées : une seule valeur alpha, pas de dégradé |
| α2 | `lightPool` | `lampWarm` à 35 %, additif | Flaques de lumière la nuit |

**Teintes de projet**. Le ton clair et le ton sombre se calculent par formule (`light = mix(base, chalk, 0.45)`, `dark = mix(base, ink, 0.45)`) et sont figés dans le fichier. Le ton `dark` sert de **contour** aux objets de cette couleur.

| # | Nom | base | light | dark |
|---|---|---|---|---|
| P0 | Tomate | `#E4572E` | `#EE9F86` | `#8A3C2E` |
| P1 | Mandarine | `#F29E4C` | `#F6C697` | `#92633E` |
| P2 | Olive | `#8AB17D` | `#BCD1B2` | `#586E59` |
| P3 | Menthe | `#2A9D8F` | `#88C6BC` | `#246263` |
| P4 | Lagune | `#3A86C8` | `#90B9DB` | `#2C5683` |
| P5 | Indigo | `#5E60CE` | `#A4A4DE` | `#404186` |
| P6 | Prune | `#9B5DE5` | `#C6A3EB` | `#623F93` |
| P7 | Framboise | `#D6336C` | `#E68CA8` | `#822850` |
| P8 | Cacao | `#8D6346` | `#BEA693` | `#5A433B` |
| P9 | Ardoise | `#5C6B7A` | `#A3AAB0` | `#3F4758` |

Règle : **aucune teinte de projet n'est jaune vif**, pour que l'attente reste reconnaissable. Au-delà de 10 projets, on réutilise les teintes avec un motif de moquette différent (rayures, pois).

**Couleurs dérivées, dans le même fichier** (aucune couleur ne vit ailleurs) : voile de nuit `nightVeil` `#3A3F6E` ; face sombre de l'UI `uiFaceDark` `#34334F` et son titre `uiTitleDark` `#2B3F78` ; couleurs clés des PNG de remplacement `keyBase` `#FF00FF`, `keyLight` `#FF80FF`, `keyDark` `#800080` (7.7), jamais présentes dans un sprite généré. `Palette.swift` expose aussi des accesseurs `Color` SwiftUI : les panneaux, le tableau et les fenêtres rétro n'utilisent **que** ces couleurs (plus les couleurs système pour le texte long).

**Plafond par sprite** : 12 couleurs au plus hors contours et ombre, et des rampes de 3 tons (clair, base, sombre) ; un test le vérifie.

### 7.2 Lumière, contours, ombres

- **Lumière venant du haut à gauche** :
  - faces supérieures : ton `light` ;
  - faces gauches, tournées vers le sud-ouest : ton `base` ;
  - faces droites, tournées vers le sud-est : ton `dark`.

  Les objets neutres suivent la même logique avec `chalk`/`mist`, `stone` et `slate`.
- **Règle testée** : dans chaque sprite généré, la face gauche d'un volume est plus claire que sa face droite (luminance moyenne échantillonnée). C'est pourquoi aucun meuble ni mur n'est obtenu par miroir (7.4).
- **Contour de 1 px** dans le ton sombre de la couleur **de chaque matière** : `dark` de la teinte pour un vêtement ou un objet teinté, ton de peau suivant pour la peau, ton sombre des cheveux pour les cheveux, `ink` pour les objets neutres ; **jamais du noir pur**. Une ligne de reflet de 1 px, en ton clair, marque l'arête avant du dessus (contour sélectif).
- **Aucun anticrénelage.** Le seul tramage autorisé est un damier à 50 %, en petite quantité, sur les grandes surfaces (moquette).
- **Ombres portées** : une forme plate en `shadow` (α 30 %), décalée de (+2, +1) px vers le bas à droite. Un losange sous les meubles, une ellipse pixel de 20×8 sous les personnages.
- **Lignes iso strictes** : 2 px horizontaux pour 1 px vertical, marches régulières, aucune marche de 1 ou de 3.
- **Objets muraux** (mur de liège, mini post-its, affiches, fenêtres, prises) : ils suivent le plan du mur, donc sont **cisaillés en 2:1** et générés une fois pour le mur NO et une fois pour le mur NE. La pancarte d'îlot, elle, est un **panneau de face** (non cisaillé) pour que son texte reste net.
- **Étiquettes dans la scène** (plaques de nom, pancartes, compteurs) : texte Silkscreen en `chalk` avec un contour de 1 px en `ink`, ou sur une plaque `ink` à 85 % ; jamais de texte nu sur la moquette.

### 7.3 Grille et gabarits

| Élément | Spécification |
|---|---|
| Tuile | Losange de 64×32 px. Largeur de la rangée y : `4y + 4` pour y < 16, puis symétrique. Origine : sommet haut de la tuile (0,0) en (0,0) scène ; centre de la tuile (i,j) = `IsoMath.toScene(i,j) + (0, −16)` |
| Unité de hauteur | 1 niveau = 16 px verticaux |
| Hauteurs | Assise de chaise 16 px · plateau de bureau 24 px · haut d'écran 44 px · personnage 56 px · mur 96 px (6 niveaux) |
| Ancres | En pixels depuis le coin haut-gauche. Converties en `anchorPoint = (ax/w, 1 − ay/h)`, ce qui donne toujours des produits entiers. Objets 1×1 : centre du losange d'emprise. Personnages : entre les pieds `(16, 53)` |
| Profondeur | `z = bande + (i + j)·10 + couche`. Couches : tapis 0, meuble 2, personnage 4, écran 5, overlay 8. Les meubles de plusieurs tuiles sont découpés en bandes d'une tuile à la génération |
| Zooms | Vue d'ensemble 0,5 pt par texel (1 px physique sur Retina seulement), puis ×1 / ×2 / ×3 points par texel (2 / 4 / 6 px physiques sur Retina). Aucun autre zoom au repos |
| Échelle de l'UI | Fixe : **2 pt par texel** pour tout l'habillage SwiftUI (fenêtres rétro, tableau, barre d'état), quel que soit le zoom de la scène. Une même surface ne mélange jamais deux tailles de pixel |
| Temps | Horloge d'animation à **24 ticks/s** ; chaque frame dure un nombre entier de ticks (`holds`). Cadences permises : 12, 8, 6, 4, 3, 2, 1,5 et 1 fps |

**Règles pixel-parfait** (chacune a son test de capture, y compris à des positions de caméra fractionnaires) :
1. **Déplacements** : pas de `SKAction.move` brut, qui interpole en sous-texels et tremble en filtrage `.nearest`. Une action maison recalcule la position à chaque frame et l'arrondit au texel entier (marche, vol de caméra, frétillements).
2. **Caméra** : position arrondie vers le bas à la grille des pixels physiques ; si la vue a une largeur ou une hauteur impaire en pixels physiques, la position est décalée d'un demi-pixel pour que le centre tombe sur une frontière de texel.
3. **Miroir** : un sprite retourné (`xScale = −1`) utilise l'ancre `largeur − ax`, calculée depuis la largeur de la texture, sinon il saute d'un pixel.
4. **Ombres** : toutes les ombres portées sont dessinées **opaques** dans un seul calque (`SKEffectNode` rastérisé) dont l'alpha de 30 % est appliqué une fois : deux ombres qui se chevauchent ne foncent pas en une couleur hors palette.
5. **Texte pixel dans SwiftUI** : Core Text lisse toujours le texte. Les titres et étiquettes en police pixel sont donc rasterisés dans un `CGContext` sans anticrénelage, à leur taille native, puis affichés en `Image` `.interpolation(.none)` à l'échelle de l'UI.
6. **9-slice** : les tailles des panneaux sont arrondies à un multiple de l'échelle de l'UI (2 pt), pour que les bords ne soient jamais flous.

### 7.4 Liste complète des sprites

Colonnes : **Taille** en px · **Ancre** en px · **Frames × fps** (1 = statique ; cadences de la grille à 24 ticks/s, 7.3) · **Miroir** : « oui » = sprite plat, sans face ombrée, dont SW et NW sont obtenus en miroir horizontal ; « 4 or. » = les quatre orientations sont **générées** par `Draw.isoBox` (tout volume éclairé : un miroir mettrait la lumière du mauvais côté) · **Ét.** = étape de livraison.

**7.4.1 Sols et marquages**

| ID | Taille | Ancre | Frames × fps | Variantes | Miroir | Ét. |
|---|---|---|---|---|---|---|
| `floor.hall` | 64×32 | 32,16 | 1 | 3 bruits de parquet | - | 3 |
| `floor.corridor` | 64×32 | 32,16 | 1 | 2 | - | 3 |
| `floor.carpet` | 64×32 | 32,16 | 1 | 10 teintes × 2 motifs | - | 3 |
| `floor.carpet.edge.n / .s` | 64×32 | 32,16 | 1 | 10 teintes | oui → `.e/.w` | 3 |
| `floor.carpet.corner.n / .e / .s` | 64×32 | 32,16 | 1 | 10 teintes | oui → `.w` | 3 |
| `floor.hover` | 64×32 | 32,16 | 2 × 4 | contour pointillé `chalk` | - | 3 |
| `floor.dropTarget` | 64×32 | 32,16 | 4 × 8 | halo `chalk` pulsé (post-it au-dessus d'un poste) | - | 3 |
| `floor.editGrid` | 64×32 | 32,16 | 1 | libre / occupé | - | 6 |
| `shadow.tile` · `shadow.char` · `shadow.small` | 56×28 · 20×8 · 16×8 | centre | 1 | - | - | 3 |

**7.4.2 Murs et structure**

| ID | Taille | Ancre | Frames × fps | Variantes | Miroir | Ét. |
|---|---|---|---|---|---|---|
| `wall.segment` | 32×112 | 16,104 | 1 | uni · prise · plinthe | 4 or. (mur NO et mur NE générés séparément) | 3 |
| `wall.window` | 32×112 | 16,104 | 1 (nuages 4 × 1 en option) | ciel jour / crépuscule / nuit | 4 or. | 3 |
| `wall.corner` | 16×112 | 8,104 | 1 | - | - | 3 |
| `pillar` | 32×96 | 16,88 | 1 | - | - | 3 |
| `elevator` | 64×128 | 32,120 | portes 6 × 12 · voyant 2 × 2 | - | - | 3 |
| `board.cork` (mur de liège, cisaillé 2:1) | 192×128 | 96,120 | 1 (mini post-its ajoutés dynamiquement) | 48 emplacements (4 rangées de 12) ; au-delà, compteur « +23 » épinglé | 4 or. | 3 |
| `sign.island` (pancarte, panneau de face) | 64×40 | 32,38 | 1 | 10 teintes ; nom rasterisé en Silkscreen 8 px, 10 caractères max puis « … » | - | 3 |

**7.4.3 Mobilier du poste**

| ID | Taille | Ancre | Frames × fps | Variantes | Miroir | Ét. |
|---|---|---|---|---|---|---|
| `desk` | 64×48 | 32,40 | 1 | bois clair / foncé | 4 or. | 3 |
| `chair` | 32×40 | 16,36 | 1 | `slate` + 10 teintes ; variante « veste posée » (agent hors ligne) | 4 or. | 3 |
| `monitor.front` (écran visible) | 24×24 | 12,22 | 1 | décalé de 6 px vers l'allée en rangée A, pour que l'écran ne soit pas caché par l'avatar (à valider au jalon visuel) | 4 or. | 3 |
| `monitor.back` (dos + LED d'état) | 24×24 | 12,22 | LED 2 × 2 | LED de la couleur **et** du motif de l'état (clignote en attente) | 4 or. | 3 |
| `screen.off / .boot / .idle / .thinking / .working / .waiting / .done / .error / .quota / .background` | 16×10 | 8,10 | 1 · 4×8 · 2×1 · 3×4 · 4×8 · 2×4 · 1 · 3×8 · 2×1 · 3×2 | contenu d'écran superposé ; `.waiting` = clignotement jaune ; `.quota` = horloge ; `.background` = sablier | oui | 3 |
| `keyboard` · `mug` · `papers` | 14×6 · 6×8 · 12×6 | bas-centre | 1 · vapeur 3 × 4 · 1 | - | 4 or. | 3 |
| `desk.postit` (post-it collé à l'écran) | 6×6 | 3,6 | 1 | 11 teintes | - | 3 |
| `desk.queue` (pile de post-its en file) | 10×8 | 5,8 | 1 | 1 à 3 feuilles | - | 3 |
| `lamp.desk` (une par poste, mobilier de base) | 12×18 | 6,17 | 1 | allumée / éteinte | 4 or. | 3 |
| `light.cone` | 48×32 | 24,16 | 1 | additif, nuit | - | 4 |
| `trash` · `printer` | 12×14 · 32×32 | bas-centre | 1 · impression 4 × 8 | - | 4 or. | 4 |

**7.4.4 Personnages** (32×56, ancre `(16, 53)`, dessinés en SE et NE ; SW et NW = miroir de la silhouette **puis ré-ombrage**, 7.5)

Chaque apparence est **composée à la demande** à partir de calques (corps et peau, haut, bas, cheveux, accessoire), puis mise en cache par empreinte de `AgentLook`. Chaque combinaison donne une planche dédiée de 184 frames (≈ 1,3 Mo en RGBA, soit ≈ 26 Mo pour 20 agents). Variantes : 4 peaux × 6 coupes × 8 couleurs de cheveux × 16 couleurs de haut (10 projets + 6 neutres) × 4 accessoires (aucun, lunettes, casque audio, bonnet).

| Animation | Frames / dir. | fps | Boucle | Déclenchée par |
|---|---|---|---|---|
| `stand` | 2 | 2 | oui | debout, inactif |
| `walk` | 4 | 8 | oui | trajet ascenseur → poste, départ |
| `sitDown` | 2 | 8 | non | arrivée au poste ; jouée à l'envers (`standUp`) au départ, sans frame de plus |
| `sitIdle` | 2 | 2 | oui | `idle` ; aussi `waitingBackground` (+ `ov.background`) et `quotaPaused` (+ `ov.quota`) |
| `type` | 4 | 12 | oui | `working` |
| `think` | 2 | 2 | oui | `thinking` (main au menton) |
| `stretch` | 6 | 6 | non | `idle`, toutes les 45 à 90 s |
| `coffee` | 4 | 4 | non | `idle`, en alternance avec l'étirement |
| `sleep` | 2 | 1,5 | oui | `idle` depuis plus de 10 min (+ `ov.zzz`) |
| `raiseHand` | 4 (**SE/SW uniquement** : l'avatar se tourne vers toi) | 6 | oui | `waitingInput`, lisible de loin |
| `celebrate` | 6 | 8 | non | `Stop` **confirmé**, une seule fois, puis `sitIdle` + `ov.check` |
| `grab` | 4 | 8 | non | reçoit un post-it et le colle sur l'écran |
| `cough` | 4 | 6 | oui | `error` (+ `ov.storm`) |
| `wave` | 2 | 4 | non | fermeture de la session, avant `standUp` et la marche vers l'ascenseur |

Total : 48 frames en SE et 44 en NE (`raiseHand` n'existe que vers le spectateur), soit 92 frames dessinées et 184 avec SW et NW ré-ombrés. **Hors ligne** : pas d'avatar, la chaise porte la veste (`chair`, variante). S'y ajoute un mini sous-agent, `agent.mini` : 16×24, ancre `(8,23)`, 2 frames à 4 fps, posé à côté du poste tant que `activeSubagents > 0`.

**7.4.5 Overlays d'état, bulles, icônes**

| ID | Taille | Ancre | Frames × fps | Rôle | Ét. |
|---|---|---|---|---|---|
| `ov.bang` (« ! ») | 12×24 (version XL 24×48 sous le zoom ×1) | 6,24 | 4 × 8 (rebond) | `waitingInput` : jaune + contour orange, **toujours au-dessus de la nuit** | 3 |
| `ov.bang.halo` | 32×32 | 16,16 | 2 × 4 | halo pulsé autour du « ! » (coupé si « réduire les animations ») | 3 |
| `ov.dots` (bulle « … ») | 20×14 | 10,14 | 3 × 3 | `thinking` | 3 |
| `ov.tool.read / .edit / .bash / .search / .web / .subagent / .mcp / .question / .other` | 12×12 dans une bulle de 16×16 | 8,16 | 1 | outil en cours : feuille, crayon, `>_`, loupe, globe, mini-bonhomme, prise, « ? », engrenage | 3 |
| `ov.zzz` | 16×16 | 4,16 | 3 × 2 | endormi | 3 |
| `ov.storm` | 28×18 | 14,18 | 4 × 6 (éclair) | `error` | 3 |
| `ov.smoke` | 16×16 | 8,16 | 6 × 12, une fois | échec d'outil (`PostToolUseFailure`) | 4 |
| `ov.check` | 12×12 | 6,12 | 3 × 12 (pop) | `done` | 3 |
| `ov.stale` (« ? ») | 10×14 | 5,14 | 2 × 2 | sans nouvelles | 3 |
| `ov.background` (sablier) | 12×16 | 6,16 | 4 × 2 (sable qui coule) | `waitingBackground` | 3 |
| `ov.quota` (horloge) | 14×14 | 7,14 | 2 × 1 (aiguille) | `quotaPaused` ; jamais l'orage | 3 |
| `ov.draft` (« ✎ ») | 10×10 | 5,10 | 1 | zone de saisie non vide : la file attend | 3 |
| `ov.edgeArrow` | 16×16 | 8,8 | 2 × 4 | flèche de bord avec « ! » pour un agent en attente hors champ (8 directions par rotation de 45°, sprite symétrique) | 3 |
| `ov.degraded` · `ov.unsafe` · `ov.external` | 12×12 | 6,12 | 1 | panneaux : mode dégradé · `bypassPermissions` · session externe | 3 |
| `ov.selection` | 36×18 | 18,9 | 2 × 3 | anneau de sélection au sol | 3 |
| `ov.speech` (9-slice) | 24×16, bords 4/4/4/8 avec pointe | - | 1 | bulle de texte court (nom, « Salut ! ») | 4 |

**7.4.6 Habillage d'UI (SwiftUI, 9-slice, affiché avec `.interpolation(.none)` et une échelle entière)**

| ID | Taille | Bords | États | Ét. |
|---|---|---|---|---|
| `ui.window` | 24×24 | 8 | active / inactive | 4 |
| `ui.titlebar` | 24×18 | 6 | teinte projet ou `uiTitle` · inactive | 4 |
| `ui.button` | 16×16 | 4 | normal / survol / enfoncé / désactivé / principal / danger | 4 |
| `ui.close` | 12×12 | - | normal / survol / enfoncé | 4 |
| `ui.field` | 12×12 | 4 | normal / focus / erreur | 4 |
| `ui.panel` | 16×16 | 4 | en relief / en creux | 4 |
| `ui.scroll.track` · `ui.scroll.thumb` | 8×16 | 3 | normal / survol | 4 |
| `ui.check` · `ui.toggle` | 12×12 · 20×12 | - | on / off / mixte | 4 |
| `ui.tab` · `ui.tooltip` · `ui.badge` | 16×16 · 12×12 · 10×10 | 4 · 4 · 3 | actif / inactif | 4 |
| `ui.cursor.grab` · `ui.cursor.drop` · `ui.cursor.forbidden` | 16×16 | point chaud 8,8 | - | 4 |
| `ui.dropdown` · `ui.segmented` · `ui.progress` | 16×16 · 16×16 · 12×8 | 4 · 4 · 3 | normal / survol / enfoncé / désactivé ; segment actif ; remplissage | 4 |
| `board.corkTile` (fond du tableau SwiftUI, en mosaïque) | 32×32 | - | 1 | 4 |
| `app.icon` (maître 64×64, exporté ×16) · `menubar.icon` (gabarit 18×18 monochrome) | - | - | - | 4 |

**7.4.7 Post-its et punaises**

| ID | Taille | Ancre | Frames × fps | Variantes | Ét. |
|---|---|---|---|---|---|
| `postit.card` (tableau, **9-slice**, affiché ×2) | 16×16, bords de 4 px | - | 1 | 11 teintes (10 projets + `paper`) ; taille libre selon le contenu (titre, 2 lignes, tags, projet, assigné) | 4 |
| `postit.corner` (coin corné, superposé) | 8×8 | en haut à droite | 1 | 11 teintes | 4 |
| `postit.wiggle` | - | - | 2 × 8 (décalage de 1 px du 9-slice entier, pas de rotation) | - | 4 |
| `pin.red / .yellow / .green` | 8×10 | 4,9 | 2 (normale / enfoncée) | Sur le tableau (UI), la punaise jaune utilise `alertYellow` : la réserve ne vaut que dans la scène | 4 |
| `tape` | 16×6 | 8,3 | 1 | - | 4 |
| `postit.mini` (mur de liège, cisaillé 2:1) | 8×12 | 4,12 | 1 | 11 teintes × 2 murs | 3 |

**7.4.8 Effets et particules**

| ID | Taille | Frames × fps | Déclencheur | Ét. |
|---|---|---|---|---|
| `fx.dust` | 24×16 | 6 × 12 | meuble posé, îlot qui apparaît | 3 |
| `fx.ding` | 12×12 | 3 × 8 | ascenseur qui arrive | 3 |
| `fx.pinDrop` | 12×8 | 3 × 12 | post-it déposé sur un agent | 3 |
| `fx.confetti` | 32×32 | 8 × 12 | post-it validé | 4 |
| `fx.sparkle` | 8×8 | 4 × 12 | déblocage, survol d'un objet débloqué | 4 |
| `fx.steam` | 8×12 | 4 × 6 | machine à café, tasse | 4 |
| `fx.levelUp` | 48×48 | 8 × 12 | passage de niveau | 6 |
| `fx.xp` | texte « +10 » rasterisé | montée de 1 s | XP gagnée | 6 |

**7.4.9 Décor de base et décor déblocable** (base dès l'étape 3 ; déblocable à l'étape 6, placé en mode édition ⇧⌘E ; un seul ID par objet)

| ID | Taille | Animation | Déblocage |
|---|---|---|---|
| `decor.plantSmall` (hall, une par îlot) | 16×24 | balancement 2 × 1 | **base** |
| `decor.coffeeMachine` (coin café du hall) | 32×48 | vapeur 4 × 6 | **base** (anime `coffee`) |
| `lamp.desk` (7.4.3, une par poste) | 12×18 | on/off | **base** (allumée la nuit) |
| `decor.cactus` | 16×24 | - | badge « Première tâche » |
| `decor.espressoMachine` (habillage de la machine du hall) | 32×48 | vapeur 4 × 6 | 5 tâches validées |
| `decor.floorLamp` | 16×48 | on/off | 10 tâches validées |
| `decor.posterMountain` | 24×32 (mur, cisaillé 2:1) | - | badge « 5 agents en parallèle » |
| `decor.rug` (3 motifs) | 128×64 | - | 3 projets |
| `decor.plantBig` | 32×56 | 2 × 1 | niveau 3 |
| `decor.bookshelf` | 32×64 | - | 25 tâches validées |
| `decor.aquarium` | 64×48 | poissons 6 × 6, bulles 3 × 4 | niveau 5 |
| `decor.arcade` (borne originale) | 32×56 | écran 4 × 4 | badge « 10 post-its vidés dans la journée » |
| `decor.sofa` | 64×48 | - | 50 tâches validées |
| `decor.waterCooler` | 16×40 | bulle 3 × 3 | badge « Zéro attente » |
| `decor.posterWave` · `decor.posterRobot` | 24×32 | - | niveaux 7 et 10 |

**Badges** (`BadgeID`) :

| Badge | Condition |
|---|---|
| Première tâche | 1 post-it validé |
| 5 agents en parallèle | 5 agents en `thinking`/`working` au même instant |
| 10 post-its vidés dans la journée | 10 validations le même jour calendaire |
| Trois îlots | 3 projets actifs |
| Réveil matinal | une validation avant 8 h |
| Oiseau de nuit | une validation après 23 h |
| Zéro attente | une journée d'au moins 5 tâches sans attente de plus de 2 min |
| Centurion | 100 tâches validées |

**7.4.10 Compléments : HUD, mini-carte, portraits, progression, mode édition**

| ID | Taille | Ancre | Frames × fps | Rôle | Ét. |
|---|---|---|---|---|---|
| `desk.nameplate` (9-slice) | 16×8, bords 3 | bas-centre | 1 | plaque de nom du poste ; variante « OFF · Relancer » | 3 |
| `desk.queueBadge` | 8×8 | 4,8 | 1 | nombre de post-its en file (1 à 9, puis « + ») | 3 |
| `hud.state.*` (un par `AgentStateKind`) | 12×12 | - | 1 | icônes de la barre d'état, du plateau d'attente et de la vue Liste | 3 |
| `minimap.frame` (9-slice) · `minimap.dot.*` · `minimap.viewport` | 16×16 · 5×5 · 9-slice 8×8 | - | 1 | cadre ; un point **avec glyphe** par état ; rectangle de la zone visible | 3 |
| `portrait.mini` | 12×12 | - | 1 (composé depuis `AgentLook`) | agent assigné sur le post-it, menu de la barre de menus, vue Liste | 4 |
| `agent.outline.dashed` | 32×56 | 16,53 | 2 × 2 | contour pointillé d'un visiteur externe | 5 |
| `fx.star` | 1×1 et 3×3 | centre | 2 × 1 | étoiles des fenêtres la nuit | 4 |
| `light.screenGlow` | 24×16 | 12,8 | 1, additif | lueur d'écran la nuit | 4 |
| `hud.level` · `hud.xpBar` (9-slice) | 16×16 · 8×8 | - | 1 | niveau et barre d'XP de la barre d'outils | 6 |
| `badge.*` (8 icônes, une par `BadgeID`) | 16×16 | - | 1 · version grisée | vitrine des badges | 6 |
| `edit.drawer` (9-slice) · `edit.ghost` · `edit.invalid` | 16×16 · emprise · emprise | - | 1 · 2 × 4 · 1 | tiroir du mode édition ; fantôme de placement ; teinte rouge d'emplacement occupé | 6 |

**Couverture** : un test (`SpriteCoverageTests`) tient la liste de chaque nom de la spec et de ce document (état, animation, meuble, élément d'UI) et vérifie qu'un `SpriteID` lui correspond dans `SpriteCatalog` ; un nom sans sprite fait échouer la CI.

### 7.5 Générateur : du DSL au `SKTexture`

1. **Des rôles, pas des couleurs**. Les dessins utilisent des `PaletteRole` : `s`/`S` peau et son ombre, `h`/`H` cheveux, `t`/`T` haut, `p` bas, `e` œil, `.` transparent, `P`/`L`/`D` teinte projet (base, clair, sombre). Les contours sont **par matière** : `q` contour de peau (ton de peau suivant), `j` contour de cheveux (ton sombre des cheveux), `D` pour un vêtement teinté, `o` (`ink`) pour le reste. Le même dessin sert ainsi à toutes les teintes et à toutes les apparences.
   ```swift
   static let headSE = PixelMap("""
     ....jjjjjj....
     ...jhhhhhHj...
     ..jhhhhhhhHj..
     ..jhsssssshHj.
     ..qsseSsseSq..
     ..qssssssSSq..
     ...qssssSSq...
     ....qqqqqq....
     """)                                   // 14×8, lue de haut en bas
   ```
   **Ré-ombrage des personnages** : SE et NE sont dessinés à la main, ombres comprises. Pour SW et NW, le générateur retourne la version **à plat** (rôles d'ombre ramenés à leur base), puis réapplique une passe d'ombrage procédurale (bande de 1 px sur le bord droit de chaque matière, sous le menton et sous la frange). La lumière reste ainsi en haut à gauche dans les quatre directions.
2. **Primitives géométriques** pour tout le mobilier : `Draw.isoBox(footprint:height:ramp:)` applique d'office la règle d'éclairage (7.2), plus `isoDiamond`, `line2to1`, `dither50` et `outlineSelective`. Les meubles sont des compositions de boîtes et de détails en `PixelMap`.
3. **Pipeline** : `SpriteCatalog` (définitions) → `PixelImage` (RGBA en Swift pur, **déterministe**) → `AtlasPacker` (étagères, pages de 2048², 2 px de marge avec bords dupliqués) → `SpriteManifest`.
   - **App** : `SKTexture(data:size:)` en `.nearest`, découpée en sous-textures.
   - **Outil** : `swift run sprite-export --out build/sprites --contact-sheet --scale 4` écrit les pages PNG, `manifest.json` et une planche de contact agrandie.
   - Encodeur PNG minimal en Swift pur (deflate « stored » + CRC32/Adler32), sans dépendance : fonctionne sous Linux.
4. **Tests** :
   - chaque pixel appartient à la palette ;
   - les losanges respectent la marche 2:1 ;
   - les ancres donnent des produits entiers ;
   - la face gauche de chaque volume est plus claire que sa face droite (7.2), dans les quatre orientations ;
   - au plus 12 couleurs par sprite hors contours et ombre ;
   - chaque nom de la spec a son sprite (`SpriteCoverageTests`, 7.4.10) ;
   - chaque sprite a une empreinte « golden » (`Tests/Golden/*.sha`) ; un changement volontaire se valide en régénérant les empreintes.

   Les PNG produits sous Linux sont **visibles directement** par l'IA qui écrit le code, et publiés comme artefacts de la CI.

### 7.6 Atlas et manifeste (`manifest.json`)

```json
{
  "format": "pixelopenspace-atlas", "version": 1, "theme": "day",
  "pages": [ { "file": "atlas-0.png", "size": [2048, 2048] } ],
  "sprites": {
    "desk@se":            { "page": 0, "rect": [2, 2, 64, 48],   "anchor": [32, 40], "mask": true },
    "screen.working@se#2":{ "page": 0, "rect": [70, 2, 16, 10],  "anchor": [8, 10] }
  },
  "animations": {
    "screen.working@se":  { "frames": ["screen.working@se#0", "screen.working@se#1", "screen.working@se#2", "screen.working@se#3"], "fps": 8, "loop": true }
  },
  "mirrors": { "floor.carpet.edge.e": "floor.carpet.edge.n" },
  "tinted": [ "floor.carpet", "chair", "sign.island", "postit.card" ]
}
```

- **Nommage** : `id@direction#frame`.
- **`mirrors`** : réservé aux sprites **plats** (colonne « Miroir : oui » de 7.4). Un miroir **ne prend aucune place** dans l'atlas ; il s'affiche avec `xScale = −1`, l'ancre `largeur − ax` et le masque retourné. Meubles, murs et personnages ré-ombrés ont leurs propres entrées.
- **`tinted`** : sprites générés une fois par teinte de projet, à la demande.
- **Planches par apparence** : les planches de personnages composées pour un `AgentLook` vont dans des pages dynamiques séparées, qui ne sont pas exportées.

### 7.7 Remplacer les sprites par les tiens

Dossier : `~/Library/Application Support/PixelOpenSpace/Sprites/`.

- **Formats acceptés** :
  - `desk@se.png` : remplace une frame unique ;
  - `type@se#0.png`, `type@se#1.png`… : une frame d'animation ;
  - `type@se.sheet.png` + `type@se.json` (`{ "frames": 4, "fps": 10, "anchor": [16, 53] }`) : une planche horizontale.
- **Sprites teintés** : dessine avec trois couleurs clés, qui seront remplacées par la teinte du projet au chargement :
  - `#FF00FF` = base ;
  - `#FF80FF` = clair ;
  - `#800080` = sombre.
- **Validation** :
  - la taille doit correspondre, sauf si le `.json` déclare une autre ancre ;
  - une couleur hors palette donne un avertissement, pas un refus ;
  - le masque de clic est recalculé.
- **Réglages › Avancé** : « Recharger les sprites » (à chaud), « Exporter le pack par défaut » (sert de gabarit), « Revenir aux sprites générés ».

### 7.8 Mode nuit

- **Déclenchement** : il suit l'apparence de macOS (`viewDidChangeEffectiveAppearance`), avec un réglage manuel « toujours jour / toujours nuit ».
- **Rendu** :
  1. Les fenêtres passent au ciel `skyNight`, avec quelques étoiles (`fx.star`) qui scintillent (2 × 1 fps).
  2. Un nœud plein écran en `.multiply` (`nightVeil`, α 0,55) assombrit le monde ; avec « Réduire la transparence » ou « Augmenter le contraste » de macOS, α descend à 0,35.
  3. Au-dessus de ce voile, des sprites **additifs** (`light.cone`, `lightPool`) créent les flaques de lumière des lampes de bureau (`lamp.desk`, mobilier de base, allumées automatiquement la nuit), la lueur des écrans (`light.screenGlow`) et le voyant de l'ascenseur.
  4. Les **overlays d'état restent au-dessus du voile**, donc aussi lisibles que le jour ; le « ! » y gagne même.
- **Plus tard, en option** : une vraie permutation de palette jour → nuit générée à l'atlas. C'est plus « pixel » qu'un voile, mais aussi plus long à faire.
- **UI SwiftUI** : les fenêtres rétro passent sur `uiFaceDark` et `uiTitleDark` (7.1).

### 7.9 Accessibilité

- **Jamais la couleur seule** : chaque état combine une **forme** d'overlay distincte (« ! », « … », icône d'outil, coche, zzz, orage, « ? », sablier, horloge, chaise vide), une **pose** d'avatar (main levée, frappe, menton, bras en l'air, avachi, toux, absent) et un **texte** (infobulle, barre d'état, VoiceOver). Les points de la mini-carte portent aussi leur glyphe.
- **VoiceOver** :
  - chemin principal : la **vue Liste** (⌘L) et les panneaux SwiftUI, tous étiquetés (« Nova, projet API, attend ta réponse : Bash rm -rf dist, depuis 42 secondes ») ;
  - dans la scène, qui est un `SKView` AppKit (donc sans `.accessibilityChildren` SwiftUI), `WorldView` expose des `NSAccessibilityElement` enfants, un par agent et par îlot, avec leur cadre à l'écran recalculé quand la caméra bouge ;
  - un **rotor personnalisé** « Agents en attente » ;
  - annonces (`NSAccessibility.post`) **seulement** quand un agent se met à attendre ou tombe en erreur, regroupées sur 2 s (« 3 agents attendent ta réponse ») et priorisées, pour qu'à 20 agents VoiceOver ne soit pas noyé.
- **Contrôles rétro** : chaque bouton 9-slice, case, onglet ou bouton de fermeture pixel a un rôle, un libellé et l'anneau de focus du système ; une checklist VoiceOver et clavier par écran est passée à l'étape 5.
- **Réglages système respectés** : « Réduire les animations » (plus de rebond ni de halo, un « ! » fixe mais plus grand, des transitions de caméra instantanées), « Différencier sans couleur » (les glyphes d'état passent en taille XL et les post-its affichent leur priorité en toutes lettres), « Augmenter le contraste » (contours `ink` de 2 px sur les overlays, texte des panneaux ≥ 7:1) et « Réduire la transparence » (voile de nuit plus léger, panneaux opaques).
- **Clavier partout** : voir 3.16. Aucune action n'existe seulement dans le jeu.
- **Contrastes** : texte ≥ 4,5:1 dans les panneaux. Les titres pixel restent courts, le texte long utilise la police système.

### 7.10 Originalité et propriété intellectuelle (à respecter à chaque sprite)

**À faire** :
- tout dessiner à partir de zéro, par programme ;
- tenir un journal de provenance (`Resources/ASSETS.md` : qui, quoi, comment) ;
- choisir nos propres proportions : environ 3,5 têtes, yeux de 1×2 px, pas de bouche au repos ;
- garder notre palette, notre cadre d'UI et nos noms d'objets et de lieux (« îlot », « poste », « mur de liège ») ;
- livrer les polices OFL avec leur licence ;
- afficher la mention « Pixel Open Space n'est ni affilié à Anthropic ni approuvé par Anthropic ; il lance l'outil Claude Code installé sur ta machine ».

**À ne pas faire** :
- reprendre le nom, les termes, la monnaie, le gabarit d'avatar, les bulles de dialogue, le navigateur de salles, le catalogue ou le mobilier emblématique d'un hôtel virtuel existant ;
- décalquer ou recolorer des sprites extraits d'un jeu ;
- utiliser des personnages de films ou de séries ;
- utiliser le logo, le nom ou la mascotte d'Anthropic ou de Claude comme avatar ou comme icône ;
- intégrer des packs d'assets à licence non commerciale.

La projection iso 2:1, le pixel art, des bureaux et des chaises sont des idées communes ; ce qui compte, c'est **l'exécution originale**.

### 7.11 Polices et sons

- **Polices** :
  - **Silkscreen** (OFL, dessinée sur une grille de 8 unités par em) pour le HUD, les pancartes et les compteurs. Elle n'est rasterisée qu'à **8 px par em**, soit 1 unité = 1 texel, puis affichée à l'échelle entière de la surface : ×2 dans l'UI (16 pt), le zoom courant dans la scène ;
  - **Pixelify Sans** (OFL, variable 400–700) pour les titres des fenêtres rétro. Elle n'est pas dessinée sur une grille aussi stricte : on cherche sa taille native nette sur la planche de contact (⚠️ à vérifier) ; à défaut, les titres restent en Silkscreen ;
  - police système pour le texte long, police à chasse fixe de l'utilisateur dans le terminal.

  Les polices sont enregistrées au lancement (`CTFontManagerRegisterFontsForURL`, portée process). Tout texte en police pixel, dans SpriteKit **comme dans SwiftUI**, est rasterisé dans un `CGContext` sans anticrénelage puis affiché en texture ou en `Image` `.interpolation(.none)` (7.3, règle 5).
- **Sons** (synthétisés, 3.17) :
  - `alert` : deux notes montantes, pour l'attente ;
  - `done` : arpège de 3 notes ;
  - `drop` : « toc » ;
  - `ding` : ascenseur ;
  - `levelUp` : arpège de 5 notes ;
  - `error` : buzz grave.

---

## 8. Plan de livraison

**À chaque étape**, tu reçois :
- du code qui compile (CI Linux + macOS au vert) ;
- les instructions pour le lancer dans Xcode ;
- la liste de ce qui reste à faire ;
- une courte checklist de vérification manuelle à cocher sur ton Mac.

**Base commune pour lancer l'app** (toutes les étapes) :
```bash
brew install xcodegen                         # une seule fois
git clone <ton dépôt> pixelopenspace && cd pixelopenspace
xcodegen generate                             # crée PixelOpenSpace.xcodeproj depuis project.yml
open PixelOpenSpace.xcodeproj
# Xcode : cible PixelOpenSpace › Signing & Capabilities › Team = ton Apple ID (identité « Apple Development »)
# Schéma PixelOpenSpace › ⌘R.   Tests : ⌘U (ou `swift test` pour le cœur, sans Xcode)
```
Une identité de signature **stable** est importante : macOS attache les autorisations (notifications, réseau local, fichiers) à la signature. Une signature ad hoc qui change à chaque build les ferait redemander à chaque fois.

### Étape 2 : MVP fonctionnel, sans graphismes, en deux jalons

L'étape est coupée en **2a** puis **2b**, chacune avec sa démo sur ton Mac, pour que tu puisses corriger le tir à mi-parcours. Interface : SwiftUI simple (maquette 6(b)) et symboles SF.

**Étape 2a : agents, états et terminaux**
- **Périmètre** : ajouter des projets, créer et lancer des agents dans des terminaux intégrés, états en temps réel par hooks dans la vue Liste, notifications d'attente, quitter proprement (feuille de sortie, 2.5).
- **Tâches** :
  1. `Tools/spikes/run-spikes.sh` (5.11). **Tu l'exécutes et tu me colles le rapport** (ou tu suis la checklist manuelle de repli). J'ajuste ensuite le décodeur, les motifs d'écran et les lignes de commande.
  2. Squelette : `Package.swift` (PixelCore, PixelIPC, `pixel-hook`, `fake-claude`), `project.yml`, deux workflows CI (Linux : `swift test` ; macOS : compilation et tests unitaires), app vide qui se lance.
  3. `PixelCore/Model` + `Codecs` + `Migrator` (v1), avec leurs tests.
  4. Chaîne des hooks : `HookDecoder` (fixtures issues des spikes), `pixel-hook`, `UnixSocketServer`, dédoublonnage. Test d'intégration **sous Linux** : `fake-claude` **rejoue des fixtures JSONL** → `pixel-hook` → serveur → événements décodés. `fake-claude` n'émule **pas** de TUI à ce stade.
  5. `AgentStateMachine` : un test par ligne de la table 4.3, des scénarios rejoués, et les cas d'ordre mélangé (outils parallèles, sous-agents).
  6. Lancement : `ClaudeLocator`, résolution de l'environnement, `LaunchPlanner` (tests), `TerminalHost`, `TerminalPresenter`, panneau terminal (re-parentage), `ScreenPatterns` (fixtures d'écran issues de S3/S7).
  7. Feuilles « Nouveau projet », « Nouvel agent », premier lancement (maquettes 6(m), 6(n), 6(r)) ; `NotificationBridge` (attente), badge du Dock, compteurs et plateau d'attente dans la barre d'état ; feuille de sortie.
- **Démo 2a** : critères d'acceptation 1 à 3 ci-dessous.

**Étape 2b : tableau, livraison, persistance**
- **Périmètre** : tableau de post-its, éditeur et modèles, assignation par glisser-déposer, livraison gardée, file, persistance, relance et reprise.
- **Tâches** :
  1. `TaskLifecycle` (un test par ligne de 4.3b + tests de propriétés), `TaskStore` (⌘N, collage de liste, 4 colonnes, filtres simples), éditeur de post-it et modèles (6(l)).
  2. Glisser d'un post-it vers une carte d'agent, « Donner à… », « Premier agent libre », `TaskDispatcher`, `PromptSanitizer`/`DeliveryPlan` avec ses gardes (tests), vérification par `UserPromptSubmit`, `Stop` provisoire (T13 à T13c).
  3. `PersistenceStore`, restauration, détection des orphelins, bannière et feuille « Relancer les sessions » (6(p)).
  4. Passage de la grille d'acceptation (ci-dessous).
- **Livrable** : app utilisable au quotidien, sans décor.

- **Tests (2a et 2b)** :
  - `swift test` sous Linux et macOS (cœur, plus de 150 tests visés) ;
  - checklist manuelle avec le vrai `claude` ;
  - les tests UI `xcodebuild` avec `fake-claude` arrivent à l'étape 3, quand `fake-claude` saura aussi rejouer un écran.
- **Terminé quand** : les 5 critères d'acceptation passent sur ton Mac avec le vrai `claude`, la latence hook → écran est mesurée (p95 affiché dans Réglages › Avancé), et la CI est au vert.

**Grille d'acceptation du MVP**

| Critère | Fonctions qui le satisfont | Vérification |
|---|---|---|
| 1. Ajouter 3 projets et ouvrir 2 sessions dans chacun (2a) | Sélecteur de dossier / dépôt d'un dossier → `WorkspaceStore` ; « + Agent » → `SessionManager.launch` ; 6 `TerminalHost` détachés | Manuel avec `claude` ; test d'intégration `fake-claude` (6 sessions) |
| 2. Chaque session affiche un état juste, mis à jour en moins de 1 s (2a) | Hooks synchrones → `pixel-hook` → socket → `reduce` (regroupé toutes les 16 ms) | Horodatage `ts_ns` du helper comparé à l'instant d'affichage, p95 visé < 150 ms ; test d'intégration rejoué ; scénario manuel « lis ce fichier, lance les tests » |
| 3. Une demande de permission se voit tout de suite, avec notification (2a) | `PermissionRequest` → attente `.permission` → carte « ATTEND » + `(!)` + plateau d'attente + **notification macOS, même app au premier plan** (décision 18) + badge Dock | Manuel : en mode `default`, demander « exécute `ls` » ; chronométrer. **Réussi si** la carte passe « ATTEND » en moins de 1 s **et** une notification macOS s'affiche, app au premier plan comme en arrière-plan |
| 4. Créer un post-it en moins de 5 s et l'assigner par glisser-déposer : la tâche part et le post-it change de colonne tout seul (2b) | ⌘N → titre → Entrée ; glisser sur la carte d'agent ; `DeliveryPlan` gardé ; `UserPromptSubmit` → En cours ; `Stop` confirmé → À valider | Chrono manuel ; cas « agent occupé » → file, puis envoi après le `Stop` confirmé ; cas « permission qui surgit pendant la livraison » → abandon propre (S3b) |
| 5. Quitter puis relancer : projets et post-its reviennent, les sessions peuvent être reprises (2b) | Feuille de sortie ; JSON atomique ; `SessionRef` (id + cwd) ; feuille « Relancer les sessions » → `claude --resume <id>` | Tests de codecs et de migration ; manuel : quitter pendant un tour (« Attendre la fin des tours » puis « Quitter quand même »), relancer, reprendre, vérifier la conversation et le choix « Continuer la tâche » |

### Jalon visuel : valider la direction artistique **avant** de construire la scène

- **Livrable**, produit sous Linux par `sprite-export` et `SceneCompositor` : la planche de contact de tous les sprites v0, et un **îlot complet** (rangées A et B, un agent dans chaque état, post-its, pancarte, lampe) aux zooms ×1, ×2 et ×3, de jour et de nuit, plus la vue d'ensemble de 20 agents sur 6 projets (6(q)).
- **Questions tranchées à ce jalon** : lisibilité de l'écran en rangée A (l'avatar de dos le cache-t-il ? repli prévu : écran décalé vers l'allée et LED d'état sur le haut du moniteur, 7.4.3) ; taille des overlays à ×1 et en vue d'ensemble ; palette.
- **Terminé quand** : tu valides les images. L'étape 3 ne commence qu'après.

### Étape 3 : l'open space isométrique

- **Périmètre** :
  - `WorldLayout` (slots « append-only ») et `IsoMath` ; sprites générés validés au jalon visuel ; atlas et `SpriteRegistry` ;
  - `WorldView`/`WorldScene`, caméra (déplacement souris, trackpad et clavier, pincement, vue d'ensemble et zooms ×1/×2/×3, Tout voir, centrage) ;
  - avatars animés selon l'état, plaques de nom, flèches de bord, plateau d'attente ;
  - glisser-déposer d'un post-it sur un agent de la scène, avec le tableau en panneau latéral (6(k)) et le défilement automatique ;
  - clic → fenêtre agent, double-clic → terminal (règles de 3.9) ;
  - barre d'état cliquable avec vol de caméra, mini-carte ;
  - arrivée par l'ascenseur, meubles qui tombent avec de la poussière.

  La vue Liste (ex-MVP) reste disponible via ⌘L.
- **Tâches** :
  1. `WorldLayout` avec ses tests de propriétés (dont « aucun îlot ne bouge »).
  2. DSL, `PixelImage`, `sprite-export` et `SceneCompositor` (fait au jalon visuel).
  3. `WorldView` + réconciliation par ID.
  4. `AgentPresenter` → animations.
  5. Hit-test par masque, résolution des clics.
  6. Glisser-déposer AppKit (S8, ou décodage direct de l'UTI).
  7. Caméra au pixel près (règles de 7.3).
  8. Mini-carte, plateau d'attente, flèches de bord.
  9. Accessibilité de base (éléments AppKit, rotor).
- **Tests** :
  - layout et présentation en Core ; captures du `SceneCompositor` sous Linux (référence) ;
  - tests UI `xcodebuild` avec `fake-claude` (6 sessions, permissions, tours) ; captures `SKView.texture(from:)` sur la CI macOS **en plus**, sachant que les runners macOS hébergés sont des machines virtuelles sans vraie accélération graphique (captures possiblement noires : la référence reste le compositeur logiciel) ;
  - compteur de draw calls ; scénario de 20 agents simulés sur 6 projets ;
  - captures à des positions de caméra fractionnaires (aucun flou).
- **Terminé quand** :
  - avec 20 agents sur 5 projets : 60 fps en interaction, et les budgets de 3.9 tenus au repos (≤ 5 % CPU, ≤ 400 Mo, 0 fps fenêtre masquée), mesurés dans Instruments (S11) ;
  - **protocole « 3 s »** : un scénario `fake-claude` met au hasard 2 agents en attente parmi 20, fenêtre ouverte sur la scène au zoom par défaut ; tu dois dire à voix haute qui attend et quoi. Réussi si tu le fais en moins de 3 s dans 9 essais sur 10 ;
  - le glisser-déposer vers un agent fonctionne, **y compris quand l'agent cible est hors du champ au début du glisser** ;
  - aucun flou à aucun zoom.

### Étape 4 : finitions visuelles

- **Périmètre** :
  - palette finale et jeu complet d'animations (7.4) ;
  - fenêtres rétro en 9-slice ;
  - polices Silkscreen et Pixelify Sans ;
  - micro-animations : post-it qui frétille, punaise qui s'enfonce, poussière, confettis ;
  - mode nuit ;
  - sons 8 bits ;
  - icône de l'app.
- **Tâches** :
  - itérations sur la planche de contact, avec ton retour à chaque tour (captures dans la CI) ;
  - voile de nuit et lumières additives ;
  - `SoundPlayer` ;
  - mécanisme de remplacement des sprites (7.7).
- **Tests** : empreintes golden, conformité à la palette, captures jour et nuit, respect de « réduire les animations ».
- **Terminé quand** : tu valides la direction artistique sur les captures, et le mode nuit suit macOS.

### Étape 5 : confort

- **Périmètre** :
  - notifications avec actions et clic qui recentre sur l'agent ;
  - `MenuBarExtra` avec le nombre d'agents en attente et la liste rapide ;
  - tous les raccourcis de 3.16, palette ⌘K, ⌘' pour passer d'un agent en attente au suivant ;
  - restauration complète : fenêtres, caméra, sélection, terminaux détachés ;
  - installation globale **optionnelle** des hooks, avec consentement, sauvegarde et désinstallation (5.9), pour les sessions externes ;
  - « Reprendre une ancienne conversation » (`SessionDiscovery`).
- **Tests** :
  - `SettingsPatcher`, avec fixtures de settings réels : vide, commentaires refusés, hooks existants, liens symboliques ;
  - `TranscriptScanner`, avec fixtures corrompues ;
  - tests UI des raccourcis ; test « chaque `AppCommand` est dans un menu et dans ⌘K » ;
  - checklist manuelle sur clavier **AZERTY** (⌘., ⌘', ⌘1…⌘9, ⌘+/⌘−) et checklist VoiceOver des contrôles rétro.
- **Terminé quand** : l'installation puis la désinstallation laissent ton `settings.json` **identique octet pour octet** à l'original (édition par plages, 3.3 ; aucune exception), et chaque action a une entrée de menu et de palette.

### Étape 6 : gamification

- **Périmètre** :
  - noms générés (liste de syllabes originales) et éditeur d'apparence (cheveux, couleur de tenue, accessoire) ;
  - XP, niveaux et badges (maquette 6(s)) ;
  - décor déblocable et mode édition ⇧⌘E (maquette 6(s) : tiroir, placement sur la grille, contrôle d'occupation, rotation R, suppression) ;
  - tout se désactive en un interrupteur.
- **Tests** : `ProgressRules` (pas de double comptage, badges quotidiens et fuseau horaire), occupation du décor.
- **Terminé quand** : le jeu reste discret et ne ralentit aucune action.

### Étape 7 : bonus

- **Import GitHub** : via `gh issue list --json number,title,body,labels,url` exécuté **par ton `gh`**, en lecture seule, uniquement si `gh` est installé et authentifié. Les cartes importées sont marquées « externe » : jamais livrées automatiquement, aperçu et confirmation avant le premier envoi (5.5).
- **Statistiques du jour** : tâches validées, temps cumulé en attente, délai moyen de réponse.
- **Options** :
  - mode « décider depuis l'app » par hook `PermissionRequest` bloquant (5.8) ;
  - expérimentation des canaux (research preview) ;
  - worktree par agent, avec interface.

### Ce que je ne pourrai pas vérifier moi-même, et comment on s'y prend

L'IA qui écrit le code travaille dans un conteneur Linux, **sans Xcode, sans macOS et sans ta session Claude**. Voici comment on compense :

1. Toute la logique vit dans `PixelCore`, compilé et testé sous Linux à chaque modification.
2. La CI macOS (GitHub Actions) génère le projet, compile l'app, lance les tests unitaires (et les tests UI à partir de l'étape 3), et publie l'app zippée, des captures PNG et les journaux. Je lis ces artefacts.
3. `fake-claude` remplace le vrai CLI en CI.
4. Les sprites **et la scène entière** (`SceneCompositor`) sont rendus en PNG sous Linux, et je peux les regarder ; les captures SpriteKit de la CI macOS ne sont qu'un contrôle en plus (machines virtuelles sans vraie accélération graphique).
5. Ce qui touche au vrai `claude` (timings de saisie, rendu des dialogues) passe par des **spikes scriptés** que tu exécutes, puis par ta checklist manuelle à chaque étape.
6. Tous les appels SwiftTerm passent par `TerminalHost`, ce qui limite l'impact d'un changement d'API de SwiftTerm 2.0.

---

## 9. Structure du dépôt

```text
pixelopenspace/
├── Package.swift                      # swift-tools 6.2 ; cibles Core/IPC/outils + tests (Linux + macOS)
├── project.yml                        # XcodeGen : app macOS 14+, dépend du package local + SwiftTerm (révision épinglée)
├── Sources/
│   ├── PixelCore/
│   │   ├── Model/                     # Project, Agent, TaskCard, SessionRef, AppSettings, IDs…
│   │   ├── Hooks/                     # HookEvent, HookEnvelope, HookDecoder, HookSettingsBuilder
│   │   ├── State/                     # AgentStateMachine, AgentPresenter, AgentRuntime, ScreenPatterns (versionnés)
│   │   ├── Tasks/                     # TaskLifecycle, TaskQueue, DispatchPolicy, PromptComposer, PromptSanitizer, DeliveryPlan (+ gardes)
│   │   ├── Launch/                    # LaunchPlanner, EnvSanitizer
│   │   ├── Config/                    # OrderedJSON, SettingsPatcher
│   │   ├── Discovery/                 # TranscriptScanner, JSONLLineReader
│   │   ├── World/                     # IsoMath, WorldLayout (slots), DepthKey, SceneCompositor
│   │   ├── Assets/                    # Palette, PixelImage, PixelMap, Draw, SpriteCatalog/, AtlasPacker, SpriteManifest, PNGEncoder
│   │   ├── Game/                      # ProgressRules, Badges, NameGenerator
│   │   ├── Audio/                     # SquareSynth (échantillons PCM en Swift pur)
│   │   ├── Persistence/               # Codecs, Migrator, WorkspaceValidator
│   │   └── Util/                      # FuzzyMatcher, Clock
│   ├── PixelIPC/                      # UnixSocketServer, UnixSocketClient, LineFramer (Darwin/Glibc)
│   ├── pixel-hook/                    # main.swift : stdin → socket, exit 0
│   ├── fake-claude/                   # rejoue des fixtures JSONL de hooks (et d'écran à l'étape 3) ; enregistreur des spikes
│   └── sprite-export/                 # atlas PNG + manifest + planche de contact
├── Tests/
│   ├── PixelCoreTests/                # + Fixtures/hooks/*.jsonl, Fixtures/screens/, Fixtures/transcripts/, Fixtures/settings/
│   ├── PixelIPCTests/
│   └── Golden/                        # empreintes des sprites
├── App/
│   ├── Sources/
│   │   ├── AppMain/                   # PixelOpenSpaceApp, AppDelegate (notifications), CommandCenter
│   │   ├── Model/                     # AppModel, stores, SettingsStore
│   │   ├── Sessions/                  # SessionManager, TerminalHost, TerminalPresenter, AgentTerminalView, ClaudeLocator,
│   │   │                              # EnvironmentResolver, ProcessInspector (orphelins)
│   │   ├── Hooks/                     # HookServer, HooksInstaller
│   │   ├── Tasks/                     # TaskDispatcher
│   │   ├── World/                     # WorldView, WorldScene, nodes/, CameraController, SpriteRegistry, WorldSceneCoordinator
│   │   ├── UI/                        # StatusBar, ListView, Board/, AgentWindow/, TerminalPanel, Settings/, Palette, MenuBarContent, Retro/ (9-slices)
│   │   └── System/                    # NotificationBridge, SoundPlayer, PersistenceStore, SessionDiscovery
│   ├── Resources/                     # Fonts/ (+ OFL.txt ×2), Localizable.xcstrings, AppIcon, ASSETS.md (provenance)
│   ├── Info.plist (généré)            # LSMinimumSystemVersion 14.0, UTExportedTypeDeclarations (post-it),
│   │                                  # NSLocalNetworkUsageDescription, ATSApplicationFontsPath
│   ├── PixelOpenSpace.entitlements    # sans sandbox ; Hardened Runtime activé
│   └── UITests/
├── Tools/
│   ├── spikes/run-spikes.sh           # S1–S11 (5.11)
│   ├── bootstrap.sh                   # vérifie xcodegen/Xcode, génère le projet
│   └── make-release.sh                # plus tard : archive + notarisation optionnelle
├── docs/PROPOSITION.md                # ce document ; plus tard ARCHITECTURE.md, DECISIONS.md (ADR)
└── .github/workflows/
    ├── core.yml                       # ubuntu-latest + conteneur swift:6.2 : swift build && swift test ; sprite-export → artefact
    └── app.yml                        # macos-26 (Xcode 26.x) : xcodegen generate ; xcodebuild build test ;
                                       # artefacts : PixelOpenSpace.app.zip, captures UI, journaux, xcresult
```

**Conventions** :
- **Langage** : Swift 6, mode de langage 6, concurrence stricte ; `@MainActor` pour toute l'UI.
- **Code** : aucune logique dans les vues ; pas de `!` hors tests ; `swift-format` en CI.
- **Nommage** : code et identifiants en anglais ; commentaires de documentation en anglais ; textes d'interface en français dans le String Catalog.
- **Tests** : toute modification de `PixelCore` s'accompagne de tests. Les fixtures réelles, issues des spikes, sont anonymisées : chemins et contenus remplacés.
- **Décisions** : chaque décision d'architecture est tracée dans `docs/DECISIONS.md`, au format ADR court.
- **Commits** : un commit par tâche, avec un message impératif.
- **CI** :
  - le workflow Linux tourne à chaque push ;
  - le workflow macOS tourne à chaque push sur `main` et sur les PR ;
  - on évite `macos-14`, abandonné en novembre 2026 ;
  - `macos-26` apporte Xcode 26, que SwiftTerm `main` exige (swift-tools 6.2).

---

## 10. Risques et mitigations

Classés par criticité (probabilité × impact).

| # | Risque | P | I | Mitigation |
|---|---|---|---|---|
| 1 | **Timing de saisie dans la TUI** : Entrée perdue, collage avalé, texte envoyé avant que la TUI soit prête (bugs connus #91205, #28137 ; plusieurs outils tiers touchés) | Haute | Haut | Premier post-it en argument positionnel ; livraison gardée en deux phases (état, événements, écran) ; écritures séparées avec délai ; vérification par `UserPromptSubmit` et un seul `\r` de secours, lui aussi gardé ; spikes S3 et S3b ; paramètres ajustables sans recompiler |
| 2 | **Dérive des hooks** : champs renommés, nouveaux types de `Notification` ou de `StopFailure`, `prompt_id` absent avant la première saisie | Moyenne | Haut | Décodeur tolérant (champs optionnels, `.other`) ; JSON brut conservé dans le journal ; fixtures par version de `claude` ; la version détectée est affichée dans Réglages |
| 3 | **`--settings` remplace au lieu d'ajouter**, ou hooks bloqués par une politique gérée | Faible à moyenne | Haut | Spike S1 ; repli `--plugin-dir` ; détection « aucun hook en 15 s » → mode dégradé annoncé, jamais silencieux |
| 4 | **Changements de `session_id`** (`/clear`, `/resume`, fork) | Haute | Moyen | `AgentID` + `PIXEL_AGENT_ID` + `claude_pid` ; historique de `SessionRef` (avec `cwd`) ; un nouvel id n'est adopté que par un `SessionStart` du processus de l'agent |
| 5 | **`PATH` des apps GUI** : `claude` introuvable, ou Bash de Claude sans tes outils | Haute | Moyen | Résolution par le shell de connexion, chemins connus, réglage manuel, test « Détecter » ; environnement explicite, jamais `nil` |
| 6 | **Performances avec 20 terminaux** (SwiftTerm #658 : CPU élevé avec plusieurs TUI en flux) | Moyenne | Moyen | SwiftTerm `main` (parsing hors thread principal ; rendu hors écran suspendu, ⚠️ à mesurer) ; Metal désactivé sauf panneau visible ; historique de 2 000 lignes ; budgets chiffrés (3.9) mesurés par S11 ; `tick` à 1 Hz ; événements regroupés par frame |
| 7 | **SwiftTerm 2.0 non taguée** (API mouvante, Xcode 26 requis) | Moyenne | Moyen | Révision épinglée ; adaptateur `TerminalHost` unique ; bascule vers `from: "2.0.0"` dès la publication du tag |
| 8 | **Pas de Xcode dans le conteneur de l'IA** | Certaine | Moyen | Cœur testé sous Linux ; CI macOS avec artefacts (app, captures) ; `fake-claude` ; spikes et checklists sur ton Mac (8, fin) |
| 9 | **Format JSONL interne** qui casse la découverte | Haute | Faible | Lecture seule et tolérante ; jamais sur le chemin critique ; affichage « sans titre » en cas de doute |
| 10 | **Collage traité comme « non écrit par toi »** : Claude ignore les consignes collées | Moyenne | Moyen | Texte court saisi ; amorce saisie devant un corps long ; spike S3 |
| 11 | **Brouillon ou autocomplétion** de l'utilisateur envoyés avec le post-it | Moyenne | Moyen | Zone de saisie lue **à l'écran** avant chaque phase (G3) : pas d'envoi auto avec un brouillon ; aucun `@` ou `/` en tête. `chat:sendNow` (Ctrl+X Ctrl+S ou Ctrl+Entrée, v2.1.275+, https://code.claude.com/docs/en/interactive-mode.md) n'est **pas** utilisé : il enverrait aussi ton brouillon |
| 12 | **Mode vim** (`editorMode: "vim"`) : le texte envoyé est interprété comme des mouvements | Faible | Moyen | Lecture seule de tes settings au lancement ; avertissement ; envoi automatique désactivé pour ces agents (question 11.4) |
| 13 | **Session qui quitte notre PTY** (`←` ou `/bg` vers la vue agents) | Faible | Moyen | `CLAUDE_CODE_DISABLE_AGENT_VIEW=1` par défaut ; l'app n'envoie jamais de flèches ; T19/T20 si le processus se termine |
| 14 | **Chevauchement avec la vue agents officielle**, qui pourrait évoluer | Moyenne | Faible | Positionnement complémentaire (visuel, terminaux intégrés, tableau) ; aucune dépendance à la vue agents |
| 15 | **Permissions macOS** : notifications refusées, invites Réseau local et Fichiers attribuées à l'app | Moyenne | Faible | Demande en contexte ; badge du Dock et barre de menus en secours ; textes Info.plist clairs ; signature stable |
| 16 | **Dialogue de permission non reconnu** pour les réponses rapides | Haute | Faible | Heuristique désactivable ; « Refuser (Échap) » et « Ouvrir le terminal » toujours disponibles |
| 17 | **Propriété intellectuelle** : ressemblance avec un hôtel virtuel connu | Faible | Haut | Règles de 7.10, journal de provenance, revue visuelle à l'étape 4 |
| 18 | **Écriture de settings concurrente** lors de l'installation globale | Faible | Haut | Écriture atomique, relecture avant `rename`, sauvegarde, sentinelle, refus sur JSON invalide |
| 19 | **AZERTY et Option = Méta** : caractères `{ [ \| ~` impossibles à taper | Moyenne | Faible | `optionAsMetaKey = false` par défaut, réglable ; raccourcis vérifiés sur AZERTY (3.16) |
| 20 | **`Stop` qui n'est pas une fin** (hook `Stop` bloquant, `/goal`, tâches de fond, crons, reprise après limite d'usage) | Haute | Haut | `Stop` provisoire + fenêtre de calme (T13 à T13c) ; `waitingBackground` sans envoi auto ; gardes G1/G2 ; spike S3b |
| 21 | **Motifs d'écran cassés** par une mise à jour de Claude Code : l'envoi automatique dépend désormais de G3 | Moyenne | Moyen | Motifs versionnés par version de Claude Code, fixtures d'écran ; en cas d'échec, envoi automatique **suspendu** et annoncé (6(o)), jamais d'envoi à l'aveugle : tu colles le post-it toi-même dans le terminal (« Copier le prompt ») |
| 22 | **Limite d'usage** qui frappe 10 à 20 agents à la fois | Haute | Moyen | État `quotaPaused` distinct, **une** bannière globale avec l'heure de reprise, aucune livraison ni `ESC` pendant l'attente, file relancée après `quota_auto_resume_fired` (T14 à T14e) |
| 23 | **Processus orphelins ou imbriqués** : deux écrivains sur un transcript, événements attribués au mauvais agent, doublons | Moyenne | Moyen | pid + heure de départ persistés, jamais de `--resume` d'un id détenu par un processus vivant (2.5) ; filtre `claude_pid` ; sortie immédiate du hook global ; dédoublonnage (5.7) |
| 24 | **Injection de prompt** par un texte importé (issue GitHub) livré à un agent en mode permissif | Faible | Haut | Cartes « externe » jamais livrées automatiquement ; aperçu et confirmation avant le premier envoi (5.5) |

---

## 11. Questions ouvertes pour toi

1. **Mac et Xcode** : quelle version de macOS et d'Xcode ? **Xcode 26 ou plus est un prérequis ferme** (décision 3) : la lecture d'écran, le drapeau de collage et la fin d'écriture reposent sur l'API de SwiftTerm `main`. Si tu ne peux pas l'installer, dis-le **avant d'approuver** : il faudrait étudier un adaptateur SwiftTerm 1.x (⚠️ API non vérifiées) et revoir ce document.
2. **Installation de `claude`** : native (`~/.local/bin`), Homebrew ou npm ? Dans quel shell (zsh + nvm, fish…) ?
3. **Compte Claude** : individuel, ou Team/Enterprise avec des settings gérés, qui pourraient bloquer les hooks ou les canaux ?
4. **Réglages de saisie** : utilises-tu le mode vim, des raccourcis personnalisés (`~/.claude/keybindings.json`), un remappage d'Entrée, ou le rendu plein écran de Claude Code ?
5. **Sessions hors de l'app** : veux-tu les voir, ce qui demande l'installation globale optionnelle, ou tout lancer depuis l'app ?
6. **Même dépôt, plusieurs agents** : c'est fréquent chez toi ? Si oui, veux-tu les worktrees dès le MVP ?
7. **Validation** : « Fait » uniquement sur ton clic, ou veux-tu une validation automatique après N minutes sans retour ?
8. **Enchaînement** : après un `Stop` confirmé, faut-il enchaîner automatiquement le post-it suivant (mon défaut), ou attendre ton feu vert ?
9. **Nom, identifiant de bundle et compte Apple** : quel nom retiens-tu ? As-tu un compte Apple Developer payant (notarisation) ou seulement un Apple ID gratuit ?
10. **Volume** : combien d'agents simultanés en pratique, et combien de projets ?
11. **Rendu du terminal intégré** : garder ton réglage de Claude Code (plein écran ou classique), ou forcer le rendu classique pour garder l'historique de défilement dans SwiftTerm ?
12. **Sons et notifications** : les défauts de la décision 14 te conviennent-ils ?
13. **Spikes** : es-tu d'accord pour exécuter `Tools/spikes/run-spikes.sh` au début de l'étape 2 ? Il tourne en quelques minutes, dans un dossier jetable, avec ton compte Claude, et consomme un peu de quota (environ 30 tours courts avec `haiku`, détail en 5.11). Sinon, la checklist manuelle de repli te convient-elle ?
14. **Notification au premier plan** (critère d'acceptation 3) : une notification macOS à **chaque** mise en attente, même quand l'app est devant toi (décision 18), ou le « ! » + son suffisent-ils au premier plan ?
15. **Durée de vie des sessions** : acceptes-tu que quitter l'app ferme les sessions (avec la feuille de sortie), plutôt qu'un processus d'arrière-plan qui les garderait vivantes (décision 19) ?
16. **Couverture de la spec** (0.4) : la liste des exigences est reconstruite depuis ta spec telle que je l'ai comprise ; manque-t-il une ligne, ou une adaptation (« ≈ ») te gêne-t-elle ?
