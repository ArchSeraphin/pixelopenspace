# Résultats des spikes de l'étape 2

Date : 2026-09-30T18:51:08+02:00 · Claude Code : 2.1.285 (Claude Code) · macOS 27.0 (26A428) · Python 3.13.0 · harnais v2
Modèle : `haiku` · mode de permission : `default` · terminal simulé 120x36, `TERM=xterm-256color` (réponses aux requêtes du terminal : comme SwiftTerm)

Les réponses ci-dessous sont calculées automatiquement ; les détails sont dans chaque dossier (`notes.json`, `events.jsonl`, `screens/`, `transcript.txt`, `pty.jsonl`).

## Déroulé

| Scénario | Statut | Durée | Détail |
|---|---|---|---|
| S1 — Fusion des hooks : --settings + .claude/settings.local.json | ok | 7 s |  |
| S2 — --session-id, puis fermeture du PTY | ok | 5 s |  |
| S3.a-30ms — Saisie puis Entrée après 30 ms | ok | 8 s |  |
| S3.a-120ms — Saisie puis Entrée après 120 ms | ok | 6 s |  |
| S3.a-250ms — Saisie puis Entrée après 250 ms (+ captures d'écran) | ok | 6 s |  |
| S3.b-lf — Saut de ligne LF dans le texte saisi | ok | 6 s |  |
| S3.c-paste — Amorce + collage entre crochets de 1200 caractères | ok | 7 s |  |
| S3.d-positional — Prompt positionnel | ok | 8 s |  |
| S3.e-permission — Permission : « 1 », puis enchaînement | ok | 18 s |  |
| S4 — Identifiants : /clear, /compact, /resume, --resume, --fork-session ; --worktree | ok | 74 s |  |
| S5 — Refus d'une permission par Échap | ok | 17 s |  |
| S7 — Dialogue AskUserQuestion | ok | 18 s |  |
| S9 — Latence de pixel-hook | ok | 8 s |  |

## S1 — Les hooks de `--settings` s'ajoutent-ils aux autres ?
**OUI**, les deux sources ont reçu les événements (hooks « app » passés par `--settings`, hooks « project-local » dans `.claude/settings.local.json` du dossier jetable).
- SessionStart : app, project-local
- UserPromptSubmit : app, project-local
- Note : les hooks « déjà là » sont simulés dans les settings locaux du projet (le harnais ne touche jamais `~/.claude/settings.json`). La doc de `--settings` dit que ses valeurs remplacent les mêmes clés des fichiers, d'où la question pour la clé `hooks`.

## S2 — `SessionStart.session_id` = `--session-id` ?
**OUI** (demandé `d6acd40d-4066-4a37-b44f-5dbe71b2a700`, reçu `d6acd40d-4066-4a37-b44f-5dbe71b2a700`, source `startup`).
- Fermeture du PTY (SIGHUP, comme un crash de l'app) : processus terminé = oui, code 129, SessionEnd = `other`.

## S3 — Saisie dans le PTY

### (a) Texte saisi d'un bloc, puis Entrée seule après un délai

| Délai | UserPromptSubmit | Prompt identique | Entrée → hook | Stop |
|---|---|---|---|---|
| 30 ms | oui | oui | 61.3 ms | oui |
| 120 ms | oui | oui | 66.1 ms | oui |
| 250 ms | oui | oui | 58.2 ms | oui |

### (b) `LF` dans le texte saisi
UserPromptSubmit : oui · le prompt contient un saut de ligne : **oui** · prompt reçu : `Ligne 1 : réponds juste OK.\nLigne 2 : rien d'autre.`

### (c) Amorce saisie + collage entre crochets (1200 caractères), Entrée après 250 ms
- `ESC[?2004h` émis par claude : **oui** (actif au moment du collage : oui)
- « [Pasted text » affiché : oui
- UserPromptSubmit : **oui** (après 94.4 ms)
- Prompt reçu : 1314 caractères, 18 lignes ; commence par l'amorce : oui ; contient le texte collé exact : oui (aux espaces près : oui) ; contient « [Pasted text » : non
- Début : `Réalise la tâche décrite dans le texte collé ci-dessous.\n\n<pasted_content id="2f9a">\nLigne 01 du texte collé : contenu de test sans consigne, pour mesurer le c…`

### (d) Prompt positionnel (`claude … "Réponds juste OK."`)
UserPromptSubmit : **oui** · prompt : `Réponds juste OK.` · 516.7 ms après SessionStart · Stop : oui

### (e) Permission : « 1 », puis enchaînement d'un nouveau prompt
- PermissionRequest : outil `Bash`, entrée `{"command": "touch spike-permission.txt", "description": "Créer le fichier spike-permission.txt"}` ; champs : cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, transcript_path
- « 1 » seul répond : **oui**
- Événements après la touche : PostToolUse → PostToolBatch → Stop
- Fichier créé : oui · Stop : oui · écran calme 2722.1 ms après Stop
- Enchaînement après Stop (nouveau prompt, Entrée à 250 ms) : UserPromptSubmit **oui**, prompt identique oui, Stop oui

Captures utiles aux motifs d'écran (`ScreenPatterns`) : `S3.a-250ms/screens/` (prêt, brouillon, en cours), `S3.e-permission/screens/` (dialogue, saisie après Stop).

## S3b — Tâche de fond (minimal)
_Non lancé (option `--with-perturbation`)._

## S4 — `session_id` après /clear, /compact, /resume, --resume, --fork-session ; `cwd` avec --worktree

| Étape | Événement | source / reason / new_cwd | session_id | cwd |
|---|---|---|---|---|
| lancement --session-id | SessionStart | startup | `4a5a6985-a1aa-4ee3-a8c7-8dd2093d7efb` | `<tmp>/S4/projet` |
| /clear | SessionEnd | clear | `4a5a6985-a1aa-4ee3-a8c7-8dd2093d7efb` | `<tmp>/S4/projet` |
| /clear | SessionStart | clear | `1bc0f21d-68d1-43d3-b612-24f1504ef645` | `<tmp>/S4/projet` |
| /compact | PreCompact | manual | `1bc0f21d-68d1-43d3-b612-24f1504ef645` | `<tmp>/S4/projet` |
| /compact | SessionStart | compact | `1bc0f21d-68d1-43d3-b612-24f1504ef645` | `<tmp>/S4/projet` |
| /compact | PostCompact | manual | `1bc0f21d-68d1-43d3-b612-24f1504ef645` | `<tmp>/S4/projet` |
| /exit | SessionEnd | prompt_input_exit | `1bc0f21d-68d1-43d3-b612-24f1504ef645` | `<tmp>/S4/projet` |
| --resume | SessionStart | resume | `1bc0f21d-68d1-43d3-b612-24f1504ef645` | `<tmp>/S4/projet` |
| /exit (reprise) | SessionEnd | prompt_input_exit | `1bc0f21d-68d1-43d3-b612-24f1504ef645` | `<tmp>/S4/projet` |
| --resume --fork-session | SessionStart | fork | `a3f0ffb5-f2f0-418c-9273-dce57d9f8068` | `<tmp>/S4/projet` |
| /exit (fork) | SessionEnd | prompt_input_exit | `a3f0ffb5-f2f0-418c-9273-dce57d9f8068` | `<tmp>/S4/projet` |
| --worktree | SessionStart | startup | `6c6135c6-087c-4778-b177-77cb1e4bbe0c` | `<tmp>/S4/projet/.claude/worktrees/spike-s4` |
| /exit (worktree) | SessionEnd | prompt_input_exit | `6c6135c6-087c-4778-b177-77cb1e4bbe0c` | `<tmp>/S4/projet` |

- `--session-id` respecté : oui
- /clear change l'id : **oui** (source `clear`)
- /compact garde l'id : **oui** (source `compact`)
- /resume dans la session revient à l'id du premier sujet : **non** (source `None`)
- Sélecteur de /resume : ligne en surbrillance `/clear`, options numérotées `[]` (capture `S4/screens/`)
- --resume garde l'id : **oui** (source `resume`)
- --fork-session donne un nouvel id : **oui** (source `fork`)
- --worktree : `cwd` de SessionStart = `<tmp>/S4/projet/.claude/worktrees/spike-s4` (dans `.claude/worktrees/` : **oui** ; dossier lancé : `<tmp>/S4/projet`) ; CwdChanged : `[]`

## S5 — Refus manuel d'une permission par Échap
- Après Échap : aucun événement
- PreToolUse non · PostToolUse non · PostToolUseFailure non · PostToolBatch non · PermissionDenied non · Stop non · StopFailure non · Notification non · UserPromptSubmit non
- Dialogue encore affiché : non · fichier créé : non · octet Échap brut (0x1B) envoyé avec les drapeaux clavier kitty = 5
- Champs de PermissionRequest : cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, transcript_path

## S7 — Dialogues à l'écran

Options détectées par le motif de l'app `^\s*[❯>]?\s*([1-9])\.\s+(.+)$` (bordures `│` retirées).

### Permission (S3 e)
Options : `[["1", "Yes"], ["2", "No"]]`
```text

 ▐▛███▛█   Claude Code v2.1.285
▝▜██████▀  Haiku 4.5 · Claude Max
 ▝▝   ▝▝   /…<tmp>/S3.e-permission/projet


❯ Exécute la commande touch spike-permission.txt avec l'outil Bash, puis réponds juste OK.

⏺ Créer le fichier spike-permission.txt
  ⎿  $ touch spike-permission.txt

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command

   touch spike-permission.txt
   Créer le fichier spike-permission.txt

 Permission rule Bash(touch *) requires confirmation for this command.
 /permissions to update rules

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
```

### Permission (S5)
Options : `[["1", "Yes"], ["2", "No"]]`
```text

 ▐▛███▛█   Claude Code v2.1.285
▝▜██████▀  Haiku 4.5 · Claude Max
 ▝▝   ▝▝   <tmp>/S5/projet


❯ Exécute la commande touch spike-refus.txt avec l'outil Bash, puis réponds juste OK.

⏺ Créer le fichier spike-refus.txt
  ⎿  $ touch spike-refus.txt

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command

   touch spike-refus.txt
   Créer le fichier spike-refus.txt

 Permission rule Bash(touch *) requires confirmation for this command.
 /permissions to update rules

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
```

### AskUserQuestion (S7)
- Premier événement : PreToolUse · `tool_input` : `{"questions": [{"question": "Choisissez votre couleur préférée entre les deux options suivantes", "header": "Couleur", "options": [{"label": "Rouge", "description": "Une couleur chaude et énergique"}, {"label": "Bleu", "description": "Une couleur froide et apaisante"}], "multiSelect": false}]}`
- Événements jusqu'au dialogue : UserPromptSubmit → PreToolUse → PermissionRequest
- Options : `[["1", "Rouge"], ["2", "Bleu"], ["3", "Type something."], ["4", "Chat about this"]]`
- Après Échap : aucun événement
```text
❯ Utilise l'outil AskUserQuestion pour me demander de choisir entre rouge et bleu, puis attends ma réponse.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Couleur

Choisissez votre couleur préférée entre les deux options suivantes

❯ 1. Rouge
     Une couleur chaude et énergique
  2. Bleu
     Une couleur froide et apaisante
  3. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel














───────────────────────────────────────────────────────────────────────────────────────────────────────── pos-spike-s7 ─
```

## S9 — Latence de `pixel-hook`
| Mesure | n | p50 | p95 | max |
|---|---|---|---|---|
| Lancement → message reçu sur le socket | 50 | 7.7 ms | 9.3 ms | 195.3 ms |
| Lancement → fin du processus | 50 | 10.2 ms | 12.1 ms | 197.9 ms |
| Sans socket (app fermée) → fin | 10 | 13.1 ms | 18.3 ms | 18.3 ms |
| Référence : `/usr/bin/true` | 20 | 2.8 ms | 3.4 ms | 3.9 ms |

Échecs : 0

## S10 — Des hooks tournent-ils avant l'acceptation de la confiance du dossier ?
**NON** : aucun hook avant l'acceptation, sur 12 lancement(s) avec le dialogue puis SessionStart.
- Lancements sans dialogue de confiance (dossier déjà approuvé, ex. reprise) : 3.
- Flèches bas avant « Yes, I trust this folder » : 1.

## Dialogues au démarrage (fermés par Échap avant toute saisie)
Aucun.

## Non couvert par ce script (à vérifier à la main)
- S5 : la ligne « limite d'usage » à l'écran (il faudrait épuiser le quota).
- S7 : les touches qui choisissent chaque option ; seules « 1 » (S3.e) et Échap (S5, S7) sont testées.
- S8 : glisser-déposer SwiftUI → AppKit, à tester dans l'app.
- S11 : 20 sessions au repos pendant 10 min, à mesurer dans Instruments avec l'app.

## Champs observés par événement

| Événement | Nb | Champs du JSON de hook |
|---|---|---|
| PermissionRequest | 3 | cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, transcript_path |
| PostCompact | 1 | compact_summary, cwd, hook_event_name, prompt_id, scratchpad_dir, session_id, transcript_path, trigger |
| PostToolBatch | 1 | cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_calls, transcript_path |
| PostToolUse | 1 | cwd, duration_ms, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, tool_response, tool_use_id, transcript_path |
| PreCompact | 1 | custom_instructions, cwd, hook_event_name, prompt_id, scratchpad_dir, session_id, transcript_path, trigger |
| PreToolUse | 3 | cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, tool_use_id, transcript_path |
| SessionEnd | 16 | cwd, hook_event_name, prompt_id, reason, scratchpad_dir, session_id, transcript_path |
| SessionStart | 18 | cwd, hook_event_name, model, prompt_id, scratchpad_dir, session_id, session_title, source, transcript_path |
| Stop | 11 | background_tasks, cwd, hook_event_name, last_assistant_message, permission_mode, prompt_id, scratchpad_dir, session_crons, session_id, stop_hook_active, transcript_path |
| SubagentStop | 1 | agent_id, agent_transcript_path, agent_type, background_tasks, cwd, hook_event_name, last_assistant_message, permission_mode, prompt_id, scratchpad_dir, session_crons, session_id, stop_hook_active, transcript_path |
| UserPromptSubmit | 14 | cwd, hook_event_name, permission_mode, prompt, prompt_id, scratchpad_dir, session_id, session_title, transcript_path |

## Terminal : modes et requêtes de claude
- Modes privés : ?1000h, ?1000l, ?1002h, ?1002l, ?1003h, ?1003l, ?1004h, ?1004l, ?1006h, ?1006l, ?1016l, ?1049h, ?1049l, ?2004h, ?2004l, ?2026h, ?2026l, ?2031h, ?2031l, ?25h, ?25l
- Requêtes auxquelles le terminal a répondu : CSI 16 t, DA1, DECRQM ?1016, DECRQM ?2026, OSC 11 ?, XTVERSION, kitty keyboard ?
- Codes OSC : 0, 11
- Drapeaux du protocole clavier kitty demandés : 0, 5

## Partage

`git add Tools/spikes/results && git commit -m "Résultats des spikes" && git push`
