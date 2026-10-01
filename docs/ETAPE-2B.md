# Étape 2b : post-its, livraison gardée et relance

Second jalon du MVP (voir `docs/PROPOSITION.md`, section 8). Le tableau de post-its arrive à côté des agents. Un
post-it donné à un agent part tout seul dans son terminal, par une livraison gardée qui ne répond jamais à un
dialogue à ta place. L'app sait aussi quitter puis relancer sans rien reprendre toute seule. Toujours pas de scène
isométrique : elle arrive à l'étape 3. L'étape a été livrée en trois morceaux : 2b-1 (post-its), 2b-2 (livraison
gardée), 2b-3 (quitter, relancer, reprendre).

## Ce qui est livré

### 2b-1 : le tableau de post-its

- **Tableau** en panneau à droite des agents (⌘B l'affiche ou le masque ; tire son bord gauche pour changer sa
  largeur). Quatre sections empilées : « À faire », « En cours », « À valider », « Fait » (repliée par défaut).
  Le tableau plein écran de la maquette 6(c) viendra avec l'étape 3.
- **Créer un post-it** : ⌘N ouvre un champ de titre en haut de « À faire » (et affiche le tableau s'il était
  masqué). Entrée crée le post-it et laisse le champ vide pour le suivant ; Échap, ou Entrée sur un champ vide,
  le ferme. Le post-it prend le projet du filtre du tableau, sinon le projet sélectionné. Le tableau défile
  jusqu'au nouveau post-it et le surligne un instant.
- **Coller une liste** (⇧⌘V) : un post-it par ligne. Les puces (`-`, `*`, `•`, `1.`, `1)`, `[ ]`) sont retirées et
  les lignes vides ignorées ; aperçu avant création, ⌘↩ crée.
- **Filtres** : projet, recherche approximative (« Chercher… »), tags.
- **Un post-it montre** : sa punaise (rouge haute, jaune normale, verte basse ; la priorité est aussi écrite au
  survol et lue par VoiceOver), la couleur de son projet, ses tags, une ligne d'état (« non assigné »,
  « Nova · file #2 », « Nova · file #1 · occupé », « Pixou · en cours · 6 min », « Rio · fini il y a 2 min ») et
  ses drapeaux en toutes lettres (« échec d'envoi », « interrompue », « tour en échec », « session perdue »,
  « tâche de fond en cours »).
- **Clavier, sur un post-it qui a le focus** : Entrée (ou double-clic) ouvre l'éditeur ; ⌘↩ valide un post-it
  « À valider » (ailleurs, il le marque fait après confirmation) ; ⌥⌘↩ le renvoie avec une précision ; ⌘⌫ le
  supprime ; ↑ et ↓ passent au post-it précédent ou suivant.
- **Éditeur** (maquette 6(l)) : titre, description, projet, priorité, tags, modèle de prompt
  (« Gérer les modèles… »), « Donner à… » (⌘D, liste d'agents utilisable au clavier), « Retirer », et l'**aperçu
  exact** du texte qui sera tapé dans le terminal. Cet aperçu passe par le même chemin que la livraison (modèle,
  puis nettoyage) et donne le nombre de caractères, « saisie courte » ou « collage », les caractères retirés, et
  l'alerte au-delà de 16 Ko. Puis l'historique. ⌘↩ enregistre, Échap annule.
- **Modèles de prompt** (Fichier › « Gérer les modèles de prompt… ») : trois modèles de départ (« Corriger un bug »,
  « Ajouter une fonctionnalité », « Écrire la documentation »), les variables `{titre}` `{description}` `{projet}`
  `{chemin}` `{tags}` `{priorite}`, et un modèle par défaut pour chaque projet. Sans modèle, le texte envoyé est le
  titre, puis la description.
- **Donner un post-it à un agent** :
  - le glisser sur la carte de l'agent (« Donner à Nova » s'affiche pendant le survol) ;
  - clic droit › « Donner à › », ou « Donner au premier agent libre (Nova) » ;
  - sans agent lancé dans le projet : « Lancer un nouvel agent avec ce post-it » (le post-it devient son premier
    prompt) ;
  - un agent d'un autre projet demande une confirmation.
- **Glisser entre les sections** : vers « À faire », le post-it est remis à faire ; vers « À valider », il est
  marqué à valider ; vers « Fait », il est validé. Dans une même section, l'ordre change. Un post-it « En cours »
  ou « À valider » ne se redonne pas : il faut d'abord le remettre à faire.
- **Cycle de vie** : chaque changement passe par le réducteur `TaskLifecycle` (lignes C1 à C20 de la proposition,
  4.3b).
- **Sauvegarde** : `state/tasks.json` dans `~/Library/Application Support/PixelOpenSpace/`, écrit comme
  `workspace.json` (fichier 0600 atomique, sauvegarde du jour, fichier illisible mis de côté avec une bannière,
  lecture seule si son format est plus récent que l'app).

### 2b-2 : la livraison gardée

- **Une file par agent** : les consignes d'abord, puis les post-its dans l'ordre. Le premier part tout seul quand
  l'agent est libre : au repos, ou tour terminé **confirmé** (`Stop`, puis 3 s de calme et un écran au repos),
  après une pause de 1,5 s entre deux tâches.
- **Sinon, il attend**, et la carte de l'agent comme le post-it disent pourquoi : « occupé », « attend ta
  réponse », « attend une tâche de fond », « en pause : limite d'usage », « ✎ brouillon », « écran non reconnu »,
  « file en pause », « hors ligne », « hooks non reçus : envoi automatique coupé », « pause entre deux tâches »,
  « envoi en cours », « l'app va quitter ».
- **Envoi en deux temps** (proposition 5.6) : garde avant le texte, écriture du texte, attente de la fin
  d'écriture et d'un délai, garde avant l'Entrée, `\r` seul dans une écriture à part, puis attente de
  `UserPromptSubmit` pendant 3 s. Chaque garde relit l'écran et le compteur de hooks de l'agent juste avant
  d'écrire. Une garde qui échoue arrête tout : rien n'est « essayé quand même », et l'Entrée n'est jamais écrite
  après un échec. Sans confirmation de Claude Code, une seule Entrée de plus, gardée elle aussi.
- **Texte court** (800 caractères et 3 lignes au plus) : tapé comme au clavier, les lignes séparées par `LF`.
  **Texte long** : une amorce tapée (« Réalise la tâche décrite dans le texte collé ci-dessous. »), puis un collage
  entre crochets. Si le terminal n'accepte pas ce collage, refus « trop long pour un envoi sûr ». Au-delà de
  16 Ko, la carte de l'agent demande « Texte de n Ko : l'envoyer ? » avec [Envoyer].
- **Le post-it change de colonne tout seul** : « En cours » dès que `UserPromptSubmit` reprend le début du texte
  envoyé, « À valider » au `Stop` confirmé, avec [Valider] et ↺ (« Renvoyer avec une précision »). Puis la file
  enchaîne.
- **Échec d'envoi** : le post-it reste en tête de « À faire » avec « échec d'envoi », la file de l'agent se met en
  pause, et sa carte affiche « Dernier envoi : <raison> » avec [Ouvrir le terminal]. « Réessayer l'envoi » (clic
  droit sur le post-it) ou « Reprendre la file » relancent.
- **Brouillon** : si la zone de saisie du terminal contient du texte, rien n'est écrit. « Envoyer quand même… »
  (après une mise en garde) ne lève que ce point, et seulement tant que la zone montre le texte que tu as vu ;
  jamais un dialogue, un tour en cours ni un nouvel événement.
- **Écran non reconnu** (autre version de Claude Code, vue plein écran) : rien n'est envoyé, un bandeau
  « Envoi automatique suspendu : écran non reconnu » s'affiche en haut du tableau avec [Terminal], et l'app relit
  l'écran d'elle-même (après 0,5 s, 1 s, 2 s, puis toutes les 4 s).
- **Interrompre** (⌘.) met la file en pause. Le post-it reste « En cours » avec « interrompue » et propose
  « Continuer la tâche », « Remettre à faire » ou « Marquer à valider ». Rien n'est renvoyé tout seul.
- **Refus d'une permission par Échap** : Claude Code n'envoie alors aucun hook (spikes S5 et S7). L'app relit
  l'écran après ta touche Échap : dès que le dialogue a disparu, l'attente se ferme. Si le tour s'arrête là, c'est
  compté comme une interruption (file en pause, post-it « interrompue »).
- **« Donner une consigne… »** (menu « … » de la carte d'agent, ⌘↩ pour l'envoyer) : même livraison gardée, en
  tête de file si l'agent est occupé.
- **Latence hook → écran** : p50 et p95 sur les 500 dernières mesures, dans Réglages › Avancé (objectif : p95 sous
  150 ms).
- **L'app n'écrit jamais** que le texte, les marqueurs de collage et `\r` : ni flèche, ni Ctrl+C, Ctrl+D ou Ctrl+U,
  ni réponse à un dialogue.

### 2b-3 : quitter, relancer, reprendre

- **Quitter pendant un tour** (⌘Q) : la feuille de sortie de 2a. « Attendre la fin des tours » bloque désormais
  toute nouvelle livraison : les files affichent « l'app va quitter », et une bannière « Pixel Open Space quittera
  à la fin des tours en cours » propose [Ne plus quitter]. « Quitter quand même » ferme les sessions.
- **Au redémarrage**, le post-it « En cours » de chaque agent hors ligne reçoit le drapeau « session perdue ». Il
  reste « En cours » ; rien n'est mis en file ni envoyé. La file de cet agent se met en pause (« file en pause ») :
  une fois l'agent relancé, son post-it suivant ne part pas tant que le post-it perdu n'est pas tranché.
- **Bannière « n sessions peuvent être relancées »** :
  - [Tout relancer] : les sessions cochées par défaut ; leurs post-its en cours sont remis à faire ;
  - [Choisir…] : la feuille « Relancer les sessions » ;
  - [Plus tard] : la bannière disparaît jusqu'au prochain lancement ; chaque agent reste relançable par son bouton
    « Relancer » ou ⇧⌘R.

  Les dossiers, transcripts et processus encore ouverts sont relus quand la bannière ou la feuille s'affiche, sur
  [Actualiser], après une relance, et toutes les 5 s au plus sinon.
- **Feuille « Relancer les sessions »** (maquette 6(p)) : une ligne par agent (nom · projet, titre du post-it en
  cours ou « session 7d2f… », « il y a 2 h », dossier) :
  - conversation reprenable : cochée, `claude --resume <id>` dans son dossier ;
  - dossier de la session disparu (worktree supprimé) : cochée, la conversation est dupliquée dans le dossier du
    projet (`--resume <id> --fork-session`) ;
  - transcript purgé ou aucune session : « une nouvelle session sera créée », non cochée ;
  - session encore tenue par un processus vivant hors de l'app (après un plantage) : ligne désactivée « ⚠ tourne
    encore hors de l'app (pid n) », avec [Terminer ce processus] et [Laisser tourner]. Jamais de `--resume` d'une
    session tenue par un processus vivant ;
  - dossier du projet introuvable : ligne désactivée.

  Pour un post-it en cours : « Continuer la tâche » ou « Remettre à faire » (choix par défaut). Puis
  « Relancer n sessions ». [Fermer] (ou Échap) ferme seulement la feuille : la bannière reste. [Plus tard] fait
  comme sur la bannière.
- **« Continuer la tâche »** n'agit qu'**une fois la session démarrée** : la consigne « Continue la tâche :
  <titre> » passe en tête de file et part par la livraison gardée. Si le processus s'arrête avant, le post-it garde
  « session perdue » et un message le dit, et la file reste en pause. « Remettre à faire » s'applique tout de suite
  et reprend la file.
- Une fois une session relancée et son post-it perdu tranché (« Continuer la tâche » ou « Remettre à faire » dans
  la feuille ou par [Tout relancer]), les post-its qui attendaient déjà dans sa file (donnés par toi avant de
  quitter) repartent normalement quand l'agent est libre. Seul le tour interrompu ne repart jamais tout seul.
- Un post-it perdu tranché plus tard par son menu (« Remettre à faire », « Marquer à valider », « Marquer comme
  fait… », « Continuer la tâche ») : « Continuer la tâche » reprend la file ; sinon [Reprendre la file], grisé sur la
  carte de l'agent tant qu'un post-it arrêté reste « En cours », devient cliquable.

### Raccourcis

| Raccourci | Action | Menu |
|---|---|---|
| ⌘N | Nouveau post-it | Fichier |
| ⇧⌘V | Coller une liste de post-its… | Fichier |
| ⌥⌘N | Nouveau projet… | Fichier |
| ⇧⌘N | Nouvel agent… | Fichier |
| ⌘B | Afficher ou masquer le tableau | Présentation |
| ⌥⌘T | Afficher ou masquer le terminal | Présentation |
| ⌘T | Ouvrir le terminal de l'agent sélectionné | Agent |
| ⌘. | Interrompre | Agent |
| ⇧⌘R | Relancer la session | Agent |
| ⌘' et ⇧⌘' | Agent en attente suivant, précédent | Aller |
| ⌥⌘→ et ⌥⌘← | Agent suivant, précédent | Aller |
| ⌘1 à ⌘9 | Aller au projet n | Aller |

Sans raccourci (menu seulement) : « Gérer les modèles de prompt… », « Fermer la session », « Retirer l'agent ».
Sur un post-it qui a le focus : Entrée, ⌘↩, ⌥⌘↩, ⌘⌫, ↑ ↓. Dans l'éditeur : ⌘D, ⌘↩, Échap. Les commandes qui
ouvrent une feuille (⌘N, ⇧⌘V, ⌥⌘N, ⇧⌘N, les modèles) sont grisées tant qu'une feuille est ouverte.

## Lancer l'app

Comme pour l'étape 2a (voir `docs/ETAPE-2A.md`). Si le dépôt est déjà cloné :

```bash
git pull
xcodegen generate      # project.yml a changé : type de glisser-déposer des post-its
```

Puis, dans Xcode : schéma **PixelOpenSpace**, ⌘R. Les tests du cœur : `cd Core && swift test`.

## Démo 2b : critères d'acceptation 4 et 5

**Préparation** : un projet sur un dépôt sans valeur (par exemple `mkdir ~/demo-pos && cd ~/demo-pos && git init &&
echo "# Démo" > README.md`), un agent « Nova » en mode de permission `default`, lancé et « Au repos » (accepte
toi-même le dialogue de confiance du dossier). Tableau visible (⌘B). Si Claude demande une permission pour
`sleep` dans les étapes ci-dessous, réponds « 1 » toi-même dans le terminal : l'app ne le fera jamais.

### Critère 4 : un post-it en moins de 5 s, donné par glisser-déposer, qui change de colonne tout seul

1. ⌘N, tape « Lis le README et résume-le en trois lignes », Entrée. Chronomètre : moins de 5 s entre ⌘N et le
   post-it dans « À faire ».
2. Glisse le post-it sur la carte de Nova : son cadre s'épaissit et « Donner à Nova » s'affiche. Lâche.
3. Le texte apparaît dans le terminal de Nova et part seul. Le post-it passe dans « En cours » (« Nova · en
   cours · … ») dès que Claude Code a reçu le prompt.
4. Quelques secondes après la fin du tour (3 s de calme après le `Stop`), le post-it passe dans « À valider »
   avec [Valider] et ↺. [Valider], ou ⌘↩ sur le post-it sélectionné, le range dans « Fait ».

**Agent occupé : file, puis envoi après le `Stop` confirmé**

5. ⌘N « Exécute la commande sleep 45 avec l'outil Bash, puis réponds juste OK », Entrée, et glisse-le sur Nova.
   Nova passe « Travaille · Bash ».
6. ⌘N « Réponds juste : deuxième post-it reçu », Entrée, et glisse-le sur Nova pendant qu'il travaille. Le
   post-it reste dans « À faire » avec « Nova · file #1 · occupé » ; la carte de Nova affiche « file : 1 post-it ·
   occupé ».
7. À la fin du `sleep` : le premier post-it passe « À valider » après les 3 s de calme, la file indique « pause
   entre deux tâches » pendant 1,5 s, puis le second part tout seul, passe « En cours », puis « À valider ».

### Critère 5 : quitter pendant un tour, relancer, reprendre

1. Donne à Nova un post-it « Exécute la commande sleep 120 avec l'outil Bash, puis réponds juste OK ». Attends
   qu'il soit « En cours » et que Nova affiche « Travaille · Bash ».
2. Donne-lui un second post-it, « Réponds juste : file reprise » : il attend en « file #1 ».
3. ⌘Q : la feuille « Quitter Pixel Open Space ? » liste Nova. Choisis « Attendre la fin des tours ». La bannière
   « Pixel Open Space quittera à la fin des tours en cours » s'affiche, et le second post-it indique « Nova ·
   file #1 · l'app va quitter » au lieu de partir.
4. Avant la fin du `sleep`, ⌘Q encore, puis « Quitter quand même » : l'app ferme les sessions et quitte.
5. Relance l'app (⌘R dans Xcode). Projets, agents et post-its reviennent. Nova est « Hors ligne ». Le premier
   post-it est toujours « En cours », avec « session perdue » ; le second est toujours en « file #1 · file en
   pause ». Rien ne part.
6. Sur la bannière « 1 session peut être relancée », clique [Choisir…]. La feuille « Relancer les sessions »
   montre Nova, le titre du post-it en cours, « à l'instant » ou « il y a n min », et le dossier. Choisis
   « Continuer la tâche », puis « Relancer 1 session ».
7. Le terminal de Nova reprend la conversation (`claude --resume`) : l'échange d'avant est visible. Une fois la
   session démarrée, « Continue la tâche : Exécute la commande sleep 120… » part tout seul ; « session perdue »
   disparaît. À la fin du tour, le post-it passe « À valider », puis le second post-it part.
8. Variante : refais les étapes 1 à 5, puis clique [Tout relancer]. La session est reprise, le post-it en cours
   revient dans « À faire » sans agent, et le second post-it part dès que Nova est libre.

### Trois vérifications des règles de sécurité

1. **Une permission n'est jamais répondue par l'app.** Donne à Nova « Crée le fichier essai-1.txt avec la commande
   touch ». Le post-it passe « En cours », Nova « Attend ta réponse · Bash : touch essai-1.txt », une notification
   arrive. Donne-lui un second post-it : il reste en « file #1 · attend ta réponse ». Attends 30 s : le dialogue
   est toujours là, `essai-1.txt` n'existe pas, rien n'a été tapé. Réponds « 1 » toi-même : le tour continue, puis
   la file reprend.
2. **Un brouillon bloque la livraison.** Dans le terminal de Nova au repos, tape « brouillon » sans Entrée.
   Glisse un post-it sur Nova : il reste dans « À faire » avec « Nova · file #1 · ✎ brouillon », la carte de Nova
   propose [Envoyer quand même…], et rien n'est écrit dans le terminal. Efface ton texte : le post-it part en
   quelques secondes.
3. **Échap sur une permission ferme l'attente.** Donne à Nova « Crée le fichier essai-2.txt avec la commande
   touch ». Quand le dialogue s'affiche, clique dans le terminal et appuie sur Échap (« Interrompre » est grisé
   pendant une attente). En une seconde environ, l'attente disparaît (plateau, badge du Dock), Nova repasse « Au
   repos », le post-it reste « En cours » avec « interrompue », et la file est en pause : rien ne part. Clic droit
   sur le post-it › « Remettre à faire » (ou « Continuer la tâche »), puis [Reprendre la file] sur la carte de
   Nova.

## Ce que les spikes ont réglé

Résultats de `Tools/spikes/run-spikes.sh` sur ton Mac le 30 septembre (Claude Code 2.1.285, 13 scénarios sur 13
réussis ; détails dans `Tools/spikes/results/20260930-185108/summary.md`) :

- **Texte tapé d'un bloc, puis Entrée seule** après 30, 120 ou 250 ms : `UserPromptSubmit` à chaque fois, prompt
  identique, environ 60 ms après l'Entrée. Les délais de la proposition sont donc gardés : 120 ms sous 500 octets,
  250 ms sous 2 Ko, 500 ms sous 16 Ko, 1 s au-delà. Ils sont tous au-dessus de ce qui a marché.
- **`LF` dans le texte tapé** = un saut de ligne dans le prompt : d'où la saisie des textes courts sur plusieurs
  lignes.
- **Collage entre crochets** actif (`ESC[?2004h`) : l'amorce tapée suivie d'un collage de 1 200 caractères arrive
  intacte. L'écran affiche `[Pasted text #1 +12 lines]` après l'amorce : c'est le début de l'amorce que la garde
  cherche avant l'Entrée.
- **Prompt positionnel** confirmé par `UserPromptSubmit` environ 0,5 s après `SessionStart` : c'est ainsi que
  « Lancer un nouvel agent avec ce post-it » confirme la livraison.
- **Permission** : « 1 » seul répond, et un nouveau prompt enchaîne normalement après le `Stop`.
- **Refus par Échap** (permission ou `AskUserQuestion`) : aucun hook. Seul l'écran dit que le dialogue a disparu,
  d'où la règle T28b de 2b-2.
- **`--resume`** garde le `session_id`, **`--fork-session`** en donne un nouveau, `/clear` le change : c'est ce que
  la feuille de relance utilise.
- **Motifs d'écran** (`ScreenPatterns` version 2) réglés sur les captures réelles : zone de saisie vide, brouillon,
  spinner, dialogues de permission et de question, confiance du dossier. Ces captures sont devenues des tests.
- **`pixel-hook`** : p95 de 9,3 ms jusqu'au socket.

## Ce qui a été vérifié, et ce qui ne l'a pas été

- **Cœur** (`Core/`) : `cd Core && swift test` donne **761 tests dans 47 suites, tous verts**, sur ce Mac
  (2a en comptait 376). Les cas délicats ont chacun leur test : dialogue qui surgit avant l'Entrée
  (`beforeEnterAbortsOnNewHookEvent`, `beforeEnterAbortsOnDialog`), brouillon (`draftBlocks`,
  `sendAnywayLiftsOnlyDraft`), écran non reconnu (`unrecognizedScreenAborts`), refus par Échap
  (`escapeRefusalClearsWaitFromScreen`), processus arrêté pendant l'envoi (`processGoneAbortsEveryGuard`),
  sortie en attente (`quitPendingBlocksDelivery`), orphelin vivant, transcript purgé et dossier disparu
  (`RelaunchPlannerTests`), invariants du cycle de vie par tests de propriétés.
- **CI** (Linux et macOS) : verte jusqu'au commit `78b9fbc`. Les deux derniers commits de code (`5a93a97` et
  `9fd904b` : dossier du projet introuvable, bannière et feuille de relance) et ce guide ne sont pas encore
  poussés : la CI les vérifiera au prochain push.
- **App** : compilée en Debug avec `xcodebuild` (BUILD SUCCEEDED, sans avertissement de concurrence).
- **App lancée une fois sur ce Mac, puis quittée** : le journal (sous-système `fr.vv2.pixelopenspace`) montre le
  serveur de hooks à l'écoute et `claude` 2.1.286 détecté ; la sortie est propre. L'écran n'était pas visible :
  je n'ai rien vu de l'interface elle-même.
- **Pas vérifié, personne n'a cliqué dans l'interface** :
  - ⌘N et le champ de titre, le chrono des 5 s, l'éditeur, les modèles, le collage de liste ;
  - le glisser-déposer d'un post-it sur une carte d'agent et entre les sections (le spike S8 prévoyait de le
    tester dans l'app : c'est ta démo qui le fera) ;
  - une vraie livraison dans un terminal de l'app : texte tapé, Entrée, post-it qui passe « En cours » puis
    « À valider », enchaînement de la file, collage d'un texte long, « Envoyer quand même… » ;
  - la feuille de sortie avec les livraisons bloquées, la bannière et la feuille de relance, une vraie reprise
    `--resume` suivie de « Continuer la tâche », le fork dans le dossier du projet, un orphelin après un
    plantage ;
  - VoiceOver sur le tableau et les post-its (les libellés et actions existent dans le code, personne ne les a
    écoutés) ;
  - ⌘. sur un clavier AZERTY, où le point demande Maj (checklist prévue à l'étape 5).
- **Autres limites connues** :
  - ton Mac a maintenant Claude Code **2.1.286**, et les motifs d'écran ont été réglés sur 2.1.285. Si l'écran a
    changé, tu verras « écran non reconnu » et rien ne partira : dis-le-moi, avec une capture du terminal ;
  - le spike S3b (une tâche de fond ou un cron qui relance un tour pendant une livraison) n'a pas été lancé : ce
    cas n'est couvert que par les tests des gardes ;
  - la latence hook → écran s'affiche dans Réglages › Avancé, mais n'a jamais été mesurée sur de vraies sessions.
    Note le p95 pendant ta démo.

## Reste à faire

- **Ta démo** des critères 4 et 5 et des trois vérifications ci-dessus, avec le vrai `claude`. L'étape 2 est
  terminée quand les 5 critères passent sur ton Mac, que le p95 est noté et que la CI est au vert. Ce que tu
  remarques pendant la démo m'intéresse.
- **Pas fait en 2b** :
  - « Glisser dans le tour en cours » (une consigne écrite dans le tour d'un agent occupé) ;
  - le tableau plein écran (6(c)), avec l'étape 3 ;
  - l'XP et les badges à la validation d'un post-it (étape 6) ;
  - les tests d'interface `xcodebuild` avec `fake-claude` (étape 3) ;
  - le spike S11 (20 sessions au repos pendant 10 min, dans Instruments), à l'étape 3.
- **Jalon visuel** : la planche de contact des sprites v0 et un îlot complet (un agent dans chaque état, post-its,
  pancarte, lampe) aux zooms ×1, ×2 et ×3, de jour et de nuit, plus la vue de 20 agents sur 6 projets. Tu valides
  la direction artistique avant l'étape 3.
- **Étapes suivantes** :
  - **3** : l'open space isométrique (scène, caméra, avatars animés, glisser un post-it sur un agent de la scène,
    mini-carte ; la vue actuelle reste disponible par ⌘L) ;
  - **4** : finitions visuelles (palette finale, animations, polices, mode nuit, sons 8 bits, icône) ;
  - **5** : confort (palette ⌘K, icône de barre de menus, notifications avec actions, restauration des fenêtres,
    installation globale optionnelle des hooks, « Reprendre une ancienne conversation ») ;
  - **6** : gamification (noms et apparence des agents, XP, niveaux, badges, décor) ;
  - **7** : bonus (import GitHub, statistiques du jour, options).
