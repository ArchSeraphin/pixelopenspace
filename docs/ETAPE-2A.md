# Étape 2a : agents, états et terminaux

Premier jalon du MVP (voir `docs/PROPOSITION.md`, section 8). Pas encore de post-its ni de scène isométrique : une
vue en liste, de vrais terminaux `claude` intégrés, et leur état en temps réel grâce aux hooks.

## Ce qui est livré

- **Projets** : « + Projet » (⌥⌘N) ou dépôt d'un dossier sur la fenêtre. Nom (10 caractères pour la future pancarte),
  couleur parmi 10, modèle et mode de permission par défaut. Renommer, changer la couleur, réordonner (⌘1…⌘9),
  archiver.
- **Agents** : « + Agent » (⇧⌘N) : nom généré, modèle, mode de permission (`bypassPermissions` exige de cocher la
  case de risque), worktree optionnel. Chaque agent lance le vrai `claude` dans un terminal SwiftTerm, avec ta
  connexion habituelle.
- **États en temps réel** par les hooks officiels, injectés **par session** avec `claude --settings`. Aucun fichier
  de `~/.claude` n'est modifié. États affichés : démarre, au repos, endormi, réfléchit, travaille (avec l'outil),
  attend ta réponse (permission ou question), tour terminé, tâche de fond, pause de limite d'usage, erreur,
  hors ligne. Chaque état a une icône et un texte, jamais la couleur seule.
- **Barre d'état** avec les compteurs, et **plateau d'attente** : qui attend quoi, depuis quand. Un clic sur une
  ligne ouvre le terminal de l'agent. ⌘' passe à l'agent en attente suivant (⇧⌘' au précédent).
- **Notifications macOS** dès qu'un agent attend, même app au premier plan (décision 18). Un clic ouvre l'agent.
  Badge du Dock = nombre d'agents en attente.
- **Terminal** en panneau sous la liste (⌘T), détachable dans sa propre fenêtre. C'est la même vue : le processus
  n'est jamais relancé. « Interrompre » (⌘.) n'envoie Échap que si l'agent travaille vraiment.
- **Quitter** : fermer la fenêtre ne quitte pas. ⌘Q propose « Attendre la fin des tours » si des agents
  travaillent ou attendent.
- **Relance** : projets, agents et réglages sont sauvegardés. Au redémarrage, les agents sont « hors ligne » ;
  « Relancer la session » (⇧⌘R) reprend la dernière conversation (`claude --resume`).
- **Réglages** (⌘,) : chemin de `claude` et détection, modèle et mode par défaut, vue agents, rendu classique,
  trafic non essentiel, variables d'environnement en plus, notifications, terminal.

## Lancer l'app

Prérequis : Xcode à jour (26 ou plus), Homebrew.

```bash
git clone https://github.com/ArchSeraphin/pixelopenspace.git
cd pixelopenspace
git checkout claude/macos-claude-code-visual-manager-7jskwz
Tools/bootstrap.sh
```

`bootstrap.sh` vérifie Xcode, installe XcodeGen (après confirmation), te demande ton identifiant d'équipe Apple
(il sait le détecter à partir de ton certificat « Apple Development ») pour créer `Config/Local.xcconfig`, génère
`PixelOpenSpace.xcodeproj`, puis l'ouvre. Ensuite, dans Xcode : schéma **PixelOpenSpace**, ⌘R.

- Au premier build, Xcode peut demander de faire confiance au plug-in de SwiftTerm (« Trust & Enable »).
- Après un `git pull` qui change `project.yml`, relance `xcodegen generate` (ou `Tools/bootstrap.sh`).
- Les tests du cœur se lancent sans Xcode : `cd Core && swift test`.
- Une signature stable (identité « Apple Development ») évite que macOS redemande les autorisations de
  notifications à chaque build.

## Démo 2a : critères d'acceptation 1 à 3

1. **3 projets, 2 sessions chacun** : ajoute trois dossiers de code, puis deux agents par projet. Les six
   terminaux démarrent ; chacun passe de « Démarre » à « Au repos ». Dans un dossier jamais ouvert avec Claude,
   le dialogue de confiance s'affiche dans le terminal : le poste indique alors « Regarde le terminal ».
2. **État juste en moins de 1 s** : demande « lis le README et résume-le » dans un terminal. La carte passe par
   « Réfléchit », « Travaille · Read », puis « Tour terminé ».
3. **Permission vue tout de suite, avec notification** : en mode `default`, demande « exécute `ls` ». La carte
   passe à « Attend ta réponse · Bash : ls » en moins d'une seconde, le plateau d'attente s'ouvre, une
   notification macOS arrive (app devant ou derrière) et le Dock affiche 1.

Les critères 4 (post-its) et 5 (relance complète) sont ceux de l'étape 2b.

## Spikes : à lancer une fois sur ton Mac

Le script vérifie avec ton vrai `claude` les points encore marqués ⚠️ dans la proposition : saisie dans la TUI,
délais, dialogues, identifiants de session, fusion des hooks. Il travaille dans des dossiers jetables avec le
modèle `haiku`, sans jamais toucher à `~/.claude` ni à tes dépôts. Compte 5 à 10 minutes et une trentaine de tours
courts.

```bash
Tools/spikes/run-spikes.sh
git add Tools/spikes/results && git commit -m "Résultats des spikes" && git push
```

Détails dans `Tools/spikes/README.md`. Ces résultats servent à régler l'envoi des post-its de l'étape 2b.

## Ce qui a été vérifié, et ce qui ne l'a pas été

- **Cœur** (`Core/`) : 376 tests, verts sous Linux ; la CI les relance sous Linux et macOS à chaque push.
- **App** : compilée par la CI macOS (Xcode 26) à chaque push, qui vérifie aussi que `pixel-hook` est bien embarqué
  et qu'il sort en silence avec le code 0.
- **Pas encore vérifié sur un vrai Mac** : le comportement réel des fenêtres (fermeture et réouverture,
  terminal détaché), le re-parentage du terminal entre panneau et fenêtre, les notifications signées, et les motifs
  d'écran de Claude Code (version 1, réglés sur la version 2.1.285). Ce que tu remarques pendant la démo
  m'intéresse.
- Un premier passage du script de spikes dans un conteneur, avec un vrai `claude` 2.1.285 sans compte, a déjà
  confirmé deux points :
  - les hooks passés par `--settings` **s'ajoutent** à ceux du projet ;
  - `SessionStart` n'arrive qu'**après** l'acceptation du dialogue de confiance du dossier.

## Reste à faire

- **Étape 2b** :
  - tableau de post-its (⌘N, collage de liste, 4 colonnes, filtres), éditeur et modèles de prompt ;
  - glisser-déposer d'un post-it sur un agent, « Donner à… », « premier agent libre » ;
  - livraison gardée dans le PTY (réglée par les spikes), file par agent, enchaînement après `Stop` confirmé ;
  - relance complète : feuille « Relancer les sessions », processus orphelins, « Continuer la tâche ».
- **Jalon visuel**, puis **étape 3** (open space isométrique) et les suivantes, comme prévu dans la proposition.
- **Petits manques connus de 2a** :
  - pas de palette ⌘K (étape 5) ;
  - pas d'icône de barre de menus (étape 5) ;
  - pas de sons 8 bits (étape 4) ;
  - pas de « Reprendre une ancienne conversation » depuis `~/.claude/projects` (étape 5).
