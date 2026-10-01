# Résultats des spikes de l'étape 2

Date : 2026-10-01T10:41:35+02:00 · Claude Code : 2.1.286 (Claude Code) · macOS 27.0 (26A428) · Python 3.13.0 · harnais v2
Modèle : `haiku` · mode de permission : `default` · terminal simulé 120x36, `TERM=xterm-256color` (réponses aux requêtes du terminal : comme SwiftTerm)

Les réponses ci-dessous sont calculées automatiquement ; les détails sont dans chaque dossier (`notes.json`, `events.jsonl`, `screens/`, `transcript.txt`, `pty.jsonl`).

## Déroulé

| Scénario | Statut | Durée | Détail |
|---|---|---|---|
| S3.a-250ms : Saisie puis Entrée après 250 ms (+ captures d'écran) | ok | 9 s |  |
| S3.c-paste : Amorce + collage entre crochets de 1200 caractères | ok | 7 s |  |
| S3.e-permission : Permission : « 1 », puis enchaînement | ok | 13 s |  |
| S5 : Refus d'une permission par Échap | ok | 18 s |  |
| S7 : Dialogue AskUserQuestion | ok | 17 s |  |
| S3b-background : Tâche de fond (optionnel, --with-perturbation) | ok | 20 s |  |

## S1 : Les hooks de `--settings` s'ajoutent-ils aux autres ?
_Pas de réponse (non lancé)._

## S2 : `SessionStart.session_id` = `--session-id` ?
_Pas de réponse (non lancé)._

## S3 : Saisie dans le PTY

### (a) Texte saisi d'un bloc, puis Entrée seule après un délai

| Délai | UserPromptSubmit | Prompt identique | Entrée → hook | Stop |
|---|---|---|---|---|
| S3.a-30ms | non lancé | | | |
| S3.a-120ms | non lancé | | | |
| 250 ms | oui | oui | 94.7 ms | oui |

### (b) `LF` dans le texte saisi
_Pas de réponse (non lancé)._

### (c) Amorce saisie + collage entre crochets (1200 caractères), Entrée après 250 ms
- `ESC[?2004h` émis par claude : **oui** (actif au moment du collage : oui)
- « [Pasted text » affiché : oui
- UserPromptSubmit : **oui** (après 79.1 ms)
- Prompt reçu : 1314 caractères, 18 lignes ; commence par l'amorce : oui ; contient le texte collé exact : oui (aux espaces près : oui) ; contient « [Pasted text » : non
- Début : `Réalise la tâche décrite dans le texte collé ci-dessous.\n\n<pasted_content id="795b">\nLigne 01 du texte collé : contenu de test sans consigne, pour mesurer le c…`

### (d) Prompt positionnel (`claude … "Réponds juste OK."`)
_Pas de réponse (non lancé)._

### (e) Permission : « 1 », puis enchaînement d'un nouveau prompt
- PermissionRequest : outil `Bash`, entrée `{"command": "touch spike-permission.txt", "description": "Create spike-permission.txt file"}` ; champs : cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, transcript_path
- « 1 » seul répond : **oui**
- Événements après la touche : PostToolUse → PostToolBatch → Stop
- Fichier créé : oui · Stop : oui · écran calme 2402.0 ms après Stop
- Enchaînement après Stop (nouveau prompt, Entrée à 250 ms) : UserPromptSubmit **oui**, prompt identique oui, Stop oui

Captures utiles aux motifs d'écran (`ScreenPatterns`) : `S3.a-250ms/screens/` (prêt, brouillon, en cours), `S3.e-permission/screens/` (dialogue, saisie après Stop).

## S3b : Tâche de fond (minimal)
- Stop.background_tasks : `[{"id": "buy41950f", "type": "shell", "status": "running", "description": "Launch sleep command in background", "command": "sleep 8"}]`
- Stop.session_crons : `[]`
- À la fin de la tâche : nouveau UserPromptSubmit oui, second Stop oui
- Événements après le premier Stop : UserPromptSubmit(+6.6 s) → Stop(+8.4 s)

## S4 : `session_id` après /clear, /compact, /resume, --resume, --fork-session ; `cwd` avec --worktree
_Pas de réponse (non lancé)._

## S5 : Refus manuel d'une permission par Échap
- Après Échap : aucun événement
- PreToolUse non · PostToolUse non · PostToolUseFailure non · PostToolBatch non · PermissionDenied non · Stop non · StopFailure non · Notification non · UserPromptSubmit non
- Dialogue encore affiché : non · fichier créé : non · octet Échap brut (0x1B) envoyé avec les drapeaux clavier kitty = 5
- Champs de PermissionRequest : cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, transcript_path

## S7 : Dialogues à l'écran

Options détectées par le motif de l'app `^\s*[❯>]?\s*([1-9])\.\s+(.+)$` (bordures `│` retirées).

### Permission (S3 e)
Options : `[["1", "Yes"], ["2", "No"]]`
```text

 ▐▛███▛█   Claude Code v2.1.286
▝▜██████▀  Haiku 4.5 · Claude Max
 ▝▝   ▝▝   /…<tmp>/S3.e-permission/projet

▎ Your voice can help guide AI
▎ Take 15 min to share your experiences with Anthropic Interviewer. Start now (https://clau.de/yourthoughts)

❯ Exécute la commande touch spike-permission.txt avec l'outil Bash, puis réponds juste OK.

⏺ Creating spike-permission.txt file
  ⎿  $ touch spike-permission.txt

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Create spike-permission.txt file
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch spike-permission.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
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

 ▐▛███▛█   Claude Code v2.1.286
▝▜██████▀  Haiku 4.5 · Claude Max
 ▝▝   ▝▝   <tmp>/S5/projet


❯ Exécute la commande touch spike-refus.txt avec l'outil Bash, puis réponds juste OK.

  Créer le fichier spike-refus.txt
  ⎿  $ touch spike-refus.txt

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Créer le fichier spike-refus.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch spike-refus.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Permission rule Bash(touch *) requires confirmation for this command.
 /permissions to update rules

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
```

### AskUserQuestion (S7)
- Premier événement : PreToolUse · `tool_input` : `{"questions": [{"question": "Préférez-vous le rouge ou le bleu ?", "header": "Choix couleur", "options": [{"label": "Rouge", "description": "La couleur rouge, chaude et dynamique"}, {"label": "Bleu", "description": "La couleur bleu, calme et sereine"}], "multiSelect": false}]}`
- Événements jusqu'au dialogue : UserPromptSubmit → PreToolUse → PermissionRequest
- Options : `[["1", "Rouge"], ["2", "Bleu"], ["3", "Type something."], ["4", "Chat about this"]]`
- Après Échap : aucun événement
```text
❯ Utilise l'outil AskUserQuestion pour me demander de choisir entre rouge et bleu, puis attends ma réponse.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ☐ Choix couleur

Préférez-vous le rouge ou le bleu ?

❯ 1. Rouge
     La couleur rouge, chaude et dynamique
  2. Bleu
     La couleur bleu, calme et sereine
  3. Type something.
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel














───────────────────────────────────────────────────────────────────────────────────────────────────────── pos-spike-s7 ─
```

## S9 : Latence de `pixel-hook`
_Pas de mesure (non lancé)._

## S10 : Des hooks tournent-ils avant l'acceptation de la confiance du dossier ?
**NON** : aucun hook avant l'acceptation, sur 6 lancement(s) avec le dialogue puis SessionStart.
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
| PostToolBatch | 2 | cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_calls, transcript_path |
| PostToolUse | 2 | cwd, duration_ms, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, tool_response, tool_use_id, transcript_path |
| PreToolUse | 4 | cwd, hook_event_name, permission_mode, prompt_id, scratchpad_dir, session_id, tool_input, tool_name, tool_use_id, transcript_path |
| SessionEnd | 6 | cwd, hook_event_name, prompt_id, reason, scratchpad_dir, session_id, transcript_path |
| SessionStart | 6 | cwd, hook_event_name, model, scratchpad_dir, session_id, session_title, source, transcript_path |
| Stop | 6 | background_tasks, cwd, hook_event_name, last_assistant_message, permission_mode, prompt_id, scratchpad_dir, session_crons, session_id, stop_hook_active, transcript_path |
| UserPromptSubmit | 8 | cwd, hook_event_name, permission_mode, prompt, prompt_id, scratchpad_dir, session_id, session_title, transcript_path |

## Terminal : modes et requêtes de claude
- Modes privés : ?1000h, ?1000l, ?1002h, ?1002l, ?1003h, ?1003l, ?1004h, ?1004l, ?1006h, ?1006l, ?1016l, ?1049h, ?1049l, ?2004h, ?2004l, ?2026h, ?2026l, ?2031h, ?2031l, ?25h, ?25l
- Requêtes auxquelles le terminal a répondu : CSI 16 t, DA1, DECRQM ?1016, DECRQM ?2026, OSC 11 ?, XTVERSION, kitty keyboard ?
- Codes OSC : 0, 11
- Drapeaux du protocole clavier kitty demandés : 0, 5

## Partage

`git add Tools/spikes/results && git commit -m "Résultats des spikes" && git push`
