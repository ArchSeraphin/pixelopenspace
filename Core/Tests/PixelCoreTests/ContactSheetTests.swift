import Foundation
import Testing
@testable import PixelCore

@Suite struct ContactSheetTests {
    /// The seven pages at 1 pixel per texel, built once for the suite.
    static let pages = ContactSheet.pages(scale: 1)

    static func page(_ sheet: ContactSheet.Sheet) -> ContactSheet.Page { pages[sheet.rawValue] }

    /// The sheet of the default look, as the catalog holds it (hue 4, décision 12).
    static let defaultVariant = ResolvedLook(AgentLook(), projectHue: 4).variantName

    /// Every frame of every cell is drawn, opaque pixels unchanged, at its rect inside the page; `frames` gives the
    /// expected frames of a cell (nil: unknown sprite).
    static func drawingIssues(_ page: ContactSheet.Page, frames: (ContactSheet.Cell) -> [PixelImage]?) -> [String] {
        var issues: [String] = []
        let image = page.image
        for cell in page.cells {
            guard let expected = frames(cell) else {
                issues.append("\(cell.key.name): no such sprite")
                continue
            }
            guard expected.count == cell.frames.count else {
                issues.append("\(cell.key.name): \(cell.frames.count) frames shown, \(expected.count) expected")
                continue
            }
            for (index, (frame, rect)) in zip(expected, cell.frames).enumerated() {
                let name = cell.key.frameName(index)
                guard rect.width == frame.width, rect.height == frame.height else {
                    issues.append("\(name): rect \(rect.width)×\(rect.height), frame \(frame.width)×\(frame.height)")
                    continue
                }
                guard rect.x >= 0, rect.y >= 0, rect.x + rect.width <= image.width, rect.y + rect.height <= image.height
                else {
                    issues.append("\(name): outside the page")
                    continue
                }
                var drawn = true
                for y in 0..<frame.height where drawn {
                    for x in 0..<frame.width {
                        let p = frame[x, y]
                        if p.a != 0, image[rect.x + x, rect.y + y] != p {
                            drawn = false
                            break
                        }
                    }
                }
                if !drawn { issues.append("\(name): not drawn at its rect") }
            }
        }
        return issues
    }

    static func catalogFrames(_ cell: ContactSheet.Cell) -> [PixelImage]? {
        SpriteCatalog.sprite(cell.key)?.frames
    }

    @Test func sevenPagesInDeliverableOrder() {
        #expect(Self.pages.map(\.fileName) == [
            "planche-0-palette.png", "planche-1-sols-murs.png", "planche-2-mobilier-decor.png",
            "planche-3-ecrans-overlays.png", "planche-4-hud-texte.png", "planche-5-personnage.png",
            "planche-6-apparences.png",
        ])
        #expect(ContactSheet.Sheet.allCases.map(\.fileName) == Self.pages.map(\.fileName))
        #expect(Self.pages.map(\.title) == ContactSheet.Sheet.allCases.map(\.title))
        #expect(Self.pages.allSatisfy { $0.scale == 1 && $0.image.width > 0 && $0.image.height > 0 })
        #expect(Self.pages.allSatisfy { !$0.title.isEmpty && !$0.title.unicodeScalars.contains("\u{2014}") })
        #expect(ContactSheet.defaultScale == 4)
    }

    @Test func everyCatalogSpriteHasACell() {
        let spritePages: [(ContactSheet.Sheet, [SpriteCategory])] = [
            (.floorsWalls, [.floors, .walls]),
            (.furnitureDecor, [.furniture, .deskItems, .decor, .lights]),
            (.screensOverlays, [.monitors, .screens, .overlays, .effects]),
            (.hudText, [.hud]),
        ]
        for (sheet, categories) in spritePages {
            #expect(sheet.categories == categories)
            let page = Self.page(sheet)
            let expected = categories.flatMap { SpriteCatalog.sprites(in: $0) }.map(\.key)
            let shown = page.cells.map(\.key)
            #expect(shown.count == expected.count, "\(sheet): \(shown.count) cells for \(expected.count) sprites")
            #expect(Set(shown) == Set(expected), "\(sheet)")
            let issues = Self.drawingIssues(page, frames: Self.catalogFrames)
            #expect(issues.isEmpty, "\(sheet): \(issues.prefix(10))")
        }
        // Planches 1 to 4 show every category but the characters.
        #expect(Set(spritePages.flatMap(\.1)) == Set(SpriteCategory.allCases).subtracting([.characters]))

        // Planche 5: the full sheet of the default look, 184 frames.
        let character = Self.page(.character)
        #expect(character.cells.reduce(0) { $0 + $1.frames.count } == 184)
        let sheetKeys = SpriteCatalog.sprites(in: .characters).map(\.key).filter { $0.id != "agent.mini" }
        #expect(character.cells.count == sheetKeys.count && Set(character.cells.map(\.key)) == Set(sheetKeys))
        let characterIssues = Self.drawingIssues(character, frames: Self.catalogFrames)
        #expect(characterIssues.isEmpty, "\(characterIssues.prefix(10))")

        // Planche 6: each sample look seated (frame 0, SE and NE), then agent.mini in the 10 hues.
        let looks = Self.page(.looks)
        let lookKeys = CharacterSprites.sampleLooks.flatMap { look in
            [Facing.se, .ne].map {
                SpriteKey("agent.sitIdle", variant: ResolvedLook(look, projectHue: 4).variantName, facing: $0)
            }
        }
        let miniKeys = (0..<10).map { SpriteKey("agent.mini", variant: "hue\($0)") }
        #expect(looks.cells.map(\.key) == lookKeys + miniKeys)
        let lookIssues = Self.drawingIssues(looks) { cell in
            if cell.key.id == "agent.mini" { return Self.catalogFrames(cell) }
            guard let index = lookKeys.firstIndex(of: cell.key) else { return nil }
            let resolved = ResolvedLook(CharacterSprites.sampleLooks[index / 2], projectHue: 4)
            return CharacterSprites.canvas(.sitIdle, cell.key.facing!, frame: 0, look: resolved).map { [$0.render(resolved)] }
        }
        #expect(lookIssues.isEmpty, "\(lookIssues.prefix(10))")

        // The palette page shows colours, not sprites.
        #expect(Self.page(.palette).cells.isEmpty)
    }

    @Test func characterRowsFollowTheAnimations() {
        var expected: [SpriteKey] = []
        for animation in CharacterAnimation.allCases {
            for facing in [Facing.se, .sw, .ne, .nw] where animation.facings.contains(facing) {
                expected.append(SpriteKey(animation.spriteID, variant: Self.defaultVariant, facing: facing))
            }
        }
        #expect(Self.page(.character).cells.map(\.key) == expected)
        // One row per animation, top to bottom; the four directions of a row side by side, left to right.
        let cells = Self.page(.character).cells
        var previousRowTop = -1
        for animation in CharacterAnimation.allCases {
            let row = cells.filter { $0.key.id == animation.spriteID }
            let tops = Set(row.map { $0.frames[0].y })
            #expect(tops.count == 1, "\(animation): one row")
            #expect(row.map { $0.frames[0].x } == row.map { $0.frames[0].x }.sorted(), "\(animation): left to right")
            if let top = tops.first {
                #expect(top > previousRowTop, "\(animation): below the previous row")
                previousRowTop = top
            }
        }
    }

    @Test func cellsStayApart() {
        for page in Self.pages {
            let rects = page.cells.flatMap(\.frames)
            var overlaps = 0
            for (index, a) in rects.enumerated() {
                for b in rects[(index + 1)...] {
                    if a.x < b.x + b.width, b.x < a.x + a.width, a.y < b.y + b.height, b.y < a.y + a.height {
                        overlaps += 1
                    }
                }
            }
            #expect(overlaps == 0, "\(page.fileName): \(overlaps) overlapping frames")
        }
    }

    @Test func pagesAreOpaque() {
        for page in Self.pages {
            #expect(page.image.pixels.allSatisfy { $0.isOpaque }, "\(page.fileName)")
            #expect(page.image[0, page.image.height - 1] == Palette.color(.chalk), "\(page.fileName): chalk background")
        }
    }

    @Test func pagesAreDeterministic() {
        let again = ContactSheet.pages(scale: 1)
        #expect(again.map(\.image.fingerprint) == Self.pages.map(\.image.fingerprint))
        #expect(again.map(\.cells) == Self.pages.map(\.cells))
    }

    /// `big` is `small.scaled(by: factor)`, checked pixel by pixel without building the upscale (fast in debug).
    static func isUpscale(_ big: PixelImage, of small: PixelImage, by factor: Int) -> Bool {
        guard big.width == small.width * factor, big.height == small.height * factor else { return false }
        return big.pixels.withUnsafeBufferPointer { b in
            small.pixels.withUnsafeBufferPointer { s in
                for y in 0..<big.height {
                    let bigRow = y * big.width, smallRow = (y / factor) * small.width
                    for x in 0..<big.width where b[bigRow + x] != s[smallRow + x / factor] { return false }
                }
                return true
            }
        }
    }

    @Test func scaleIsExact() {
        let doubled = ContactSheet.pages(scale: 2)
        #expect(doubled.count == Self.pages.count)
        for (big, small) in zip(doubled, Self.pages) {
            #expect(big.scale == 2 && big.fileName == small.fileName)
            #expect(Self.isUpscale(big.image, of: small.image, by: 2), "\(small.fileName)")
            #expect(big.cells == small.cells, "\(small.fileName): cells stay in texels")
        }
        #expect(Self.isUpscale(ContactSheet.page(.palette, scale: 3).image, of: Self.page(.palette).image, by: 3))
        // The checker itself: a small image and its exact upscale.
        let small = Self.page(.looks).image
        #expect(Self.isUpscale(small.scaled(by: 2), of: small, by: 2))
        #expect(!Self.isUpscale(small.scaled(by: 2), of: Self.page(.palette).image, by: 2))
    }

    @Test func paletteSheetShowsEveryColor() {
        let colors = Set(Self.page(.palette).image.pixels)
        for role in PaletteRole.allCases {
            #expect(colors.contains(Palette.color(role)), "\(role)")
        }
        for tones in Palette.projectHues {
            #expect(colors.isSuperset(of: [tones.base, tones.light, tones.dark]), "\(tones.name)")
        }
        for derived in [Palette.nightVeil, Palette.uiFaceDark, Palette.uiTitleDark] {
            #expect(colors.contains(derived), "\(derived.hexString)")
        }
        #expect(colors.isSuperset(of: Palette.keyColors), "key colours, marked never in a sprite")
        // Shadow on floorLight; the lamp's pool as the scenes draw it (the solid middle of `light.cone`, added at
        // 35 % on the desk top), by day and under the veil, with the compositor's own arithmetic.
        let floor = Palette.color(.floorLight), deskTop = ContactSheet.poolGround
        #expect(deskTop == Palette.color(.woodLight))
        let cone = SpriteCatalog.sprite(SpriteKey("light.cone"))!
        let warm = cone.frames[0][cone.anchor.x, cone.anchor.y]
        #expect(warm == Palette.color(.alertOrange))
        var shadow = PixelImage(width: 1, height: 1, fill: floor)
        shadow.composite(PixelImage(width: 1, height: 1, fill: Palette.color(.ink)), alpha: Palette.shadowAlpha)
        var pool = PixelImage(width: 1, height: 1, fill: deskTop)
        pool.add(PixelImage(width: 1, height: 1, fill: warm), alpha: Palette.lightPoolAlpha)
        var veil = PixelImage(width: 1, height: 1, fill: deskTop)
        veil.multiply(by: Palette.nightVeil, alpha: Palette.nightVeilAlpha)
        var nightPool = veil
        nightPool.add(PixelImage(width: 1, height: 1, fill: warm), alpha: Palette.lightPoolAlpha)
        for sample in [shadow, pool, veil, nightPool] {
            #expect(colors.contains(sample[0, 0]), "\(sample[0, 0].hexString)")
        }
        // The pool stays warm under the veil: more red than blue (lampWarm turned grey mauve).
        #expect(nightPool[0, 0].r > nightPool[0, 0].b + 40)
    }

    /// Light sprites go on a dark checkerboard (slate / shade): on paper / mist the floor markings, the stars, the
    /// dust and the dropped pin all but vanished on the first render.
    @Test func lightSpritesSitOnADarkCheckerboard() {
        func frames(_ key: SpriteKey) -> [PixelImage] { SpriteCatalog.sprite(key)!.frames }
        let light = [SpriteKey("floor.dropTarget"), SpriteKey("floor.hover"), SpriteKey("fx.star", variant: "small"),
                     SpriteKey("fx.star", variant: "big"), SpriteKey("fx.dust"), SpriteKey("fx.pinDrop"),
                     SpriteKey("floor.hall", variant: "n0"), SpriteKey("floor.corridor", variant: "n0"),
                     SpriteKey("desk.postit", variant: "paper"), SpriteKey("minimap.dot.idle")]
        for key in light { #expect(ContactSheet.needsDarkChecker(frames(key)), "\(key.name)") }
        // Outlined in ink or drawn in saturated colours: they read on the light checkerboard and stay there.
        let kept = [SpriteKey("ov.bang"), SpriteKey("ov.bang.halo"), SpriteKey("ov.tool.edit"), SpriteKey("ov.selection"),
                    SpriteKey("floor.carpet", variant: "hue1.plain"), SpriteKey("floor.carpet", variant: "hue2.plain"),
                    SpriteKey("desk.postit", variant: "hue1"), SpriteKey("desk", variant: "light", facing: .ne),
                    SpriteKey("shadow.tile"), SpriteKey("light.cone"), SpriteKey("fx.ding")]
        for key in kept { #expect(!ContactSheet.needsDarkChecker(frames(key)), "\(key.name)") }
        #expect(!ContactSheet.needsDarkChecker([PixelImage(width: 4, height: 4)]), "nothing opaque")

        // On the pages, every frame sits on the checkerboard its sprite asks for: the tile's top-left square, one
        // texel up and left of the frame, is slate on the dark one and paper on the light one.
        let pad = ContactSheet.Layout.framePad
        var dark = 0
        for sheet in [ContactSheet.Sheet.floorsWalls, .furnitureDecor, .screensOverlays, .hudText, .character, .looks] {
            let page = Self.page(sheet)
            for cell in page.cells {
                let shown = Self.catalogFrames(cell) ?? []
                let expected = ContactSheet.needsDarkChecker(shown) ? Palette.color(.slate) : Palette.color(.paper)
                if expected == Palette.color(.slate) { dark += 1 }
                for rect in cell.frames {
                    #expect(page.image[rect.x - pad, rect.y - pad] == expected, "\(sheet) \(cell.key.name)")
                }
            }
        }
        #expect(dark >= light.count, "\(dark) cells on the dark checkerboard")

        // And there they stand out: their opaque pixels are farther, in luma, from the dark squares than from the
        // light ones.
        func distance(_ frames: [PixelImage], _ squares: [RGBA8]) -> Double {
            var sum = 0.0, count = 0
            for frame in frames {
                for p in frame.pixels where p.a != 0 {
                    sum += squares.map { abs(Double(p.luma) - Double($0.luma)) }.min()!
                    count += 1
                }
            }
            return sum / Double(count)
        }
        let lightSquares = [Palette.color(.paper), Palette.color(.mist)]
        let darkSquares = [Palette.color(.slate), Palette.color(.shade)]
        for key in light {
            #expect(distance(frames(key), darkSquares) > 2 * distance(frames(key), lightSquares), "\(key.name)")
        }
    }

    @Test func fontSpecimenCoversEveryGlyphAndName() {
        let specimen = ContactSheet.specimenLines.joined(separator: " ")
        let shown = Set(PixelFont.normalized(specimen))
        let missing = PixelFont.supportedCharacters.subtracting(shown).subtracting([" "])
        #expect(missing.isEmpty, "\(missing.sorted())")
        let upper = specimen.uppercased()
        for name in NameGenerator.names {
            #expect(upper.contains(name.uppercased()), "\(name)")
        }
        #expect(!specimen.unicodeScalars.contains("\u{2014}"))
    }
}
