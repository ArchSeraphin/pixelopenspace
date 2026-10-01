import Foundation

/// The contact sheets of the visual milestone (section 8, 7.5): the palette, every v0 sprite of the catalog with its
/// key, size and cadence, the pixel font and the labels, the full sheet of the default character and the sample
/// looks. Each frame sits on a light checkerboard (paper / mist, 4×4 texels) that shows its transparency.
///
/// A page is composed at 1 pixel per texel, then scaled by a whole factor at the very end: `page(s, scale: k)` is
/// exactly `page(s, scale: 1)` upscaled to the nearest neighbour, and its cells keep their texel rects. Pure and
/// deterministic: everything is laid out in catalog order, never in a dictionary's.
public enum ContactSheet {
    /// The milestone's sheets are exported at 4 pixels per texel.
    public static let defaultScale = 4

    /// The seven sheets, in the order of the deliverable (`planche-0` … `planche-6`).
    public enum Sheet: Int, CaseIterable, Sendable {
        case palette, floorsWalls, furnitureDecor, screensOverlays, hudText, character, looks

        public var fileName: String {
            switch self {
            case .palette: return "planche-0-palette.png"
            case .floorsWalls: return "planche-1-sols-murs.png"
            case .furnitureDecor: return "planche-2-mobilier-decor.png"
            case .screensOverlays: return "planche-3-ecrans-overlays.png"
            case .hudText: return "planche-4-hud-texte.png"
            case .character: return "planche-5-personnage.png"
            case .looks: return "planche-6-apparences.png"
            }
        }

        /// French, shown in the title band of the page.
        public var title: String {
            switch self {
            case .palette: return "Planche 0 : palette"
            case .floorsWalls: return "Planche 1 : sols et murs"
            case .furnitureDecor: return "Planche 2 : mobilier, objets, décor et lumières"
            case .screensOverlays: return "Planche 3 : moniteurs, écrans, overlays et effets"
            case .hudText: return "Planche 4 : HUD et texte"
            case .character: return "Planche 5 : personnage"
            case .looks: return "Planche 6 : apparences"
            }
        }

        /// The catalog categories shown one cell per sprite; empty for the palette, the character and the looks,
        /// which have their own layouts.
        public var categories: [SpriteCategory] {
            switch self {
            case .floorsWalls: return [.floors, .walls]
            case .furnitureDecor: return [.furniture, .deskItems, .decor, .lights]
            case .screensOverlays: return [.monitors, .screens, .overlays, .effects]
            case .hudText: return [.hud]
            case .palette, .character, .looks: return []
            }
        }
    }

    /// One sprite shown on a page: its key and where each of its frames is drawn.
    public struct Cell: Hashable, Sendable {
        public let key: SpriteKey
        /// In page texels (multiply by `Page.scale` for image pixels), frame 0 first.
        public let frames: [PixelRect]

        public init(key: SpriteKey, frames: [PixelRect]) {
            self.key = key
            self.frames = frames
        }

        func offset(by point: PixelPoint) -> Cell {
            Cell(key: key, frames: frames.map {
                PixelRect(x: $0.x + point.x, y: $0.y + point.y, width: $0.width, height: $0.height)
            })
        }
    }

    public struct Page: Sendable {
        public let fileName: String
        public let title: String
        /// Pixels per texel of `image`.
        public let scale: Int
        public let image: PixelImage
        /// The sprites shown, in drawing order (none on the palette page).
        public let cells: [Cell]
    }

    /// planche-0 … planche-6.
    public static func pages(scale: Int = defaultScale) -> [Page] {
        Sheet.allCases.map { page($0, scale: scale) }
    }

    /// One page (the export builds them one at a time). Precondition: scale ≥ 1.
    public static func page(_ sheet: Sheet, scale: Int = defaultScale) -> Page {
        precondition(scale >= 1, "scale must be at least 1")
        let body: Block
        switch sheet {
        case .palette: body = paletteBody()
        case .floorsWalls, .furnitureDecor, .screensOverlays: body = spriteBody(sheet.categories)
        case .hudText:
            body = .column([spriteBody(sheet.categories), fontSection(), labelSection()], spacing: Layout.sectionSpacing)
        case .character: body = characterBody()
        case .looks: body = looksBody()
        }
        let page = framed(body, title: sheet.title)
        return Page(fileName: sheet.fileName, title: sheet.title, scale: scale, image: page.image.scaled(by: scale),
                    cells: page.cells)
    }

    /// The hue of the catalog's character sheet and of the looks page (`CharacterSprites.catalogDefs`, décision 12).
    static let characterHue = 4

    /// The PixelFont specimen of planche 4: every glyph, then every name of `NameGenerator`.
    static let specimenLines: [String] = {
        var lines = [
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "ÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŒ",
            "0123456789",
            ". , : ; ! ? ' \" - + / ( ) # % @ ~ _ < > = · … ×",
        ]
        let names = NameGenerator.names
        for start in stride(from: 0, to: names.count, by: 10) {
            lines.append(names[start..<min(start + 10, names.count)].joined(separator: "  "))
        }
        return lines
    }()

    // MARK: Layout

    enum Layout {
        static let margin = 8
        /// Width of the flows of cells and groups (texels).
        static let contentWidth = 768
        static let sectionSpacing = 18
        static let groupSpacing = 14
        static let groupLineSpacing = 10
        static let cellSpacing = 6
        static let cellLineSpacing = 6
        /// Checkerboard around each frame, and blank page between two frames of a sprite.
        static let framePad = 1
        static let frameGap = 2
        static let checkerSize = 4
        /// A cell's label may wrap at this width even under a narrower sprite.
        static let minLabelWidth = 64
    }

    enum Ink {
        static let background = Palette.color(.chalk)
        static let titleBand = Palette.color(.uiTitle)
        static let titleText = Palette.color(.chalk)
        static let heading = Palette.color(.ink)
        static let rule = Palette.color(.mist)
        static let detail = Palette.color(.slate)
        static let mirror = Palette.color(.uiTitle)
        static let warning = Palette.color(.errorRed)
        static let checkerLight = Palette.color(.paper)
        static let checkerDark = Palette.color(.mist)
    }

    /// An image placed in a block.
    struct Draw {
        var image: PixelImage
        var origin: PixelPoint
    }

    /// A piece of a page: images placed in a width × height box, drawn in order (later ones on top), and the cells
    /// shown in it. Composition only moves the draws; `rendered` rasterizes them once, at the end.
    struct Block {
        var width: Int
        var height: Int
        var draws: [Draw]
        var cells: [Cell] = []

        init(image: PixelImage) {
            width = image.width
            height = image.height
            draws = [Draw(image: image, origin: PixelPoint(0, 0))]
        }

        init(width: Int, height: Int, draws: [Draw], cells: [Cell]) {
            self.width = width
            self.height = height
            self.draws = draws
            self.cells = cells
        }

        static let empty = Block(image: PixelImage(width: 0, height: 0))

        /// The blocks at their origins, in one box that holds them all.
        static func placed(_ items: [(block: Block, origin: PixelPoint)]) -> Block {
            let width = items.map { $0.origin.x + $0.block.width }.max() ?? 0
            let height = items.map { $0.origin.y + $0.block.height }.max() ?? 0
            var draws: [Draw] = []
            var cells: [Cell] = []
            for (block, origin) in items {
                draws += block.draws.map {
                    Draw(image: $0.image, origin: PixelPoint($0.origin.x + origin.x, $0.origin.y + origin.y))
                }
                cells += block.cells.map { $0.offset(by: origin) }
            }
            return Block(width: max(width, 0), height: max(height, 0), draws: draws, cells: cells)
        }

        /// The draws on a `width` × `height` image filled with `background`.
        func rendered(width: Int, height: Int, background: RGBA8) -> PixelImage {
            var image = PixelImage(width: width, height: height, fill: background)
            for draw in draws { image.blit(draw.image, x: draw.origin.x, y: draw.origin.y) }
            return image
        }

        /// One under the other, aligned left.
        static func column(_ blocks: [Block], spacing: Int) -> Block {
            var y = 0
            var items: [(block: Block, origin: PixelPoint)] = []
            for block in blocks where block.height > 0 {
                items.append((block, PixelPoint(0, y)))
                y += block.height + spacing
            }
            return placed(items)
        }

        /// Side by side, aligned top.
        static func row(_ blocks: [Block], spacing: Int) -> Block {
            var x = 0
            var items: [(block: Block, origin: PixelPoint)] = []
            for block in blocks where block.width > 0 {
                items.append((block, PixelPoint(x, 0)))
                x += block.width + spacing
            }
            return placed(items)
        }

        /// Left to right, wrapping before a block that would cross `width`; lines aligned top.
        static func flow(_ blocks: [Block], width: Int, spacing: Int, lineSpacing: Int) -> Block {
            var items: [(block: Block, origin: PixelPoint)] = []
            var x = 0, y = 0, lineHeight = 0
            for block in blocks where block.width > 0 {
                if x > 0, x + block.width > width {
                    x = 0
                    y += lineHeight + lineSpacing
                    lineHeight = 0
                }
                items.append((block, PixelPoint(x, y)))
                x += block.width + spacing
                lineHeight = max(lineHeight, block.height)
            }
            return placed(items)
        }

        /// Columns of equal width (the widest block) and rows of equal height, row-major.
        static func grid(_ blocks: [Block], columns: Int, spacing: Int, lineSpacing: Int) -> Block {
            let columnWidth = blocks.map(\.width).max() ?? 0
            let rowHeight = blocks.map(\.height).max() ?? 0
            let items = blocks.enumerated().map { index, block in
                (block: block, origin: PixelPoint((index % columns) * (columnWidth + spacing),
                                                 (index / columns) * (rowHeight + lineSpacing)))
            }
            return placed(items)
        }
    }

    // MARK: Text and frames

    /// One line of PixelFont, `size` times larger.
    static func text(_ string: String, _ color: RGBA8, size: Int = 1) -> Block {
        let image = PixelFont.render(string, color: color)
        return Block(image: size == 1 ? image : image.scaled(by: size))
    }

    static func lines(_ strings: [String], _ color: RGBA8) -> Block {
        .column(strings.map { text($0, color) }, spacing: 1)
    }

    /// A section: its title twice as large, a rule under it, then the body.
    static func section(_ title: String, _ body: Block, note: [String] = []) -> Block {
        let heading = text(title, Ink.heading, size: 2)
        let width = max(Layout.contentWidth, body.width, heading.width)
        let rule = Block(image: PixelImage(width: width, height: 1, fill: Ink.rule))
        let notes = note.isEmpty ? Block.empty : lines(note, Ink.detail)
        return .column([.column([heading, rule], spacing: 2), notes, body], spacing: 6)
    }

    /// paper / mist squares of `Layout.checkerSize` texels, paper in the top-left corner.
    static func checkerboard(width: Int, height: Int) -> PixelImage {
        let size = Layout.checkerSize
        let rows = [0, 1].map { phase in
            (0..<width).map { (($0 / size + phase) % 2 == 0) ? Ink.checkerLight : Ink.checkerDark }
        }
        var pixels: [RGBA8] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height { pixels += rows[(y / size) % 2] }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    /// Each frame on its own checkerboard tile, the tiles side by side; one cell per entry.
    static func frames(_ entries: [(key: SpriteKey?, frames: [PixelImage])]) -> Block {
        let pad = Layout.framePad
        var x = 0
        var items: [(block: Block, origin: PixelPoint)] = []
        var cells: [Cell] = []
        for entry in entries {
            var rects: [PixelRect] = []
            for frame in entry.frames {
                var tile = checkerboard(width: frame.width + 2 * pad, height: frame.height + 2 * pad)
                tile.blit(frame, x: pad, y: pad)
                items.append((Block(image: tile), PixelPoint(x, 0)))
                rects.append(PixelRect(x: x + pad, y: pad, width: frame.width, height: frame.height))
                x += tile.width + Layout.frameGap
            }
            if let key = entry.key { cells.append(Cell(key: key, frames: rects)) }
        }
        var block = Block.placed(items)
        block.cells = cells
        return block
    }

    /// The pieces a key may wrap at: after ".", before "~" and "@".
    static func wrapPieces(_ string: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in string {
            if character == "~" || character == "@", !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current.append(character)
            if character == "." {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Greedy wrap at `wrapPieces`; a piece wider than `width` keeps its own line.
    static func wrapped(_ string: String, width: Int) -> [String] {
        var out: [String] = []
        var line = ""
        for piece in wrapPieces(string) {
            if !line.isEmpty, PixelFont.width(of: line + piece) > width {
                out.append(line)
                line = piece
            } else {
                line += piece
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    /// "12", "1,5": frames per second of a hold, with a French decimal comma.
    static func fps(hold: Int) -> String {
        let ticks = AnimationClock.ticksPerSecond
        guard hold > 0 else { return "?" }
        if ticks % hold == 0 { return "\(ticks / hold)" }
        let tenths = (ticks * 10 + hold / 2) / hold
        return "\(tenths / 10),\(tenths % 10)"
    }

    /// "1 IMAGE", "4 × 8 FPS", "3 × 12 FPS · UNE FOIS".
    static func cadence(frames: Int, holds: [Int], loops: Bool) -> String {
        guard frames > 1 else { return "1 IMAGE" }
        var out: String
        if let hold = holds.first, holds.count == frames, holds.allSatisfy({ $0 == hold }) {
            out = "\(frames) × \(fps(hold: hold)) FPS"
        } else {
            out = "\(frames) IMAGES"
        }
        if !loops { out += " · UNE FOIS" }
        return out
    }

    static func derivationLabel(_ derivation: Derivation?) -> String? {
        switch derivation {
        case .mirror: return "MIROIR"
        case .mirrorReshaded: return "MIROIR RÉ-OMBRÉ"
        case nil: return nil
        }
    }

    /// The frames of a sprite, its label under them (what its group header leaves out of the key) and "MIROIR"
    /// for a derived sprite; `extra` lines go last.
    static func spriteCell(_ def: SpriteDef, labelPrefix: String = "", extra: [String] = []) -> Block {
        let shown = frames([(def.key, def.frames)])
        var label = labelPrefix
        if let variant = def.key.variant { label += "~" + variant }
        if let facing = def.key.facing { label += "@" + facing.rawValue }
        var parts = [shown]
        let labelLines = wrapped(label, width: max(shown.width, Layout.minLabelWidth))
        if !labelLines.isEmpty { parts.append(lines(labelLines, Ink.detail)) }
        if let mirror = derivationLabel(def.derivation) { parts.append(text(mirror, Ink.mirror)) }
        if !extra.isEmpty { parts.append(lines(extra, Ink.detail)) }
        return .column(parts, spacing: 2)
    }

    // MARK: Sprite pages (planches 1 to 4)

    /// Ids drawn as one family: the header names the family ("ov.tool.<nom>"), each cell its last component.
    static let familyPrefixes = ["hud.state.", "minimap.dot.", "ov.tool."]

    static func family(of id: SpriteID) -> (header: String, suffix: String) {
        for prefix in familyPrefixes where id.rawValue.hasPrefix(prefix) {
            return (prefix + "<nom>", String(id.rawValue.dropFirst(prefix.count)))
        }
        return (id.rawValue, "")
    }

    /// Consecutive sprites (catalog order) of one family with the same size, anchor and timing.
    static func groups(_ defs: [SpriteDef]) -> [[SpriteDef]] {
        func sameGroup(_ a: SpriteDef, _ b: SpriteDef) -> Bool {
            family(of: a.key.id).header == family(of: b.key.id).header && a.width == b.width && a.height == b.height
                && a.anchor == b.anchor && a.frames.count == b.frames.count && a.holds == b.holds && a.loops == b.loops
        }
        var out: [[SpriteDef]] = []
        for def in defs {
            if let last = out.last?.last, sameGroup(last, def) {
                out[out.count - 1].append(def)
            } else {
                out.append([def])
            }
        }
        return out
    }

    /// Header (id, size and cadence, anchor), then the cells.
    static func groupBlock(_ defs: [SpriteDef]) -> Block {
        let first = defs[0]
        let header = lines([
            "\(first.width)×\(first.height) · " + cadence(frames: first.frames.count, holds: first.holds, loops: first.loops),
            "ANCRE \(first.anchor.x),\(first.anchor.y)",
        ], Ink.detail)
        let title = text(family(of: first.key.id).header, Ink.heading)
        let cells = defs.map { spriteCell($0, labelPrefix: family(of: $0.key.id).suffix) }
        let body = Block.flow(cells, width: Layout.contentWidth, spacing: Layout.cellSpacing,
                              lineSpacing: Layout.cellLineSpacing)
        return .column([.column([title, header], spacing: 1), body], spacing: 3)
    }

    static func categoryTitle(_ category: SpriteCategory) -> String {
        switch category {
        case .floors: return "Sols et marquages"
        case .walls: return "Murs et structure"
        case .furniture: return "Mobilier"
        case .deskItems: return "Objets du bureau"
        case .decor: return "Décor"
        case .lights: return "Ombres et lumières"
        case .monitors: return "Moniteurs"
        case .screens: return "Écrans"
        case .overlays: return "Overlays d'état"
        case .effects: return "Effets"
        case .hud: return "HUD et étiquettes"
        case .characters: return "Personnages"
        }
    }

    static func spriteBody(_ categories: [SpriteCategory]) -> Block {
        .column(categories.map { category in
            let defs = SpriteCatalog.sprites(in: category)
            let frameCount = defs.reduce(0) { $0 + $1.frames.count }
            let groups = groups(defs).map(groupBlock)
            let body = Block.flow(groups, width: Layout.contentWidth, spacing: Layout.groupSpacing,
                                  lineSpacing: Layout.groupLineSpacing)
            return section("\(categoryTitle(category)) · \(defs.count) sprites, \(frameCount) images", body)
        }, spacing: Layout.sectionSpacing)
    }

    // MARK: Planche 4: font and labels

    static func fontSection() -> Block {
        let glyphs = lines(Array(specimenLines.prefix(4)), Ink.heading)
        let names = lines(Array(specimenLines.dropFirst(4)), Ink.heading)
        let outlined = Block(image: PixelFont.render("NOVA · ZÉPHYR · PÉPIN · ÉCUME", color: Palette.color(.chalk),
                                                     outline: Palette.color(.ink)))
        let body = Block.column([
            glyphs,
            .column([text("Les \(NameGenerator.names.count) noms de NameGenerator :", Ink.detail), names], spacing: 3),
            .column([text("Chalk avec contour ink (texte dans la scène) :", Ink.detail), outlined], spacing: 3),
        ], spacing: 10)
        return section("Police PixelFont (originale) · capitales de 5 px, accents au-dessus", body, note: [
            "Le cœur la dessine sans CoreText (décision 6) ; les minuscules s'affichent en capitales, "
                + "un caractère inconnu en \"?\".",
        ])
    }

    /// Island signs and desk name plates, as the scene composes them.
    static func labelSection() -> Block {
        let signs: [(name: String, hue: Int)] = [("API", 4), ("SITE WEB", 0), ("DOCUMENTATION", 2)]
        let signBlocks = signs.map { sign in
            Block.column([
                frames([(nil, [HUDSprites.sign(name: sign.name, hue: sign.hue)])]),
                lines(["\"\(sign.name)\"", "P\(sign.hue) \(Palette.hue(sign.hue).name)"], Ink.detail),
            ], spacing: 2)
        }
        let plates: [(text: String, off: Bool)] = [("NOVA", false), ("ZÉPHYR", false), ("OFF", true)]
        let plateBlocks = plates.map { plate in
            Block.column([
                frames([(nil, [HUDSprites.nameplate(plate.text, off: plate.off)])]),
                text(plate.off ? "\"\(plate.text)\" (HORS LIGNE)" : "\"\(plate.text)\"", Ink.detail),
            ], spacing: 2)
        }
        let body = Block.row([
            .column([text("Pancartes d'îlot (10 caractères au plus)", Ink.heading),
                     .row(signBlocks, spacing: Layout.groupSpacing)], spacing: 4),
            .column([text("Plaques de nom (9-slice)", Ink.heading),
                     .row(plateBlocks, spacing: Layout.groupSpacing)], spacing: 4),
        ], spacing: 3 * Layout.groupSpacing)
        return section("Étiquettes composées", body)
    }

    // MARK: Planche 5: the full sheet of the default look

    static func characterBody() -> Block {
        let resolved = ResolvedLook(AgentLook(), projectHue: characterHue)
        let directions: [Facing] = [.se, .sw, .ne, .nw]
        var rows: [Block] = []
        var frameCount = 0
        for animation in CharacterAnimation.allCases {
            var cells: [Block] = []
            for facing in directions {
                let key = SpriteKey(animation.spriteID, variant: resolved.variantName, facing: facing)
                guard let def = SpriteCatalog.sprite(key) else { continue }
                frameCount += def.frames.count
                var label = ["@" + facing.rawValue]
                if let mirror = derivationLabel(def.derivation) { label.append(mirror) }
                cells.append(.column([frames([(def.key, def.frames)]), lines(label, Ink.detail)], spacing: 2))
            }
            let header = "\(animation.rawValue) · "
                + cadence(frames: animation.framesPerFacing, holds: animation.holds, loops: animation.loops)
            rows.append(.column([text(header, Ink.heading), .row(cells, spacing: Layout.groupSpacing)], spacing: 3))
        }
        let hue = Palette.hue(characterHue)
        return section("AgentLook() par défaut · \(frameCount) images", .column(rows, spacing: 8), note: [
            "Variante ~\(resolved.variantName) : haut à la teinte du projet (P\(characterHue) \(hue.name)). "
                + "\(CharacterSprites.frameWidth)×\(CharacterSprites.frameHeight), ancre "
                + "\(CharacterSprites.anchor.x),\(CharacterSprites.anchor.y) entre les pieds.",
            "SE et NE dessinés ; SW et NW : miroirs ré-ombrés (lumière en haut à gauche). Image 0 : pose clé.",
        ])
    }

    // MARK: Planche 6: looks and minis

    static let accessoryNames = ["sans accessoire", "lunettes", "casque", "bonnet"]

    static func looksBody() -> Block {
        let lookCells = CharacterSprites.sampleLooks.map { look -> Block in
            let resolved = ResolvedLook(look, projectHue: characterHue)
            let entries: [(key: SpriteKey?, frames: [PixelImage])] = [Facing.se, .ne].map { facing in
                let frame = CharacterSprites.canvas(.sitIdle, facing, frame: 0, look: resolved)?.render(resolved)
                return (SpriteKey(CharacterAnimation.sitIdle.spriteID, variant: resolved.variantName, facing: facing),
                        frame.map { [$0] } ?? [])
            }
            let shown = frames(entries)
            let label = wrapped("~" + resolved.variantName, width: max(shown.width, Layout.minLabelWidth))
            return .column([shown, lines(label + [accessoryNames[resolved.accessory]], Ink.detail)], spacing: 2)
        }
        let looks = section(
            "\(CharacterSprites.sampleLooks.count) apparences · sitIdle, image 0, @se et @ne",
            .flow(lookCells, width: Layout.contentWidth, spacing: Layout.cellSpacing + 4,
                  lineSpacing: Layout.cellLineSpacing),
            note: ["s peau · h coupe · c cheveux · o haut (p : teinte de projet) · a accessoire"])
        let minis = SpriteCatalog.sprites(in: .characters).filter { $0.key.id == "agent.mini" }
        let miniCells = minis.map { def -> Block in
            let hue = Int(def.key.variant?.dropFirst(3) ?? "") ?? 0
            return spriteCell(def, extra: [Palette.hue(hue).name])
        }
        let miniTitle = minis.first.map {
            "agent.mini · \($0.width)×\($0.height) · " + cadence(frames: $0.frames.count, holds: $0.holds, loops: $0.loops)
        } ?? "agent.mini"
        let miniSection = section(miniTitle, .flow(miniCells, width: Layout.contentWidth, spacing: Layout.cellSpacing,
                                                   lineSpacing: Layout.cellLineSpacing))
        return .column([looks, miniSection], spacing: Layout.sectionSpacing)
    }

    // MARK: Planche 0: palette

    /// `image` inside a 1-texel ink border.
    static func bordered(_ image: PixelImage) -> PixelImage {
        var out = PixelImage(width: image.width + 2, height: image.height + 2, fill: Palette.color(.ink))
        out.fill(PixelRect(x: 1, y: 1, width: image.width, height: image.height), .clear)
        out.blit(image, x: 1, y: 1)
        return out
    }

    /// A colour swatch with its ink border, width × height in all.
    static func swatch(_ color: RGBA8, width: Int = 24, height: Int = 14) -> Block {
        Block(image: bordered(PixelImage(width: width - 2, height: height - 2, fill: color)))
    }

    /// Swatch, then its name and hexadecimal value; `warning` adds a red line.
    static func colorEntry(_ color: RGBA8, name: String, warning: String? = nil) -> Block {
        var details = [text(name, Ink.heading), text(color.hexString, Ink.detail)]
        if let warning { details.append(text(warning, Ink.warning)) }
        return .row([swatch(color), .column(details, spacing: 1)], spacing: 4)
    }

    static func paletteBody() -> Block {
        let roles = PaletteRole.allCases.enumerated().map { index, role in
            colorEntry(Palette.color(role), name: "\(index + 1) \(role.rawValue)")
        }
        let rolesSection = section("32 couleurs de base", .grid(roles, columns: 4, spacing: 12, lineSpacing: 6), note: [
            "alertYellow est réservé à l'attente (\"!\", halo, écran qui clignote) ; au plus 12 couleurs par sprite, "
                + "hors contours et ombre.",
        ])

        let hues = Palette.projectHues.enumerated().map { index, tones -> Block in
            let columns = [("clair", tones.light), ("base", tones.base), ("sombre", tones.dark)].map { name, color in
                Block.column([swatch(color, width: 32), text(name, Ink.detail), text(color.hexString, Ink.detail)],
                             spacing: 1)
            }
            return .column([text("P\(index) \(tones.name)", Ink.heading), .row(columns, spacing: 3)], spacing: 2)
        }
        let huesSection = section("10 teintes de projet", .grid(hues, columns: 5, spacing: 14, lineSpacing: 8), note: [
            "clair = mix(base, chalk, 0,45) ; sombre = mix(base, ink, 0,45), contour des objets de la teinte.",
        ])

        let light = lightSamples()
        let derived = [
            colorEntry(Palette.nightVeil, name: "nightVeil"),
            colorEntry(Palette.uiFaceDark, name: "uiFaceDark"),
            colorEntry(Palette.uiTitleDark, name: "uiTitleDark"),
        ]
        let keys = [(Palette.keyBase, "keyBase"), (Palette.keyLight, "keyLight"), (Palette.keyDark, "keyDark")].map {
            colorEntry($0.0, name: $0.1, warning: "jamais dans un sprite")
        }
        let derivedSection = section("Couleurs dérivées", .column([
            .row(derived, spacing: 16),
            .column([text("Couleurs clés des PNG de remplacement (7.7) :", Ink.heading), .row(keys, spacing: 16)],
                    spacing: 4),
        ], spacing: 10))
        return .column([rolesSection, huesSection, light, derivedSection], spacing: Layout.sectionSpacing)
    }

    /// Shadow, light pool and night veil on floorLight, with the compositor's own arithmetic.
    static func lightSamples() -> Block {
        let floor = Palette.color(.floorLight), ink = Palette.color(.ink), lamp = Palette.color(.lampWarm)
        let (width, height) = (64, 32)
        func panel(_ build: (inout PixelImage) -> Void) -> PixelImage {
            var image = PixelImage(width: width, height: height, fill: floor)
            build(&image)
            return image
        }
        func layer(_ rects: [PixelRect], _ color: RGBA8) -> PixelImage {
            var image = PixelImage(width: width, height: height)
            for rect in rects { image.fill(rect, color) }
            return image
        }
        let first = PixelRect(x: 8, y: 6, width: 28, height: 14), second = PixelRect(x: 26, y: 12, width: 28, height: 14)
        let pool = PixelRect(x: 16, y: 8, width: 32, height: 16)
        let shadow = panel { $0.composite(layer([first, second], ink), alpha: Palette.shadowAlpha) }
        let lit = panel { $0.add(layer([pool], lamp), alpha: Palette.lightPoolAlpha) }
        func night(_ alpha: UInt8) -> PixelImage {
            panel {
                $0.multiply(by: Palette.nightVeil, alpha: alpha)
                $0.add(layer([pool], lamp), alpha: Palette.lightPoolAlpha)
            }
        }
        let nightFull = night(Palette.nightVeilAlpha), nightReduced = night(Palette.nightVeilAlphaReduced)
        let samples: [(PixelImage, [String])] = [
            (shadow, ["Ombre : ink à 30 %, une seule fois", "(deux ombres qui se chevauchent)",
                      shadow[10, 8].hexString]),
            (lit, ["Flaque : lampWarm à 35 %, additive", lit[width / 2, height / 2].hexString]),
            (nightFull, ["Nuit : voile nightVeil à 55 %", "et flaque d'une lampe",
                         "\(nightFull[2, 2].hexString) / \(nightFull[width / 2, height / 2].hexString)"]),
            (nightReduced, ["Voile réduit à 35 %", "(Réduire la transparence)",
                            "\(nightReduced[2, 2].hexString) / \(nightReduced[width / 2, height / 2].hexString)"]),
        ]
        let blocks = samples.map { image, label in
            Block.column([Block(image: bordered(image)), lines(label, Ink.detail)], spacing: 2)
        }
        return section("Ombre, flaque de lumière et voile de nuit sur floorLight",
                       .row(blocks, spacing: 2 * Layout.groupSpacing))
    }

    // MARK: Page

    /// The title band, a subtitle, the body; margins all around, on chalk.
    static func framed(_ body: Block, title: String) -> (image: PixelImage, cells: [Cell]) {
        let margin = Layout.margin
        let heading = text(title, Ink.titleText, size: 2)
        let subtitle = text("Pixel Open Space · jalon visuel · sprites v0 générés par le code, aucune image "
                            + "externe · damier paper / mist = transparence", Ink.detail)
        let width = max(body.width, heading.width, subtitle.width) + 2 * margin
        let bandHeight = heading.height + 2 * 5
        let content = Block.placed([
            (Block(image: PixelImage(width: width, height: bandHeight, fill: Ink.titleBand)), PixelPoint(0, 0)),
            (heading, PixelPoint(margin, 5)),
            (subtitle, PixelPoint(margin, bandHeight + 6)),
            (body, PixelPoint(margin, bandHeight + 6 + subtitle.height + 12)),
        ])
        return (content.rendered(width: width, height: content.height + margin, background: Ink.background),
                content.cells)
    }
}
