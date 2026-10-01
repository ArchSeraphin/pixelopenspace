# Jalon visuel : sprites générés, îlot de démonstration et vue d'ensemble (cœur seul) : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** valider la direction artistique **avant** l'étape 3, avec des images produites par le cœur seul (`Core/`, compilé et testé sous Linux comme sous macOS) : la planche de contact de tous les sprites v0 ; **un îlot complet** (rangées A et B, un agent dans chaque état, post-its, pancarte, lampes) aux zooms ×1, ×2 et ×3, de jour et de nuit ; la **vue d'ensemble** de 20 agents sur 6 projets (maquette 6(q)). Un exécutable, `sprite-export`, écrit ces PNG dans `docs/jalon-visuel/`.

**Architecture:** tout est pur, déterministe et en Swift sans framework graphique. Les sprites sont décrits par des cartes ASCII de rôles (`PixelMap`, 7.5) et des primitives iso (`Draw.isoBox`…), rendus en `PixelImage` (RGBA en mémoire) avec la seule palette de 7.1, puis contrôlés par des tests (palette, marches 2:1, lumière, cadences, couverture de 7.4). `WorldLayout` place îlots, postes, murs et hall sur la grille (slots « append-only », 3.8) ; `AgentPresenter.scene` traduit l'état d'un agent en pose, overlay et écran ; `SceneCompositor` assemble la scène en logiciel (ombres dans un seul calque, voile de nuit, lumières additives, overlays au-dessus du voile). Un encodeur PNG maison (zlib : blocs « stored » et deflate à Huffman fixe, CRC32, Adler32) écrit les fichiers. Des empreintes « golden » figent chaque sprite et les scènes clés.

**Tech Stack:** Swift 6.2 (mode de langage 6, concurrence stricte), Foundation seule, swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), aucune dépendance nouvelle.

**Spec:** `docs/PROPOSITION.md` : **section 7 en entier** (7.1 palette, 7.2 lumière, contours et ombres, 7.3 grille et gabarits, 7.4 liste complète des sprites, 7.5 générateur, 7.8 mode nuit, 7.9 accessibilité, 7.10 originalité, 7.11 polices), 3.7 (`AgentPresentation`), 3.8 (`WorldLayout`, `IsoMath`), 3.10 (`SpriteCatalog`, `SceneCompositor`), 4.3 (états d'un agent), 6(a) et 6(q) (maquettes de la scène), 8 (« Jalon visuel » : livrable et critère de fin). Lire aussi `Core/Sources/PixelCore/State/AgentPresenter.swift`, `State/AgentRuntime.swift`, `Model/Workspace.swift`, `Persistence/WorkspaceOps.swift` et `Util/NameGenerator.swift`, qui existent déjà.

## Global Constraints

- **Ne pas compiler ni lancer l'app** : jamais de `xcodebuild`, de `xcodegen` ni d'`open`, aucune modification de `App/`, `project.yml` ou `Config/` (l'utilisateur teste une copie de l'app en ce moment). Tout se vérifie par `cd Core && swift build && swift test`.
- Le cœur compile et passe ses tests **sous Linux et macOS** : Foundation seulement ; ni CoreGraphics, ni AppKit, ni ImageIO, ni CryptoKit dans `Core/Sources`. ImageIO n'est permis que dans un test, sous `#if canImport(ImageIO)`, comme contre-vérification de l'encodeur PNG.
- Swift 6, concurrence stricte : tous les types publics sont `Sendable` ; aucun état global mutable (les caches sont des `static let` immuables ou des variables locales à un appel).
- Tests en swift-testing avec `@testable import PixelCore`, comme les fichiers existants. Les 764 tests existants restent verts. Chaque nouvelle suite reste rapide en debug (quelques secondes). Tout aléa est semé avec `SplitMix64` (déjà défini dans `AgentStateMachineTests.swift`, même module de test).
- **Déterminisme strict, mêmes octets sous Linux et macOS** : aucune `Date()`, aucun `UUID()`, aucun aléa non semé ; ne jamais parcourir un `Dictionary` ou un `Set` pour produire un ordre de sortie (toujours trier) ; mélanges de couleurs en arithmétique entière (formules de la tâche 1) ; aucune fonction transcendante de libm (`sin`, `pow`, `exp`…) dans le chemin des pixels (ellipse et cercles par algorithmes entiers).
- **Palette** (7.1) : un sprite généré n'utilise que `Palette.spriteColors` (32 rôles et 30 tons de teinte), en pixels opaques ou transparents (α 0 ou 255) ; jamais les couleurs clés `#FF00FF`, `#FF80FF`, `#800080` ; `alertYellow` seulement dans les sprites de l'attente (`Palette.alertYellowSprites`). Aucune couleur ne vit ailleurs que dans `Palette.swift`.
- **Pixel parfait** (7.3) : texels et ancres entiers, agrandissement au plus proche par facteur entier, marches iso 2:1 (jamais de marche de 1 ou 3 px), aucun anticrénelage ; seul tramage permis : un damier à 50 %, en petite quantité, sur les grandes surfaces.
- **Lumière en haut à gauche** (7.2) dans les quatre directions ; aucun volume éclairé n'est obtenu par simple miroir.
- **Originalité (7.10), à respecter dans chaque sprite** : tout est dessiné de zéro, par programme ; nos propres proportions (environ 3,5 têtes, yeux de 1×2 px, pas de bouche au repos) ; rien qui reprenne ou évoque un jeu, un hôtel virtuel, une borne d'arcade connue, un personnage de film ou de série, une marque, ni le nom, le logo ou la mascotte d'Anthropic ou de Claude ; aucun nom de marque ou de jeu dans les images ; noms d'agents tirés de `NameGenerator` ou des maquettes ; vocabulaire maison (« îlot », « poste », « mur de liège »).
- Code, identifiants et commentaires en anglais, au ton du code existant ; textes affichés dans les images et documents en français.
- **Jamais de tiret cadratin** (U+2014) nulle part : code, commentaires, chaînes, images (la police pixel n'a pas ce glyphe), docs, messages de commit.
- Un commit par tâche, message impératif en anglais. Pas de push.

## Review Focus

1. **Aucun îlot ne bouge, aucun poste ne bouge** quand un projet ou un agent est ajouté, retiré ou archivé, y compris quand un îlot passe de 4 à 8 postes. Tests : `WorldLayoutPropertyTests.noIslandEverMoves`, `existingDesksNeverMove`, `WorldLayoutTests.islandGrowsInPlace`.
2. **Pixel parfait** : ×2 et ×3 sont exactement ×1 agrandi au plus proche ; losanges en `4y + 4` ; lignes 2:1 ; aucune valeur alpha intermédiaire dans un sprite. Tests : `SceneCompositorTests.zoomIsExactUpscale`, `DrawTests.diamondRowsAre4yPlus4`, `DrawTests.line2to1StepsAreTwoPixels`, `SpriteCatalogTests.everySpriteIsLintClean`.
3. **Palette et ombre unique** : de jour, chaque pixel de la scène est une couleur de palette, ou une couleur de palette assombrie **une seule fois** par l'ombre (règle 4 de 7.3 : deux ombres qui se chevauchent ne foncent pas) ; le jaune d'alerte n'apparaît que si un agent attend. Tests : `SceneCompositorTests.dayPixelsArePaletteOrSingleShadow`, `alertYellowOnlyWhenWaiting`.
4. **Lumière en haut à gauche dans les quatre directions**, y compris les personnages SW et NW obtenus par miroir **ré-ombré**. Tests : `FurnitureSpriteTests.leftFaceLighterInAllFacings`, `FloorWallSpriteTests.wallsLitFromTopLeft`, `CharacterReshadeTests.lightStaysTopLeft`.
5. **Nuit** : les overlays d'état restent au-dessus du voile, pixel pour pixel identiques au jour. Test : `SceneCompositorTests.overlaysIgnoreNightVeil`.
6. **Déterminisme multiplateforme** : mêmes octets sous Linux et macOS. Tests : `GoldenTests.spritesAndScenesMatchGolden`, étape CI `cmp` des PNG du dépôt (tâche 8), `SceneCompositorTests.deterministic`.
7. **Originalité (7.10) et accessibilité (7.9)** : revue humaine de la planche ; chaque état a une forme d'overlay distincte (jamais la couleur seule). Tests : `OverlaySpriteTests.stateShapesAreDistinct`, `HUDSpriteTests.minimapDotsCarryGlyphs`.

## Décisions et précisions (à lire avant toute tâche)

1. **Sprites v0** = tous les sprites de 7.4 marqués « Ét. 3 », plus `light.cone`, `light.screenGlow` et `fx.star` (marqués « Ét. 4 » mais nécessaires au rendu de nuit demandé), plus `elevator.led` (voyant de l'ascenseur en sprite séparé). Liste exacte : `SpriteCatalog.v0IDs` (tâche 7). Hors v0 : 7.4.6 (habillage SwiftUI), `postit.card`, `postit.corner`, `pin.*`, `tape`, `trash`, `printer`, `ov.smoke`, `ov.speech`, `fx.confetti`, `fx.sparkle`, `fx.steam`, `fx.levelUp`, `fx.xp`, décor déblocable, `portrait.mini`, `agent.outline.dashed`, `hud.level`, `hud.xpBar`, `badge.*`, `edit.*`, `floor.editGrid`.
2. **Orientation des rangées** (précision de 3.8). La formule de taille de l'îlot (`W = cap + 2` le long de i, `D = 7` le long de j) impose des rangées le long de i, donc des regards selon j. **Rangée A** (devant : bureaux en j local 4, chaises en 5) : regard `ne` (−j) ; on voit l'écran allumé et le dos de l'avatar. **Rangée B** (derrière : bureaux en j local 3, chaises en 2) : regard `sw` (+j) ; on voit le visage. Les libellés « nord-ouest / sud-est » de 3.8 deviennent `ne` / `sw`. `ne` est dessiné à la main, `sw` est le miroir ré-ombré de `se` (7.4.4). À trancher au jalon.
3. **Pas des postes** : un poste occupe la tuile du bureau et celle de la chaise (le long de j). Dans une rangée, les postes sont espacés de 2 tuiles le long de i (bureau, puis une tuile de dégagement), ce qui redonne exactement `(2·⌈cap/2⌉ + 2) × 7`. La tuile de dégagement reçoit `agent.mini` et la flaque de lumière de la lampe. À trancher au jalon (repli : postes jointifs, îlot plus étroit).
4. **Index de poste indépendant de la capacité** : `deskIndex` d → partie d'îlot `d / 8` (0 = îlot principal, 1 et plus = annexes), index local `l = d % 8`, rangée A si `l` est pair, B sinon, poste `l / 2` dans la rangée. Un îlot qui passe de 4 à 8 postes grandit vers +i sans déplacer un seul poste.
5. **Moniteurs** : `monitor.front` n'est généré que pour les regards `ne` et `nw` (écran visible) et `monitor.back` que pour `se` et `sw` (dos visible) ; les deux autres orientations de chacun ne seraient jamais vues (écart assumé avec « 4 or. » de 7.4.3).
6. **Police** : le cœur ne peut pas rasteriser Silkscreen sans CoreText. Il a sa propre police pixel **originale**, `PixelFont` (capitales de 5 px, accents au-dessus, chiffres, ponctuation), pour les pancartes, les plaques de nom et les planches. Question du jalon : la garder aussi dans l'app (texte net garanti, même rendu partout) ou revenir à Silkscreen (7.11).
7. **Annexes** (« API · 2 ») : placées au calcul dans le premier slot libre. Leur slot n'est pas persisté : la création d'un projet peut déplacer une annexe. Limite connue, corrigée à l'étape 3 (slot d'annexe persistant). Les tests de stabilité portent sur les îlots principaux, et sur les annexes à liste de projets constante.
8. **Tailles de 7.4** : ce sont les cibles et les tests les vérifient. Une tâche peut en ajuster une quand la géométrie l'impose (exemple : `board.cork` doit tenir 48 emplacements une fois cisaillé sur le mur, ce que 192×128 ne permet pas), en le signalant par une ligne « Écart : … » dans son message de commit ; la tâche 8 reporte ces écarts dans le README du jalon.
9. **Atlas et manifeste** (`AtlasPacker`, `manifest.json`, 7.6) et remplacement par des PNG (7.7) : reportés à l'étape 3, où `SpriteRegistry` les consomme. Le jalon n'en a pas besoin.
10. **Alpha** : tous les sprites sont opaques ou transparents. Les ombres sont dessinées opaques en `ink` et reçoivent leurs 30 % **une seule fois**, au compositing (règle 4 de 7.3) ; les lumières de nuit sont opaques et reçoivent `lightPoolAlpha` au compositing, en mode additif.
11. **Lecture des PNG** : à ×k, un texel = k pixels. Ouvert dans Aperçu en taille réelle sur un écran Retina, `ilot-xk-*.png` s'affiche comme l'app au zoom ×k (1 pt par pixel d'image). La vue d'ensemble est à 1 pixel par texel avec 144 ppp (chunk `pHYs`) : en taille réelle, elle s'affiche à 0,5 pt par texel, comme le niveau « vue d'ensemble » de l'app.
12. **Apparences** : `AgentLook()` par défaut est le même pour tous les agents ; les scènes de démonstration fixent des apparences variées à la main. Le choix automatique d'une apparence par agent relève de l'étape 3.
13. **Un agent dans chaque état** : un îlot a au plus 8 postes, dont un toujours libre, donc 7 agents ; il y a 10 états (`AgentStateKind`) plus l'agent endormi. Les images de l'îlot montrent donc **le même îlot de 8 postes dans deux distributions**, empilées dans chaque PNG (tableau de la tâche 7) : ensemble, elles couvrent chaque état, chacun des plus fréquents dans les deux rangées.

## Conventions communes (contrat entre les tâches)

**Nommage** (`SpriteKey.name`, 7.6) : `id`, puis `~variante` si besoin, puis `@direction` si besoin ; une frame s'écrit `nom#n`. Exemples : `chair~hue3.jacket@ne`, `screen.working#2`, `wall.window~night@nw`, `agent.type~s0h2c1op4a0@se`.

| Élément | Convention |
|---|---|
| Teintes de projet | variante `hue0` à `hue9` (index de `Palette.projectHues`) ; post-it neutre : `paper` |
| Directions | `Facing` : `se` = +i (bas droite à l'écran), `sw` = +j (bas gauche), `nw` = −i, `ne` = −j ; `se`/`sw` regardent le spectateur |
| Objets de poste | direction = **regard de l'agent assis** (rangée A : `ne`, rangée B : `sw`) |
| Objets muraux | direction = **le mur** : `nw` (mur le long de i = 0) ou `ne` (mur le long de j = 0) ; ils sont cisaillés 2:1 (`Draw.shearToWall`) |
| Bords de moquette | `.n` = bord j = 0 de l'îlot (haut droit à l'écran), `.e` = bord i = W − 1 (bas droit), `.s` = bord j = D − 1 (bas gauche), `.w` = bord i = 0 (haut gauche) ; coins `.n` (0, 0), `.e` (W − 1, 0), `.s` (W − 1, D − 1), `.w` (0, D − 1) ; `.e` = miroir de `.s`, `.w` = miroir de `.n`, `corner.w` = miroir de `corner.e` |
| Frame 0 | la **pose clé** : c'est elle que montrent les rendus statiques (`tick = 0`) ; un écran ou un « ! » qui clignote est « allumé » en frame 0 |
| Cadences | `holds` en ticks à 24/s : 12, 8, 6, 4, 3, 2, 1,5 et 1 fps donnent 2, 3, 4, 6, 8, 12, 16 et 24 ticks |
| Groupes | chaque fichier de sprites expose `enum XxxSprites { static func all() -> [SpriteDef] }`, trié par `SpriteKey` ; le catalogue (tâche 7) les concatène |
| Aperçu | chaque tâche de dessin a un test `preview()` qui écrit ses sprites en PNG via `PreviewWriter` (tâche 2) quand `PIXEL_PREVIEW_DIR` est défini, et ne fait rien sinon ; les aperçus ne sont jamais commités |

## Vagues

| Vague | Tâches (en parallèle) | Utilise |
|---|---|---|
| 1 | Tâche 1 (fondations) ; Tâche 2 (PNG) | le code existant |
| 2 | Tâche 3 (modèle de scène) ; Tâche 4 (décor) ; Tâche 5 (écrans, overlays, HUD, police) ; Tâche 6 (personnages) | tâche 1 (et `PreviewWriter` de la tâche 2 dans les tests) |
| 3 | Tâche 7 (catalogue, compositeur, scènes de démonstration) | tâches 1, 3, 4, 5, 6 |
| 4 | Tâche 8 (`sprite-export`, planches, empreintes, rendu, docs, CI) | toutes |

Les fichiers des tâches d'une même vague sont disjoints (carte ci-dessous). Seule la tâche 8 touche `Core/Package.swift`.

## Carte des fichiers

Cœur (`Core/Sources/PixelCore/`) :
- Tâche 1 : `Assets/Palette.swift`, `Assets/PixelImage.swift`, `Assets/PixelMap.swift`, `Assets/Draw.swift`, `Assets/SpriteDef.swift`, `Assets/SpriteLint.swift`, `Assets/SceneVocabulary.swift`, `World/Grid.swift`, `World/IsoMath.swift`.
- Tâche 2 : `Assets/PNGEncoder.swift`, `Assets/Deflate.swift`.
- Tâche 3 : `World/WorldTypes.swift`, `World/WorldLayout.swift`, `State/AgentScenePresenter.swift`.
- Tâche 4 : `Assets/Sprites/FloorSprites.swift`, `WallSprites.swift`, `FurnitureSprites.swift`, `DeskItemSprites.swift`, `DecorSprites.swift`, `LightSprites.swift`.
- Tâche 5 : `Assets/PixelFont.swift`, `Assets/Sprites/MonitorSprites.swift`, `OverlaySprites.swift`, `EffectSprites.swift`, `HUDSprites.swift`.
- Tâche 6 : `Assets/Characters/CharacterPalette.swift`, `SlotCanvas.swift`, `CharacterParts.swift`, `CharacterPoses.swift`, `CharacterSprites.swift`.
- Tâche 7 : `Assets/SpriteCatalog.swift`, `World/SceneModel.swift`, `World/SceneCompositor.swift`, `World/Showcase.swift`.
- Tâche 8 : `Assets/PixelImage+PNG.swift`, `Assets/ContactSheet.swift`, `Assets/MilestoneExport.swift`.

Exécutable : `Core/Sources/sprite-export/main.swift` (tâche 8) ; `Core/Package.swift` modifié (tâche 8).

Tests (`Core/Tests/PixelCoreTests/`) :
- Tâche 1 : `PaletteTests.swift`, `PixelImageTests.swift`, `PixelMapTests.swift`, `DrawTests.swift`, `SpriteDefTests.swift`, `IsoMathTests.swift`.
- Tâche 2 : `DeflateTests.swift`, `PNGEncoderTests.swift`, `Support/PNGTestDecoder.swift`, `Support/PreviewWriter.swift`.
- Tâche 3 : `WorldLayoutTests.swift`, `WorldLayoutPropertyTests.swift`, `AgentScenePresenterTests.swift`.
- Tâche 4 : `FloorWallSpriteTests.swift`, `FurnitureSpriteTests.swift`, `DecorLightSpriteTests.swift`.
- Tâche 5 : `PixelFontTests.swift`, `MonitorSpriteTests.swift`, `OverlaySpriteTests.swift`, `HUDSpriteTests.swift`.
- Tâche 6 : `CharacterSpriteTests.swift`, `CharacterReshadeTests.swift`.
- Tâche 7 : `SpriteCatalogTests.swift`, `SceneCompositorTests.swift`, `ShowcaseTests.swift`.
- Tâche 8 : `ContactSheetTests.swift`, `GoldenTests.swift`, `MilestoneExportTests.swift`, `Fixtures/golden/sprites.txt` (copié avec `Fixtures`, sans changer `Package.swift`).

Docs et CI (tâche 8) : `docs/jalon-visuel/README.md` et les 15 PNG du livrable, `docs/ASSETS.md` (journal de provenance, 7.10), `.github/workflows/core.yml` (rendu, contrôle et artefact).

---

### Task 1: Fondations : palette, images, DSL, primitives iso, vocabulaire des sprites, grille (vague 1)

**Files:**
- Create: `Core/Sources/PixelCore/Assets/Palette.swift`, `Assets/PixelImage.swift`, `Assets/PixelMap.swift`, `Assets/Draw.swift`, `Assets/SpriteDef.swift`, `Assets/SpriteLint.swift`, `Assets/SceneVocabulary.swift`, `Core/Sources/PixelCore/World/Grid.swift`, `World/IsoMath.swift`
- Test: `Core/Tests/PixelCoreTests/PaletteTests.swift`, `PixelImageTests.swift`, `PixelMapTests.swift`, `DrawTests.swift`, `SpriteDefTests.swift`, `IsoMathTests.swift`

**Interfaces:**
- Consumes: `ToolKind`, `AgentStateKind` (`State/AgentRuntime.swift`), `Workspace.projectHueCount`.
- Produces (utilisé par toutes les autres tâches) :

```swift
// Assets/PixelImage.swift
public struct RGBA8: Hashable, Comparable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255)
    public init(hex: UInt32, alpha: UInt8 = 255)                 // 0xRRGGBB
    public static let clear: RGBA8                                // (0, 0, 0, 0)
    public var isOpaque: Bool { get }                             // a == 255
    public var hexString: String { get }                          // "#RRGGBB"
    /// Integer Rec. 709 luma: 2126·r + 7152·g + 722·b. Every "lighter than" rule compares this value.
    public var luma: Int { get }
    public static func < (lhs: RGBA8, rhs: RGBA8) -> Bool         // by (r, g, b, a): sorted outputs
}
public struct PixelPoint: Hashable, Sendable { public var x: Int; public var y: Int; public init(_ x: Int, _ y: Int) }
public struct PixelRect: Hashable, Sendable { public var x: Int, y: Int, width: Int, height: Int
                                              public init(x: Int, y: Int, width: Int, height: Int) }
public struct EdgeInsets: Hashable, Sendable { public var top: Int, left: Int, bottom: Int, right: Int
                                               public init(_ all: Int); public init(top: Int, left: Int, bottom: Int, right: Int) }
public struct BitMask: Hashable, Sendable {
    public let width: Int, height: Int
    public subscript(x: Int, y: Int) -> Bool { get }              // false out of bounds
    public var count: Int { get }
}
public enum StackAxis: Sendable { case horizontal, vertical }
public struct PixelImage: Hashable, Sendable {
    public let width: Int, height: Int
    public private(set) var pixels: [RGBA8]                       // row-major, top row first
    public init(width: Int, height: Int, fill: RGBA8 = .clear)
    public init(width: Int, height: Int, pixels: [RGBA8])         // precondition: count == width·height
    public subscript(x: Int, y: Int) -> RGBA8 { get set }         // precondition: in bounds
    public mutating func set(_ x: Int, _ y: Int, _ color: RGBA8)  // ignored out of bounds (clipping)
    public mutating func fill(_ rect: PixelRect, _ color: RGBA8)
    /// Copies the opaque pixels of `src`, its top-left at (x, y); clipped.
    public mutating func blit(_ src: PixelImage, x: Int, y: Int)
    /// Same size. Each opaque pixel s of `layer` over d: (s·α + d·(255 − α) + 127) / 255 per channel.
    public mutating func composite(_ layer: PixelImage, alpha: UInt8)
    /// Same size, additive. Each opaque pixel s of `layer`: min(255, d + (s·α + 127) / 255) per channel.
    public mutating func add(_ layer: PixelImage, alpha: UInt8)
    /// Each opaque pixel: f = 255 − ((255 − c)·α + 127) / 255, then (d·f + 127) / 255 per channel.
    public mutating func multiply(by color: RGBA8, alpha: UInt8)
    public func mirrored() -> PixelImage                          // horizontal flip
    public func scaled(by factor: Int) -> PixelImage              // nearest neighbour, factor ≥ 1
    public func cropped(_ rect: PixelRect) -> PixelImage          // pixels outside the source are clear
    public func recolored(_ map: [RGBA8: RGBA8]) -> PixelImage
    /// Corners kept, edges and centre repeated (never stretched) to width × height.
    public func nineSlice(insets: EdgeInsets, width: Int, height: Int) -> PixelImage
    public func alphaMask() -> BitMask
    public var opaqueBounds: PixelRect? { get }
    public var distinctColors: [RGBA8] { get }                    // opaque colours, sorted
    public var rgbaBytes: [UInt8] { get }                         // 4·width·height bytes, for PNGEncoder
    /// FNV-1a 64 of width, height and rgbaBytes: 16 lowercase hex digits (golden files).
    public var fingerprint: String { get }
    public static func stacked(_ images: [PixelImage], axis: StackAxis, spacing: Int,
                               background: RGBA8 = .clear) -> PixelImage   // aligned left / top
}

// Assets/Palette.swift
public enum PaletteRole: String, CaseIterable, Codable, Sendable {   // the 32 base colours of 7.1, table order
    case ink, shade, slate, stone, mist, paper, chalk, skin1, skin2, skin3, skin4, hairDark,
         woodDark, woodMid, woodLight, cork, floorLight, floorDark, leafDark, leaf, leafLight,
         skyDay, skyNight, uiTitle, uiFace, alertYellow, alertOrange, screenGlow, okGreen, errorRed, thinkLilac, lampWarm
}
public struct HueTones: Hashable, Sendable { public let name: String; public let base: RGBA8; public let light: RGBA8; public let dark: RGBA8 }
public enum Palette {
    public static func color(_ role: PaletteRole) -> RGBA8
    public static let projectHues: [HueTones]                     // P0 Tomate … P9 Ardoise, frozen values of 7.1
    public static func hue(_ index: Int) -> HueTones              // clamped to 0...9
    /// a + (b − a)·t per channel in Double, rounded to nearest even: reproduces every frozen tone of 7.1.
    public static func mix(_ a: RGBA8, _ b: RGBA8, _ t: Double) -> RGBA8
    public static let shadowAlpha: UInt8 = 77                     // 30 %
    public static let lightPoolAlpha: UInt8 = 89                  // 35 %
    public static let nightVeilAlpha: UInt8 = 140                 // 0,55
    public static let nightVeilAlphaReduced: UInt8 = 89           // 0,35 (Réduire la transparence)
    public static let nightVeil: RGBA8                            // #3A3F6E
    public static let uiFaceDark: RGBA8                           // #34334F
    public static let uiTitleDark: RGBA8                          // #2B3F78
    public static let keyBase: RGBA8, keyLight: RGBA8, keyDark: RGBA8   // #FF00FF #FF80FF #800080, never in a sprite
    public static let spriteColors: Set<RGBA8>                    // 32 roles + 30 hue tones, opaque
    /// The only sprite ids that may contain alertYellow: ov.bang, ov.bang.halo, ov.edgeArrow, screen.waiting,
    /// monitor.back (its led.waiting variant only), hud.state.waitingInput, minimap.dot.waitingInput.
    public static let alertYellowSprites: Set<SpriteID>
}

// Assets/PixelMap.swift
/// What a DSL character stands for: a fixed role, or a slot resolved later (project hue, agent look).
public enum Slot: Hashable, Sendable {
    case clear
    case role(PaletteRole)
    case hueBase, hueLight, hueDark                               // P L D
    case skin, skinShade, skinOutline                             // s S q
    case hair, hairShade, hairOutline                             // h H j
    case top, topShade, topOutline                                // t T u
    case bottom, bottomShade                                      // p b
    case eye                                                      // e
    case accessory, accessoryShade                                // a A
}
public enum PixelMapError: Error, Equatable { case empty, raggedRow(Int), unknownCharacter(Character, row: Int, column: Int) }
public struct PixelMap: Hashable, Sendable {
    public let width: Int, height: Int
    public let cells: [Slot]                                      // row-major, top row first
    /// Base legend: `.` clear, the 7.5 letters above, `o` ink, and fixed roles `1` chalk, `2` mist, `3` stone,
    /// `4` slate, `5` shade, `6` paper, `7` woodLight, `8` woodMid, `9` woodDark, `c` cork, `m` hairDark,
    /// `f` leaf, `F` leafDark, `i` leafLight, `y` alertYellow, `Y` alertOrange, `g` screenGlow, `G` okGreen,
    /// `r` errorRed, `v` thinkLilac, `w` lampWarm, `k` skyDay, `n` skyNight, `z` floorLight, `Z` floorDark.
    /// `legend` adds or overrides letters for one map.
    public static let baseLegend: [Character: Slot]
    /// Blank first/last lines and the common indentation are ignored; every row has the same width.
    public static func parse(_ ascii: String, legend: [Character: Slot] = [:]) throws -> PixelMap
    public init(_ ascii: String, legend: [Character: Slot] = [:])  // traps on a malformed map (art is static code)
    public func mirrored() -> PixelMap
    public func render(_ paint: (Slot) -> RGBA8?) -> PixelImage   // nil → transparent
}
public enum SlotPaint {
    /// Decor paint: roles as themselves, P/L/D from `hue` (precondition: hue given when used); character slots trap.
    public static func decor(_ slot: Slot, hue: Int?) -> RGBA8?
}

// Assets/Draw.swift
public struct Ramp: Hashable, Sendable {
    public var top: RGBA8, left: RGBA8, right: RGBA8, outline: RGBA8, highlight: RGBA8
    public init(top: RGBA8, left: RGBA8, right: RGBA8, outline: RGBA8, highlight: RGBA8)
    public static let neutral: Ramp      // mist / stone / slate, outline ink, highlight chalk
    public static let wall: Ramp         // chalk / stone / slate, outline ink, highlight chalk
    public static let woodLight: Ramp    // woodLight / woodMid / woodDark, outline hairDark, highlight paper
    public static let woodDark: Ramp     // woodMid / woodDark / hairDark, outline ink, highlight woodLight
    public static func hue(_ index: Int) -> Ramp   // light / base / dark, outline dark (7.1), highlight chalk
}
public enum WallSide: String, CaseIterable, Codable, Sendable { case nw, ne }   // the two back walls (3.8)
public struct LightProbe: Hashable, Sendable { public var left: PixelRect; public var right: PixelRect }
public struct IsoBox: Sendable { public var image: PixelImage; public var top: BitMask; public var left: BitMask
                                 public var right: BitMask; public var lightProbe: LightProbe }
public enum Draw {
    /// Floor diamond: width multiple of 4, height width / 2; row y < height / 2 is 4y + 4 px wide, centred,
    /// mirrored below (7.3: a 64×32 tile).
    public static func isoDiamond(width: Int, fill: RGBA8) -> PixelImage
    public static func isoDiamondMask(width: Int) -> BitMask
    /// Lit box. Footprint in iso units (1 unit = 2 px across, 1 px down), height in px. Image 2(w + d) × (w + d + height).
    /// Top = ramp.top; face toward +j (left on screen) = ramp.left; face toward +i (right) = ramp.right;
    /// 1-px selective outline; highlight on the front edges of the top. isoBox(w: 16, d: 16, height: 0).top
    /// equals isoDiamondMask(width: 64).
    public static func isoBox(w: Int, d: Int, height: Int, ramp: Ramp) -> IsoBox
    /// 2:1 line: every step is exactly 2 px across and 1 px down (or up).
    public static func line2to1(into image: inout PixelImage, from: PixelPoint, steps: Int, rightward: Bool,
                                downward: Bool, color: RGBA8)
    /// 50 % checkerboard of `color` over `mask`; `phase` (0 or 1) picks the parity.
    public static func dither50(into image: inout PixelImage, mask: BitMask, color: RGBA8, phase: Int)
    /// Recolours the outer ring of the opaque area (selective outline of 7.2).
    public static func outline(_ image: PixelImage, color: RGBA8) -> PixelImage
    /// Integer midpoint ellipse, symmetric on both axes (character shadow 20×8).
    public static func ellipse(width: Int, height: Int, fill: RGBA8) -> PixelImage
    /// Puts a front-drawn object on a back wall: each 2-px column pair moves 1 px down toward the front
    /// (ne wall: rightward, nw wall: leftward). Output height = input height + width / 2.
    public static func shearToWall(_ image: PixelImage, wall: WallSide) -> PixelImage
}

// Assets/SpriteDef.swift
public struct SpriteID: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByStringLiteral,
                        CustomStringConvertible { public let rawValue: String }   // "desk", "screen.working"
public struct SpriteKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var id: SpriteID
    public var variant: String?                                   // "hue3", "hue3.jacket", "led.waiting", "night"…
    public var facing: Facing?
    public init(_ id: SpriteID, variant: String? = nil, facing: Facing? = nil)
    public var name: String { get }                               // "chair~hue3.jacket@ne"; frames add "#n"
}
public enum Derivation: String, Codable, Sendable { case mirror, mirrorReshaded }
public enum SpriteCategory: String, CaseIterable, Codable, Sendable {
    case floors, walls, furniture, deskItems, decor, lights, monitors, screens, overlays, effects, hud, characters
}
public enum AnimationClock {
    public static let ticksPerSecond = 24
    public static let allowedHolds: Set<Int>                      // [2, 3, 4, 6, 8, 12, 16, 24]
    public static func holds(fps: Double, frames: Int) -> [Int]   // [] for one frame; precondition: allowed fps
}
public struct SpriteDef: Sendable {
    public var key: SpriteKey
    public var category: SpriteCategory
    public var anchor: PixelPoint                                 // px from the top-left (7.3)
    public var frames: [PixelImage]                               // same size; frame 0 = key pose
    public var holds: [Int]                                       // ticks per frame; [] when one frame
    public var loops: Bool
    public var derivation: Derivation?                            // set on a mirror; built from `source`
    public var source: SpriteKey?
    public var outlineColors: Set<RGBA8>                          // material outlines, outside the colour cap
    public var lightProbe: LightProbe?                            // lit volume: left must be lighter than right
    public init(key: SpriteKey, category: SpriteCategory, anchor: PixelPoint, frames: [PixelImage], holds: [Int] = [],
                loops: Bool = true, derivation: Derivation? = nil, source: SpriteKey? = nil,
                outlineColors: Set<RGBA8> = [], lightProbe: LightProbe? = nil)
    public var width: Int { get }
    public var height: Int { get }
    public func frameIndex(atTick tick: Int) -> Int              // loops, or stays on the last frame
}

// Assets/SpriteLint.swift
public enum SpriteLint {
    /// Empty when the sprite follows 7.1 to 7.3: frames non-empty and of equal size; holds empty for one frame,
    /// else one allowed hold per frame; anchor inside [0, w] × [0, h]; alpha 0 or 255 only; opaque colours in
    /// Palette.spriteColors, never a key colour; alertYellow only for Palette.alertYellowSprites; at most 12 colours
    /// per frame once ink and outlineColors are left out; mean luma of lightProbe.left > lightProbe.right on frame 0.
    public static func issues(_ def: SpriteDef) -> [String]
}

// Assets/SceneVocabulary.swift (shared by the presenter, the sprite sets and the compositor)
public enum CharacterAnimation: String, CaseIterable, Codable, Sendable {
    case stand, walk, sitDown, sitIdle, type, think, stretch, coffee, sleep, raiseHand, celebrate, grab, cough, wave
    public var framesPerFacing: Int { get }   // 7.4.4: 2 4 2 2 4 2 6 4 2 4 6 4 4 2
    public var fps: Double { get }            // 2 8 8 2 12 2 6 4 1.5 6 8 8 6 4
    public var loops: Bool { get }            // true: stand walk sitIdle type think sleep raiseHand cough
    public var drawnFacings: [Facing] { get } // [.se, .ne]; raiseHand: [.se]
    public var facings: [Facing] { get }      // [.se, .ne, .sw, .nw]; raiseHand: [.se, .sw]
    public var spriteID: SpriteID { get }     // "agent.<rawValue>"
}
public enum ScreenState: String, CaseIterable, Codable, Sendable {
    case off, boot, idle, thinking, working, waiting, done, error, quota, background
    public var frames: Int { get }            // 7.4.3: 1 4 2 3 4 2 1 3 2 3
    public var fps: Double { get }            //        - 8 1 4 8 4 - 8 1 2
    public var spriteID: SpriteID { get }     // "screen.<rawValue>"
}
public enum OverlayKind: String, CaseIterable, Codable, Sendable {
    case bang, dots, tool, zzz, storm, check, background, quota   // primary overlay above the head
}
public enum ToolIcon: String, CaseIterable, Codable, Sendable {
    case read, edit, bash, search, web, subagent, mcp, question, other
    public init(_ tool: ToolKind)
    public var spriteID: SpriteID { get }     // "ov.tool.<rawValue>"
}
public enum SceneBadge: String, CaseIterable, Codable, Sendable {
    case stale, draft, degraded, unsafe, external                 // ov.stale ov.draft ov.degraded ov.unsafe ov.external
    public var spriteID: SpriteID { get }
}

// World/Grid.swift
public struct GridPoint: Hashable, Comparable, Codable, Sendable { public var i: Int; public var j: Int; public init(_ i: Int, _ j: Int) }
public struct GridSize: Hashable, Codable, Sendable { public var w: Int; public var d: Int; public init(w: Int, d: Int) }   // w along i
public struct GridRect: Hashable, Codable, Sendable {
    public var origin: GridPoint; public var size: GridSize
    public init(origin: GridPoint, size: GridSize)
    public func contains(_ p: GridPoint) -> Bool
    public func contains(_ r: GridRect) -> Bool
    public func intersects(_ r: GridRect) -> Bool
    public func union(_ r: GridRect) -> GridRect
    public var tiles: [GridPoint] { get }                         // j-major then i
}
/// se = +i (down-right on screen), sw = +j (down-left), nw = −i, ne = −j. se and sw face the viewer.
public enum Facing: String, CaseIterable, Codable, Sendable {
    case ne, nw, se, sw
    public var isTowardViewer: Bool { get }   // se, sw
    public var mirrored: Facing { get }       // se ↔ sw, ne ↔ nw (horizontal flip)
    public var opposite: Facing { get }       // se ↔ nw, sw ↔ ne
    public var step: GridPoint { get }        // ne (0, −1), nw (−1, 0), se (1, 0), sw (0, 1)
}

// World/IsoMath.swift
public struct ScenePoint: Hashable, Sendable { public var x: Int; public var y: Int }   // texels, y up (3.8)
public enum DepthLayer: Int, CaseIterable, Sendable { case carpet = 0, furniture = 2, character = 4, screen = 5, overlay = 8 }
public enum IsoMath {
    public static let tileWidth = 64, tileHeight = 32, levelHeight = 16
    public static let seatHeight = 16, deskTopHeight = 24, screenTopHeight = 44, characterHeight = 56, wallHeight = 96
    public static func toScene(_ p: GridPoint) -> ScenePoint                  // ((i − j)·32, −(i + j)·16)
    public static func tileCenter(_ p: GridPoint) -> ScenePoint               // toScene + (0, −16)
    public static func toGrid(x: Double, y: Double) -> (i: Double, j: Double) // inverse of toScene
    public static func depth(_ p: GridPoint, layer: DepthLayer) -> Int        // (i + j)·10 + layer
    public static func depth(i: Double, j: Double, layer: DepthLayer) -> Double
}
```

- [ ] **Step 1: Write the failing tests.**
  - `PaletteTests` : les 32 rôles et les 30 tons de teinte, valeur hexadécimale par valeur (tableaux de 7.1) ; `hueTonesFollowMixFormula` (pour les 10 teintes, `mix(base, chalk, 0.45) == light` et `mix(base, ink, 0.45) == dark` : l'arrondi au pair le plus proche reproduit toutes les valeurs figées, par exemple Menthe sombre `#246263`) ; `noProjectHueIsBrightYellow` (aucune base de teinte avec une teinte HSV entre 40° et 75° et une saturation ≥ 0,5 ; contrôle : `alertYellow` serait refusé) ; `spriteColors` compte 62 couleurs distinctes et exclut les trois couleurs clés ; constantes alpha 77, 89, 140, 89.
  - `PixelImageTests` : `blit` découpé aux bords ; `compositeUsesIntegerFormula` (ink sur `floorLight` à 77 : valeur attendue calculée à la main dans le test) ; `add` borné à 255 ; `multiply` exact ; `mirrored().mirrored() == self` ; `scaled(by: 3)[x, y] == self[x / 3, y / 3]` ; `nineSlice` garde les coins et répète les bords ; `fingerprint` stable, 16 chiffres hexadécimaux, différent pour deux images différentes ; `stacked` (tailles et positions).
  - `PixelMapTests` : lecture avec indentation commune ; `raggedRow(n)` ; `unknownCharacter` avec ligne et colonne ; légende ajoutée ; `render` ; `mirrored`.
  - `DrawTests` : `diamondRowsAre4yPlus4` (64×32 : largeurs 4, 8, …, 64 puis symétriques, centrées) ; `boxTopIsTheTileDiamond` ; `boxLeftFaceLighterThanRight` (toutes les rampes, `lightProbe` compris) ; `boxSizeFormula` ; `line2to1StepsAreTwoPixels` (chaque palier fait exactement 2 px) ; `dither50` en damier ; `ellipse(20, 8)` symétrique sur les deux axes ; `shearToWall` (hauteur, décalage de 1 px par paire de colonnes, sens selon le mur).
  - `SpriteDefTests` : `SpriteKey.name` (`chair~hue3.jacket@ne`) ; `AnimationClock.holds` pour chaque cadence permise, refus d'une cadence interdite ; `frameIndex(atTick:)` en boucle et sans boucle ; `lintCatchesEveryRule` (un sprite fautif par règle : pixel semi-transparent, couleur hors palette, couleur clé, jaune hors liste, 13 couleurs, `holds` incohérents, frames de tailles différentes, ancre hors cadre, sonde de lumière inversée) et `cleanSpriteHasNoIssue` ; `CharacterAnimation` : 92 frames dessinées et 184 en tout (somme sur `drawnFacings` puis sur `facings`) ; `ScreenState` : frames et cadences de 7.4.3 ; `ToolIcon(ToolKind)` pour chaque cas de `ToolKind`.
  - `IsoMathTests` : `toScene((1, 0)) == (32, −16)`, `toScene((0, 1)) == (−32, −16)` ; `tileCenter` ; `toGrid(toScene(p)) == p` sur une grille de points ; ordre des profondeurs (plus loin d'abord, couches dans l'ordre) ; `Facing.step`, `mirrored`, `opposite`, `isTowardViewer`.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "PaletteTests|PixelImageTests|PixelMapTests|DrawTests|SpriteDefTests|IsoMathTests"` → échec de compilation (types absents).
- [ ] **Step 3: Implement** les fichiers listés. `isoBox` dessine d'abord les trois faces avec la géométrie 2:1 (même règle de largeur de rangée que le losange pour le dessus), puis le contour sélectif et le reflet ; ses masques et sa sonde de lumière (un rectangle au milieu de chaque face) viennent de la géométrie, pas d'une analyse de l'image.
- [ ] **Step 4: Run.** `cd Core && swift build && swift test` → tout vert, sans nouvel avertissement.
- [ ] **Step 5: Commit.** `git add Core && git commit -m "Core visual milestone: palette, pixel images, DSL, iso primitives and sprite vocabulary"`

### Task 2: Encodeur PNG en Swift pur (vague 1)

**Files:**
- Create: `Core/Sources/PixelCore/Assets/PNGEncoder.swift`, `Core/Sources/PixelCore/Assets/Deflate.swift`
- Test: `Core/Tests/PixelCoreTests/DeflateTests.swift`, `PNGEncoderTests.swift`, `Support/PNGTestDecoder.swift`, `Support/PreviewWriter.swift`

**Interfaces:**
- Consumes: rien (octets bruts : la passerelle `PixelImage.pngData` est faite à la tâche 8).
- Produces :

```swift
public enum CRC32 {
    /// Table-driven, reflected polynomial 0xEDB88320 (PNG, zlib).
    public static func checksum(_ bytes: [UInt8], initial: UInt32 = 0) -> UInt32
}
public enum Adler32 { public static func checksum(_ bytes: [UInt8]) -> UInt32 }
public enum DeflateMode: Sendable { case stored, fixedHuffman }
public enum Deflate {
    /// zlib stream (RFC 1950): CMF/FLG, deflate blocks (RFC 1951), Adler32. `.stored`: blocks of ≤ 65 535 bytes.
    /// `.fixedHuffman`: LZ77 (32 KiB window, hash chains on 3-byte prefixes, greedy, matches of 3 to 258) coded with
    /// the fixed Huffman tables (BTYPE 01). Deterministic.
    public static func zlib(_ data: [UInt8], mode: DeflateMode = .fixedHuffman) -> [UInt8]
}
public struct PNGOptions: Hashable, Sendable {
    public var mode: DeflateMode = .fixedHuffman
    public var pixelsPerMeter: Int? = nil                     // pHYs chunk when set (144 ppp = 5669)
    public init(mode: DeflateMode = .fixedHuffman, pixelsPerMeter: Int? = nil)
    public static let dpi144: Int = 5669
}
public enum PNGEncoder {
    /// RGBA 8-bit, non-premultiplied, rows top to bottom (4·width·height bytes), colour type 6, no interlace.
    /// Per row, the filter (0 to 4) with the smallest sum of |signed bytes|, lowest type on ties.
    /// Chunks: IHDR, pHYs (optional), one IDAT, IEND. Same input, same bytes.
    public static func encode(width: Int, height: Int, rgba: [UInt8], options: PNGOptions = .init()) -> [UInt8]
}
```

Support de test (module de test, utilisé par les tâches 4 à 8) :

```swift
/// Test-only PNG reader: signature, chunk CRCs, IHDR (8-bit RGBA), IDAT concatenation, zlib header and Adler32,
/// inflate of stored and fixed-Huffman blocks (dynamic blocks are an error), the five filters.
enum PNGTestDecoder {
    struct Decoded: Equatable { var width: Int; var height: Int; var rgba: [UInt8]; var pixelsPerMeter: Int? }
    static func decode(_ png: [UInt8]) throws -> Decoded
    static func inflateZlib(_ data: [UInt8]) throws -> [UInt8]
}
/// Writes `<PIXEL_PREVIEW_DIR>/<name>.png` (nearest upscale by `scale`) when the variable is set; no-op otherwise.
enum PreviewWriter {
    static func write(_ name: String, width: Int, height: Int, rgba: [UInt8], scale: Int = 1)
}
```

- [ ] **Step 1: Write the failing tests.** `DeflateTests` : `crc32KnownVectors` (`"123456789"` → `0xCBF43926`, `"IEND"` → `0xAE426082`) ; `adler32KnownVectors` (`"Wikipedia"` → `0x11E60398`, vide → 1) ; `roundTripStoredAndFixed` (vide, 1 octet, 100 000 octets aléatoires semés, 100 000 zéros, texte répétitif, données de plus de 65 535 octets : `inflateZlib(zlib(x)) == x` dans les deux modes) ; `fixedHuffmanCompressesRuns` (100 000 zéros → moins de 1 000 octets). `PNGEncoderTests` : `chunksAndCRCs` (signature, IHDR : profondeur 8, type 6 ; IEND en dernier ; CRC de chaque chunk) ; `roundTripRandomImage` (37×23 aléatoire semé, et 300×200 à motifs, avec `PNGTestDecoder`) ; `deterministicBytes` ; `flatImageCompresses` (512×512 d'une seule couleur → moins de 4 096 octets) ; `physChunkWhenRequested` (présent avec 5669 sur les deux axes et l'unité mètre, absent sinon) ; `imageIODecodesSamePixels` (sous `#if canImport(ImageIO)` seulement : ImageIO décode une image aux alphas 0 et 255 et rend les mêmes pixels opaques, ce qui valide le deflate contre un vrai zlib).
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "DeflateTests|PNGEncoderTests"`.
- [ ] **Step 3: Implement.** Codes de Huffman fixes de RFC 1951 3.2.6 (littéraux 0 à 143 sur 8 bits, 144 à 255 sur 9, 256 à 279 sur 7, 280 à 287 sur 8 ; distances sur 5 bits), bits écrits LSB d'abord, codes de Huffman inversés. `PreviewWriter` agrandit les octets lui-même puis appelle `PNGEncoder`.
- [ ] **Step 4: Run.** `cd Core && swift build && swift test` → vert.
- [ ] **Step 5: Commit.** `git add Core && git commit -m "Core visual milestone: pure Swift PNG encoder (deflate, CRC32, Adler32)"`

### Task 3: Modèle de la scène : `WorldLayout` et présentation des agents (vague 2)

**Files:**
- Create: `Core/Sources/PixelCore/World/WorldTypes.swift`, `World/WorldLayout.swift`, `Core/Sources/PixelCore/State/AgentScenePresenter.swift`
- Test: `Core/Tests/PixelCoreTests/WorldLayoutTests.swift`, `WorldLayoutPropertyTests.swift`, `AgentScenePresenterTests.swift`

**Interfaces:**
- Consumes: tâche 1 (`GridPoint`, `GridSize`, `GridRect`, `Facing`, `WallSide`, `CharacterAnimation`, `ScreenState`, `OverlayKind`, `ToolIcon`, `SceneBadge`) ; existants : `Project`, `Agent`, `Workspace` (+ `WorkspaceOps`), `AgentRuntime`, `AgentPresenter.present`, `AgentPresenter.accessibilityLabel`, `AgentPresenter.asleepAfter`, `PermissionMode`.
- Produces (utilisé par la tâche 7) :

```swift
// World/WorldTypes.swift
public enum DecorKind: String, CaseIterable, Codable, Sendable {   // 4.1; only plantSmall and coffeeMachine are drawn in v0
    case plantSmall, coffeeMachine, cactus, espressoMachine, floorLamp, plantBig, posterMountain, posterWave,
         posterRobot, aquarium, rug, bookshelf, sofa, arcade, waterCooler
}
public enum DecorAnchor: Hashable, Codable, Sendable { case hall, island(ProjectID) }
public struct DecorItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID; public var kind: DecorKind; public var tile: GridPoint; public var facing: Facing; public var anchor: DecorAnchor
}
public struct LayoutConfig: Hashable, Sendable {
    public var slotPitch = GridSize(w: 12, d: 9)      // island of 10×7 + corridors
    public var hallDepth = 6                          // fixed band along the back wall (j < 6)
    public var islandInset = GridPoint(1, 1)          // island origin inside its slot
    public var desksPerIsland = 8
    public static let standard = LayoutConfig()
}
public struct WorldInput: Sendable {
    public var projects: [Project]; public var agents: [Agent]; public var decor: [DecorItem]; public var config: LayoutConfig
    public init(projects: [Project], agents: [Agent], decor: [DecorItem] = [], config: LayoutConfig = .standard)
    public init(workspace: Workspace, decor: [DecorItem] = [], config: LayoutConfig = .standard)
}
public enum IslandRow: String, Codable, Sendable { case a, b }   // a: front, gaze ne (screen + back); b: back, gaze sw (face)
public struct DeskPlacement: Hashable, Sendable {
    public var index: Int                             // Agent.deskIndex (8 per island part)
    public var row: IslandRow; public var post: Int
    public var deskTile: GridPoint; public var seatTile: GridPoint; public var sideTile: GridPoint
    public var facing: Facing                         // gaze of the seated agent: .ne (A), .sw (B)
    public var agentID: AgentID?
}
public struct IslandPlacement: Hashable, Sendable {
    public var projectID: ProjectID
    public var part: Int                              // 0 main island, 1… annexes ("API · 2")
    public var slot: Int
    public var origin: GridPoint; public var size: GridSize; public var capacity: Int
    public var rect: GridRect { get }
    public var sign: GridPoint; public var plant: GridPoint
    public var desks: [DeskPlacement]                 // by index
}
public enum WallSegmentStyle: String, CaseIterable, Codable, Sendable { case plain, socket, baseboard }
public enum WallPiece: Hashable, Sendable { case corner, segment(WallSegmentStyle), window, board, elevator }
public struct WallPlacement: Hashable, Sendable {
    public var wall: WallSide?                        // nil for the corner
    public var start: Int                             // tile index along the wall (i for .ne, j for .nw)
    public var span: Int                              // board 6, elevator 2, others 1
    public var piece: WallPiece
}
public struct PropPlacement: Hashable, Sendable { public var kind: DecorKind; public var tile: GridPoint
                                                  public var facing: Facing; public var anchor: DecorAnchor }
public struct WorldLayoutResult: Equatable, Sendable {
    public var islands: [IslandPlacement]             // by (slot, part)
    public var props: [PropPlacement]                 // hall props and input decor, sorted (island plants: IslandPlacement.plant)
    public var walls: [WallPlacement]                 // corner, ne wall by start, nw wall by start
    public var corridors: [GridRect]                  // every slot rect inside bounds (floor painted as corridor)
    public var bounds: GridRect; public var hall: GridRect; public var boardWall: GridRect; public var elevator: GridRect
}

// World/WorldLayout.swift
public enum WorldLayout {
    public static func compute(_ input: WorldInput) -> WorldLayoutResult
    /// Square shells: (0,0) (1,0) (0,1) (1,1) (2,0) (2,1) (0,2) (1,2) (2,2) (3,0)…: shell s lists (s, 0)…(s, s − 1),
    /// then (0, s)…(s, s). Independent of the number of projects.
    public static func slotCoordinates(_ slot: Int) -> (column: Int, row: Int)
    /// 4·⌈(max(agents, highestLocalIndex + 1) + 1) / 4⌉, at most desksPerIsland: 4 for 0 to 3 agents, 8 for 4 to 7.
    public static func capacity(agents: Int, highestLocalIndex: Int?) -> Int
    public static func islandSize(capacity: Int) -> GridSize      // (capacity + 2) × 7
    public static func deskLocal(_ localIndex: Int) -> (row: IslandRow, post: Int)   // even → A; post = index / 2
}

// State/AgentScenePresenter.swift
public struct AgentPresentation: Equatable, Sendable {
    public var kind: AgentStateKind
    public var asleep: Bool
    public var animation: CharacterAnimation?         // nil: no avatar (offline, jacket on the chair)
    public var facesViewer: Bool                      // raiseHand: the avatar turns toward the viewer, whatever its row
    public var overlay: OverlayKind?
    public var toolIcon: ToolIcon?                    // with .tool, or the "?" of a waiting AskUserQuestion
    public var halo: Bool                             // ov.bang.halo
    public var screen: ScreenState                    // screen content (row A) and monitor LED (row B)
    public var badges: [SceneBadge]                   // in SceneBadge.allCases order
    public var subagents: Int                         // agent.mini beside the desk when > 0
    public var jacketOnChair: Bool
    public var deskLit: Bool                          // lamp lit at night
    public var nameplateAlways: Bool                  // waiting, error, offline (7.4.10, 6(q))
    public var nameplateOff: Bool                     // "OFF" plate
    public var urgency: Int
    public var label: String                          // AgentPresenter.accessibilityLabel
}
public struct ScenePresentationOptions: Hashable, Sendable {
    public var reduceMotion: Bool; public var permissionMode: PermissionMode
    public init(reduceMotion: Bool = false, permissionMode: PermissionMode = .default)
}
extension AgentPresenter {
    public static func scene(_ r: AgentRuntime, now: Date, agentName: String, projectName: String,
                             options: ScenePresentationOptions = .init()) -> AgentPresentation
}
```

**Règles de `WorldLayout.compute`** (une ligne de test chacune au moins) :
- Seuls les projets non archivés ont un îlot ; un agent d'un projet archivé n'a pas de poste.
- Slot (colonne c, rangée r) → origine `(12·c, 6 + 9·r)` ; îlot principal dans `Project.slot`, à l'origine du slot + `islandInset`.
- Partie p d'un projet = agents dont `deskIndex / 8 == p`. La partie p ≥ 1 existe si elle a un agent, ou si la partie p − 1 a ses 8 postes occupés (il reste toujours un poste libre). Capacité de chaque partie par `capacity`, taille par `islandSize`. Les annexes prennent, dans l'ordre (projets par slot, puis partie), les plus petits slots qui ne sont ni le slot d'un projet vivant ni celui d'une annexe déjà placée (décision 7).
- Géométrie locale (origine de l'îlot, W = capacité + 2, D = 7) : bureau `(1 + 2·post, 4)` en rangée A, `(1 + 2·post, 3)` en rangée B ; chaise `(1 + 2·post, 5)` en A, `(1 + 2·post, 2)` en B ; dégagement `(2 + 2·post, même j que le bureau)` ; pancarte `(0, 0)` ; plante `(W − 1, 0)` ; j = 1 est l'allée de la rangée B, j = 6 le bord avant. Regard : `.ne` en A, `.sw` en B. Tous les postes jusqu'à la capacité sont listés, libres compris (`agentID == nil`).
- Emprise : colonnes et rangées = boîte englobante des slots utilisés (au moins 1×1) ; `bounds = (0, 0)` + `(12·colonnes) × (6 + 9·rangées)`. Exemples (projets à 7 agents au plus) : 1 projet → 12×15 ; 3 → 24×24 ; 5 ou 6 → 36×24 ; 8 → 36×33 (table de 3.8).
- Hall fixe, indépendant des projets : `hall = (0, 0)` + `W_bounds × 6` ; `boardWall` = tuiles i 1 à 6 du mur `ne` ; `elevator` = tuiles j 2 et 3 du mur `nw` ; machine à café en `(8, 1)` et plante du hall en `(10, 1)`, regard `.sw`.
- Murs : coin en (0, 0) ; mur `ne` le long de j = 0 pour i de 0 à W − 1, mur `nw` le long de i = 0 pour j de 0 à D − 1 ; le mur de liège et l'ascenseur occupent leurs tuiles ; une fenêtre toutes les 3 tuiles ailleurs (`start % 3 == 2`) ; le style des segments (`plain`, `socket`, `baseboard`) suit une règle déterministe écrite dans le code. Les bords avant n'ont pas de mur.
- Résultat trié et indépendant de l'ordre des tableaux d'entrée.

**Règles de `AgentPresenter.scene`** (un test par ligne) :

| État de `AgentRuntime` | `animation` | `overlay` | `toolIcon` | `screen` | Autres |
|---|---|---|---|---|---|
| attente ouverte (`oldestWait`), permission ou autre | `raiseHand`, `facesViewer` | `bang` | - | `waiting` | `halo` sauf `reduceMotion` ou `acknowledgedWaiting` ; `nameplateAlways` |
| attente `question` | `raiseHand`, `facesViewer` | `bang` | `question` | `waiting` | idem |
| `thinking` | `think` | `dots` | - | `thinking` | |
| `working(tool)` | `type` | `tool` | `ToolIcon(tool)` | `working` | |
| `idle` depuis 10 min au plus | `sitIdle` | - | - | `idle` | |
| `idle` depuis plus de `asleepAfter` | `sleep` | `zzz` | - | `idle` | `asleep` |
| `done` | `sitIdle` | `check` | - | `done` | |
| `waitingBackground` | `sitIdle` | `background` | - | `background` | |
| `quotaPaused` | `sitIdle` | `quota` | - | `quota` | jamais `storm` |
| `error` | `cough` | `storm` | - | `error` | `nameplateAlways` |
| `launching` | `stand` | - | - | `boot` | |
| `offline` | `nil` | - | - | `off` | `jacketOnChair`, `nameplateOff`, `nameplateAlways`, `deskLit == false` |

Badges, seulement si `pid != nil` sauf `unsafe` : `stale` (`r.stale`), `degraded` (`hookHealth == .degraded`), `draft` (`screen?.inputBox` est `.draft` et l'état est `idle` ou `done`), `unsafe` (`permissionMode == .bypassPermissions`, tout état sauf hors ligne) ; `external` n'est jamais produit ici (agents de l'app). `subagents = pid != nil ? activeSubagents : 0`. `urgency = kind.urgency`. `label = accessibilityLabel(present(r, now:), agentName:, projectName:, now:)`.

- [ ] **Step 1: Write the failing tests.** `WorldLayoutTests` : `slotOrder` (les 10 premiers slots ci-dessus) ; `capacityAndIslandSize` (0 à 3 agents → 4 et 6×7, 4 à 7 → 8 et 10×7, index local 6 avec 3 agents → 8) ; `footprintTable` (1, 3, 6, 8 projets) ; `deskGeometry` (tuiles, regards, rangée selon la parité, poste libre listé) ; `islandGrowsInPlace` (passer de 3 à 4 agents : même origine, mêmes tuiles pour les postes 0 à 3, W de 6 à 10) ; `hallIsFixed` ; `wallsFollowBounds` (longueurs, fenêtres, mur de liège, ascenseur, aucun mur à l'avant) ; `annexAfterSevenAgents` (8 agents → annexe partie 1 de capacité 4 dans le premier slot libre) ; `archivedProjectHasNoIsland` ; `inputOrderDoesNotMatter` (entrées mélangées → résultat identique). `WorldLayoutPropertyTests` (200 séquences semées de 40 opérations sur un `Workspace` réel via `addProject`, `addAgent`, `removeAgent`, `archiveProject`, au plus 7 agents par projet) : `noIslandEverMoves` (un îlot présent avant et après garde son origine), `existingDesksNeverMove` (un agent présent avant et après garde ses tuiles), `noOverlapAndInsideBounds` (îlots disjoints, chacun dans son slot ; bureaux, chaises, dégagements, pancartes et plantes distincts et dans leur îlot ; props du hall dans le hall ; tout dans `bounds`), `deterministic`. `AgentScenePresenterTests` : une fonction par ligne du tableau, plus `badges`, `haloRules`, `labelMatchesAccessibilityLabel`.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "WorldLayout|AgentScenePresenterTests"`.
- [ ] **Step 3: Implement.** Lire d'abord `Persistence/WorkspaceOps.swift` (slots et postes : plus petit libre) et `State/AgentPresenter.swift`.
- [ ] **Step 4: Run.** `cd Core && swift build && swift test` → vert.
- [ ] **Step 5: Commit.** `git add Core && git commit -m "Core visual milestone: append-only world layout and scene presentation of agents"`

### Task 4: Sprites du décor : sols, murs, mobilier, objets du bureau, décor de base, ombres et lumières (vague 2)

**Files:**
- Create: `Core/Sources/PixelCore/Assets/Sprites/FloorSprites.swift`, `WallSprites.swift`, `FurnitureSprites.swift`, `DeskItemSprites.swift`, `DecorSprites.swift`, `LightSprites.swift`
- Test: `Core/Tests/PixelCoreTests/FloorWallSpriteTests.swift`, `FurnitureSpriteTests.swift`, `DecorLightSpriteTests.swift`

**Interfaces:**
- Consumes: tâche 1 (`PixelMap`, `SlotPaint.decor`, `Draw`, `Ramp`, `SpriteDef`, `SpriteLint`, `Palette`, `Facing`, `WallSide`) ; `PreviewWriter` (tâche 2, tests).
- Produces : `FloorSprites.all()`, `WallSprites.all()`, `FurnitureSprites.all()`, `DeskItemSprites.all()`, `DecorSprites.all()`, `LightSprites.all()` (chacune `-> [SpriteDef]`, triée par clé), avec exactement ces clés :

| ID | Taille, ancre | Frames × fps | Variantes (`variant`) | Directions | Catégorie |
|---|---|---|---|---|---|
| `floor.hall` | 64×32, (32,16) | 1 | `n0` `n1` `n2` (bruits de parquet) | - | floors |
| `floor.corridor` | 64×32, (32,16) | 1 | `n0` `n1` | - | floors |
| `floor.carpet` | 64×32, (32,16) | 1 | `hue0.plain` … `hue9.stripes` (10 teintes × uni, rayures) | - | floors |
| `floor.carpet.edge.n` / `.s` | 64×32, (32,16) | 1 | `hue0` … `hue9` | - ; `.w` et `.e` en miroir (`derivation: .mirror`) | floors |
| `floor.carpet.corner.n` / `.e` / `.s` | 64×32, (32,16) | 1 | `hue0` … `hue9` | - ; `.w` = miroir de `.e` | floors |
| `floor.hover` | 64×32, (32,16) | 2 × 4 | pointillé `chalk` | - | floors |
| `floor.dropTarget` | 64×32, (32,16) | 4 × 8 | halo `chalk` pulsé | - | floors |
| `shadow.tile` · `shadow.char` · `shadow.small` | 56×28 (28,14) · 20×8 (10,4) · 16×8 (8,4) | 1 | opaques en `ink` (décision 10) | - | lights |
| `wall.segment` | 32×112, (16,104) | 1 | `plain` `socket` `baseboard` | `nw`, `ne` (le mur) | walls |
| `wall.window` | 32×112, (16,104) | 1 | `day` `dusk` `night` | `nw`, `ne` | walls |
| `wall.corner` | 16×112, (8,104) | 1 | - | - | walls |
| `pillar` | 32×96, (16,88) | 1 | - | - | walls |
| `elevator` | 64×128, (32,120) | 6 × 12, sans boucle (portes) | - | mur `nw` seulement | walls |
| `elevator.led` | au plus 8×8 | 2 × 2 | - | - | walls |
| `board.cork` | 192×128 visé (décision 8), ancre en bas au centre | 1 | 48 emplacements (4 rangées de 12) exposés par `WallSprites.boardSlots(wall:)` | `nw`, `ne` | walls |
| `desk` | 64×48, (32,40) | 1 | `light` `dark` | 4 | furniture |
| `chair` | 32×40, (16,36) | 1 | `slate`, `hue0` … `hue9`, et chacune `.jacket` (veste posée, hors ligne) | 4 | furniture |
| `keyboard` · `papers` | 14×6 · 12×6, en bas au centre | 1 | - | 4 | deskItems |
| `mug` | 6×8, en bas au centre | 1 ; `mug~steam` 3 × 4 | - , `steam` | 4 | deskItems |
| `lamp.desk` | 12×18, (6,17) | 1 | `on` `off` | 4 | deskItems |
| `desk.postit` | 6×6, (3,6) | 1 | `hue0` … `hue9`, `paper` | - | deskItems |
| `desk.queue` | 10×8, (5,8) | 1 | `1` `2` `3` (feuilles) | - | deskItems |
| `postit.mini` | 8×12, (4,12) | 1 | `hue0` … `hue9`, `paper` | `nw`, `ne` | deskItems |
| `decor.plantSmall` | 16×24, (8,23) | 2 × 1 | - | - | decor |
| `decor.coffeeMachine` | 32×48, (16,44) | 4 × 6 (vapeur) | - | - | decor |
| `light.cone` | 48×32, (24,16) | 1 | opaque `lampWarm` (additif au compositing) | - | lights |
| `light.screenGlow` | 24×16, (12,8) | 1 | opaque `screenGlow` | - | lights |
| `fx.star` | 1×1 (0,0) et 3×3 (1,1) | 2 × 1 | `small` `big` | - | lights |

Plus ces aides pour le compositeur :

```swift
extension WallSprites { public static func boardSlots(wall: WallSide) -> [PixelPoint] }  // 48 pin points, row-major
extension FurnitureSprites {
    /// Where the monitor sits on a desk of this facing (px from the desk anchor), and the 6-px aisle shift of row A.
    public static func monitorOffset(facing: Facing) -> PixelPoint
    public static func lampOffset(facing: Facing) -> PixelPoint
    public static func keyboardOffset(facing: Facing) -> PixelPoint
}
```

Règles de dessin : chaque volume (bureau, chaise, lampe, clavier, tasse, papiers, machine à café, ascenseur, pilier) est composé de `Draw.isoBox` et de détails en `PixelMap`, **généré dans chacune de ses directions** (jamais un miroir) et porte sa `lightProbe`. Les sols ont exactement le masque du losange. Le mur `ne` (face tournée vers le spectateur à gauche) est en ton `left` de la rampe, le mur `nw` en ton `right`. Les objets muraux sont dessinés de face puis cisaillés par `Draw.shearToWall`, une fois par mur. Moquette : teinte de projet, damier à 50 % discret, motif rayures distinct de l'uni. Fenêtre de nuit : `skyNight` (les étoiles sont posées par le compositeur). Aucun sprite de cette tâche ne contient `alertYellow`.

- [ ] **Step 1: Write the failing tests.** `FloorWallSpriteTests` : `sizesAnchorsAndFrames` (une ligne par ID du tableau : taille, ancre, nombre de frames, `holds`, boucle, variantes, directions ; `board.cork` vérifie au moins 48 emplacements dans le cadre) ; `floorTilesShareTheDiamondMask` ; `carpetHasTenHuesTwoMotifs` (20 images distinctes) ; `edgeMirrorsAreExact` (`.w == mirror(.n)`, `.e == mirror(.s)`, `corner.w == mirror(corner.e)`) ; `wallsLitFromTopLeft` (luminance moyenne de la face du mur `ne` > celle du mur `nw`) ; `wallObjectsAreSheared2to1` (bord haut du masque de `board.cork` et de `elevator` en marches de 2 px) ; `windowsHaveThreeSkies`. `FurnitureSpriteTests` : `sizesAnchorsAndFrames` ; `leftFaceLighterInAllFacings` (sonde de chaque volume, quatre directions) ; `chairVariants` (11 couleurs × avec ou sans veste × 4) ; `lampOnOff` (allumée : `lampWarm` présent, éteinte : absent). `DecorLightSpriteTests` : `sizesAnchorsAndFrames` ; `shadowsAreOpaqueInk` ; `charShadowIsSymmetricEllipse` ; `lightsAreOpaqueWarmOrGlow`. Dans chaque fichier : `everySpriteIsLintClean` (`SpriteLint.issues` vide), `noAlertYellow`, `preview()`.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "FloorWallSpriteTests|FurnitureSpriteTests|DecorLightSpriteTests"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Aperçu visuel.** `cd Core && PIXEL_PREVIEW_DIR=<dossier temporaire hors du dépôt> swift test --filter "preview"` ; ouvrir les PNG (outil Read), corriger proportions, contrastes et lisibilité ; vérifier la règle 7.10 (rien qui rappelle un jeu ou une marque). Ne rien committer de ce dossier.
- [ ] **Step 5: Run.** `cd Core && swift build && swift test` → vert.
- [ ] **Step 6: Commit.** `git add Core && git commit -m "Core visual milestone: floor, wall, furniture, desk item, decor and light sprites"` (ajouter une ligne « Écart : … » par taille de 7.4 modifiée).

### Task 5: Police pixel, moniteurs et écrans, overlays, effets, HUD (vague 2)

**Files:**
- Create: `Core/Sources/PixelCore/Assets/PixelFont.swift`, `Assets/Sprites/MonitorSprites.swift`, `OverlaySprites.swift`, `EffectSprites.swift`, `HUDSprites.swift`
- Test: `Core/Tests/PixelCoreTests/PixelFontTests.swift`, `MonitorSpriteTests.swift`, `OverlaySpriteTests.swift`, `HUDSpriteTests.swift`

**Interfaces:**
- Consumes: tâche 1 (dont `ScreenState`, `OverlayKind`, `ToolIcon`, `SceneBadge`, `Palette.alertYellowSprites`) ; existants : `AgentStateKind`, `NameGenerator.names` ; `PreviewWriter` (tests).
- Produces :

```swift
public enum PixelFont {
    public static let capHeight = 5                  // glyph cell: 2 accent rows + 5 cap rows; 1 px between glyphs
    public static let lineHeight = 7
    /// Uppercases first; letters A-Z with French accents (À Â Ä Ç É È Ê Ë Î Ï Ô Ö Ù Û Ü Œ), 0-9, space and
    /// . , : ; ! ? ' " - + / ( ) # % @ ~ _ < > = · … ×; any other character renders as "?".
    public static func render(_ text: String, color: RGBA8, outline: RGBA8? = nil) -> PixelImage
    public static func width(of text: String) -> Int
    /// The text, or its first maxCharacters − 1 characters followed by "…" (sign: 10 characters, 7.4.2).
    public static func fitted(_ text: String, maxCharacters: Int) -> String
    public static let supportedCharacters: Set<Character>
}
public enum MonitorSprites { public static func all() -> [SpriteDef] }
public enum OverlaySprites { public static func all() -> [SpriteDef] }
public enum EffectSprites { public static func all() -> [SpriteDef] }
public enum HUDSprites {
    public static func all() -> [SpriteDef]
    /// Island sign (front panel, never sheared): hue plate + name in chalk with an ink outline, fitted to 10 characters.
    public static func sign(name: String, hue: Int) -> PixelImage
    /// desk.nameplate 9-slice sized to the text (chalk text on the plate); `off`: the "OFF" variant.
    public static func nameplate(_ text: String, off: Bool) -> PixelImage
    public static func queueBadgeKey(count: Int) -> SpriteKey     // "1"…"9", then "plus"
}
```

Clés produites :

| ID | Taille, ancre | Frames × fps | Variantes | Directions | Catégorie |
|---|---|---|---|---|---|
| `monitor.front` | 24×24, (12,22) | 1 | - | `ne`, `nw` (décision 5) | monitors |
| `monitor.back` | 24×24, (12,22) | 2 × 2 (LED) | `led.<ScreenState>` (10 ; couleur **et** motif de clignotement propres à chaque état) | `se`, `sw` | monitors |
| `screen.<ScreenState>` | 16×10, (8,10) | selon `ScreenState` | - | `ne` ; `nw` = miroir | screens |
| `ov.bang` | 12×24, (6,24) ; `xl` 24×48, (12,48) | 4 × 8 (rebond) | -, `xl` | - | overlays |
| `ov.bang.halo` | 32×32, (16,16) | 2 × 4 | - | - | overlays |
| `ov.dots` | 20×14, (10,14) | 3 × 3 | - | - | overlays |
| `ov.tool.<ToolIcon>` | 16×16 (icône 12×12 dans une bulle), (8,16) | 1 | feuille, crayon, `>_`, loupe, globe, mini-bonhomme, prise, « ? », engrenage | - | overlays |
| `ov.zzz` | 16×16, (4,16) | 3 × 2 | - | - | overlays |
| `ov.storm` | 28×18, (14,18) | 4 × 6 (éclair) | - | - | overlays |
| `ov.check` | 12×12, (6,12) | 3 × 12, sans boucle | - | - | overlays |
| `ov.stale` | 10×14, (5,14) | 2 × 2 | - | - | overlays |
| `ov.background` | 12×16, (6,16) | 4 × 2 (sablier) | - | - | overlays |
| `ov.quota` | 14×14, (7,14) | 2 × 1 (aiguille) | - | - | overlays |
| `ov.draft` | 10×10, (5,10) | 1 | - | - | overlays |
| `ov.edgeArrow` | 16×16, (8,8) | 2 × 4 | symétrique (rotations à l'étape 3) | - | overlays |
| `ov.degraded` · `ov.unsafe` · `ov.external` | 12×12, (6,12) | 1 | - | - | overlays |
| `ov.selection` | 36×18, (18,9) | 2 × 3 | - | - | overlays |
| `fx.dust` · `fx.ding` · `fx.pinDrop` | 24×16 (12,16) · 12×12 (6,12) · 12×8 (6,8) | 6 × 12 · 3 × 8 · 3 × 12, sans boucle | - | - | effects |
| `sign.island` | 64×40, (32,38) | 1 | `hue0` … `hue9` (plaque sans texte) | - | hud |
| `desk.nameplate` | 16×8, bords 3, ancre en bas au centre | 1 | `normal`, `off` | - | hud |
| `desk.queueBadge` | 8×8, (4,8) | 1 | `1` … `9`, `plus` | - | hud |
| `hud.state.<AgentStateKind>` | 12×12, (6,12) | 1 | - | - | hud |
| `minimap.frame` · `minimap.viewport` | 16×16 · 8×8 (9-slice) | 1 | - | - | hud |
| `minimap.dot.<AgentStateKind>` | 5×5 | 1 | un glyphe par état | - | hud |

Règles : `ov.bang` en `alertYellow` avec contour `alertOrange` ; chaque état a une forme propre (7.9) ; `alertYellow` seulement dans `Palette.alertYellowSprites` (et pour `monitor.back`, seulement la variante `led.waiting`) ; `screen.waiting` clignote en jaune ; `screen.quota` montre une horloge, `screen.background` un sablier ; les icônes d'outil sont génériques et originales. `PixelFont` est une police **originale** (aucun glyphe recopié d'une police existante) ; le texte dans la scène est toujours sur une plaque ou avec un contour `ink` (7.2).

- [ ] **Step 1: Write the failing tests.** `PixelFontTests` : `coversNamesAndSymbols` (chaque nom de `NameGenerator.names` en capitales, les chiffres, `+ · … ~ @ # . : - / >`) ; `capHeightAndWidths` (hauteur 7, capitales sur 5 rangées, largeur = somme des glyphes + espacements) ; `fittedTruncatesAtTen` (`"DOCUMENTATION"` → `"DOCUMENTA…"`) ; `lowercaseRendersAsUppercase` ; `unknownCharacterIsQuestionMark`. `MonitorSpriteTests` : `screenStatesFramesAndFps` ; `onlyWaitingScreenIsYellow` ; `monitorFacings` ; `ledVariantsAreDistinct` (10 variantes, frames 0 deux à deux différentes ; seule `led.waiting` contient du jaune). `OverlaySpriteTests` : `sizesAnchorsAndFrames` ; `bangIsYellowWithOrangeOutline` ; `bangXLIsTwiceTheSize` ; `stateShapesAreDistinct` (masques alpha de la frame 0 de `ov.bang`, `ov.dots`, `ov.zzz`, `ov.storm`, `ov.check`, `ov.stale`, `ov.background`, `ov.quota` deux à deux différents) ; `toolIconsAreDistinct` ; `alertYellowOnlyWhereAllowed`. `HUDSpriteTests` : `signFitsTenCharacters` (« SITE WEB » et « DOCUMENTATION » tiennent dans 64 px) ; `nameplateNineSlice` (largeur = texte + bords, variante OFF) ; `queueBadgeDigits` ; `hudStatePerKind` (10, masques distincts) ; `minimapDotsCarryGlyphs` (10 masques distincts, jamais la couleur seule). Partout : `everySpriteIsLintClean`, `preview()`.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "PixelFontTests|MonitorSpriteTests|OverlaySpriteTests|HUDSpriteTests"`.
- [ ] **Step 3: Implement.** Le contenu d'écran suit le plan de la face du moniteur ; si le cisaillement l'exige, la taille 16×10 peut changer (décision 8).
- [ ] **Step 4: Aperçu visuel** comme à la tâche 4 (lisibilité des icônes à ×1, netteté du texte, distinction des formes).
- [ ] **Step 5: Run.** `cd Core && swift build && swift test` → vert.
- [ ] **Step 6: Commit.** `git add Core && git commit -m "Core visual milestone: pixel font, monitors, screens, overlays, effects and HUD sprites"`

### Task 6: Personnages : apparences, 14 animations, miroirs ré-ombrés (vague 2)

**Files:**
- Create: `Core/Sources/PixelCore/Assets/Characters/CharacterPalette.swift`, `SlotCanvas.swift`, `CharacterParts.swift`, `CharacterPoses.swift`, `CharacterSprites.swift`
- Test: `Core/Tests/PixelCoreTests/CharacterSpriteTests.swift`, `CharacterReshadeTests.swift`

**Interfaces:**
- Consumes: tâche 1 (`PixelMap`, `Slot`, `CharacterAnimation`, `SpriteDef`, `SpriteLint`, `Palette`, `Facing`) ; existant : `AgentLook` (`Model/Workspace.swift`) ; `PreviewWriter` (tests).
- Produces :

```swift
// CharacterPalette.swift
public enum CharacterPalette {
    public static let skinCount = 4, hairStyleCount = 6, hairColorCount = 8, outfitCount = 16, accessoryCount = 4
}
/// AgentLook + project hue → colour of every character slot (values out of range are clamped).
public struct ResolvedLook: Hashable, Sendable {
    public init(_ look: AgentLook, projectHue: Int)
    public func color(_ slot: Slot) -> RGBA8?
    public var outlineColors: Set<RGBA8> { get }        // q, j, u tones (outside the 12-colour cap)
    public var variantName: String { get }              // "s0h2c1op4a0": skin, hair style, hair colour, outfit, accessory
}
// SlotCanvas.swift
public struct SlotCanvas: Hashable, Sendable {           // composition in slot space, needed by the reshade pass
    public init(width: Int, height: Int)
    public mutating func draw(_ map: PixelMap, x: Int, y: Int)   // non-clear cells overwrite
    public func mirrored() -> SlotCanvas
    public func flattened() -> SlotCanvas                // shade slots back to their base: S→s, H→h, T→t, b→p, A→a
    /// 1-px shade band on the right edge of every horizontal run of a material (≥ 3 px), under the chin and under
    /// the fringe (7.5): light stays top-left after a mirror.
    public func reshaded() -> SlotCanvas
    public func render(_ look: ResolvedLook) -> PixelImage
}
// CharacterSprites.swift
public struct CharacterSheet: Sendable {
    public let look: ResolvedLook
    public func def(_ animation: CharacterAnimation, _ facing: Facing) -> SpriteDef?   // nil: raiseHand toward ne/nw
    public var defs: [SpriteDef] { get }                 // 14 animations × facings: 184 frames
}
public enum CharacterSprites {
    public static let frameWidth = 32, frameHeight = 56
    public static let anchor = PixelPoint(16, 53)        // between the feet
    public static let headHeight: Int                    // for the 3.5-heads test
    /// Key "agent.<animation>~<variantName>@<facing>"; SE and NE drawn, SW and NW = mirrorReshaded.
    public static func sheet(look: AgentLook, projectHue: Int) -> CharacterSheet
    public static func mini(projectHue: Int) -> SpriteDef   // agent.mini~hueN: 16×24, (8,23), 2 × 4
    /// Catalog entries: the sheet of AgentLook() with hue 4, and agent.mini for hues 0…9.
    public static func catalogDefs() -> [SpriteDef]
    /// Looks of contact sheet 6: each skin, each haircut, each hair colour, each outfit, each accessory.
    public static let sampleLooks: [AgentLook]
}
```

Tables d'apparence (palette uniquement, jamais `alertYellow`) :
- **Peaux** (`s` / `S` / `q`) : 0 `skin1`/`skin2`/`skin3` ; 1 `skin2`/`skin3`/`skin4` ; 2 `skin3`/`skin4`/`hairDark` ; 3 `skin4`/`hairDark`/`ink`.
- **Cheveux** (`h` / `H` / `j`) : 0 `hairDark`/`ink`/`ink` ; 1 `woodMid`/`woodDark`/`hairDark` ; 2 `woodLight`/`woodMid`/`woodDark` ; 3 `stone`/`slate`/`shade` ; 4 `paper`/`mist`/`stone` ; 5 Tomate base/dark/`ink` ; 6 Mandarine base/dark/`woodDark` ; 7 Prune base/dark/`ink`.
- **Hauts** (`t` / `T` / `u`) : `outfitPaletteIndex` 0 à 9 = teinte de projet (base/dark/dark) ; `nil` = la teinte du projet de l'agent ; 10 `paper`/`mist`/`stone` ; 11 `stone`/`slate`/`shade` ; 12 `slate`/`shade`/`ink` ; 13 `woodMid`/`woodDark`/`hairDark` ; 14 `leaf`/`leafDark`/`ink` ; 15 `uiTitle`/`shade`/`ink`.
- **Bas** (`p` / `b`) : `slate`/`shade` ; chaussures `ink` ; **yeux** `e` : `ink`, 1×2 px.
- **Accessoires** (`a` / `A`) : `nil` ou 0 aucun, 1 lunettes, 2 casque audio, 3 bonnet ; couleurs au choix dans la palette.
- **Coupes** : 6 coupes distinctes, chacune dessinée de face (SE) et de dos (NE).

Structure attendue : `CharacterParts` contient les cartes ASCII des parties (tête de face et de dos, 6 coupes de face et de dos, accessoires, torse debout et assis, jambes debout, cycle de marche, jambes assises, bras par geste : frappe, menton, main levée, tasse, étirement, bras en l'air, saisie, toux, salut) ; `CharacterPoses` décrit chaque frame de chaque animation, en SE et en NE, comme une liste de parties posées à des décalages entiers (balancement de tête, alternance des mains) ; `CharacterSprites` compose en `SlotCanvas`, puis rend avec `ResolvedLook`. SW = `SE.flattened().mirrored().reshaded()`, NW = `NE.flattened().mirrored().reshaded()` (`derivation: .mirrorReshaded`). Proportions **à nous** : environ 3,5 têtes, yeux de 1×2 px, aucune bouche ; silhouette, coiffures et vêtements sans rapport avec un avatar de jeu connu. Les poses assises sont prévues pour la chaise de la tâche 4 (assise à 16 px) ; la frame 0 de `sitIdle`, `type`, `think`, `raiseHand` et `cough` doit être lisible à ×1.

- [ ] **Step 1: Write the failing tests.** `CharacterSpriteTests` : `frameCounts` (SE 48, NE 44, SW 48, NW 44, total 184) ; `sizesAnchorsHolds` (32×56, ancre (16,53), `holds` depuis les cadences, boucles) ; `raiseHandOnlyTowardViewer` ; `paletteAndColorCapOnSampledLooks` (`SpriteLint` sur les frames 0 de toutes les animations pour chaque élément de `sampleLooks`, et sur la planche complète de trois apparences) ; `threeAndHalfHeads` (hauteur opaque de `stand@se#0` entre 3,2 et 3,8 fois `headHeight`) ; `eyesAreOneByTwo` (dans le `SlotCanvas` de `sitIdle@se#0` et `stand@se#0` : deux composantes de l'emplacement `eye`, chacune de 1×2) ; `noMouthAtRest` (sous les yeux, seulement peau et ombre de peau dans `stand`, `sitIdle`, `type`, `think`, `sleep`) ; `feetOnAnchor` (dernière rangée opaque de `stand@se#0` = 53) ; `looksAreDistinct` (deux coupes, deux couleurs, deux accessoires différents donnent des images différentes) ; `deterministicSheets` ; `miniAgent`. `CharacterReshadeTests` : `flattenRemovesShades` ; `reshadeBandsOnRightEdges` (dans les frames SW et NW, le pixel le plus à droite de chaque segment horizontal d'une matière de 3 px ou plus est son ton d'ombre) ; `swIsNotPlainMirror` ; `lightStaysTopLeft` (luminance moyenne de la moitié gauche de la tête > moitié droite, dans les quatre directions, sur `sitIdle#0`). `preview()` : planche d'une apparence et de `sampleLooks`.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "CharacterSpriteTests|CharacterReshadeTests"`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Aperçu visuel** comme à la tâche 4 : lisibilité des poses à ×1 (main levée, frappe, menton, toux), cohérence des quatre directions, originalité (7.10).
- [ ] **Step 5: Run.** `cd Core && swift build && swift test` → vert.
- [ ] **Step 6: Commit.** `git add Core && git commit -m "Core visual milestone: characters with looks, 14 animations and reshaded mirrors"`

### Task 7: Catalogue, `SceneCompositor` et scènes de démonstration (vague 3)

**Files:**
- Create: `Core/Sources/PixelCore/Assets/SpriteCatalog.swift`, `Core/Sources/PixelCore/World/SceneModel.swift`, `World/SceneCompositor.swift`, `World/Showcase.swift`
- Test: `Core/Tests/PixelCoreTests/SpriteCatalogTests.swift`, `SceneCompositorTests.swift`, `ShowcaseTests.swift`

**Interfaces:**
- Consumes: tâches 1, 3, 4, 5, 6 (toutes les fonctions `all()`, `CharacterSprites.sheet`, `HUDSprites.sign`, `HUDSprites.nameplate`, `PixelFont`, `WallSprites.boardSlots`, les décalages de `FurnitureSprites`, `WorldLayout.compute`, `AgentPresenter.scene`) ; existants : `Workspace`, `WorkspaceOps`, `AgentRuntime` ; `PreviewWriter`, `PNGTestDecoder` (tests).
- Produces (utilisé par la tâche 8) :

```swift
// Assets/SpriteCatalog.swift
public enum SpriteCatalog {
    /// The v0 ids (décision 1), sorted.
    public static let v0IDs: [SpriteID]
    /// Every v0 sprite (all groups + CharacterSprites.catalogDefs()), sorted by key, built once.
    public static let all: [SpriteDef]
    public static func sprite(_ key: SpriteKey) -> SpriteDef?
    public static func sprites(in category: SpriteCategory) -> [SpriteDef]
}

// World/SceneModel.swift
public enum SceneZoom: Int, CaseIterable, Sendable {
    case overview = 0, x1 = 1, x2 = 2, x3 = 3
    public var pixelsPerTexel: Int { get }               // overview 1 (shown at 0.5 pt per texel), else rawValue
}
public struct RenderOptions: Hashable, Sendable {
    public var zoom: SceneZoom; public var night: Bool
    public var tick: Int                                 // animation clock (24/s); 0 = frame 0 everywhere
    public var crop: GridRect?                           // nil: whole world with walls; else tiles inside only, no walls
    public var reduceTransparency: Bool                  // night veil 0.35 instead of 0.55
    public init(zoom: SceneZoom = .x1, night: Bool = false, tick: Int = 0, crop: GridRect? = nil, reduceTransparency: Bool = false)
}
public struct ProjectVisual: Hashable, Sendable { public var name: String; public var hueIndex: Int; public init(name: String, hueIndex: Int) }
public struct AgentExtras: Hashable, Sendable {
    public var queued: Int                               // post-its in the queue: desk.queue (1…3 sheets) + badge
    public var cardOnScreenHue: Int?                     // post-it stuck on the monitor: hue 0…9, 10 = paper
    public init(queued: Int = 0, cardOnScreenHue: Int? = nil)
}
public struct SceneAgent: Sendable {
    public var name: String; public var look: AgentLook; public var presentation: AgentPresentation; public var extras: AgentExtras
    public init(name: String, look: AgentLook, presentation: AgentPresentation, extras: AgentExtras = .init())
}
public struct SceneInput: Sendable {
    public var layout: WorldLayoutResult
    public var projects: [ProjectID: ProjectVisual]
    public var agents: [AgentID: SceneAgent]
    public var boardCardHues: [Int]                      // mini post-its of the cork wall, in order (48 shown, then "+n")
    public init(layout: WorldLayoutResult, projects: [ProjectID: ProjectVisual], agents: [AgentID: SceneAgent], boardCardHues: [Int] = [])
    /// Layout by WorldLayout.compute, presentations by AgentPresenter.scene (no runtime → offline(.notStarted)),
    /// permission mode from each Agent.
    public static func make(workspace: Workspace, runtimes: [AgentID: AgentRuntime], extras: [AgentID: AgentExtras] = [:],
                            boardCardHues: [Int] = [], now: Date, reduceMotion: Bool = false) -> SceneInput
}

// World/SceneCompositor.swift
public enum SceneCompositor {
    public static func render(_ scene: SceneInput, options: RenderOptions) -> PixelImage
    /// (W + D)·32 × ((W + D)·16 + 96) texels for a W × D rect (3.8): 24×24 → 1536×864, 36×24 → 1920×1056.
    public static func canvasSize(for rect: GridRect) -> (width: Int, height: Int)
    /// Top vertex of a tile in that canvas (texels, y down): x = ((i − i0) − (j − j0) + D)·32, y = (i − i0 + j − j0)·16 + 96.
    public static func imagePoint(of tile: GridPoint, in rect: GridRect) -> PixelPoint
}

// World/Showcase.swift
public enum Showcase {
    public static let now: Date                          // 2026-10-01 09:00 UTC (1 790 845 200)
    public static func islandCasts() -> [SceneInput]     // the 2 distributions below, same project, same 8-desk island
    public static func islandCrop() -> GridRect          // slot 0 (island + its corridor ring)
    /// Both casts rendered at 1 texel per pixel, stacked with a PixelFont caption above each, then scaled.
    public static func islandSheet(zoom: SceneZoom, night: Bool) -> PixelImage
    public static func overview() -> SceneInput          // mockup 6(q)
    public static func overviewImage(night: Bool) -> PixelImage   // zoom .overview, whole world
}
```

**Rendu** (`SceneCompositor.render`), dans cet ordre, tout en texels puis `scaled(by: zoom.pixelsPerTexel)` à la toute fin :
1. **Sol** : parquet du hall (variante `n(i·7 + j·13) % 3`), couloir partout ailleurs (variante `% 2`), moquette des îlots à la teinte du projet (bords et coins selon les conventions, motif uni).
2. **Ombres** : `shadow.tile` sous les bureaux, `shadow.char` sous les avatars, `shadow.small` sous les chaises et les plantes, dessinées opaques dans **un calque séparé**, décalées de (+2, +1), puis `composite(alpha: Palette.shadowAlpha)` une seule fois.
3. **Monde**, trié par profondeur `IsoMath.depth` puis par ordre d'insertion stable : coin, murs (fenêtres au ciel `day`, ou `night` de nuit), mur de liège avec ses mini post-its aux emplacements de `boardSlots`, ascenseur (portes fermées, frame 0) et son voyant, machine à café, plantes ; par îlot : pancarte (`HUDSprites.sign`, nom du projet, « NOM · 2 » pour une annexe), plante ; par poste : chaise (avant l'avatar si le regard va vers le spectateur, après sinon : le dossier couvre le bas du dos), bureau, moniteur (`monitor.front` décalé de 6 px vers la tuile de dégagement en rangée A, `monitor.back~led.<écran>` en rangée B), contenu d'écran, clavier, lampe (`on` la nuit si `deskLit`), tasse ou papiers sur certains postes (règle déterministe sur l'index), `desk.postit` si `cardOnScreenHue`, `desk.queue` (min(queued, 3) feuilles), avatar (`CharacterSprites.sheet(look:projectHue:)`, mis en cache le temps de l'appel ; direction = regard du poste, ou son opposé vers le spectateur si `facesViewer`), `agent.mini` sur la tuile de dégagement si `subagents > 0`. Poste libre : chaise sans veste, bureau, écran `off`, lampe éteinte. Hors ligne : pas d'avatar, chaise `.jacket`, écran `off`, lampe éteinte.
4. **Nuit seulement** : `multiply(by: Palette.nightVeil, alpha: nightVeilAlpha)` (ou `nightVeilAlphaReduced`) sur tout ce qui précède ; puis un calque additif (`light.cone` sous chaque lampe allumée, `light.screenGlow` devant chaque écran allumé, étoiles `fx.star` dans les fenêtres à des positions déterministes) appliqué par `add(alpha: Palette.lightPoolAlpha)`.
5. **Overlays**, jamais voilés, triés par profondeur : overlay principal au-dessus de la tête (`ov.bang~xl` en vue d'ensemble, `ov.bang` sinon, `ov.bang.halo` derrière si `halo`), bulle d'outil, badges en ligne à côté, `desk.queueBadge` si `queued > 0`, plaques de nom (`HUDSprites.nameplate`) pour `nameplateAlways`, compteur « +n » du mur de liège au-delà de 48. **Vue d'ensemble** : en plus, l'icône `hud.state.<kind>` au-dessus de chaque poste occupé (6(q) : pastille d'état avec glyphe).
6. **Recadrage** (`crop`) : seules les tuiles du rectangle et les objets ancrés dessus, sans murs, dans un canevas `canvasSize(for: crop)`. Hors du monde, les pixels restent transparents.

**Distributions de l'îlot** (projet « API », teinte Lagune `hue4`, 8 postes ; rangée A = index pair, devant ; B = impair, derrière) :

| Poste | Distribution 1 | Distribution 2 |
|---|---|---|
| 0 (A0) | Nova : attend une permission (Bash « rm -rf dist », depuis 42 s), 1 post-it en file | Pixou : travaille (Edit), post-it collé à l'écran, 2 post-its en file |
| 1 (B0) | Bip : travaille (Bash), 2 sous-agents | Sol : attend une réponse à une question |
| 2 (A1) | Lune : réfléchit | Mika : attend une tâche de fond |
| 3 (B1) | Oslo : tour terminé | Rio : en pause, limite d'usage (reprise automatique dans 40 min) |
| 4 (A2) | Zéphyr : erreur (serveurs surchargés) | Lou : démarre |
| 5 (B2) | Tao : au repos depuis 12 min (endormi) | Plume : réfléchit, sans nouvelles, mode dégradé |
| 6 (A3) | Kiwi : hors ligne (session fermée) | (poste libre) |
| 7 (B3) | (poste libre) | Galet : au repos depuis 2 min, brouillon dans la zone de saisie, mode `bypassPermissions` |

Apparences variées fixées à la main (toutes les peaux, au moins 5 coupes, lunettes, casque et bonnet présents). Légendes en `PixelFont` sur une bande `paper` : « DISTRIBUTION 1 : ATTENTE, TRAVAIL, RÉFLEXION, FINI, ERREUR, ENDORMI, HORS LIGNE, POSTE LIBRE » et « DISTRIBUTION 2 : … ».

**Vue d'ensemble** (6(q)), projets créés dans cet ordre (slots 0 à 5) : API (Lagune, 5 agents : Nova attend (Bash), Bip travaille, Lune réfléchit, Kiwi travaille, Oslo fini) ; INFRA (Menthe, 4 : Zéphyr erreur, Ada travaille, Rio au repos, Sol attend (question)) ; SITE (Tomate, 3 : Pixou travaille, Tao au repos, Mika fini) ; DATA (Indigo, 3 : Plume travaille, Galet travaille, Brume réfléchit) ; MOBILE (Framboise, 3 : Comète travaille, Nuage au repos, Pépin travaille) ; DOCS (Olive, 2 : Ivo attend (Edit), Cajou travaille). 20 agents, 3 en attente, mur de liège de 12 mini post-its aux teintes des projets, emprise 36×24 (1920×1056 texels).

- [ ] **Step 1: Write the failing tests.** `SpriteCatalogTests` : `coversEveryV0ID` (chaque ID de `v0IDs` a au moins un sprite) ; `noUnknownIDs` ; `uniqueKeys` ; `everySpriteIsLintClean` ; `mirrorsMatchTheirSource` (`derivation == .mirror` → frames = frames de la source en miroir). `SceneCompositorTests` (petites scènes, sauf mention) : `canvasSizeFollowsFootprintTable` (12×15 → 864×528, 24×24 → 1536×864, 36×24 → 1920×1056, 36×33 → 2208×1200) ; `tileTopVertexPosition` ; `zoomIsExactUpscale` (rendu ×2 et ×3 = rendu ×1 `scaled(by:)`) ; `dayPixelsArePaletteOrSingleShadow` (chaque pixel opaque du rendu de jour de la distribution 1 est dans `spriteColors` ou égal à un pixel de `spriteColors` mélangé une fois avec `ink` à 77 ; la formule de `composite` sert de référence) ; `alertYellowOnlyWhenWaiting` (aucun pixel `alertYellow` dans un îlot sans attente, présent avec Nova) ; `overlaysIgnoreNightVeil` (les pixels du « ! » de Nova sont identiques de jour et de nuit) ; `nightIsDarkerExceptLights` (un pixel de moquette loin des lampes est plus sombre la nuit ; un pixel sous `light.cone` est plus clair que son voisin hors flaque) ; `overviewUsesXLBang` ; `drawOrderBackToFront` (sur une scène à deux postes, l'objet de la tuile la plus proche recouvre l'autre là où ils se chevauchent) ; `cropHasNoWalls` ; `deterministic`. `ShowcaseTests` : `castsCoverEveryState` (les 10 `AgentStateKind`, l'agent endormi, la question, les 4 badges, les sous-agents, le post-it collé et la file apparaissent dans l'union des deux distributions ; attente, travail et réflexion dans les deux rangées) ; `oneFreeDeskPerCast` ; `overviewMatchesMockupQ` (20 agents, 6 projets, attentes : Nova, Sol, Ivo) ; `overviewFitsSixSlots` (`bounds` 36×24). `preview()` : îlot ×2 jour et nuit, vue d'ensemble.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "SpriteCatalogTests|SceneCompositorTests|ShowcaseTests"`.
- [ ] **Step 3: Implement.** `Showcase` construit un vrai `Workspace` avec `addProject`/`addAgent` (identifiants `UUID(uuidString: "00000000-0000-0000-0000-0000000000NN")`, dates dérivées de `Showcase.now`), retire un agent pour libérer le poste 6 de la distribution 2, fixe les apparences et `permissionMode`, puis des `AgentRuntime` (`pid` pour les agents vivants, `pendingWaits`, `phaseSince`, `stale`, `hookHealth`, `screen`, `activeSubagentIDs`) et passe par `SceneInput.make`.
- [ ] **Step 4: Aperçu visuel** (`preview()`) : vérifier placement, occlusions (écran de la rangée A visible à côté de la tête, visages de la rangée B au-dessus des moniteurs), lisibilité des overlays à ×1 et en vue d'ensemble. Corriger les placements, pas l'art des tâches 4 à 6.
- [ ] **Step 5: Run.** `cd Core && swift build && swift test` → vert.
- [ ] **Step 6: Commit.** `git add Core && git commit -m "Core visual milestone: sprite catalog, software scene compositor and showcase scenes"`

### Task 8: `sprite-export`, planches de contact, empreintes golden, rendu du jalon, docs et CI (vague 4)

**Files:**
- Modify: `Core/Package.swift`, `.github/workflows/core.yml` (aucun fichier d'une autre tâche : un défaut vu au rendu est noté, pas corrigé ici)
- Create: `Core/Sources/sprite-export/main.swift`, `Core/Sources/PixelCore/Assets/PixelImage+PNG.swift`, `Assets/ContactSheet.swift`, `Assets/MilestoneExport.swift`, `Core/Tests/PixelCoreTests/ContactSheetTests.swift`, `GoldenTests.swift`, `MilestoneExportTests.swift`, `Fixtures/golden/sprites.txt`, `docs/jalon-visuel/README.md`, les 15 PNG de `docs/jalon-visuel/`, `docs/ASSETS.md`

**Interfaces:**
- Consumes: toutes les tâches précédentes.
- Produces :

```swift
extension PixelImage { public func pngData(pixelsPerMeter: Int? = nil) -> [UInt8] }   // PNGEncoder, fixed Huffman

public enum ContactSheet {
    public static let defaultScale = 4
    public struct Page: Sendable { public let fileName: String; public let title: String; public let image: PixelImage }
    /// planche-0 … planche-6 (list below); every cell: the frames side by side on a light checkerboard (paper / mist,
    /// 4×4) to show transparency, the label under them (key, size, frames × fps, "MIROIR" for a derived sprite).
    public static func pages(scale: Int = defaultScale) -> [Page]
}

public enum MilestoneExport {
    public enum Part: String, CaseIterable, Sendable { case palette, sheets, island, overview }
    public struct Output: Sendable { public let fileName: String; public let image: PixelImage; public let pixelsPerMeter: Int? }
    public static func fileNames(parts: Set<Part> = Set(Part.allCases)) -> [String]   // output order
    /// One image at a time (memory), in fileNames order.
    public static func forEach(parts: Set<Part> = Set(Part.allCases), scale: Int = ContactSheet.defaultScale,
                               _ body: (Output) throws -> Void) rethrows
    /// "<key>#<frame> <fingerprint>" for every frame of SpriteCatalog.all, then "scene:<name> <fingerprint>" for
    /// ilot-1-x1-jour, ilot-2-x1-jour, vue-ensemble-jour, vue-ensemble-nuit; sorted.
    public static func goldenLines() -> [String]
}
```

`sprite-export` (`main.swift`, logique dans `MilestoneExport`) :

```text
sprite-export [--out <dossier>] [--only palette,sheets,island,overview] [--scale <n>] [--golden-out <fichier>]
```
Par défaut, `--out docs/jalon-visuel` relatif au dossier courant et toutes les parties ; écriture atomique de chaque fichier ; une ligne par fichier (nom, largeur × hauteur, taille en octets) ; `--golden-out <fichier>` écrit `goldenLines()` dans ce fichier et aucune image ; code de sortie 1 et message d'usage sur une option inconnue.

`Package.swift` : produit `.executable(name: "sprite-export", targets: ["sprite-export"])` et cible `.executableTarget(name: "sprite-export", dependencies: ["PixelCore"])`.

**Les 15 fichiers du livrable** (`docs/jalon-visuel/`) :

| Fichier | Contenu |
|---|---|
| `planche-0-palette.png` | 32 rôles (pastille, nom, hexadécimal), ombre et flaque de lumière sur `floorLight`, 10 teintes × 3 tons, couleurs dérivées ; couleurs clés marquées « jamais dans un sprite » |
| `planche-1-sols-murs.png` | catégories `floors`, `walls` |
| `planche-2-mobilier-decor.png` | `furniture`, `deskItems`, `decor`, `lights` |
| `planche-3-ecrans-overlays.png` | `monitors`, `screens`, `overlays`, `effects` |
| `planche-4-hud-texte.png` | `hud`, spécimen de `PixelFont` (alphabet, accents, chiffres, symboles, tous les noms de `NameGenerator`), pancartes « API », « SITE WEB », « DOCUMENTATION », plaques « NOVA » et « OFF » |
| `planche-5-personnage.png` | planche complète de `AgentLook()` : une ligne par animation, SE, SW, NE, NW, frames côte à côte, « TYPE · 4 × 12 FPS » |
| `planche-6-apparences.png` | `sampleLooks` en `sitIdle` SE et NE, `agent.mini` dans les 10 teintes |
| `ilot-x1-jour.png`, `ilot-x2-jour.png`, `ilot-x3-jour.png` | `Showcase.islandSheet(zoom:night: false)` |
| `ilot-x1-nuit.png`, `ilot-x2-nuit.png`, `ilot-x3-nuit.png` | `Showcase.islandSheet(zoom:night: true)` |
| `vue-ensemble-jour.png`, `vue-ensemble-nuit.png` | `Showcase.overviewImage(night:)`, 1920×1056, chunk `pHYs` à 144 ppp |

Planches à l'échelle 4 ; îlot à 1, 2 et 3 pixels par texel.

**CI** (`core.yml`, job Linux, après « Test ») :

```yaml
      - name: Render the visual milestone
        run: swift run --package-path Core -c release sprite-export --out "$PWD/build/jalon-visuel"

      - name: Check the committed images
        shell: bash
        run: |
          for f in build/jalon-visuel/*.png; do
            cmp -s "$f" "docs/jalon-visuel/$(basename "$f")" || { echo "::error::$(basename "$f") is out of date: run the render command and commit"; exit 1; }
          done

      - name: Upload the visual milestone
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: jalon-visuel
          path: build/jalon-visuel
```

- [ ] **Step 1: Write the failing tests.** `ContactSheetTests` : `everyCatalogSpriteHasACell` (planches 1 à 4 : une cellule par sprite de leurs catégories ; planche 5 : 184 frames) ; `pagesAreDeterministic` ; `scaleIsExact` (`pages(scale: 2)` = `pages(scale: 1)` agrandies). `MilestoneExportTests` : `fileNamesAreTheFifteenDeliverables` (noms et ordre du tableau) ; `paletteFileDecodes` (`planche-0` encodée puis relue par `PNGTestDecoder` : mêmes pixels) ; `overviewHas144dpi` (chunk `pHYs` à 5669, vérifié sur un rendu recadré pour rester rapide) ; `goldenLinesAreSortedAndUnique`. `GoldenTests.spritesAndScenesMatchGolden` : lit `Fixtures/golden/sprites.txt` (`Bundle.module.resourceURL`), compare à `MilestoneExport.goldenLines()` ; en cas d'écart, liste au plus 20 clés et rappelle la commande de régénération.
- [ ] **Step 2: Run to verify they fail.** `cd Core && swift test --filter "ContactSheetTests|MilestoneExportTests|GoldenTests"`.
- [ ] **Step 3: Implement** `PixelImage+PNG.swift`, `ContactSheet.swift`, `MilestoneExport.swift`, `main.swift`, `Package.swift`.
- [ ] **Step 4: Golden.** Depuis la racine du dépôt : `swift run --package-path Core sprite-export --golden-out Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt`, puis `cd Core && swift build && swift test` → tout vert.
- [ ] **Step 5: Render.** Depuis la racine du dépôt : `swift run --package-path Core -c release sprite-export --out "$PWD/docs/jalon-visuel"` (attendu : une minute au plus sur un Mac M1). Déterminisme : `shasum docs/jalon-visuel/*.png`, relancer la commande, puis `shasum` de nouveau : les 15 empreintes doivent être identiques.
- [ ] **Step 6: Revue des images.** Ouvrir chaque PNG (outil Read) et noter chaque défaut (placement, art, tailles, couleurs, lisibilité) dans le README, section « Défauts constatés », avec le fichier et la tâche concernée. Ne pas modifier les fichiers des tâches 1 à 7 : une correction fera l'objet d'une tâche de suivi, après quoi le golden et les images seront régénérés.
- [ ] **Step 7: Docs.** `docs/jalon-visuel/README.md` (en français, sans tiret cadratin) : but du jalon ; commande de rendu ; tableau des 15 fichiers ; comment les regarder (Aperçu, taille réelle ⌘0 sur Retina = l'app au zoom ×k ; vue d'ensemble à 144 ppp = 0,5 pt par texel) ; **questions à trancher**, en cases à cocher : lisibilité de l'écran en rangée A (l'avatar de dos le cache-t-il ? décalage de 6 px ; repli : LED sur le haut du moniteur), taille des overlays à ×1 et en vue d'ensemble, palette (valeurs à ajuster à l'œil), orientation des rangées (décision 2), pas des postes (décision 3), police `PixelFont` ou Silkscreen (décision 6), force du voile de nuit (0,55) et des flaques de lumière, lisibilité des visages de la rangée B derrière les moniteurs ; **écarts à la proposition** (décisions 1 à 13, et chaque ligne « Écart : » des commits des tâches 4 à 7) ; défauts constatés. `docs/ASSETS.md` : journal de provenance (7.10) : chaque sprite est généré par le code de `Core/Sources/PixelCore/Assets` (fichier par groupe), aucune source externe, aucune image décalquée ; `PixelFont` originale ; Silkscreen et Pixelify Sans (OFL) prévues pour l'app, pas encore livrées ; mention « Pixel Open Space n'est ni affilié à Anthropic ni approuvé par Anthropic ; il lance l'outil Claude Code installé sur ta machine ».
- [ ] **Step 8: CI** : ajouter les trois étapes à `core.yml` (ne pas lancer de workflow).
- [ ] **Step 9: Run.** `cd Core && swift build && swift test` → vert ; `grep -rn "$(printf '\342\200\224')" docs/jalon-visuel docs/ASSETS.md Core/Sources Core/Tests` (motif : le tiret cadratin, écrit en octal pour ne pas l'écrire) → aucune ligne.
- [ ] **Step 10: Commit.** `git add Core docs/jalon-visuel docs/ASSETS.md .github/workflows/core.yml && git commit -m "Visual milestone: sprite-export, contact sheets, golden fingerprints and renders"`

---

## Rendu final

Depuis la racine du dépôt, une fois les 8 tâches fusionnées :

```bash
swift run --package-path Core -c release sprite-export --out "$PWD/docs/jalon-visuel"
```

Sortie : `docs/jalon-visuel/`, 15 PNG (`planche-0-palette.png` à `planche-6-apparences.png`, `ilot-x1-jour.png` à `ilot-x3-nuit.png`, `vue-ensemble-jour.png`, `vue-ensemble-nuit.png`), plus le `README.md` de la tâche 8. Contrôle : `cd Core && swift build && swift test`.

**Terminé quand** (section 8) : tu valides les images et tu tranches les questions du README. L'étape 3 ne commence qu'après.

## Hors de ce plan

Atlas et `manifest.json` (7.6), remplacement par tes PNG (7.7), `SpriteRegistry` et toute la partie SpriteKit (étape 3), habillage SwiftUI en 9-slice (7.4.6) et autres sprites hors v0 (décision 1), slot persistant des annexes, apparence automatique d'un nouvel agent, animations de transition jouées en direct (`walk`, `sitDown`, `celebrate`…), caméra, mini-carte interactive, sons. Ces éléments consommeront `SpriteCatalog`, `WorldLayout`, `AgentPresenter.scene` et `SceneCompositor` tels que définis ici.
