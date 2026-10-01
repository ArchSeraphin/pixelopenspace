# Jalon visuel : sprites v0, îlot de démonstration et vue d'ensemble

**Jalon validé le 2026-10-01.**

But : valider la direction artistique **avant** l'étape 3 (voir `docs/PROPOSITION.md`, section 8 « Jalon visuel » et
section 7). Toutes les images de ce dossier sont produites par le cœur seul (`Core/`, Swift pur, compilé et testé
sous Linux comme sous macOS), sans l'app, sans SpriteKit et sans aucune image externe : chaque sprite est dessiné par
le code (`docs/ASSETS.md`), puis la scène est composée en logiciel par `SceneCompositor`, comme SpriteKit la dessinera
à l'étape 3.

Toutes les questions ci-dessous sont tranchées et l'étape 3 part de ce rendu.

Ces images sont le **troisième rendu**. Le deuxième appliquait les quatre décisions prises sur le premier rendu le
1er octobre 2026 et corrigeait les défauts relevés alors ; le troisième corrige les défauts qui restaient, d'abord
le « ! » qui se lisait comme une ampoule (« Troisième rendu » ci-dessous). Le bilan, défaut par défaut, est dans
« Défauts : corrigés et restants ».

## Décisions du premier rendu (2026-10-01)

1. **Écran de la rangée A** (tranché le 2026-10-01) : on garde le moniteur décalé de 6 px à côté de la tête, sans le
   repli de 7.4.3 (pas de LED d'état sur le moniteur de la rangée A). Rien n'a changé dans le code : l'écran reste
   entièrement visible en haut à droite de la tête à ×1, ×2 et ×3 (Lune, Zéphyr, Mika, Lou ; Nova, qui attend, se
   tourne vers toi et dégage son écran jaune).
2. **Vue d'ensemble, maquette 6(q)** (tranché le 2026-10-01) : seuls les signes urgents restent, le « ! » XL d'un agent
   qui t'attend (avec son halo) et l'orage d'un agent en erreur. Tout le reste disparaît à ce niveau : overlays,
   bulles d'outil, petites icônes d'état, badges, badges de file, et donc plus de second « ! ». Tout revient à ×1 et
   au-delà. Choix d'interprétation : la plaque de nom des agents qui portent un signe urgent reste affichée, pour dire
   qui attend (NOVA, SOL, IVO) et qui est en erreur (ZÉPHYR) ; aucune autre plaque. Les pancartes d'îlot y sont
   dessinées ×2, leur texte garde la taille qu'il a à ×1. Tests `overviewKeepsOnlyUrgentSigns`,
   `overviewSignsAreDoubled`.
3. **Tapis des îlots** (tranché le 2026-10-01) : le tapis porte les postes occupés plus le premier poste libre, par
   postes entiers (le bureau de la rangée A et celui de la rangée B au même i), avec une marge d'une tuile tout
   autour, et grandit vers +i quand un agent arrive (`WorldLayout.rugDesks`). Le slot et l'origine de l'îlot ne
   bougent jamais (la propriété « append-only » de `WorldLayout` tient toujours), et le tapis grandit depuis un coin
   fixe, à l'intérieur des tuiles réservées de son îlot : il ne déborde jamais sur un slot voisin ni sur le couloir.
   La pancarte se tient au coin avant gauche du tapis, la plante au coin arrière droit. Tests de propriété
   `noIslandEverMoves`, `rugNeverLeavesItsSlot`, `rugCoversEveryDesk`, `rugGrowsWithItsAgents`. Les deux
   distributions de l'îlot occupent les 8 postes, donc la croissance se voit dans la vue d'ensemble : 3 postes pour
   API (5 agents) et INFRA (4), 2 pour SITE, DATA, MOBILE (3 chacun) et DOCS (2).
4. **Police** (tranché le 2026-10-01) : on garde `PixelFont`, police originale du cœur, avec les chiffres ambigus
   redessinés. Le 0 est un ovale barré (il ne se lit plus D ni O), le 8 deux ronds pincés sans hampe (il ne se lit
   plus B) ; en comparant chaque chiffre à chaque capitale, le 2, le 4, le 5, le 6 et le 7 ont aussi été redessinés
   pour ne plus passer pour Z, H, S, G et T. Un chiffre fait au plus 4 px de large, un badge de file en tient
   toujours un. Tests `digitsDoNotPassForLetters`, `zeroAndEightReadApartFromTheirLetters`, `aQueueBadgeHoldsADigit`.

## Troisième rendu (2026-10-01)

Ce rendu reprend les défauts restants du deuxième (tableau « Défauts » plus bas) avant l'étape 3. Il ne touche qu'à des
dessins de sprites : ni le compositeur, ni la disposition, ni les scènes de démonstration ne changent.

1. **Le « ! » se lit comme un « ! »** (`ov.bang`, `ov.bang~xl`). Avec sa tête large et arrondie, son col étroit et son
   halo rond, le signe d'attente évoquait une ampoule, surtout en vue d'ensemble et à ×3. C'est maintenant une barre
   droite et anguleuse : 6 px de large contour compris, coins du haut à angle vif, qui s'affine vers le bas (6, puis 4,
   puis 2 px) ; puis 2 rangées vides et un point carré de 6 × 4. Jaune d'attente, contour `alertOrange`, reflet `chalk`
   sur le bord gauche ; taille, ancre et rebond inchangés. Test `bangReadsAsAnExclamationMark`.
2. **Le halo est un losange** (`ov.bang.halo`). Plus d'anneau rond : un losange iso (marches 2:1, comme une tuile), qui
   pulse de 24 à 28 px de large, en bande jaune de 2 px, avec un losange orange en pointillé 2 px plus loin (28 puis
   32 px). Le même halo sert au « ! » et à sa version XL ; il est centré sur le milieu de la barre, si bien qu'aux deux
   tailles ni sa bande ni ses points ne touchent le vide ou le point du « ! ». Tests `haloIsAnIsoDiamond`,
   `haloStaysClearOfTheDot`. Le repli prévu (un « ! » `ink` sur un panneau jaune en losange) n'a pas servi : en vue
   d'ensemble, les « ! » XL de Nova, Sol et Ivo se lisent d'un coup d'œil comme des points d'exclamation, de même à
   ×1, ×2 et ×3.
3. **Flèche de bord diagonale** (`ov.edgeArrow~diagonal`, nouvelle) : la même flèche, pointée en haut à droite,
   symétrique par rapport à sa diagonale, avec son « ! » `ink` sur l'axe (16 × 16, ancre (8, 8), 2 images à 4 fps).
   Avec `ov.edgeArrow` et des quarts de tour, l'app obtient les 8 directions sans jamais tourner un sprite de 45°
   (étape 3). Test `edgeArrowHasADiagonal`. La planche 3 gagne une cellule (3136 × 3132).
4. **Yeux fermés de `sleep`** (vers le spectateur) : un trait horizontal de 2 px par œil au lieu d'un point, qu'on
   lisait comme un œil ouvert ; en SE comme dans le miroir ré-ombré SW. Test `sleepingEyesAreClosedLines`.
5. **Cheveux courts vus de dos** (coupe courte, chignon, coupe rase ; toutes les couleurs, le gris d'abord) : des
   mèches de 2 px en ton d'ombre dans la masse éclairée, lisibles à ×1, en plus des mèches de contour. Le miroir
   ré-ombré (NW) les aplatit, ses mèches de contour restent. Test `shortHairFromBehindHasStrands`.
6. **Lampe** (`lamp.desk`) : le pied et le bras passent dans un métal peint sombre (`shade`, `ink`, reflets `slate`)
   au lieu du gris du pied du moniteur, dans lequel la lampe se fondait à ×1. Allumée, l'abat-jour lui-même s'éclaire
   (`paper` devient `chalk`, `mist` devient `paper`) autour de l'ouverture chaude et de l'ampoule blanche : de jour,
   `~on` diffère de `~off` d'au moins 12 pixels dans chaque direction. Tests `lampOnAndOffDifferByDay`,
   `lampStandsApartFromTheMonitorFoot`.
7. **Veste sur la chaise** : jugée à l'œil sur ce rendu, gardée telle quelle (voir « Défauts »).

## Les 15 images et ce qu'il faut y regarder

| Fichier | Pixels | À regarder |
|---|---|---|
| `planche-0-palette.png` | 3136 × 2380 | Les 32 couleurs de base et les 10 teintes en 3 tons : la palette te plaît-elle telle quelle ? La case « flaque d'une lampe » montre maintenant ce que dessinent les scènes : `light.cone` (alertOrange) ajouté à 35 % sur le plateau du bureau (woodLight), de jour, sous le voile de nuit (`#C7894E`, chaud) et sous le voile réduit. |
| `planche-1-sols-murs.png` | 3136 × 6472 | Moquettes des 10 teintes avec leurs bords et coins (ceux marqués « MIROIR » restent éclairés en haut à gauche), carrelage du hall et du couloir, marquages `floor.dropTarget` et `floor.hover` (sur damier sombre), murs, fenêtres de jour, au crépuscule et de nuit, ascenseur en 6 images, mur de liège. |
| `planche-2-mobilier-decor.png` | 3136 × 4444 | Chaises en 4 orientations et 11 teintes, chaise avec la veste (agent hors ligne), bureau, lampe (pied et bras arqué en métal sombre, abat-jour) éteinte et allumée (l'abat-jour s'éclaire), petits objets, post-its, fontaine, plante, ombres, flaque, lueur d'écran et étoiles. |
| `planche-3-ecrans-overlays.png` | 3136 × 3132 | Moniteurs (LED d'état au dos, côté rangée B), les 10 contenus d'écran de 12 × 13 et tous les overlays : chaque état doit avoir sa forme propre, sans compter sur la couleur. Le « ! » est une barre anguleuse et un point carré, son halo un losange ; `ov.edgeArrow` est une flèche, `~diagonal` la même pointée en haut à droite ; `fx.dust` et `fx.pinDrop` sont sur damier sombre. |
| `planche-4-hud-texte.png` | 3136 × 2248 | Icônes d'état, points de mini-carte, pancartes, plaques de nom et police `PixelFont` : lisibilité des accents et des chiffres redessinés (0 barré, 8 rond). |
| `planche-5-personnage.png` | 3656 × 5580 | Les 14 animations du personnage par défaut en SE, SW, NE et NW : `sleep` est avachi sur le bureau (tête sur les bras et yeux fermés en traits de 2 px de face, dos voûté de dos). SW et NW, miroirs ré-ombrés, restent-ils éclairés en haut à gauche ? |
| `planche-6-apparences.png` | 3136 × 1336 | Les 16 apparences de face et de dos (peaux, coupes avec mèches, mèches de 2 px dans la masse des coupes courtes, oreilles et nuque visibles de dos, accessoires) et `agent.mini` dans les 10 teintes : assez variées, assez originales ? |
| `ilot-x1-jour.png` | 672 × 894 | Le zoom le plus petit (1 pt par texel) : chaque état se lit-il d'un coup d'œil, l'écran de la rangée A reste-t-il visible à côté de la tête (décision 1), chaque overlay est-il au-dessus du bon agent ? |
| `ilot-x2-jour.png` | 1344 × 1788 | Le zoom courant : visages de la rangée B derrière les moniteurs, post-it collé à l'écran de Pixou, file de post-its, sous-agents de Bip, plaque « SOL » à côté de sa tête, « zZ » posé sur la tête de Tao endormi. |
| `ilot-x3-jour.png` | 2016 × 2682 | Le détail : netteté (c'est exactement ×1 agrandi, sans aucun flou), finesse des personnages, de la lampe, de la veste de Kiwi et des objets du bureau. |
| `ilot-x1-nuit.png` | 672 × 894 | La nuit au plus petit zoom : les overlays restent identiques au jour au-dessus du voile ; la scène reste-t-elle lisible ? |
| `ilot-x2-nuit.png` | 1344 × 1788 | Couleur, taille et position des flaques de lumière (orange, sur le plateau, sous la lampe) et de la lueur des écrans (sur le bureau autour du moniteur, jamais sur le moniteur). |
| `ilot-x3-nuit.png` | 2016 × 2682 | Les mêmes lumières de près : la flaque reste sur le plateau, le dos des moniteurs de la rangée B reste sombre, la lueur tombe sur le clavier. |
| `vue-ensemble-jour.png` | 1920 × 1056 | La maquette 6(q), 20 agents sur 6 projets : ne restent que les « ! » XL des 3 agents qui attendent (Nova, Sol, Ivo), l'orage de Zéphyr en erreur et leurs 4 plaques (décision 2) ; les tapis sont à la taille des équipes (décision 3). Repère-t-on tout de suite qui t'attend ? Les « ! » se lisent-ils comme des points d'exclamation, pas comme des ampoules ? |
| `vue-ensemble-nuit.png` | 1920 × 1056 | La même de nuit : ambiance générale, fenêtres de nuit et leurs étoiles, flaques et lueurs, « ! » toujours aussi visibles. |

Les sept planches couvrent tous les sprites v0 (`SpriteCatalog.v0IDs`), à l'échelle 4 (4 pixels par texel). Chaque
image d'un sprite y est posée sur un damier de 4 × 4 texels qui montre sa transparence : `paper` / `mist` en général,
`slate` / `shade` sous un sprite clair, qui disparaîtrait sur le damier clair. Un sprite est clair quand au moins
deux tiers de ses pixels opaques sont des neutres clairs de la palette (chalk, paper, mist, floorLight, floorDark,
uiFace) : `floor.dropTarget`, `floor.hover`, `floor.hall`, `floor.corridor`, `fx.star`, `fx.dust`, `fx.pinDrop`, les
post-its papier et le point de mini-carte `idle` (`ContactSheet.needsDarkChecker`, test
`lightSpritesSitOnADarkCheckerboard`). Un groupe porte l'identifiant, la taille, la cadence (« 4 × 8 FPS »,
« UNE FOIS » sans boucle) et l'ancre, chaque cellule sa variante (`~hue3`), sa direction (`@ne`) et « MIROIR » pour
un sprite obtenu par miroir (« MIROIR RÉ-OMBRÉ » pour les personnages SW et NW). La planche 0 ajoute l'ombre, la
flaque d'une lampe sur le plateau, le voile de nuit, les couleurs dérivées et les couleurs clés marquées « jamais
dans un sprite » ; la planche 4 ajoute le spécimen de `PixelFont` (alphabet, accents, chiffres, symboles, les 60
noms de `NameGenerator`), les pancartes « API », « SITE WEB », « DOCUMENTATION » et les plaques « NOVA », « ZÉPHYR »,
« OFF ».

## Comment les regarder

- Ouvre les PNG dans **Aperçu**, en **taille réelle** (Présentation › Taille réelle, ⌘0).
- **Îlot** : sur un écran Retina, `ilot-xk-*.png` en taille réelle s'affiche exactement comme l'app au zoom ×k
  (1 pt par pixel d'image, donc k pt par texel, 7.3). C'est l'image à juger pour la lisibilité à chaque zoom.
- **Vue d'ensemble** : 1 pixel par texel, déclarée à 144 ppp (chunk `pHYs`) ; en taille réelle sur Retina elle
  s'affiche à 0,5 pt par texel, comme le niveau « vue d'ensemble » de l'app.
- **Planches** : 4 pixels par texel, soit 4 pt par texel en taille réelle (deux fois le zoom ×2 de l'app) ; faites
  pour regarder chaque sprite de près.

### Les deux distributions de l'îlot

Un îlot a au plus 8 postes, dont un toujours libre, donc 7 agents ; il y a 10 états plus l'agent endormi. Chaque
image de l'îlot montre donc le même îlot « API » dans deux distributions, l'une sous l'autre (décision 13). Rangée A
(devant, index pairs) : dos au spectateur, écran visible ; rangée B (derrière, index impairs) : visage visible.
Chaque îlot porte sa pancarte (au coin avant gauche du tapis), une lampe par bureau, des post-its (file sur le bureau
avec son badge, post-it collé à l'écran) et une plante.

| Poste | Distribution 1 | Distribution 2 |
|---|---|---|
| 0 (A0) | Nova : attend une permission (Bash « rm -rf dist », depuis 42 s), 1 post-it en file | Pixou : travaille (Edit), post-it collé à l'écran, 2 post-its en file |
| 1 (B0) | Bip : travaille (Bash), 2 sous-agents | Sol : attend une réponse à une question |
| 2 (A1) | Lune : réfléchit | Mika : attend une tâche de fond |
| 3 (B1) | Oslo : tour terminé | Rio : en pause, limite d'usage (reprise dans 40 min) |
| 4 (A2) | Zéphyr : erreur (serveurs surchargés) | Lou : démarre |
| 5 (B2) | Tao : au repos depuis 12 min (endormi) | Plume : réfléchit, sans nouvelles, mode dégradé |
| 6 (A3) | Kiwi : hors ligne | (poste libre) |
| 7 (B3) | (poste libre) | Galet : au repos, brouillon dans la zone de saisie, mode `bypassPermissions` |

La vue d'ensemble reprend la maquette 6(q) : API (5 agents, dont Nova qui attend), INFRA (4, dont Sol qui attend
et Zéphyr en erreur), SITE (3, dont Tao endormi), DATA (3), MOBILE (3), DOCS (2, dont Ivo qui attend), 12 mini
post-its sur le mur de liège, emprise de 36 × 24 tuiles.

## Questions (toutes tranchées le 2026-10-01)

### Les trois questions du jalon (section 8)

- [x] **Lisibilité de l'écran en rangée A** : tranché le 2026-10-01, on garde le décalage de 6 px, sans le repli LED
  (décision 1 ci-dessus).
  - Sur les rendus : à ×1, ×2 et ×3, l'écran reste entièrement visible en haut à droite de la tête. Le post-it collé
    à l'écran de Pixou en cache environ un quart. En rangée B, l'état sur le moniteur n'est qu'une LED de 2 × 2 texels
    au dos : c'est l'overlay qui porte l'information.
- [x] **Taille des overlays à ×1 et en vue d'ensemble** : tranché le 2026-10-01, tailles gardées à ×1 et au-delà ; en
  vue d'ensemble, seuls le « ! » XL et l'orage (décision 2 ci-dessus).
  - À ×1 (1 pt par texel) : le « ! » (12 × 24 pt, halo de 32 × 32) se voit au premier coup d'œil ; bulles d'outil
    (16 × 16), « … » (20 × 14), coche (12 × 12), « zZ » (16 × 16) et orage (28 × 18) se lisent ; les signes
    secondaires (brouillon 10 × 10, « ? » sans nouvelles 10 × 14, mode dégradé et `bypassPermissions` 12 × 12) sont
    petits mais se trouvent quand on les cherche.
  - Corrigé au troisième rendu : la tête large et arrondie du « ! » et son halo rond se lisaient aussi comme une
    ampoule ; le « ! » est maintenant une barre anguleuse et un point carré, son halo un losange.
- [x] **Palette** : validée telle quelle le 2026-10-01.
  - De jour : chaque pixel des scènes est une couleur de la palette ou une couleur assombrie une seule fois par
    l'ombre (test `dayPixelsArePaletteOrSingleShadow`), aucune dérive. Les 6 teintes de la vue d'ensemble se
    distinguent bien ; les moquettes au ton « clair » donnent un ensemble pastel, les pancartes au ton de base.
  - De nuit : le voile (0,55) passe le carrelage au gris et les moquettes à des tons profonds ; les overlays gardent
    leurs couleurs de jour. La flaque d'une lampe n'utilise plus `lampWarm` (qui virait au gris mauve) mais
    `alertOrange`, et reste chaude : `#C7894E` sur le plateau voilé, `#E7A059` sous le voile réduit. `lampWarm` sert
    encore ailleurs, entre autres à l'intérieur de la lampe allumée, à l'horloge de `ov.quota` et à la LED de
    l'ascenseur.

### Autres choix du plan

- [x] **Orientation des rangées** (décision 2 du plan) : validée telle quelle le 2026-10-01. Rangée A regard `ne`
  (dos et écran visibles), rangée B regard `sw` (visage visible).
- [x] **Pas des postes** (décision 3 du plan) : validé tel quel le 2026-10-01. Un poste toutes les 2 tuiles (bureau,
  puis une tuile de dégagement qui reçoit les sous-agents), sans le repli des postes jointifs.
- [x] **Police** (décision 6 du plan) : tranché le 2026-10-01, on garde `PixelFont` aussi dans l'app, chiffres
  redessinés (décision 4 ci-dessus).
- [x] **Nuit** : validée telle quelle le 2026-10-01, pour l'étape 4 (la scène de l'étape 3 est toujours de jour).
  Force du voile (0,55 ; 0,35 avec « Réduire la transparence ») et des lumières (35 %, additives) ; la flaque est
  petite (28 × 14), orange, limitée au plateau ; la lueur des écrans éclaire le bureau autour du moniteur.
- [x] **Visages de la rangée B** derrière les moniteurs : validés tels quels le 2026-10-01. Tête et yeux visibles
  au-dessus du moniteur à ×1, détail des lunettes et des casques lisible à partir de ×2.
- [x] **Texte en vue d'ensemble** : tranché le 2026-10-01, plaques des agents urgents ×2, comme les pancartes
  (étape 3, tâche 6). Les pancartes y sont déjà ×2 (capitales de 5 pt, lisibles) ; les plaques des agents urgents
  font encore 2,5 pt de haut dans ce rendu.
- [x] **Démarrage** : validé tel quel le 2026-10-01, le signe « démarre » est gardé et l'arrivée par l'ascenseur s'y
  ajoute à l'étape 3. Un agent qui démarre porte le signe « démarre » (`hud.state.launching`) au-dessus du poste, à
  ×1 et au-delà (Lou), masqué en vue d'ensemble ; de dos, la pose debout seule ressemblait à la pose assise.

## Défauts : corrigés et restants

Relevés à la revue des 15 images du premier rendu, puis du deuxième, et revus un par un sur ce rendu. Les 15 premières
lignes viennent du premier rendu (corrigées au deuxième) ; les 8 dernières sont les restants du deuxième rendu,
corrigés, tranchés ou acceptés au troisième.

### Corrigés

| Fichier | Défaut | Correction |
|---|---|---|
| `ilot-x*-*.png`, `vue-ensemble-*.png` | Les overlays du poste B0 chevauchaient ou touchaient la pancarte de l'îlot (tuile locale (0, 0)). | La pancarte se tient au coin avant gauche du tapis (tuile locale (0, 6)), loin de tout overlay. Test `signNeverTouchesOverlays` (×1 et vue d'ensemble, overlays les plus larges, erreurs sur tous les postes). |
| `ilot-x*-*.png`, `vue-ensemble-*.png` | En rangée A, l'overlay flottait au-dessus du bureau du poste de derrière (orage de Zéphyr sur le bureau de Lune, sablier de Mika sur celui de Pixou). | En rangée A, l'overlay est posé sur la tête (1 à 3 px au-dessus), droit au-dessus du siège. Test `overlaysSitOnTheirOwnAgent`. En vue d'ensemble, seuls les signes urgents restent (décision 2). |
| `ilot-x*-*.png` | La plaque d'un agent de la rangée B était posée sous ses pieds, sur le plateau du bureau (« SOL » entre Pixou et Mika). | Plaque à côté de la tête, du côté du poste précédent ; hors ligne, la plaque « OFF » prend la place de la tête au-dessus de la chaise. Test `rowBNameplateBesideTheHead`. |
| `ilot-x*-nuit.png`, `vue-ensemble-nuit.png`, `planche-0-palette.png` | Les flaques de lumière viraient au gris mauve pâle (`lampWarm` à 35 % sur la moquette voilée) et débordaient du plateau comme un spot au sol. La planche 0 montrait encore cette flaque. | `light.cone` : 28 × 14, `alertOrange` plein au centre et en damier au bord, ancré sous le pied de la lampe et découpé au losange du plateau : chaud, jamais sur la moquette. La planche 0 montre la vraie flaque sur le plateau. Tests `lampPoolStaysWarmOnEveryVeiledFloor`, `lampPoolStaysOnTheDeskTop`, `paletteSheetShowsEveryColor`. |
| `ilot-x*-nuit.png`, `vue-ensemble-nuit.png` | La lueur des écrans formait des parallélogrammes cyan pâle à bord net, comme une vitre posée sur le bureau. | `light.screenGlow` en dégradé (plein, puis damier, puis pixels épars). Au deuxième rendu, la lueur n'éclaire plus son propre moniteur : de dos (rangée B), le moniteur couvert de cyan se lisait encore comme une vitre ; il reste sombre et la lueur tombe sur le clavier et le bureau. Test `screenGlowNeverLightsItsMonitor`. |
| `ilot-x*-*.png` (Tao), `vue-ensemble-*.png` (Tao, SITE), `planche-5-personnage.png` | `sleep` ne différait de `sitIdle` que par la tête baissée d'un texel ; seul le « zZ », très haut, disait que l'agent dormait. | Pose avachie (7.9) : de face, la tête posée sur les bras croisés, 13 px plus bas ; de dos, le dos voûté, la tête enfoncée entre les épaules. Test `sleepIsSlumpedNotSitIdle`. Au deuxième rendu, le « zZ » suit la tête couchée (`SceneCompositor.headShift`) au lieu de flotter à la place d'une tête assise. Test `sleeperOverlayFollowsTheHead`. |
| `ilot-x*-*.png` (Kiwi), `planche-2-mobilier-decor.png` | `chair~*.jacket` se lisait comme une poubelle grise. | Veste dessinée (col, épaules tombantes, manches, revers et boutons), camel, ou marine sur les chaises Tomate, Mandarine et Cacao. Test `jacketReadsAsAJacket`. Lisible comme une veste à partir de ×2. |
| `planche-2-mobilier-decor.png`, scènes | `lamp.desk` : crochet noir de 12 × 18 qui se lisait comme un bras de micro. | 24 × 17 : pied métal, bras arqué, abat-jour crème penché à côté du moniteur ; allumée, l'intérieur s'éclaire et l'ampoule devient blanche. Tests `lampOnOff`, `lampShadeStandsBesideTheMonitor`. |
| `vue-ensemble-*.png` | Un agent qui attend portait le « ! » XL et la petite icône « ! » ; ailleurs, deux petites icônes redondantes au-dessus de chaque tête. | Décision 2 : seuls le « ! » XL et l'orage restent. Test `overviewKeepsOnlyUrgentSigns`. |
| `vue-ensemble-*.png` | Le texte des pancartes et des plaques faisait 2,5 pt. | Pancartes ×2. Les plaques restantes (agents urgents) font toujours 2,5 pt : voir plus bas. |
| `vue-ensemble-*.png` | Mur de liège : les 12 mini post-its formaient une seule ligne en diagonale. | Cartes réparties en rangées lâches, en quinconce, sur tout le panneau (`boardSpread`, ordre de van der Corput) ; une nouvelle carte ne déplace jamais les autres. Test `corkWallSpreadsItsCards`. |
| `planche-3-ecrans-overlays.png` | `ov.edgeArrow` ressemblait à une goutte jaune marquée « ! ». | Flèche vers le haut (tête à 45°, hampe de 8 px) en alertYellow cernée d'alertOrange, « ! » ink sur l'axe. Test `edgeArrowIsAnArrowWithABang`. |
| `planche-0` à `planche-6` | `PixelFont` : 0 lu D ou O, 8 proche du B. | Décision 4 : chiffres redessinés (« PLANCHE 0 » et « ~HUE0 » se lisent bien). |
| `planche-6-apparences.png`, scènes (Zéphyr, Lou) | Les cheveux gris courts vus de dos formaient une calotte grise uniforme (bonnet, casque). | Mèches sur toutes les coupes, oreilles et nuque dégagées pour les coupes courtes, carré qui s'arrête à la mâchoire. Test `hairFromBehindIsNotACap`. |
| `planche-1`, `planche-2`, `planche-3`, `planche-4` | Les sprites clairs étaient presque invisibles sur le damier `paper` / `mist`. | Damier sombre `slate` / `shade` sous tout sprite clair (règle plus haut). Test `lightSpritesSitOnADarkCheckerboard`. |
| `ilot-x*-*.png`, `vue-ensemble-*.png`, `planche-3-ecrans-overlays.png` | Deuxième rendu : la tête large et arrondie du « ! » (`ov.bang`, `ov.bang~xl`) avec son halo rond se lisait aussi comme une ampoule, surtout en vue d'ensemble et à ×3. | Troisième rendu, points 1 et 2 : une barre droite et anguleuse qui s'affine vers le bas, 2 rangées vides, un point carré ; un halo en losange iso centré sur la barre, loin du point. Tests `bangReadsAsAnExclamationMark`, `haloIsAnIsoDiamond`, `haloStaysClearOfTheDot`. |
| `vue-ensemble-*.png` | Deuxième rendu : les plaques des agents urgents (NOVA, SOL, IVO, ZÉPHYR) font 2,5 pt de haut, à la limite du lisible. | Tranché le 2026-10-01 : plaques ×2, comme les pancartes, dessinées par le compositeur à l'étape 3 (tâche 6). Inchangées dans ce rendu. |
| `ilot-x*-*.png` (Tao), `planche-5-personnage.png` | Deuxième rendu : les yeux fermés de la pose avachie étaient des points de 1 px, qu'on lisait comme des yeux ouverts. | Troisième rendu, point 4 : un trait horizontal de 2 px par œil. Test `sleepingEyesAreClosedLines`. |
| `ilot-x1-*.png`, `planche-2-mobilier-decor.png` | Deuxième rendu : à ×1, la lampe était petite et se mêlait au pied du moniteur ; de jour, `~on` et `~off` ne différaient que de quelques texels (la nuit, la flaque le disait). | Troisième rendu, point 6 : pied et bras en métal sombre, abat-jour qui s'éclaire ; au moins 12 pixels de différence de jour. Tests `lampOnAndOffDifferByDay`, `lampStandsApartFromTheMonitorFoot`. |
| `ilot-x1-*.png`, `planche-6-apparences.png` | Deuxième rendu : à ×1, les cheveux gris courts vus de dos restaient une masse arrondie assez uniforme (mèches d'un seul pixel). | Troisième rendu, point 5 : mèches de 2 px en ton d'ombre dans la masse de chaque coupe courte, de toute couleur. Test `shortHairFromBehindHasStrands`. |
| `ilot-x1-*.png` (Kiwi) | Deuxième rendu : à ×1, la veste n'est qu'une petite forme brune sur le dossier ; elle se lit comme une veste à partir de ×2. | Jugée à l'œil sur ce rendu, gardée telle quelle : à ×1 la plaque « KIWI · OFF » dit déjà que l'agent est hors ligne, et la veste se lit à partir de ×2. |
| `ilot-x*-*.png` (Zéphyr) | L'orage, posé sur la tête de Zéphyr, chevauche le coin avant du bureau du poste précédent : il se lit comme le sien, mais la superposition se voit. | Accepté tel quel : conséquence de la décision 1 et de la hauteur des bureaux. |
| `vue-ensemble-*.png` | La pancarte ×2 de SITE touche le bord gauche de l'image (pas coupée, vérifié pixel à pixel) et passe devant le mur. | Accepté tel quel : dans l'app, la caméra garde une marge de 48 pt autour du monde (étape 3, décision 15 du plan). |

### Restants

Aucun : chaque défaut relevé est corrigé, tranché ou accepté avec sa raison (tableau ci-dessus).

Rien d'autre à signaler sur la netteté ni sur la couverture : `ilot-x2-*` et `ilot-x3-*` sont exactement `ilot-x1-*`
agrandi au plus proche (vérifié pixel à pixel), les PNG n'ont que des pixels opaques ou transparents, et chaque
sprite v0 a sa cellule sur une planche (test `everyCatalogSpriteHasACell`).

## Rendu

Depuis la racine du dépôt :

```bash
swift run --package-path Core -c release sprite-export --out "$PWD/docs/jalon-visuel"
```

Une ligne par fichier écrit (nom, largeur × hauteur, taille en octets). Compte une minute au plus la première
fois (compilation en release), puis quelques secondes pour les 15 images ; le pic de mémoire est d'environ
1,1 Go (planche 1 à l'échelle 4). Le rendu est déterministe : deux rendus donnent les mêmes octets, sous Linux
comme sous macOS (vérifié le 1er octobre 2026 : deux rendus successifs de ce troisième rendu sont identiques octet
pour octet).

Options : `--only palette,sheets,island,overview` (une partie seulement), `--scale <n>` (échelle des planches,
de 1 à 8 ; 4 par défaut), `--out <dossier>`, `--help`.

**Contrôles automatiques** :

- `cd Core && swift test` compare l'empreinte de chaque image de chaque sprite (716) et de quatre scènes (îlot 1
  et 2 à ×1 de jour, vue d'ensemble de jour et de nuit) au fichier
  `Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt` (`GoldenTests`). Les planches n'y sont pas : leur mise en
  page est vérifiée par `ContactSheetTests`.
- La CI (job Linux de `.github/workflows/core.yml`) refait le rendu, compare chaque PNG à celui du dépôt octet
  par octet, et publie les images en artefact (`jalon-visuel`).

Après une modification **voulue** d'un sprite ou du compositeur, depuis la racine du dépôt :

```bash
swift run --package-path Core sprite-export --golden-out Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt
swift run --package-path Core -c release sprite-export --out "$PWD/docs/jalon-visuel"
```

puis commit du golden et des images.

## Écarts à la proposition

### Décisions du plan (`docs/superpowers/plans/2026-10-01-jalon-visuel.md`)

1. **Sprites v0** : les sprites « Ét. 3 » de 7.4, plus `light.cone`, `light.screenGlow`, `fx.star` (« Ét. 4 »,
   nécessaires à la nuit) et `elevator.led`. Hors v0 : l'habillage SwiftUI (7.4.6), les post-its du tableau, les
   punaises, `trash`, `printer`, `ov.smoke`, `ov.speech`, les effets des étapes 4 et 6, le décor déblocable,
   `portrait.mini`, le contour pointillé, niveaux, badges et mode édition.
2. **Orientation des rangées** : la taille de l'îlot impose des rangées le long de i ; « nord-ouest / sud-est » de
   3.8 deviennent `ne` (rangée A) et `sw` (rangée B). `ne` est dessiné, `sw` est le miroir ré-ombré de `se`.
3. **Pas des postes** : bureau puis une tuile de dégagement, d'où `(2·⌈cap/2⌉ + 2) × 7` tuiles par îlot.
4. **Index de poste** indépendant de la capacité : partie `d / 8`, rangée selon la parité, poste `l / 2` ; un îlot
   qui passe de 4 à 8 postes grandit vers +i sans déplacer un poste.
5. **Moniteurs** : `monitor.front` seulement en `ne` et `nw`, `monitor.back` seulement en `se` et `sw` (les deux
   autres orientations ne seraient jamais vues), au lieu de « 4 or. ».
6. **Police** : `PixelFont`, police pixel originale du cœur (pas de Silkscreen sans CoreText).
7. **Annexes** (« API · 2 ») placées au calcul dans le premier slot libre, slot non persisté (corrigé à l'étape 3).
8. **Tailles de 7.4** ajustables quand la géométrie l'impose, avec une ligne « Écart » (liste ci-dessous).
9. **Atlas et manifeste** (7.6) et remplacement par des PNG (7.7) reportés à l'étape 3 : `sprite-export` n'écrit ni
   pages d'atlas ni `manifest.json`, et n'a pas d'option `--contact-sheet` (les planches font toujours partie du
   rendu).
10. **Alpha** : sprites opaques ou transparents ; ombres opaques en `ink` qui reçoivent leurs 30 % une seule fois au
    compositing, lumières de nuit opaques qui reçoivent 35 % en additif.
11. **Lecture des PNG** : à ×k, un texel = k pixels ; vue d'ensemble à 144 ppp.
12. **Apparences** : `AgentLook()` par défaut identique pour tous ; les scènes fixent des apparences à la main. Le
    choix automatique relève de l'étape 3.
13. **Un agent dans chaque état** : deux distributions du même îlot (tableau plus haut).

### Tailles modifiées (lignes « Écart » des tâches 4 à 7)

- `desk` : 64 × 56 au lieu de 64 × 48 (plateau à 24 px sur toute la profondeur de la tuile). Tâche 4.
- `keyboard` : 14 × 9 au lieu de 14 × 6 ; `papers` : 12 × 8 au lieu de 12 × 6 (boîtes 2:1 avec 2 px d'épaisseur
  pour la sonde de lumière). Tâche 4.
- `mug~steam` : 6 × 14 (la vapeur monte au-dessus de la tasse de 6 × 8). Tâche 4.
- `elevator` : ancré en (32, 112) au lieu de (32, 120) (point du sol sous le milieu des deux tuiles). Tâche 4.
- `board.cork` : 192 × 192 ancré en (96, 144) au lieu de 192 × 128 (pan de mur de 6 tuiles portant 4 rangées de
  12 mini post-its). Tâche 4.
- `elevator.led` : 6 × 8. Tâche 4.
- `screen.*` : 12 × 13 au lieu de 16 × 10 (image plate de 12 × 8 cisaillée 2:1 sur la face du moniteur). Tâche 5.
- Tâches 6 et 7 : aucun écart de taille.
- Troisième rendu : aucun écart de taille (`ov.bang` 12 × 24, `ov.bang~xl` 24 × 48, `ov.bang.halo` 32 × 32 et
  `lamp.desk` 24 × 17 gardent leur taille et leur ancre) ; nouveau sprite `ov.edgeArrow~diagonal`, 16 × 16 ancré en
  (8, 8), 2 images à 4 fps, comme `ov.edgeArrow`.
- Hors 7.4 (tâche 2) : le test `flatImageCompresses` borne une image unie de 512 × 512 à 8 Kio au lieu de 4 Kio (le
  Huffman fixe ne descend pas sous 6 610 octets pour ces données).

### Écarts de la tâche 8

- **Empreintes golden** : FNV-1a 64 bits de chaque image (`PixelImage.fingerprint`), dans un seul fichier trié
  (`Fixtures/golden/sprites.txt`), au lieu de fichiers `Tests/Golden/*.sha` (7.5).
- **Planches** : une cellule par sprite, groupées par identifiant (taille, cadence et ancre dans l'en-tête du
  groupe) ; les familles `hud.state.<nom>`, `minimap.dot.<nom>` et `ov.tool.<nom>` forment un groupe chacune. La
  planche 4 ajoute la plaque « ZÉPHYR » (hauteur avec accent) et un texte `chalk` à contour `ink` ; la planche 5
  porte la teinte Lagune (P4), comme le catalogue.
- **`sprite-export`** : `--scale` va de 1 à 8 et ne touche que les planches ; `--help` ; code de sortie 2 si un
  fichier ne peut pas être écrit.
- **Journal de provenance** dans `docs/ASSETS.md` (7.10 le prévoyait dans `Resources/`).

### Écarts de la révision du 1er octobre 2026

- `light.cone` : 28 × 14 ancré en (14, 7) au lieu de 48 × 32, en `alertOrange` au lieu de `lampWarm`, découpé au
  losange du plateau au compositing (7.1, 7.4, 7.8).
- `lamp.desk` : 24 × 17 ancré en (12, 17) au lieu de 12 × 18 ancré en (6, 17).
- `light.screenGlow` : découpé au compositing pour ne jamais éclairer son propre moniteur (ni l'écran, ni le post-it
  collé dessus).
- **Tapis** : à la taille des postes occupés plus un poste libre (décision 3), au lieu de toute l'emprise de l'îlot.
- **Pancarte** : au coin avant gauche du tapis au lieu du coin arrière ; ×2 en vue d'ensemble.
- **Overlays** : en rangée A, posés sur la tête ; plaque de la rangée B à côté de la tête ; « zZ » sur la tête
  couchée d'un agent endormi ; signe « démarre » au-dessus d'un agent qui démarre (×1 et au-delà).
- **Vue d'ensemble** : seuls les signes urgents et les plaques de leurs agents (décision 2), au lieu de l'icône
  d'état et de la bulle d'outil de chaque poste.
- **Planches** : damier sombre `slate` / `shade` sous les sprites clairs ; la planche 0 montre la flaque de la lampe
  sur le plateau (woodLight) plutôt que sur floorLight.

### Écarts du troisième rendu

- `ov.edgeArrow` : les 8 directions viennent de quarts de tour de `ov.edgeArrow` et de `ov.edgeArrow~diagonal`, au
  lieu d'une rotation de 45° d'un seul sprite (7.4.5) : tourner du pixel art de 45° le déforme (7.3).
- `ov.bang.halo` : losange iso pulsé, au lieu d'un anneau rond, autour du « ! » (7.4.5 dit seulement « halo pulsé ») ;
  le « ! » est une barre anguleuse et un point carré.
- `lamp.desk` : pied et bras en métal peint sombre (`shade`, `ink`), et non dans le métal gris du mobilier.
