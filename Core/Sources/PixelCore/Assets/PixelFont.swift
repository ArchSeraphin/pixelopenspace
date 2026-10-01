import Foundation

/// The pixel font of the scene and the contact sheets: original capitals drawn here, 5 px tall, with French
/// accents on 2 rows above them (decision 6 of the visual milestone: the core cannot rasterise Silkscreen without
/// CoreText). Text is always drawn on a plate or with an ink outline in the scene (7.2).
public enum PixelFont {
    /// Height of a capital. The glyph cell is 2 accent rows + 5 cap rows.
    public static let capHeight = 5
    /// Height of a rendered line (accent rows included).
    public static let lineHeight = 7
    /// Rows above the capitals, for accents.
    public static let accentRows = 2
    /// Blank columns between two glyphs.
    public static let spacing = 1

    /// Uppercases first; letters A-Z with French accents (À Â Ä Ç É È Ê Ë Î Ï Ô Ö Ù Û Ü Œ), 0-9, space and
    /// . , : ; ! ? ' " - + / ( ) # % @ ~ _ < > = · … ×; any other character renders as "?".
    /// `lineHeight` px tall and `width(of:)` px wide; an outline adds a 1-px ring (8-neighbourhood) all around,
    /// so the image grows by 2 px in each direction and the text starts at (1, 1).
    public static func render(_ text: String, color: RGBA8, outline: RGBA8? = nil) -> PixelImage {
        let characters = Array(normalized(text))
        var image = PixelImage(width: width(ofNormalized: characters), height: lineHeight)
        var x = 0
        for character in characters {
            guard let glyph = glyphs[character] else { continue }
            for y in 0..<lineHeight {
                for gx in 0..<glyph.width where glyph.bits[y * glyph.width + gx] { image[x + gx, y] = color }
            }
            x += glyph.width + spacing
        }
        guard let outline else { return image }
        return ringed(image, color: outline)
    }

    /// Sum of the glyph widths and of the 1-px gaps between them; 0 for an empty text. Outline not included.
    public static func width(of text: String) -> Int {
        width(ofNormalized: Array(normalized(text)))
    }

    /// The text, or its first maxCharacters − 1 characters followed by "…" (sign: 10 characters, 7.4.2).
    /// Spaces left before the ellipsis are dropped.
    public static func fitted(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        guard text.count > maxCharacters else { return text }
        var head = String(text.prefix(maxCharacters - 1))
        while head.last?.isWhitespace == true { head.removeLast() }
        return head + "…"
    }

    /// What `render` draws: the text uppercased, typographic quotes, dashes and non-breaking spaces brought back to
    /// their plain forms, every other unsupported character replaced by "?".
    public static func normalized(_ text: String) -> String {
        var out = ""
        for character in text.uppercased() {
            let plain = substitutes[character] ?? character
            out.append(glyphs[plain] == nil ? "?" : plain)
        }
        return out
    }

    public static let supportedCharacters: Set<Character> = Set(glyphs.keys)

    // MARK: Helpers shared by the sprite sets of the HUD and the overlays

    /// `image` inside a 1-px ring of `color`: every clear pixel with an opaque 8-neighbour. The result is 2 px
    /// wider and taller, the source at (1, 1).
    static func ringed(_ image: PixelImage, color: RGBA8) -> PixelImage {
        var out = PixelImage(width: image.width + 2, height: image.height + 2)
        out.blit(image, x: 1, y: 1)
        let source = out
        for y in 0..<out.height {
            for x in 0..<out.width where source[x, y].a == 0 {
                var touches = false
                for dy in -1...1 where !touches {
                    for dx in -1...1 {
                        let (nx, ny) = (x + dx, y + dy)
                        if nx >= 0, ny >= 0, nx < out.width, ny < out.height, source[nx, ny].a != 0 {
                            touches = true
                            break
                        }
                    }
                }
                if touches { out[x, y] = color }
            }
        }
        return out
    }

    // MARK: Glyphs

    private struct Glyph: Sendable {
        let width: Int
        /// lineHeight rows of `width` bits, top row first.
        let bits: [Bool]

        /// `caps`: the 5 cap rows; `accent`: the 2 rows above them (blank when nil).
        init(_ caps: [String], accent: [String]? = nil) {
            let width = caps[0].count
            precondition(caps.count == PixelFont.capHeight && caps.allSatisfy { $0.count == width }, "bad glyph \(caps)")
            let top = accent ?? Array(repeating: String(repeating: ".", count: width), count: PixelFont.accentRows)
            precondition(top.count == PixelFont.accentRows && top.allSatisfy { $0.count == width }, "bad accent \(top)")
            self.width = width
            bits = (top + caps).flatMap { row in row.map { $0 == "#" } }
        }
    }

    private static func width(ofNormalized characters: [Character]) -> Int {
        guard !characters.isEmpty else { return 0 }
        let glyphWidths = characters.reduce(0) { $0 + (glyphs[$1]?.width ?? 0) }
        return glyphWidths + spacing * (characters.count - 1)
    }

    /// Typographic forms drawn with a plain glyph.
    private static let substitutes: [Character: Character] = [
        "\u{2019}": "'", "\u{2018}": "'", "\u{AB}": "\"", "\u{BB}": "\"", "\u{201C}": "\"", "\u{201D}": "\"",
        "\u{2013}": "-", "\u{2212}": "-", "\u{A0}": " ", "\u{202F}": " ", "\u{2009}": " ",
    ]

    // Accents, 2 rows, by glyph width.
    private static let grave = [".#..", "..#."]
    private static let acute = ["..#.", ".#.."]
    /// Raised and flat on 4-px letters: a 2-row caret would close the top of A, E, O into an "8".
    private static let circumflex4 = [".##.", "...."]
    private static let circumflex3 = [".#.", "#.#"]
    private static let diaeresis4 = ["#..#", "...."]
    private static let diaeresis3 = ["#.#", "..."]

    private static let letterA = [".##.", "#..#", "####", "#..#", "#..#"]
    private static let letterE = ["####", "#...", "###.", "#...", "####"]
    private static let letterI = ["###", ".#.", ".#.", ".#.", "###"]
    private static let letterO = [".##.", "#..#", "#..#", "#..#", ".##."]
    private static let letterU = ["#..#", "#..#", "#..#", "#..#", ".##."]

    private static let glyphs: [Character: Glyph] = {
        var g: [Character: Glyph] = [:]
        // Capitals: original shapes, 3 to 5 px wide, square shoulders and cut corners on the round letters.
        g["A"] = Glyph(letterA)
        g["B"] = Glyph(["###.", "#..#", "###.", "#..#", "###."])
        g["C"] = Glyph([".###", "#...", "#...", "#...", ".###"])
        g["D"] = Glyph(["###.", "#..#", "#..#", "#..#", "###."])
        g["E"] = Glyph(letterE)
        g["F"] = Glyph(["####", "#...", "###.", "#...", "#..."])
        g["G"] = Glyph([".###", "#...", "#.##", "#..#", ".###"])
        g["H"] = Glyph(["#..#", "#..#", "####", "#..#", "#..#"])
        g["I"] = Glyph(letterI)
        g["J"] = Glyph(["..##", "...#", "...#", "#..#", ".##."])
        g["K"] = Glyph(["#..#", "#.#.", "##..", "#.#.", "#..#"])
        g["L"] = Glyph(["#...", "#...", "#...", "#...", "####"])
        g["M"] = Glyph(["#...#", "##.##", "#.#.#", "#...#", "#...#"])
        g["N"] = Glyph(["#..#", "##.#", "#.##", "#..#", "#..#"])
        g["O"] = Glyph(letterO)
        g["P"] = Glyph(["###.", "#..#", "###.", "#...", "#..."])
        g["Q"] = Glyph([".##.", "#..#", "#..#", "#.#.", ".#.#"])
        g["R"] = Glyph(["###.", "#..#", "###.", "#.#.", "#..#"])
        g["S"] = Glyph([".###", "#...", ".##.", "...#", "###."])
        g["T"] = Glyph(["###", ".#.", ".#.", ".#.", ".#."])
        g["U"] = Glyph(letterU)
        g["V"] = Glyph(["#...#", "#...#", ".#.#.", ".#.#.", "..#.."])
        g["W"] = Glyph(["#...#", "#...#", "#.#.#", "##.##", "#...#"])
        g["X"] = Glyph(["#..#", "#..#", ".##.", "#..#", "#..#"])
        g["Y"] = Glyph(["#.#", "#.#", ".#.", ".#.", ".#."])
        g["Z"] = Glyph(["####", "...#", ".##.", "#...", "####"])
        // French capitals. The accent sits on the 2 rows above; Î drops the serif that would touch its caret.
        g["À"] = Glyph(letterA, accent: grave)
        g["Â"] = Glyph(letterA, accent: circumflex4)
        g["Ä"] = Glyph(letterA, accent: diaeresis4)
        g["Ç"] = Glyph([".###", "#...", "#...", ".###", "..#."])
        g["É"] = Glyph(letterE, accent: acute)
        g["È"] = Glyph(letterE, accent: grave)
        g["Ê"] = Glyph(letterE, accent: circumflex4)
        g["Ë"] = Glyph(letterE, accent: diaeresis4)
        g["Î"] = Glyph([".#.", ".#.", ".#.", ".#.", "###"], accent: circumflex3)
        g["Ï"] = Glyph(letterI, accent: diaeresis3)
        g["Ô"] = Glyph(letterO, accent: circumflex4)
        g["Ö"] = Glyph(letterO, accent: diaeresis4)
        g["Ù"] = Glyph(letterU, accent: grave)
        g["Û"] = Glyph(letterU, accent: circumflex4)
        g["Ü"] = Glyph(letterU, accent: diaeresis4)
        g["Œ"] = Glyph([".####", "#.#..", "#.###", "#.#..", ".####"])
        // Digits, 3 px wide so that a badge holds one.
        g["0"] = Glyph(["###", "#.#", "#.#", "#.#", "###"])
        g["1"] = Glyph([".#.", "##.", ".#.", ".#.", "###"])
        g["2"] = Glyph(["##.", "..#", ".#.", "#..", "###"])
        g["3"] = Glyph(["###", "..#", ".##", "..#", "###"])
        g["4"] = Glyph(["#.#", "#.#", "###", "..#", "..#"])
        g["5"] = Glyph(["###", "#..", "##.", "..#", "##."])
        g["6"] = Glyph([".##", "#..", "###", "#.#", "###"])
        g["7"] = Glyph(["###", "..#", ".#.", ".#.", ".#."])
        g["8"] = Glyph(["###", "#.#", ".#.", "#.#", "###"])
        g["9"] = Glyph(["###", "#.#", "###", "..#", "##."])
        // Space and symbols.
        g[" "] = Glyph(["...", "...", "...", "...", "..."])
        g["."] = Glyph([".", ".", ".", ".", "#"])
        g[","] = Glyph(["..", "..", "..", ".#", "#."])
        g[":"] = Glyph([".", "#", ".", "#", "."])
        g[";"] = Glyph(["..", ".#", "..", ".#", "#."])
        g["!"] = Glyph(["#", "#", "#", ".", "#"])
        g["?"] = Glyph(["##.", "..#", ".#.", "...", ".#."])
        g["'"] = Glyph(["#", "#", ".", ".", "."])
        g["\""] = Glyph(["#.#", "#.#", "...", "...", "..."])
        g["-"] = Glyph(["...", "...", "###", "...", "..."])
        g["+"] = Glyph(["...", ".#.", "###", ".#.", "..."])
        g["/"] = Glyph(["..#", "..#", ".#.", "#..", "#.."])
        g["("] = Glyph([".#", "#.", "#.", "#.", ".#"])
        g[")"] = Glyph(["#.", ".#", ".#", ".#", "#."])
        g["#"] = Glyph([".#.#.", "#####", ".#.#.", "#####", ".#.#."])
        g["%"] = Glyph(["##..#", "##.#.", "..#..", ".#.##", "#..##"])
        g["@"] = Glyph([".###.", "#.#.#", "#.###", "#....", ".###."])
        g["~"] = Glyph(["....", ".#.#", "#.#.", "....", "...."])
        g["_"] = Glyph(["....", "....", "....", "....", "####"])
        g["<"] = Glyph(["..#", ".#.", "#..", ".#.", "..#"])
        g[">"] = Glyph(["#..", ".#.", "..#", ".#.", "#.."])
        g["="] = Glyph(["...", "###", "...", "###", "..."])
        g["·"] = Glyph([".", ".", "#", ".", "."])
        g["…"] = Glyph([".....", ".....", ".....", ".....", "#.#.#"])
        g["×"] = Glyph(["...", "#.#", ".#.", "#.#", "..."])
        return g
    }()
}
