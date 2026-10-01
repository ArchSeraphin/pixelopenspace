# Jalon visuel : sprites v0, îlot de démonstration et vue d'ensemble

But : valider la direction artistique **avant** l'étape 3 (voir `docs/PROPOSITION.md`, section 8 « Jalon visuel » et
section 7). Toutes les images de ce dossier sont produites par le cœur seul (`Core/`, Swift pur, compilé et testé
sous Linux comme sous macOS), sans l'app, sans SpriteKit et sans aucune image externe : chaque sprite est dessiné par
le code (`docs/ASSETS.md`), puis la scène est composée en logiciel par `SceneCompositor`, comme SpriteKit la dessinera
à l'étape 3.

**Terminé quand** tu valides les images et que tu as tranché les questions ci-dessous. L'étape 3 ne commence
qu'après.

## Les 15 images et ce qu'il faut y regarder

| Fichier | Pixels | À regarder |
|---|---|---|
| `planche-0-palette.png` | 3136 × 2380 | Les 32 couleurs de base et les 10 teintes en 3 tons : la palette te plaît-elle telle quelle ? Regarde aussi la case « flaque d'une lampe » sous le voile de nuit (rose grisé, pas chaud). |
| `planche-1-sols-murs.png` | 3136 × 6472 | Moquettes des 10 teintes avec leurs bords et coins (ceux marqués « MIROIR » restent éclairés en haut à gauche), carrelage du hall, murs, fenêtres de jour, au crépuscule et de nuit, ascenseur en 6 images, mur de liège. |
| `planche-2-mobilier-decor.png` | 3136 × 4464 | Chaises en 4 orientations et 11 teintes, chaise avec la veste (agent hors ligne), bureau, lampe éteinte et allumée, petits objets, fontaine, plante, ombres et lumières. |
| `planche-3-ecrans-overlays.png` | 3136 × 3104 | Moniteurs (LED d'état au dos, côté rangée B), les 10 contenus d'écran de 12 × 13 et tous les overlays : chaque état doit avoir sa forme propre, sans compter sur la couleur. |
| `planche-4-hud-texte.png` | 3136 × 2248 | Icônes d'état, points de mini-carte, pancartes, plaques de nom et police `PixelFont` : lisibilité des accents et des chiffres (le 0 ressemble à un D). |
| `planche-5-personnage.png` | 3656 × 5580 | Les 14 animations du personnage par défaut en SE, SW, NE et NW : chaque pose se reconnaît-elle (surtout `sleep` face à `sitIdle`) ? SW et NW, miroirs ré-ombrés, restent-ils éclairés en haut à gauche ? |
| `planche-6-apparences.png` | 3136 × 1336 | Les 16 apparences de face et de dos (peaux, coupes, accessoires) et `agent.mini` dans les 10 teintes : assez variées, assez originales ? |
| `ilot-x1-jour.png` | 672 × 894 | Le zoom le plus petit (1 pt par texel) : chaque état se lit-il d'un coup d'œil, l'écran de la rangée A reste-t-il visible à côté de la tête, les overlays sont-ils assez grands ? |
| `ilot-x2-jour.png` | 1344 × 1788 | Le zoom courant : visages de la rangée B derrière les moniteurs, post-it collé à l'écran de Pixou, file de post-its, sous-agents de Bip, chaque overlay au-dessus du bon poste. |
| `ilot-x3-jour.png` | 2016 × 2682 | Le détail : netteté (c'est exactement ×1 agrandi, sans aucun flou), finesse des personnages et des objets du bureau. |
| `ilot-x1-nuit.png` | 672 × 894 | La nuit au plus petit zoom : les overlays restent identiques au jour au-dessus du voile ; la scène reste-t-elle lisible ? |
| `ilot-x2-nuit.png` | 1344 × 1788 | Couleur, taille et position des flaques de lumière des lampes et de la lueur des écrans. |
| `ilot-x3-nuit.png` | 2016 × 2682 | Les mêmes lumières de près : les flaques débordent du plateau sur la moquette et virent au gris mauve. |
| `vue-ensemble-jour.png` | 1920 × 1056 | La maquette 6(q), 20 agents sur 6 projets : repère-t-on tout de suite les 3 agents qui attendent (Nova, Sol, Ivo) et Zéphyr en erreur ? Les petites icônes et le texte sont-ils encore utiles à cette échelle ? |
| `vue-ensemble-nuit.png` | 1920 × 1056 | La même de nuit : ambiance générale, fenêtres de nuit, « ! » toujours aussi visibles. |

Les sept planches couvrent tous les sprites v0 (`SpriteCatalog.v0IDs`), à l'échelle 4 (4 pixels par texel). Chaque
image d'un sprite y est posée sur un damier `paper` / `mist` de 4 × 4 texels qui montre sa transparence ; un groupe
porte l'identifiant, la taille, la cadence (« 4 × 8 FPS », « UNE FOIS » sans boucle) et l'ancre, chaque cellule sa
variante (`~hue3`), sa direction (`@ne`) et « MIROIR » pour un sprite obtenu par miroir (« MIROIR RÉ-OMBRÉ » pour
les personnages SW et NW). La planche 0 ajoute l'ombre, la flaque de lumière, le voile de nuit, les couleurs
dérivées et les couleurs clés marquées « jamais dans un sprite » ; la planche 4 ajoute le spécimen de `PixelFont`
(alphabet, accents, chiffres, symboles, les 60 noms de `NameGenerator`), les pancartes « API », « SITE WEB »,
« DOCUMENTATION » et les plaques « NOVA », « ZÉPHYR », « OFF ».

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
Chaque îlot porte sa pancarte, une lampe par bureau, des post-its (file sur le bureau avec son badge, post-it collé
à l'écran) et une plante.

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
et Zéphyr en erreur), SITE (3), DATA (3), MOBILE (3), DOCS (2, dont Ivo qui attend), 12 mini post-its sur le mur
de liège, emprise de 36 × 24 tuiles.

## Questions à trancher

### Les trois questions du jalon (section 8)

- [ ] **Lisibilité de l'écran en rangée A** : l'avatar de dos cache-t-il l'écran ? Le moniteur est décalé de 6 px
  vers la tuile de dégagement.
  - Ce que montrent les rendus : à ×1, ×2 et ×3, l'écran reste entièrement visible en haut à droite de la tête
    (Lune « … » violet, Zéphyr croix rouge, Mika sablier, Lou démarrage). Le post-it collé à l'écran de Pixou en
    cache environ un quart. Nova, qui attend, se tourne vers toi : son écran jaune est dégagé. En vue
    d'ensemble, l'écran fait 6 × 6 pt : sa couleur se lit (jaune, rouge, vert), pas son contenu.
  - En rangée B, l'état sur le moniteur n'est qu'une LED de 2 × 2 texels au dos (2 × 2 pt à ×1, 1 pt en vue
    d'ensemble) : c'est l'overlay qui porte l'information.
  - Choix : garder le décalage de 6 px tel quel, ou passer au **repli** de 7.4.3 (LED d'état sur le haut du
    moniteur de la rangée A, en plus de l'écran).
- [ ] **Taille des overlays à ×1 et en vue d'ensemble**.
  - À ×1 (1 pt par texel) : le « ! » (12 × 24 pt, halo de 32 × 32) se voit au premier coup d'œil ; bulles d'outil
    (16 × 16), « … » (20 × 14), coche (12 × 12), « zZ » (16 × 16) et orage (28 × 18) se lisent ; les signes
    secondaires (brouillon 10 × 10, « ? » sans nouvelles 10 × 14, mode dégradé et `bypassPermissions` 12 × 12) sont
    petits mais se trouvent quand on les cherche.
  - En vue d'ensemble (0,5 pt par texel) : le « ! » XL (24 × 48 texels, donc 12 × 24 pt) désigne bien les trois
    agents qui attendent. Les autres signes tombent à 6 × 6 pt (icône d'état) et 8 × 8 pt (bulle d'outil) : on lit
    leur couleur (coche verte, croix rouge, bulle lilas), pas leur glyphe (loupe, globe, feuille). Chaque poste
    occupé porte deux petites icônes côte à côte, souvent redondantes (voir « Défauts »). De loin, la tête large et
    arrondie du « ! » XL peut aussi se lire comme une ampoule.
  - Choix : garder ces tailles ; ou, en vue d'ensemble, une seule icône par poste (l'état, sans la bulle d'outil),
    éventuellement agrandie ; ou masquer tout sauf le « ! » et l'orage à ce niveau.
- [ ] **Palette** : valeurs à ajuster à l'œil (planche 0, puis les scènes).
  - De jour : chaque pixel des scènes est une couleur de la palette ou une couleur assombrie une seule fois par
    l'ombre (test `dayPixelsArePaletteOrSingleShadow`), aucune dérive. Les 6 teintes de la vue d'ensemble se
    distinguent bien ; les moquettes au ton « clair » donnent un ensemble pastel, les pancartes au ton de base.
  - De nuit : le voile (0,55) passe le carrelage au gris et les moquettes à des tons profonds ; les overlays gardent
    leurs couleurs de jour. Mais `lampWarm` ajouté à 35 % sur une moquette voilée ne donne pas de lumière chaude :
    sur la moquette bleue ombrée, la flaque vaut `#98939B`, un gris mauve.
  - Choix : garder la palette telle quelle, ou nommer les couleurs à changer (rôle et valeur) ; pour la nuit, changer
    la teinte ou l'alpha de la flaque, ou passer plus tôt à la permutation de palette jour → nuit (7.8).

### Autres choix du plan à confirmer

- [ ] **Orientation des rangées** (décision 2) : rangée A regard `ne` (dos et écran visibles), rangée B regard `sw`
  (visage visible).
- [ ] **Pas des postes** (décision 3) : un poste toutes les 2 tuiles (bureau, puis une tuile de dégagement qui reçoit
  les sous-agents et la flaque de la lampe). Repli : postes jointifs, îlot plus étroit.
- [ ] **Police** (décision 6) : garder `PixelFont` (originale, même rendu partout, texte net garanti) aussi dans
  l'app, ou revenir à Silkscreen (7.11). Si elle reste : redessiner le 0 (voir « Défauts »).
- [ ] **Nuit** : force du voile (0,55 ; 0,35 avec « Réduire la transparence ») et des flaques de lumière (35 %,
  additives).
- [ ] **Visages de la rangée B** derrière les moniteurs : lisibles à ×1 ? (Sur les rendus : tête et yeux visibles
  au-dessus du moniteur à ×1, détail des lunettes et des casques lisible à partir de ×2.)
- [ ] **Texte en vue d'ensemble** : à 0,5 pt par texel, les pancartes et les plaques de nom (capitales de 5 px)
  font 2,5 pt de haut, à la limite du lisible. Les garder, les agrandir, ou les masquer à ce niveau ?
- [ ] **Démarrage** : un agent qui démarre n'a pas d'overlay (comme un agent au repos) ; seuls la pose debout et
  l'écran de démarrage le signalent, et de dos (Lou, rangée A) la pose debout ressemble à la pose assise. Ajouter un
  signe (par exemple l'icône `hud.state.launching` au-dessus du poste), ou laisser l'arrivée par l'ascenseur de
  l'étape 3 jouer ce rôle ?

## Défauts constatés

Relevés à la revue des 15 images. Ils ne sont pas corrigés ici : chaque correction fera l'objet d'une tâche de
suivi (la colonne « Tâche » renvoie au plan), après quoi le golden et les images seront régénérés.

| Fichier | Tâche | Défaut |
|---|---|---|
| `ilot-x*-*.png`, `vue-ensemble-*.png` | 7 (placement) | Les overlays du poste B0 chevauchent ou touchent la pancarte de l'îlot (tuile locale (0, 0), juste au-dessus de B0) : en distribution 2, le « ! », son halo et la bulle « ? » de Sol passent sur la pancarte « API » ; en distribution 1 et en vue d'ensemble, la bulle `>_` de Bip la touche. |
| `ilot-x*-*.png`, `vue-ensemble-*.png` | 7 (placement) | En rangée A, l'overlay principal flotte au-dessus du bureau du poste de derrière : l'orage de Zéphyr sur le bureau de Lune, le sablier de Mika sur celui de Pixou, la double coche d'un agent de la rangée A sur le bureau voisin en vue d'ensemble. On peut l'attribuer au mauvais poste. Piste : un `overlayLift` plus bas en rangée A (avatar de dos, tête plus basse). |
| `ilot-x*-*.png` | 7 (placement) | La plaque d'un agent de la rangée B est posée sous ses pieds, donc sur le plateau du bureau : en distribution 2, « SOL » se lit entre Pixou et le sablier de Mika, loin de la tête de Sol. |
| `ilot-x*-nuit.png`, `vue-ensemble-nuit.png` | 4 (`light.cone`), 7 (position) | Les flaques de lumière virent au gris mauve pâle (`#98939B` sur la moquette bleue ombrée) : `lampWarm` ajouté à 35 % sur la moquette voilée ne donne pas une lumière chaude. L'ellipse déborde du plateau sur la moquette devant le bureau et se lit comme un spot au sol. À revoir : teinte (ou alpha), taille et position. |
| `ilot-x*-nuit.png` | 4 (`light.screenGlow`), 7 | La lueur des écrans forme sur les plateaux des parallélogrammes cyan pâle à bord net, qui se lisent comme une vitre posée sur le bureau plus que comme une lueur, surtout à ×3. |
| `ilot-x*-*.png` (Tao), `vue-ensemble-*.png` (SITE, INFRA, MOBILE), `planche-5-personnage.png` | 6 | `sleep` ne diffère de `sitIdle` que par la tête baissée d'environ un texel et les yeux fermés : l'agent endormi semble assis et éveillé. Seul le « zZ », qui flotte haut au-dessus de la tête, dit qu'il dort ; 7.9 prévoit une pose « avachi ». |
| `ilot-x*-*.png` (Kiwi, hors ligne), `planche-2-mobilier-decor.png` | 4 | `chair~*.jacket` : la veste posée sur la chaise se lit comme une poubelle grise plutôt qu'un vêtement, à ×1 comme à ×3. |
| `planche-2-mobilier-decor.png`, scènes | 4 | `lamp.desk` : silhouette en crochet noir de 12 × 18 qui se lit comme un bras de micro ou de moniteur plus que comme une lampe ; `~on` ne diffère de `~off` que par 1 ou 2 texels orange. |
| `vue-ensemble-*.png` | 7 | Un agent qui attend porte à la fois le « ! » XL et la petite icône `hud.state.waitingInput` (un autre « ! ») : redondant. Pour les autres états, l'icône d'état s'ajoute à côté de la bulle d'outil ou de l'overlay (« … » à côté de « … », coche à côté de coche) : deux petites icônes au-dessus de chaque tête. |
| `vue-ensemble-*.png` | 5, 7 | À 0,5 pt par texel, le texte des pancartes et des plaques (capitales de 5 px) fait 2,5 pt : à la limite du lisible en taille réelle (voir les questions). |
| `vue-ensemble-*.png` | 7 | Mur de liège : les 12 mini post-its forment une seule ligne en diagonale en haut du panneau, le reste est vide ; le panneau se lit comme une frise plus que comme un tableau d'affichage. |
| `planche-3-ecrans-overlays.png` | 5 | `ov.edgeArrow` ressemble à une goutte jaune marquée « ! » plus qu'à une flèche qui désigne le bord de l'écran. |
| `planche-0` à `planche-6` | 5 | `PixelFont` : le chiffre 0 est un rectangle plein, qu'on lit D ou O dans les étiquettes (« ~HUE0 » se lit « ~HUED », « PLANCHE 0 » se lit « PLANCHE D ») ; le 8 est proche du B. Sans effet sur les scènes (seuls les badges de file 1 à 9 y portent des chiffres), à corriger si `PixelFont` est gardée dans l'app. |
| `planche-6-apparences.png`, scènes (Zéphyr, Lou) | 6 | Les cheveux gris courts vus de dos forment une calotte grise uniforme qui se lit comme un bonnet ou un casque. |
| `planche-1-sols-murs.png`, `planche-2-mobilier-decor.png`, `planche-3-ecrans-overlays.png` | 8 (planches) | Les sprites clairs sont presque invisibles sur le damier `paper` / `mist` : `floor.dropTarget`, `floor.hover`, `fx.star`, `fx.dust`, `fx.pinDrop`. Un damier sombre pour ces groupes permettrait de les juger. |

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
comme sous macOS (le rendu du 1er octobre 2026 est identique, octet pour octet, aux images du commit précédent).

Options : `--only palette,sheets,island,overview` (une partie seulement), `--scale <n>` (échelle des planches,
de 1 à 8 ; 4 par défaut), `--out <dossier>`, `--help`.

**Contrôles automatiques** :

- `cd Core && swift test` compare l'empreinte de chaque image de chaque sprite (714) et de quatre scènes (îlot 1
  et 2 à ×1 de jour, vue d'ensemble de jour et de nuit) au fichier
  `Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt` (`GoldenTests`).
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
