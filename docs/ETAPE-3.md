# Étape 3 : l'open space isométrique

Troisième jalon (voir `docs/PROPOSITION.md`, section 8 « Étape 3 »). La liste des agents laisse la place à l'open
space isométrique validé au jalon visuel : un îlot par projet, un poste par agent, un avatar animé selon son état.
La scène SpriteKit dessine exactement ce que le cœur a calculé, au pixel près à chaque zoom. On s'y déplace à la
souris, au trackpad et au clavier ; un clic sur un agent ouvre sa fenêtre, un double-clic son terminal ; un post-it
se glisse du tableau sur un agent de la scène, même quand l'agent est hors du champ au début du glisser. La vue Liste
de l'étape 2 reste là, par ⌘L, et reste le chemin principal pour VoiceOver. La scène est toujours de jour : le mode
nuit arrive à l'étape 4.

Le plan d'implémentation, tâche par tâche, est dans `docs/superpowers/plans/2026-10-01-etape-3-open-space.md`.

## Ce qui est livré

Les numéros sont ceux des tâches du plan.

1. **Banc de captures et mode démo.** `PixelOpenSpace --snapshot` lance l'app sur un état temporaire isolé, avec un
   open space simulé (6 projets, 20 agents dans tous les états, un tableau de 19 post-its), capture la fenêtre et la
   scène en PNG, compare la scène à son rendu logiciel, écrit un rapport, puis quitte tout seul. `--demo` ouvre le
   même open space simulé dans une fenêtre visible, pour le protocole « 3 s » et les mesures.
2. **Jalon visuel validé le 2026-10-01** : le « ! » d'attente se lit comme un « ! » (barre anguleuse, point carré,
   halo en losange), flèche de bord diagonale, yeux fermés de l'agent endormi, mèches des cheveux courts vus de dos,
   lampe de bureau qui se détache du moniteur. Détails dans `docs/jalon-visuel/README.md`.
3. **Caméra au pixel près** (cœur) : paliers de zoom, recalage sur la grille des pixels physiques de l'écran, marge
   de 48 pt autour du monde, « Tout voir », vols de caméra de 0,4 s, pincement par paliers, placement des flèches de
   bord, mini-carte, défilement automatique pendant un glisser ; **atlas** des sprites et son manifeste
   (`sprite-export --atlas`, voir `docs/ASSETS.md`).
4. **Plan de scène** (cœur) : `ScenePlanner` donne chaque élément de la scène avec un identifiant stable, sa position
   en texels entiers, son ordre de dessin et ce qu'un clic dessus veut dire ; le sol, les ombres et les murs forment
   un fond cuit en une image. Le rendu logiciel du jalon (`SceneCompositor`) passe par ce même plan : c'est la
   référence à laquelle la scène de l'app est comparée.
5. **Rien ne bouge jamais** (cœur) : les annexes d'un îlot (ses parties 2, 3…) gardent leur place à vie, comme
   l'îlot lui-même ; chaque nouvel agent reçoit une apparence générée à partir de son identifiant ; `workspace.json`
   passe en version 2 ; le cœur sait dire ce qui vient de se passer dans le monde (arrivée, départ, tour terminé,
   post-it reçu, îlot ou postes qui apparaissent) et trouver le chemin de l'ascenseur à un siège.
6. **Règles d'interaction** (cœur, une règle par test) : clic au pixel près sur la forme dessinée, règles du clic et
   du double-clic, table de dépôt d'un post-it, annonces VoiceOver regroupées. En vue d'ensemble, les plaques de nom
   des agents urgents sont dessinées ×2.
7. **Scène SpriteKit**, caméra, vue Liste (⌘L), zoom (⌘+, ⌘−, ⌘0) et monde vide (maquette 6(r)).
8. **Fenêtre agent** (maquettes 6(d), 6(e), 6(e′)).
9. **Souris, trackpad et clavier** dans la scène : déplacements, zoom, clics, survol, menu contextuel, « Nouvel agent
   ici ? ».
10. **Repères** : mini-carte, flèches de bord, contrôle de zoom dans la barre d'état, vols de caméra depuis la barre
    d'état et le plateau d'attente, accessibilité de la scène (éléments VoiceOver, rotor, annonces regroupées).
11. **La scène vit** : arrivée par l'ascenseur, départ, célébration d'un tour terminé, étirement et café au repos,
    meubles qui tombent dans la poussière quand un îlot apparaît.
12. **Glisser un post-it sur la scène**, tableau latéral et plein écran (⌘B).
13. Ce guide et le contrôle d'ensemble.

## Se déplacer dans l'open space

**Paliers de zoom** : quatre, jamais d'échelle intermédiaire au repos.

- **½**, la vue d'ensemble : un pixel de ton écran par pixel du dessin, donc net ; proposée seulement sur un écran
  Retina. Seuls les signes urgents y restent (le « ! » XL et son halo, l'orage d'un agent en erreur), avec la plaque
  de nom de ces agents et les pancartes des îlots, ×2.
- **×1**, **×2**, **×3** : chaque pixel du dessin fait 2, 4 ou 6 pixels de ton écran Retina.

Au lancement : ×2, centré sur le monde. La caméra garde 48 pt de marge autour du monde ; un monde plus petit que la
vue y est centré. **Tout voir** (⌘0) prend le plus grand palier qui montre tout le monde, centré, sinon ×1 centré avec
la mini-carte. Dans une fenêtre de 1440 × 900 pt avec le plateau d'attente, une bannière et le tableau latéral,
l'open space simulé de 20 agents ne tient qu'à ×1 ; tableau masqué, la vue d'ensemble le montre en entier.

| Pour… | Trackpad | Souris | Clavier |
|---|---|---|---|
| Se déplacer | deux doigts | glisser sur le sol vide (au-delà de 3 pt), bouton du milieu, ou Espace maintenu + glisser ; ⇧ + molette : à l'horizontale | flèches, focus dans la scène (pas de 64 pt), ⇧ + flèches (quatre fois plus) |
| Zoomer | pincement : un palier dès que le geste est assez ample, autour du curseur | molette : un palier par cran, autour du curseur | ⌘+ (ou ⌘=) et ⌘− |
| Tout voir | | | ⌘0 |

Un glisser qui part d'un agent ou d'un poste ne déplace jamais la vue. Le contrôle « ½ | ×1 | ×2 | ×3 », à droite de
la barre d'état en mode scène, montre et change le palier (« ½ » absent sans écran Retina). Le menu contextuel du sol
propose aussi « Tout voir » et « Vue Liste ».

### Raccourcis de l'étape 3

| Raccourci | Action | Menu |
|---|---|---|
| ⌘L | Vue Liste ou open space (aussi le bouton de la barre d'outils) | Présentation |
| ⌘+ (ou ⌘=) et ⌘− | Zoom avant, arrière (en mode scène seulement) | Présentation |
| ⌘0 | Tout voir (en mode scène seulement) | Présentation |
| ⌘B | Tableau : latéral, puis plein écran, puis masqué | Présentation |
| ↩ ou Espace | Ouvrir la fenêtre de l'agent sélectionné (focus dans la scène) | |
| Échap | Désélectionner (focus dans la scène) | |
| ⌘' et ⇧⌘', ⌥⌘→ et ⌥⌘← | Agent en attente suivant ou précédent, agent suivant ou précédent : la caméra vole jusqu'à lui | Aller |

Dans la fenêtre agent : ⌘W la ferme, ⌘T ouvre le terminal, ⌘. interrompt, Échap interrompt seulement si l'agent
réfléchit ou travaille (après un toast « Interruption dans 1,5 s » annulable), sinon ferme. Les autres raccourcis de
l'étape 2 (voir `docs/ETAPE-2B.md`) ne changent pas.

## Règles de clic

Le clic vise ce qui est dessiné : un clic dans la partie transparente du cadre d'un avatar tombe sur ce qu'il y a
derrière (le sol de l'îlot, un bureau).

- **Clic sur un agent** : il est sélectionné tout de suite (anneau sous son siège). Sa fenêtre s'ouvre si aucun second
  clic n'arrive dans le délai de double-clic de macOS.
- **Double-clic sur un agent** : son terminal, et seulement lui. Aucune fenêtre ne s'ouvre ni ne clignote, la caméra ne
  bouge pas.
- **Clic sur un poste libre** : un popover « Nouvel agent ici ? » (« Un agent du projet API s'installe à ce poste, et
  sa session démarre. »), [Créer] (↩) ou [Annuler]. Rien n'est jamais créé sans ce choix. Un double-clic sur un poste
  ne fait rien de plus.
- **Double-clic sur le sol ou la pancarte d'un îlot** : la caméra vole jusqu'à l'îlot.
- **Clic sur le sol vide, le mur de liège, l'ascenseur ou un accessoire du hall** : désélection.
- **Clic droit** (ou ⌃ + clic) : menu contextuel natif, avec les mêmes commandes que les menus, grisées avec leur
  raison comme ailleurs :
  - sur un agent : « Ouvrir la fenêtre de l'agent », « Ouvrir le terminal », « Donner une consigne… »,
    « Interrompre », « Relancer la session », « Fermer la session… », « Renommer… », « Retirer l'agent… » ;
  - sur un poste libre : « Nouvel agent ici… » ;
  - sur un îlot : « Nouvel agent dans API… », « Centrer l'îlot », « Renommer le projet… » ;
  - sur le sol : « Tout voir », « Vue Liste ».
- Tout nouveau clic annule une fenêtre qui attendait la fin du délai de double-clic.

**Survol** : un agent survolé montre sa plaque de nom ; un poste libre, ses marques au sol. Après 0,3 s d'immobilité,
une carte apparaît près du curseur : « Bip · API · TRAVAILLE », « commande · depuis 1 min · 2 sous-agents »,
« clic : fenêtre · double : terminal » ; sur un poste libre, « Poste libre · clic : nouvel agent ici ». Un mouvement de
caméra la fait disparaître. La carte se pose à côté du curseur sans passer sous la mini-carte ni sous une flèche de bord
(au besoin juste contre elles) ; le curseur posé sur la mini-carte ou sur une flèche ne survole rien de la scène
dessous.

## Glisser un post-it sur la scène

Glisse un post-it « À faire » du tableau sur la scène : l'aperçu reste le post-it du tableau, quel que soit le zoom.
Pendant le survol, la cible est marquée dans la scène (anneau sous l'agent, poste ou îlot en surbrillance) et une
bulle près du curseur dit ce qui va se passer ; le curseur devient « interdit » quand le dépôt est refusé.

| Cible sous le curseur | Bulle pendant le survol | Au lâcher |
|---|---|---|
| Agent du même projet, libre | « Donner à Nova · file #1 » (sa file + 1) | donné ; il part si les gardes de la livraison passent |
| Agent occupé | « Donner à Bip · en file #2 » | donné, en file |
| Agent qui attend ta réponse | « Donner à Nova · sera livré après ton accord » | donné, en file |
| Agent d'un autre projet | halo et « Donner à Sol · autre projet : ~/dev/infra » | la confirmation du tableau (C3), puis donné |
| Agent hors ligne | « Donner à Kiwi · hors ligne : sera livré après relance » | donné, puis un toast propose de relancer la session |
| Agent déjà destinataire du post-it | « Déjà dans la file de Nova · file #1 » | rien |
| Agent dont le terminal tourne hors de l'app | curseur interdit, « Nova · terminal hors de l'app » | rien |
| Poste libre | poste en surbrillance, « Nouvel agent avec ce post-it » | un agent est créé à ce poste, le post-it devient son premier prompt |
| Sol ou pancarte d'un îlot | îlot en surbrillance, « Premier agent libre de API » | le premier agent libre du projet, sinon un nouvel agent |
| N'importe où, post-it qui n'est pas dans « À faire » | curseur interdit, « Remets-la d'abord à faire. » | rien |
| Ailleurs | rien | rien |

- **Défilement automatique** : à moins de 48 pt d'un bord de la scène, la caméra glisse vers ce bord (200 pt/s ;
  600 pt/s à moins de 16 pt).
- **Cible hors du champ au début du glisser** : survoler 0,5 s une ligne du plateau d'attente, une flèche de bord ou
  un point de la mini-carte fait voler la caméra jusqu'à l'agent, sans interrompre le glisser ; lâcher le post-it
  dessus le donne à cet agent (même décision que sur l'agent lui-même).
- **Après un dépôt réussi** : un petit post-it de la couleur du projet vole jusqu'au bureau, l'agent le saisit, puis
  la punaise s'enfonce. Rien de tout cela avec « Réduire les animations ».
- Les cibles de l'étape 2 (cartes d'agent de la vue Liste, colonnes du tableau) marchent toujours.

**Tableau** : ⌘B passe du panneau latéral (à droite de la scène, décision 8 du plan) au plein écran (maquette 6(c) :
barre de filtres et quatre colonnes côte à côte, à la place de la scène ou de la liste), puis au tableau masqué, puis
de nouveau au panneau latéral.

## Repères

- **Plateau d'attente** (sous la barre d'état dès qu'un agent attend) : un clic sur une ligne fait voler la caméra
  jusqu'à l'agent (mode scène), puis ouvre sa fenêtre ; en vue Liste, il ouvre sa fenêtre.
- **Barre d'état** : en mode scène, un clic sur un compteur (« 3 attendent », « 5 travaillent »…) sélectionne le
  premier agent de cet état et fait voler la caméra jusqu'à lui, puis le suivant à chaque clic (les agents en attente
  dans l'ordre du plateau). En vue Liste, le compteur filtre les cartes, comme à l'étape 2. Quand la place manque, les
  compteurs passent aux nombres seuls (maquette 6(q)).
- **Flèches de bord** : chaque agent en attente hors du champ a une flèche jaune marquée « ! » au bord de la scène, dans
  sa direction (8 directions), avec sa plaque de nom (« SOL »). Un clic fait voler la caméra jusqu'à lui.
- **Mini-carte** (en bas à droite) : affichée tant que le monde n'est pas entièrement visible. Les îlots y ont la
  couleur de leur projet, chaque agent un point qui porte le glyphe de son état, et le rectangle blanc montre la
  partie visible. Un clic y fait voler la caméra, un glisser la déplace tout de suite.
- **Plaques de nom** : toujours visibles pour un agent en attente, en erreur ou hors ligne (« KIWI · OFF »), au survol
  pour les autres.
- Le clic sur une notification, ⌘' et ⌥⌘→ font aussi voler la caméra jusqu'à l'agent.

## Fenêtre agent

Un panneau par agent (plusieurs à la fois), réutilisé tant qu'il est ouvert, fermé avec l'agent ou son projet.
Habillage SwiftUI simple : les fenêtres rétro en 9-slice arrivent à l'étape 4.

- **En-tête** : portrait pixel de l'état, tourné vers toi, animé (figé avec « Réduire les animations ») ; « Nova ·
  API », état et durée à la seconde, post-it en cours, modèle, mode de permission (en rouge pour
  `bypassPermissions`), session (8 caractères) et nombre de sessions.
- **Attente** (seulement quand l'agent attend) : permission (outil et résumé de la commande en chasse fixe), question
  (en-tête, texte, options, « une seule réponse » ou « plusieurs réponses »), dialogue MCP, notification, lancement
  silencieux (« Regarde le terminal ») ; [Ouvrir le terminal ⌘T] et « L'app ne répond jamais à ta place. »
- **Donner une consigne** : champ et [Envoyer ↩], avec une note quand la consigne passera en tête de file.
- **File** : post-it en cours, consignes et post-its dans l'ordre de livraison ; ↑, ↓ et [Retirer] ; [Mettre en
  pause] ou [Reprendre la file].
- **Boutons** de la maquette 6(d) (Terminal, Interrompre, Relancer la session, Continuer la tâche, Envoyer quand
  même…, Fermer la session…), grisés avec leur raison en infobulle.
- Points d'entrée : un clic sur un agent dans la scène, une ligne du plateau, ↩ dans la scène, le menu contextuel
  d'une carte d'agent de la vue Liste (« Ouvrir la fenêtre de l'agent »).
- Pas encore : « Refuser (Échap) » et les boutons de réponse rapide (étape 5).

## Arrivées et animations

- **Arrivée** (un agent lancé, ou relancé depuis « hors ligne ») : les portes de l'ascenseur s'ouvrent avec un « ding »,
  l'agent en sort et marche par les couloirs jusqu'à son siège (jamais à travers un bureau), s'assoit, puis la scène
  reprend la main. Sans chemin possible, il apparaît directement à son poste.
- **Départ** (session fermée, agent retiré) : il salue, se lève, marche jusqu'à l'ascenseur, les portes se ferment.
- **Tour terminé confirmé** : l'agent célèbre une fois.
- **Au repos** (pas endormi) : de temps en temps (toutes les 45 à 90 s), il s'étire ou boit un café.
- **Nouvel îlot, nouveaux postes** : bureaux, chaises, moniteurs et lampes tombent un par un au-dessus de leur ombre,
  avec un nuage de poussière à l'atterrissage ; la pancarte et la plante avec le premier et le dernier poste.
- **Au lancement de l'app**, rien ne s'anime : les agents sont déjà à leur poste.
- Avec « Réduire les animations » (réglage d'Accessibilité de macOS) : ni marche, ni chute, ni étirement, ni rebond ;
  les changements et les vols de caméra sont instantanés.

## Accessibilité

- **Vue Liste** (⌘L) : le chemin principal pour VoiceOver, inchangé et complet (cartes, plateau, tableau).
- **Dans la scène** : un groupe « Open space, 20 agents. Vue Liste : ⌘L », un élément par îlot (« Îlot API, 5 agents
  dont 1 en attente ») et un bouton par agent, avec le même libellé que dans la liste. Appuyer ouvre la fenêtre de
  l'agent ; y amener le focus fait voler la caméra. Un agent hors du champ prend le cadre de sa flèche de bord.
- **Rotor** « Agents en attente », dans l'ordre du plateau.
- **Annonces regroupées** : quand des agents se mettent à attendre ou tombent en erreur, une seule annonce toutes les
  2 s au plus, les attentes d'abord : « Nova attend ta réponse », « 3 agents attendent ta réponse », « Nova attend
  ta réponse ; Zéphyr est en erreur ».
- **Jamais la couleur seule** : chaque état a une forme d'overlay, une pose d'avatar et un texte ; les points de la
  mini-carte portent leur glyphe.
- **« Réduire les animations »** : un « ! » XL fixe à tous les zooms, sans halo ni rebond, et le reste comme plus haut.
- Mini-carte (« Mini-carte »), flèches de bord (« Sol attend, hors champ ») et contrôle de zoom ont leur libellé.

## Énergie

La scène ne recalcule rien tant que rien ne change (un plan inchangé ne touche aucun nœud). 30 images par seconde au
repos au premier plan, 60 pendant une interaction ou un vol de caméra (et une seconde après), 15 quand l'app n'est pas
active, 0 quand la fenêtre est masquée. Les budgets de la proposition (au plus 5 % de CPU et 400 Mo de mémoire au
repos avec 20 agents) restent à mesurer dans Instruments : voir la checklist.

## `workspace.json` version 2

- **Annexes persistantes** : chaque projet garde la place de ses annexes à vie (`annexSlots`), comme celle de son îlot.
  Ajouter un projet ne prend jamais la place d'une annexe ; archiver un projet libère toutes ses places ; retirer un
  agent ne libère rien. Aucun îlot, aucune annexe, aucun poste ne bouge quand un projet ou un agent arrive ou part.
- **Apparences générées** : un nouvel agent reçoit une apparence tirée de son identifiant (peau, coupe, couleur des
  cheveux, tenue à la couleur du projet ou neutre, accessoire), toujours la même pour le même agent. L'éditeur
  d'apparence arrive à l'étape 6.
- **Migration** au premier lancement de la nouvelle app : chaque agent qui avait encore l'apparence par défaut reçoit
  une apparence générée, et chaque annexe affichée garde sa place. Une bannière le dit (« Fichier workspace.json mis à
  jour depuis le format 1. »). La copie du jour, prise avant la première écriture, reste dans
  `~/Library/Application Support/PixelOpenSpace/backups/state/<date>/` (5 jours).
- **Une copie plus ancienne de l'app**, dont celle de `build/Demo`, ouvre ensuite ce fichier **en lecture seule**
  (« workspace.json vient d'une version plus récente de l'app (format 2) : ouvert en lecture seule, tes modifications
  ne seront pas enregistrées. ») et ne l'écrase jamais. C'est attendu (décision 11 du plan).

## Lancer l'app

Comme pour l'étape 2a (voir `docs/ETAPE-2A.md`). Si le dépôt est déjà cloné :

```bash
git pull
xcodegen generate      # nouveaux fichiers dans App/Sources (World/, UI/AgentWindow/, Snapshot/)
```

Puis, dans Xcode : schéma **PixelOpenSpace**, ⌘R. Les tests du cœur : `cd Core && swift test`. L'app s'ouvre sur
l'open space ; ⌘L passe à la vue Liste, et le choix est retenu d'un lancement à l'autre.

## Mode démo : protocole « 3 s » et mesures

Le mode démo montre l'open space simulé (6 projets, 20 agents) sur un état temporaire : il ne lit ni n'écrit rien de
ton état réel, ne lance aucun terminal ni aucun `claude`, et ne touche pas à `build/Demo`. Depuis la racine du dépôt,
après un build Debug :

```bash
xcodegen generate
xcodebuild -project PixelOpenSpace.xcodeproj -scheme PixelOpenSpace -configuration Debug \
    -derivedDataPath build/DerivedData -skipPackagePluginValidation build
build/DerivedData/Build/Products/Debug/PixelOpenSpace.app/Contents/MacOS/PixelOpenSpace --demo
```

Options : `--size 1600x1000` (taille de la fenêtre en points, 1440 × 900 par défaut), `--keep-state` (garde le dossier
temporaire à la sortie ; son chemin s'affiche au lancement).

- **Fenêtre** « Pixel Open Space · démo », sur la scène au zoom par défaut (×2), avec une barre de menus réduite
  construite depuis les commandes de l'app (sans « Rechercher Claude Code » ni « Réglages… »). L'horloge avance
  chaque seconde depuis la date simulée (1er octobre 2026, 9 h UTC). Au départ, Nova, Sol et Ivo attendent.
- **Panneau « Démo »** (flottant, en haut à droite) :
  - [Nouvel essai] : tire 2 agents au hasard parmi les agents vivants (jamais Kiwi, hors ligne) et les met en attente
    (permission Bash, question, permission Edit ou message MCP) ; les autres reprennent leur activité, l'horloge
    repart de la date simulée, et le compteur « Essais » avance ;
  - [Révéler] : qui attend et quoi (« Nova (API) : Bash : rm -rf dist »), pour vérifier ta réponse ; [Cacher] le
    masque ;
  - « Animer » : toutes les 4 s, 3 agents qui n'attendent pas changent d'activité (pour mesurer les images par
    seconde pendant que la scène bouge) ;
  - « Agents simulés : aucun terminal, aucun claude ».
- **Quitter** : ⌘Q (« Quitter la démo »), la fermeture de la fenêtre ou Ctrl-C dans le terminal effacent l'état
  temporaire.

Le protocole « 3 s » et les mesures sont dans la checklist ci-dessous.

## Banc de captures

Pour regarder les images sans rien lancer d'interactif :

```bash
Tools/snapshot.sh "$TMPDIR/pos-snapshots/essai" all      # ou une liste : zooms,list
```

L'app tourne sur un état temporaire, invisible, prend ses captures, puis quitte. Dans le dossier : `window-…png` (la
fenêtre), `scene-…png` (le dessin SpriteKit), `reference-…png` (le rendu logiciel du cœur sur la même entrée) et
`diff-…png` (la référence assombrie, les écarts en magenta), plus `report.txt`, qui finit par la ligne `BILAN`.
Scénarios, isolation et lecture du rapport : `App/README.md`, section « Banc de captures et mode démo ».

## Checklist manuelle

Ce qui demande ton Mac, une vraie souris ou Instruments (critère de fin de la section 8). À cocher :

- [ ] **60 fps et budgets** (spike S11) : 20 agents sur 5 ou 6 projets (de vraies sessions si possible ; sinon
  `--demo` avec « Animer »). Dans Instruments : 60 fps pendant un déplacement, un pincement ou un vol ; au repos, au
  plus 5 % de CPU et 400 Mo de mémoire résidente pour l'app (hors processus `claude`) ; 0 image par seconde fenêtre
  masquée ; 15 au plus app inactive.
- [ ] **Protocole « 3 s »** : `--demo`, fenêtre sur la scène au zoom par défaut ; dix fois [Nouvel essai], dire à voix
  haute qui attend et quoi, puis [Révéler]. Réussi si tu réponds en moins de 3 s dans 9 essais sur 10.
- [ ] **Glisser-déposer à la vraie souris** : post-it sur un agent libre du même projet (il part), occupé (file), en
  attente (« après ton accord »), d'un autre projet (confirmation), hors ligne (proposition de relance), sur un poste
  libre (nouvel agent avec le post-it en premier prompt), sur le sol d'un îlot (premier agent libre) ; **cible hors du
  champ au début du glisser** : par le défilement au bord, par une flèche de bord, par une ligne du plateau
  d'attente, par la mini-carte.
- [ ] **Aucun flou** sur ton écran Retina : chaque zoom, un déplacement lent, un pincement, un vol de caméra ; sur un
  écran externe non Retina, la vue d'ensemble n'est pas proposée.
- [ ] **Gestes** : deux doigts, pincement par paliers, molette, ⇧ + molette, glisser sur le sol, bouton du milieu,
  Espace + glisser, flèches et ⇧ + flèches, ⌘+ ⌘− ⌘0, ⌘L, ⌘B (latéral, plein écran, masqué).
- [ ] **Clics** : un clic sur un agent ouvre sa fenêtre après un court délai ; un double-clic n'ouvre que le
  terminal ; un poste libre propose « Nouvel agent ici ? » ; un double-clic sur un îlot le centre ; un clic droit
  ouvre le menu.
- [ ] **Arrivées** : un nouvel agent sort de l'ascenseur et marche jusqu'à son poste ; un nouveau projet fait tomber
  ses meubles dans la poussière ; une fin de tour confirmée fait célébrer l'agent.
- [ ] **VoiceOver (rapide)** : la vue Liste (⌘L) reste complète ; dans la scène, le rotor « Agents en attente » ; trois
  attentes simultanées donnent une seule annonce.
- [ ] **Copie de démonstration** : après le premier lancement de la nouvelle app, `build/Demo` ouvre `workspace.json`
  en lecture seule (attendu, décision 11).

## Ce qui a été vérifié, et ce qui ne l'a pas été

Contrôle d'ensemble du 2026-10-02, sur ce Mac, au commit `8807d8e` (vagues 1 à 3 fusionnées, plus la carte de survol
qui évite la mini-carte et les flèches de bord ; la tâche 12 se déroulait en parallèle de ce guide) :

- **Cœur** : `cd Core && swift build && swift test` donne **1 272 tests dans 91 suites, tous verts** (1 113 au début
  de l'étape, 761 à la fin de l'étape 2b). Les règles de la scène y ont chacune leur test : caméra recalée au pixel
  (`CameraMathTests.snappedAlignsTexelsOnPhysicalPixels`), rendu inchangé par le plan
  (`ScenePlanTests.renderFromPlanIsUnchanged`), plan inchangé, diff vide (`unchangedInputGivesEmptyDiff`), un nouvel
  agent ne déplace rien (`addingAnAgentMovesNothing`), aucun îlot ni annexe ne bouge
  (`WorldLayoutPropertyTests.noIslandEverMoves`), migration (`PersistenceTests.workspaceV1MigratesToV2`), règles de
  clic (`ClickResolverTests`) et de dépôt (`DropResolverTests`), une fonction par règle.
- **App** : compilée en Debug avec `xcodebuild`, après un nettoyage (`** BUILD SUCCEEDED **`, aucun avertissement
  Swift, donc aucun de concurrence).
- **Banc de captures**, `Tools/snapshot.sh … all` : code de sortie 0 en 70 s, « outil de comparaison : OK ».
  - Chaque prise de scène est identique à sa référence logicielle (0 écart, tolérance de 1 par canal) : vue
    d'ensemble, ×1, ×2, ×3, cinq positions de caméra fractionnaires, sélection, survols, navigation, fenêtres agent,
    monde vide, et l'arrivée de Brume une fois assise (`brume-100`).
  - Seules les prises animées d'`arrival` s'en écartent, comme prévu : l'avatar qui marche, les portes ouvertes, le
    « ding » et les meubles en l'air ne sont pas dans la référence, qui est une image fixe (`brume-0`, `brume-40`,
    `brume-80`, `chute-mobile` : 300 816 pixels en tout).
  - 9 étapes non prises en charge, toutes de la tâche 12 (`dragHover` ×8, `board` ×1) : les crochets du glisser et
    du tableau plein écran n'étaient pas encore fusionnés. Après la fusion de la vague 4 (plus bas), il n'en reste
    aucune.
  - Statistiques de la prise `overview` (20 agents, « Tout voir », ici à ×1) : 264 nœuds, 1 page d'atlas, 1 page de
    personnages, 11 images composées, 4 tuiles de fond ; en vue d'ensemble (½), 243 nœuds.
  - Après le passage, aucun dossier d'état temporaire, aucun domaine de préférences du banc, aucun processus du banc,
    et rien de plus récent que le passage dans ton état réel (`~/Library/Application Support/PixelOpenSpace`, tes
    préférences).
  - L'atlas exporté par `sprite-export --atlas` : une page de 2048 × 2048, 716 images, 128 animations ; deux exports
    donnent les mêmes octets.
- **Images regardées** : `window-overview-tout-voir` (×1, flèche vers Nova, mini-carte et son rectangle),
  `window-zooms-ensemble` (le monde entier en ½, plaques NOVA, SOL, IVO, ZÉPHYR lisibles), `diff-fractional-x3` (aucun
  pixel magenta), `window-list-liste`, `window-empty-monde-vide`, `window-select-survol-agent` (plaque et carte de
  survol de Bip) et `-survol-poste` (le poste 5 d'API, au bord droit, est sous la mini-carte : sa carte « Poste libre ·
  clic : nouvel agent ici » se pose juste au-dessus d'elle), `window-navigation-loin` (flèches vers Nova et Sol), la
  fenêtre agent de Sol (question et options), `window-dragdrop-bip`, `window-board-plein-ecran`,
  `window-arrival-brume-40` (Brume dans le hall) et `-chute-mobile` (meubles de MOBILE en l'air au-dessus de leur
  ombre), les deux fenêtres de `demo` (la fenêtre principale et le panneau « Démo »), `diff-selftest-decalage`.
- **Après la fusion de la vague 4** (tâches 12 et 13, au commit `b7df087`, le 2026-10-02) : le cœur donne toujours
  1 272 tests dans 91 suites, tous verts ; l'app compile (`** BUILD SUCCEEDED **`, aucun avertissement de
  concurrence) ; `Tools/snapshot.sh … all` sort avec le code 0 en 82 s, sur `BILAN : écarts hors tolérance 300816 ·
  étapes non prises en charge 0`. Les huit prises de scène de `dragdrop` sont à 0 écart. Images regardées :
  `window-dragdrop-bip` (anneau sous Bip, « Donner à Bip · en file #1 »), `-poste-libre` (poste marqué, « Nouvel
  agent avec ce post-it »), `-fleche` (flèche IVO en surbrillance, sa bulle « Donner à Ivo · autre projet :
  /projets/docs » au-dessus et à gauche, hors de la mini-carte), `-plateau` (ligne de Sol en surbrillance, sa bulle
  dans la ligne), `-mini-carte` (point d'Ivo cerclé, la bulle au-dessus de la carte et de la flèche SOL),
  `window-board-plein-ecran` (barre de filtres et quatre colonnes à la place de la scène, boutons « Panneau
  latéral » et « Masquer »), `window-demo-demo`. Le même passage n'a rien laissé derrière lui.
- **Pas vérifié, personne n'a touché l'interface** : tout ce qui est dans la checklist ci-dessus (gestes réels,
  glisser-déposer à la souris, fluidité, Instruments, VoiceOver, le protocole « 3 s »). Le banc pose la scène dans
  chaque état sans vraie souris : il vérifie ce qui est dessiné, pas le ressenti.

## Limites connues

- **`BILAN` du banc** : la ligne additionne les écarts des prises animées d'`arrival` (plus haut) ; elle ne vaudra
  donc jamais 0 tant que ce scénario fait partie de `all`. Lis les écarts prise par prise dans `report.txt`.
- **Prises sans scène** : dans `demo`, la zone de la scène reste vide (blanche) dans `window-…png`, seuls
  la mini-carte et les flèches de bord y apparaissent. La capture d'une fenêtre (`cacheDisplay`) ne lit pas le dessin
  Metal de SpriteKit, et le banc ne le remplace par une image fixe que dans les prises qui capturent la scène. Ce n'est
  pas un défaut de l'app.
- **Projet sélectionné dans les captures** : quand un projet est sélectionné (scénario `select`), sa ligne de la barre
  latérale sort en noir dans `window-…png`, sans son nom ni son nombre d'agents ; seuls le carré de couleur et le
  badge d'attente restent. Vraisemblablement la même limite de la capture, avec la sélection native de la barre
  latérale ; pas vérifié sur ton écran.
- **Durée du banc** : un passage complet prend 70 à 83 s sur ce Mac, pour un chien de garde de 120 s. La marge
  diminue à chaque scénario ajouté.
- **Flèches de bord sur la mini-carte** : une flèche de bord peut se poser sur le cadre de la mini-carte (IVO dans
  `window-dragdrop-bip.png`, SOL dans `window-select-survol-agent.png`) : leur placement n'évite pas la mini-carte.
- **Monde vide** : quand le hall ne tient pas dans la vue (à ×3 par exemple), la mini-carte s'affiche quand même, vide
  à part le rectangle de la partie visible, puisqu'elle ne dessine que les îlots (`window-empty-monde-vide.png`).
- **Réglages** : le zoom de départ (×2) et le réglage « Réduire les animations » propre à l'app existent dans les
  réglages enregistrés, mais pas encore dans la fenêtre Réglages ; seul le réglage d'Accessibilité de macOS se
  change aujourd'hui.
- **Fenêtre agent** : pas de « Refuser (Échap) » ni de boutons de réponse (étape 5) ; dans le banc et le mode démo,
  les boutons du terminal sont grisés (aucune session).
- **Tests d'interface `xcodebuild` avec `fake-claude`** (6 sessions, permissions, tours) : pas faits, `fake-claude` ne
  sait pas encore rejouer un écran de Claude Code ; le banc de captures et les tests du cœur les remplacent à cette
  étape, et le protocole « 3 s » passe par `--demo`.
- **CI macOS** : elle lance le banc à chaque push et publie les captures (artefact `snapshots`), sans échouer sur ses
  écarts : ses machines virtuelles n'ont pas de vraie accélération graphique, la référence reste le rendu du cœur.

## Reste à faire

- **Ta checklist** ci-dessus. L'étape 3 est terminée quand le protocole « 3 s » passe, que les budgets sont tenus
  dans Instruments, que le glisser-déposer marche vers un agent hors du champ et que rien n'est flou.
- **Hors de ce plan** :
  - **étape 4** : mode nuit (voile, lumières additives, étoiles, suivi de l'apparence de macOS), remplacement des
    sprites par tes PNG (7.7), fenêtres rétro en 9-slice, polices, sons 8 bits, palette finale, icône ;
  - **étape 5** : « Refuser (Échap) » et réponses rapides dans la fenêtre agent, notifications avec actions, palette
    ⌘K, icône de barre de menus, restauration de la caméra et des fenêtres, visiteurs externes (contour pointillé),
    checklist VoiceOver et clavier des contrôles rétro, « Différencier sans couleur » (glyphes XL) et « Augmenter le
    contraste » (contours de 2 px), « Reprendre une ancienne conversation » ;
  - **étape 6** : éditeur d'apparence, XP, niveaux et badges, mode édition du décor, « Réorganiser l'open space » ;
  - **étape 7** : bonus (import GitHub, statistiques du jour, options) ;
  - le tableau à gauche de la scène (6(k)) : il reste à droite (décision 8 du plan).
