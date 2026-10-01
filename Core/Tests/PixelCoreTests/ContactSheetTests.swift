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
        // Shadow and light pool on floorLight, with the compositor's own arithmetic.
        let floor = Palette.color(.floorLight)
        var shadow = PixelImage(width: 1, height: 1, fill: floor)
        shadow.composite(PixelImage(width: 1, height: 1, fill: Palette.color(.ink)), alpha: Palette.shadowAlpha)
        var pool = PixelImage(width: 1, height: 1, fill: floor)
        pool.add(PixelImage(width: 1, height: 1, fill: Palette.color(.lampWarm)), alpha: Palette.lightPoolAlpha)
        var veil = PixelImage(width: 1, height: 1, fill: floor)
        veil.multiply(by: Palette.nightVeil, alpha: Palette.nightVeilAlpha)
        #expect(colors.contains(shadow[0, 0]) && colors.contains(pool[0, 0]) && colors.contains(veil[0, 0]))
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
