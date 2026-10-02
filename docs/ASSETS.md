# Journal de provenance des assets

Ce journal répond à la section 7.10 de `docs/PROPOSITION.md` (originalité et propriété intellectuelle) : qui a
fait chaque asset, quoi, et comment. Il est tenu à jour à chaque ajout ou remplacement d'un asset.

> Pixel Open Space n'est ni affilié à Anthropic ni approuvé par Anthropic ; il lance l'outil Claude Code installé
> sur ta machine.

## Principe

- **Tout est dessiné de zéro, par programme.** Chaque sprite est décrit dans le code Swift du cœur
  (`Core/Sources/PixelCore/Assets`) par des cartes ASCII de rôles de couleur (`PixelMap`, 7.5) et des primitives
  isométriques (`Draw.isoBox`, `isoDiamond`, `line2to1`, `dither50`, `shearToWall`), puis rendu en pixels par le
  même code, de façon déterministe.
- **Aucune source externe** : aucune image importée, décalquée, recolorée ou extraite d'un jeu, aucun pack d'assets,
  aucune police rasterisée. Le dépôt ne contient aucun fichier image source : les seuls PNG sont les rendus du jalon
  visuel (`docs/jalon-visuel/`), produits par `sprite-export` à partir du code. L'app n'embarque aucune image non
  plus : elle calcule les mêmes sprites au lancement et les range dans un atlas en mémoire (plus bas).
- **Une seule palette**, originale (`Assets/Palette.swift`, 7.1) : 32 couleurs de base, 10 teintes de projet en 3 tons,
  quelques couleurs dérivées. Un test vérifie chaque pixel de chaque sprite.
- **Nos propres proportions** : environ 3,5 têtes, yeux de 1 × 2 px (fermés : un trait de 2 × 1 px), pas de bouche
  au repos ; nos noms d'objets et de lieux (« îlot », « poste », « mur de liège »). Rien qui reprenne ou évoque un
  jeu, un hôtel virtuel, une borne d'arcade connue, un personnage de film ou de série, une marque, ni le nom, le logo
  ou la mascotte d'Anthropic ou de Claude. Les noms d'agents viennent de `NameGenerator` (mots inventés ou courants).

## Sprites v0 (jalon visuel)

Auteur de tout ce qui suit : le code du dépôt (Pixel Open Space), écrit avec l'assistance de Claude Code ; aucun
auteur ni aucune source tiers.

| Groupe | Fichier (`Core/Sources/PixelCore/`) | Sprites | Comment |
|---|---|---|---|
| Palette | `Assets/Palette.swift` | 32 rôles, 30 tons de teinte | Valeurs originales (7.1) ; tons clair et sombre calculés par `mix` puis figés |
| Sols | `Assets/Sprites/FloorSprites.swift` | `floor.hall`, `floor.corridor`, `floor.carpet` et ses bords et coins, `floor.hover`, `floor.dropTarget` | Losanges 2:1, damier à 50 %, détails en `PixelMap` ; bords `.e`, `.w` et `corner.w` en miroir |
| Murs | `Assets/Sprites/WallSprites.swift` | `wall.segment`, `wall.window`, `wall.corner`, `pillar`, `elevator`, `elevator.led`, `board.cork` | Boîtes iso éclairées en haut à gauche ; objets muraux dessinés de face puis cisaillés 2:1 pour chaque mur |
| Mobilier | `Assets/Sprites/FurnitureSprites.swift` | `desk`, `chair` | `Draw.isoBox` dans les quatre directions, jamais par miroir |
| Objets du bureau | `Assets/Sprites/DeskItemSprites.swift` | `keyboard`, `papers`, `mug`, `lamp.desk`, `desk.postit`, `desk.queue`, `postit.mini` | Petites boîtes iso et cartes ASCII |
| Décor | `Assets/Sprites/DecorSprites.swift` | `decor.plantSmall`, `decor.coffeeMachine` | Cartes ASCII et boîtes iso |
| Ombres et lumières | `Assets/Sprites/LightSprites.swift` | `shadow.tile`, `shadow.char`, `shadow.small`, `light.cone`, `light.screenGlow`, `fx.star` | Formes pleines (ellipse et losange par algorithmes entiers) |
| Moniteurs et écrans | `Assets/Sprites/MonitorSprites.swift` | `monitor.front`, `monitor.back` (LED par état), `screen.*` | Boîtes iso ; contenus d'écran en cartes ASCII cisaillées sur la face |
| Overlays | `Assets/Sprites/OverlaySprites.swift` | `ov.*` (états, outils, badges, sélection, flèche de bord droite et diagonale) | Cartes ASCII et losanges 2:1 ; une forme distincte par état (7.9), icônes d'outil génériques ; la flèche diagonale est un sprite à part, jamais une rotation de 45° |
| Effets | `Assets/Sprites/EffectSprites.swift` | `fx.dust`, `fx.ding`, `fx.pinDrop` | Cartes ASCII |
| HUD | `Assets/Sprites/HUDSprites.swift` | `sign.island`, `desk.nameplate`, `desk.queueBadge`, `hud.state.*`, `minimap.*` | Cartes ASCII, 9-slice, texte en `PixelFont` |
| Personnages | `Assets/Characters/` (`CharacterParts.swift`, `CharacterPoses.swift`, `CharacterSprites.swift`, `SlotCanvas.swift`, `CharacterPalette.swift`) | `agent.*` (14 animations), `agent.mini` | Parties en cartes ASCII posées image par image ; SE et NE dessinés, SW et NW en miroir ré-ombré |

Les scènes (`World/ScenePlanner.swift`, `World/SceneCompositor.swift`, `World/Showcase.swift`,
`World/ShowcaseWorkspace.swift`), les planches de contact (`Assets/ContactSheet.swift`), l'atlas
(`Assets/AtlasPacker.swift`, `Assets/SpriteManifest.swift`, `Assets/AtlasExport.swift`) et les PNG
(`Assets/PNGEncoder.swift`, `Assets/Deflate.swift`, `Assets/MilestoneExport.swift`, exécutable `sprite-export`) sont
composés à partir de ces sprites, sans autre source. Dans l'app, la scène SpriteKit affiche ces mêmes sprites, et les
contrôles SwiftUI (mini-carte, flèches de bord, portrait de la fenêtre agent) les dessinent à 2 pt par pixel, sans
lissage.

## Atlas et manifeste (étape 3)

- **Dans l'app**, `SpriteRegistry` range au premier affichage tous les sprites du catalogue (`SpriteCatalog.all`) dans
  un atlas en mémoire, puis en textures SpriteKit sans lissage. Le rangement (`AtlasPacker`) est déterministe : par
  étagères, des images les plus hautes aux plus basses, avec 2 px de marge remplis par le bord de chaque image. Aucun
  fichier n'est lu : les pixels sont ceux que le cœur calcule, ceux du jalon visuel. Les miroirs y sont des images à
  part entière (décision 5 du plan de l'étape 3), jamais un retournement à l'exécution. Les planches de personnages de
  chaque apparence sont composées à la demande dans des pages à part, qui ne sont pas exportées.
- **Exporter l'atlas**, depuis la racine du dépôt :

  ```bash
  swift run --package-path Core sprite-export --atlas <dossier>
  ```

  L'outil écrit `atlas-0.png` (et les pages suivantes s'il y en a) et `manifest.json` (7.6), une ligne par fichier,
  et aucune autre image. Le 2026-10-02 : une page de 2048 × 2048, 716 images, 128 animations, 40 miroirs plats, 14
  sprites teintés par projet. Deux exports donnent les mêmes octets. Ces fichiers ne sont pas versionnés.
- **Écarts du manifeste avec 7.6** (`Assets/SpriteManifest.swift`) : chaque nom porte son image (`desk@se#0`) ; une
  animation donne la durée de chaque image en ticks de l'horloge de 24 par seconde (`holds`) au lieu d'un nombre
  d'images par seconde (exact pour toutes les cadences de 7.3) ; `mirrors` dit seulement de quel sprite vient un
  miroir plat, qui a sa propre entrée ; `mask` dit si le sprite se clique (hit-test sur sa forme, 3.9).
- Ce manifeste et ses pages serviront de gabarit au remplacement des sprites par tes PNG, à l'étape 4 (plus bas).

## Polices

- **`PixelFont`** (`Assets/PixelFont.swift`) : police pixel **originale**, dessinée glyphe par glyphe dans le code
  (capitales de 5 px, accents français, chiffres, ponctuation) ; aucun glyphe recopié d'une police existante. Elle
  sert aux pancartes des îlots, aux plaques de nom et aux badges de file, dans les planches du jalon comme **dans
  l'app** depuis l'étape 3 : la scène, et les plaques de nom des flèches de bord, composées par le cœur
  (`HUDSprites`). Les panneaux SwiftUI de l'app utilisent la police du système.
- **Silkscreen** et **Pixelify Sans** (licence SIL Open Font License) : prévues pour l'étape 4 (7.11), **pas encore
  livrées**. Quand elles le seront, leurs fichiers et leur licence (OFL) seront ajoutés au dépôt et listés ici.

## Icônes du système

Les icônes des panneaux SwiftUI (barre d'outils, barre d'état, plateau d'attente, cartes, menus) sont des SF Symbols
d'Apple, fournis par macOS : aucun fichier n'est copié dans le dépôt.

## Sons

Aucun pour l'instant. Les sons prévus (7.11, 3.17) seront synthétisés par le code, sans échantillon externe.

## Sprites remplacés

Aucun. Le remplacement des sprites par tes PNG (7.7) arrive à l'étape 4, comme le prévoit la section 8 de la
proposition (décision 6 du plan de l'étape 3) ; l'atlas et `manifest.json` de `sprite-export --atlas` en seront le
gabarit. Un sprite remplacé et livré dans le dépôt sera listé ici avec son auteur et sa licence.
