# Spikes de l'étape 2

Ce harnais vérifie sur ton Mac, avec ta vraie installation de Claude Code, les points marqués ⚠️ dans
`docs/PROPOSITION.md` (section 5.11). Il te suffit de le lancer une fois, puis de pousser les résultats.

## Lancer

```bash
cd pixelopenspace
Tools/spikes/run-spikes.sh
```

Prérequis : `claude` dans le `PATH` et connecté, `python3` 3.9 ou plus (fourni avec Xcode). `swift` est optionnel :
il sert seulement à mesurer la latence de `pixel-hook` (S9).

Le script affiche ce qu'il va faire et demande confirmation. Compte 5 à 10 minutes, sans toucher au clavier : tout
se passe dans des terminaux simulés, sans fenêtre.

## Ce qu'il fait

- Un dossier jetable par scénario dans `$TMPDIR/pos-spikes-<date>/` (dépôt git avec un premier commit, `a.txt`,
  `b.txt`), supprimé à la fin. Le commit a sa propre identité et ne lit ni hooks git ni signature.
- `claude --model haiku --permission-mode default`, avec les hooks de l'app passés par `--settings` : chaque
  événement est ajouté à un journal par `hooklog.py`, qui n'affiche rien et ne décide rien. Le même fichier ajoute
  la règle `ask` `Bash(touch *)`, pour que la demande de permission s'affiche quels que soient tes réglages.
- Il n'écrit **jamais** dans `~/.claude` ni dans tes dépôts. Il accepte la confiance des seuls dossiers jetables
  (en descendant sur « Yes, I trust this folder » : « No, exit » est sélectionné par défaut), ferme par Échap les
  dialogues de démarrage comme « Try the new fullscreen renderer? » (Échap = « Not now », rien n'est enregistré),
  répond « 1 » à une permission et en refuse une autre par Échap (des `touch` dans le dossier jetable).

| Scénario | Question |
|---|---|
| S1 | Les hooks de `--settings` s'ajoutent-ils à ceux de `.claude/settings.local.json` ? |
| S2 | `SessionStart` reçoit-il l'id passé par `--session-id` ? Que se passe-t-il si le terminal se ferme ? |
| S3.a–e | Délai avant Entrée, saut de ligne, collage entre crochets, prompt positionnel, permission « 1 » puis enchaînement |
| S4 | Identifiants de session après `/clear`, `/compact`, `/resume` (dans la session), `--resume`, `--fork-session` ; dossier des hooks avec `--worktree` |
| S5 | Événements après un refus par Échap |
| S7 | Texte des dialogues de permission et `AskUserQuestion` |
| S9 | Latence de `pixel-hook` (p50, p95) |
| S10 | Des hooks tournent-ils avant l'acceptation de la confiance du dossier ? |

S8 (glisser-déposer) et S11 (20 sessions dans Instruments) se testent dans l'app ; la ligne « limite d'usage » (S5)
et les touches de chaque option (S7) restent à vérifier à la main : `summary.md` les rappelle.
| S3b | Tâche de fond (optionnel : `--with-perturbation`) |

Options utiles : `--only S1,S4` (relancer une partie), `--with-perturbation`, `--pixel-hook CHEMIN`, `--keep-temp`,
`-v` (détail des étapes), `--list`, `--help`.

## Résultats

`Tools/spikes/results/<date>/` contient `summary.md` (réponses calculées), `environment.json`, et un dossier par
scénario : `events.jsonl` (hooks reçus), `pty.jsonl` (octets du terminal), `transcript.txt`, `screens/` (captures
d'écran en texte), `notes.json`. Chemins, nom d'utilisateur, nom complet, e-mail et nom de machine sont remplacés
par `~`, `<user>`, `<name>`, `<email>` et `<host>`. Relis `summary.md` si tu veux, puis :

```bash
git add Tools/spikes/results && git commit -m "Résultats des spikes" && git push
```

## Tests du harnais

`python3 Tools/spikes/test_spikes.py` (sans `claude` : un faux TUI, `fake_tui.py`, joue son rôle).
