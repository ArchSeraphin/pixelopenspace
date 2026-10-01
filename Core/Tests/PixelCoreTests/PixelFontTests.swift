import Foundation
import Testing
@testable import PixelCore

@Suite struct PixelFontTests {
    static let chalk = Palette.color(.chalk)
    static let ink = Palette.color(.ink)

    // MARK: Coverage

    @Test func coversNamesAndSymbols() {
        for name in NameGenerator.names {
            for character in name.uppercased() {
                #expect(PixelFont.supportedCharacters.contains(character), "\(name): \(character)")
            }
        }
        let required = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" + "ÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŒ" + "0123456789"
            + " .,:;!?'\"-+/()#%@~_<>=·…×"
        for character in required {
            #expect(PixelFont.supportedCharacters.contains(character), "\(character)")
        }
        #expect(PixelFont.supportedCharacters.count == required.count)
        // No glyph for the em dash: it renders as "?" like any other unknown character.
        #expect(!PixelFont.supportedCharacters.contains("\u{2014}"))
    }

    @Test func everyGlyphIsDrawnAndDistinct() {
        var seen: [PixelImage: Character] = [:]
        for character in PixelFont.supportedCharacters.sorted() {
            let image = PixelFont.render(String(character), color: Self.chalk)
            #expect(image.height == PixelFont.lineHeight)
            #expect(image.width == PixelFont.width(of: String(character)))
            if character == " " {
                #expect(image.opaqueBounds == nil, "space draws nothing")
                continue
            }
            #expect(image.opaqueBounds != nil, "\(character) draws nothing")
            #expect(image.distinctColors == [Self.chalk], "\(character): one colour only")
            if let other = seen[image] { Issue.record("\(character) and \(other) render the same image") }
            seen[image] = character
        }
    }

    // MARK: Digits against letters (first render: "0" read as D or O, "8" as B)

    static let digits = Array("0123456789")
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ" + "ÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŒ")

    /// The glyph as `lineHeight` rows of ink flags, accent rows included.
    static func bitmap(_ character: Character) -> [[Bool]] {
        let image = PixelFont.render(String(character), color: chalk)
        return (0..<image.height).map { y in (0..<image.width).map { x in image[x, y].a != 0 } }
    }

    /// Pixels that differ between two glyphs. The wider one is first condensed to the other's width by removing a
    /// band of adjacent columns that touches neither of its sides (a 4-px D condensed to 3 px is the shape a 3-px
    /// figure must not have); the closest band counts.
    static func distance(_ a: [[Bool]], _ b: [[Bool]]) -> Int {
        let (narrow, wide) = a[0].count <= b[0].count ? (a, b) : (b, a)
        let band = wide[0].count - narrow[0].count
        func differing(_ other: [[Bool]]) -> Int {
            zip(narrow, other).reduce(0) { sum, rows in sum + zip(rows.0, rows.1).filter { $0 != $1 }.count }
        }
        guard band > 0 else { return differing(wide) }
        return (1..<(wide[0].count - band)).map { start in
            differing(wide.map { Array($0[..<start] + $0[(start + band)...]) })
        }.min() ?? 0
    }

    @Test func distanceCondensesTheWiderGlyph() {
        let d3: [[Bool]] = ["##.", "#.#", "##."].map { $0.map { $0 == "#" } }
        let d4: [[Bool]] = ["###.", "#..#", "###."].map { $0.map { $0 == "#" } }
        #expect(Self.distance(d3, d4) == 0, "D drawn 3 px wide is D")
        #expect(Self.distance(d4, d3) == 0)
        #expect(Self.distance(d4, d4) == 0)
        let box: [[Bool]] = ["###", "#.#", "###"].map { $0.map { $0 == "#" } }
        #expect(Self.distance(box, d4) == 2, "the old 0 against D: 2 px")
    }

    @Test func digitsDoNotPassForLetters() {
        for digit in Self.digits {
            for letter in Self.letters {
                let pixels = Self.distance(Self.bitmap(digit), Self.bitmap(letter))
                #expect(pixels >= 3, "\(digit) is \(pixels) px away from \(letter): it reads as the letter")
            }
        }
        for (index, a) in Self.digits.enumerated() {
            for b in Self.digits[(index + 1)...] {
                let pixels = Self.distance(Self.bitmap(a), Self.bitmap(b))
                #expect(pixels >= 2, "\(a) and \(b) are \(pixels) px apart")
            }
        }
    }

    /// The two confusions of the first render, by their shapes rather than by a pixel count.
    @Test func zeroAndEightReadApartFromTheirLetters() throws {
        let caps = PixelFont.accentRows..<PixelFont.lineHeight
        let (top, bottom) = (caps.lowerBound, caps.upperBound - 1)
        // 0 is the O crossed by a slash: every pixel of O, plus a stroke inside its counter over 2 rows and 2
        // columns or more. O and D have an empty counter.
        let zero = Self.bitmap("0"), o = Self.bitmap("O")
        try #require(zero[0].count == o[0].count, "0 has the width of O")
        let width = o[0].count
        var slash: [(x: Int, y: Int)] = []
        for y in 0..<PixelFont.lineHeight {
            for x in 0..<width {
                if o[y][x] { #expect(zero[y][x], "0 lacks O's pixel (\(x), \(y))") }
                else if zero[y][x] { slash.append((x, y)) }
            }
        }
        #expect(slash.allSatisfy { (top + 1..<bottom).contains($0.y) && (1..<(width - 1)).contains($0.x) },
                "the slash stays inside the counter")
        #expect(Set(slash.map(\.y)).count >= 2 && Set(slash.map(\.x)).count >= 2, "a slash, not a dot")
        for letter: Character in ["O", "D"] {
            let glyph = Self.bitmap(letter)
            let inside = (top + 1..<bottom).contains { y in (1..<(glyph[y].count - 1)).contains { glyph[y][$0] } }
            #expect(!inside, "\(letter) has an empty counter")
        }
        // 8 is pinched on both sides with cut corners; B stands on a straight left stem with square corners.
        let eight = Self.bitmap("8"), b = Self.bitmap("B")
        #expect(caps.allSatisfy { b[$0][0] }, "B: a straight stem")
        #expect(!caps.allSatisfy { eight[$0][0] }, "8: no stem")
        for row in [top, bottom] {
            #expect(!eight[row][0] && !eight[row][eight[row].count - 1], "8: cut corners on row \(row)")
        }
        #expect(eight.allSatisfy { $0 == Array($0.reversed()) }, "8: left-right symmetric")
    }

    @Test func aQueueBadgeHoldsADigit() {
        // desk.queueBadge: an 8-px disc whose 6-px face takes the digit at x = 2, with a 1-px margin on the right.
        for digit in "123456789" {
            #expect(PixelFont.width(of: String(digit)) <= 4, "\(digit)")
        }
    }

    // MARK: Metrics

    @Test func capHeightAndWidths() throws {
        #expect(PixelFont.capHeight == 5)
        #expect(PixelFont.lineHeight == 7)
        #expect(PixelFont.spacing == 1)
        let text = "NOVA"
        let image = PixelFont.render(text, color: Self.chalk)
        #expect(image.height == 7)
        let glyphWidths = text.map { PixelFont.width(of: String($0)) }
        #expect(image.width == glyphWidths.reduce(0, +) + (text.count - 1) * PixelFont.spacing)
        #expect(PixelFont.width(of: text) == image.width)
        // Capitals sit on the 5 lower rows; the 2 rows above are for accents.
        let caps = try #require(image.opaqueBounds)
        #expect(caps.y == 2 && caps.height == 5)
        for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            let bounds = try #require(PixelFont.render(String(character), color: Self.chalk).opaqueBounds)
            #expect(bounds.y == 2 && bounds.height == 5, "\(character) is not 5 rows tall on the cap line")
        }
        for character in "ÀÂÄÉÈÊËÎÏÔÖÙÛÜ" {
            let bounds = try #require(PixelFont.render(String(character), color: Self.chalk).opaqueBounds)
            #expect(bounds.y == 0, "\(character): the accent is above the capital")
        }
        #expect(PixelFont.width(of: "") == 0)
        #expect(PixelFont.render("", color: Self.chalk).width == 0)
        // A word space is a 3-px glyph between two 1-px gaps.
        #expect(PixelFont.width(of: "A B") == PixelFont.width(of: "AB") + 3 + PixelFont.spacing)
    }

    @Test func outlineIsOnePixelRingInTheOutlineColour() {
        let plain = PixelFont.render("ZÉPHYR", color: Self.chalk)
        let outlined = PixelFont.render("ZÉPHYR", color: Self.chalk, outline: Self.ink)
        #expect(outlined.width == plain.width + 2 && outlined.height == plain.height + 2)
        for y in 0..<outlined.height {
            for x in 0..<outlined.width {
                let inner = (x >= 1 && y >= 1 && x <= plain.width && y <= plain.height) ? plain[x - 1, y - 1] : .clear
                let p = outlined[x, y]
                if inner.a != 0 {
                    #expect(p == Self.chalk)
                    continue
                }
                // Every other pixel is ink exactly when one of its 8 neighbours is text.
                var touchesText = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let (sx, sy) = (x - 1 + dx, y - 1 + dy)
                        if sx >= 0, sy >= 0, sx < plain.width, sy < plain.height, plain[sx, sy].a != 0 { touchesText = true }
                    }
                }
                #expect(p == (touchesText ? Self.ink : .clear), "(\(x), \(y))")
            }
        }
    }

    // MARK: Text handling

    @Test func fittedTruncatesAtTen() {
        #expect(PixelFont.fitted("DOCUMENTATION", maxCharacters: 10) == "DOCUMENTA…")
        #expect(PixelFont.fitted("SITE WEB", maxCharacters: 10) == "SITE WEB")
        #expect(PixelFont.fitted("ABCDEFGHIJ", maxCharacters: 10) == "ABCDEFGHIJ")
        #expect(PixelFont.fitted("ABCDEFGHIJK", maxCharacters: 10) == "ABCDEFGHI…")
        #expect(PixelFont.fitted("SITE WEB PRO", maxCharacters: 10) == "SITE WEB…", "no space before the ellipsis")
        #expect(PixelFont.fitted("", maxCharacters: 10) == "")
        #expect(PixelFont.fitted("ABC", maxCharacters: 1) == "…")
        #expect(PixelFont.fitted("DOCUMENTATION", maxCharacters: 10).count == 10)
    }

    @Test func lowercaseRendersAsUppercase() {
        #expect(PixelFont.render("nova", color: Self.chalk) == PixelFont.render("NOVA", color: Self.chalk))
        #expect(PixelFont.render("zéphyr comète", color: Self.chalk) == PixelFont.render("ZÉPHYR COMÈTE", color: Self.chalk))
        #expect(PixelFont.render("œ", color: Self.chalk) == PixelFont.render("Œ", color: Self.chalk))
        #expect(PixelFont.normalized("api · 2") == "API · 2")
        #expect(PixelFont.width(of: "rosée") == PixelFont.width(of: "ROSÉE"))
    }

    @Test func unknownCharacterIsQuestionMark() {
        let question = PixelFont.render("?", color: Self.chalk)
        for unknown in ["$", "€", "&", "*", "\u{2014}", "{", "Æ", "😀"] {
            #expect(PixelFont.render(unknown, color: Self.chalk) == question, "\(unknown)")
            #expect(PixelFont.width(of: unknown) == PixelFont.width(of: "?"))
        }
        #expect(PixelFont.normalized("A$B") == "A?B")
        #expect(PixelFont.render("A$B", color: Self.chalk) == PixelFont.render("A?B", color: Self.chalk))
    }

    @Test func typographicQuotesFallBackToStraightOnes() {
        #expect(PixelFont.normalized("L’API «DATA»") == "L'API \"DATA\"")
        #expect(PixelFont.normalized("12–15") == "12-15")
    }

    @Test func renderIsDeterministicAndColoured() {
        let a = PixelFont.render("PIXEL OPEN SPACE 0123", color: Palette.color(.mist), outline: Self.ink)
        let b = PixelFont.render("PIXEL OPEN SPACE 0123", color: Palette.color(.mist), outline: Self.ink)
        #expect(a == b)
        #expect(a.distinctColors == [Self.ink, Palette.color(.mist)].sorted())
    }

    // MARK: Preview

    @Test func preview() {
        guard PreviewWriter.directory(in: ProcessInfo.processInfo.environment) != nil else { return }
        let lines = [
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            "ÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŒ 0123456789",
            "B8 D0 O0 Z2 S5 G6 T7 H4 X8 I1   ~HUE0 PLANCHE 0   4 × 8 FPS   1080 2048",
            ". , : ; ! ? ' \" - + / ( ) # % @ ~ _ < > = · … ×",
            "API · 2   SITE WEB   DOCUMENTA…   NOVA   OFF",
        ] + stride(from: 0, to: NameGenerator.names.count, by: 10).map {
            NameGenerator.names[$0..<min($0 + 10, NameGenerator.names.count)].joined(separator: " ")
        }
        let paper = Palette.color(.paper)
        let plain = lines.map { PixelFont.render($0, color: Self.ink) }
        let outlined = lines.map { PixelFont.render($0, color: Self.chalk, outline: Self.ink) }
        let sheet = PixelImage.stacked([PixelImage.stacked(plain, axis: .vertical, spacing: 2),
                                        PixelImage.stacked(outlined, axis: .vertical, spacing: 2)],
                                       axis: .vertical, spacing: 6, background: paper)
        var framed = PixelImage(width: sheet.width + 8, height: sheet.height + 8, fill: paper)
        framed.blit(sheet, x: 4, y: 4)
        PreviewWriter.write("font", width: framed.width, height: framed.height, rgba: framed.rgbaBytes, scale: 4)
    }
}
