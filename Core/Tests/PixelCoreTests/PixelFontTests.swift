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
