import Foundation

/// What a DSL character stands for: a fixed role, or a slot resolved later (project hue, agent look) (7.5).
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

/// Rows and columns are 0-based, counted after the common indentation is removed.
public enum PixelMapError: Error, Equatable {
    case empty
    case raggedRow(Int)
    case unknownCharacter(Character, row: Int, column: Int)
}

/// An ASCII map of roles (7.5): the same drawing serves every project hue and every agent look.
public struct PixelMap: Hashable, Sendable {
    public let width: Int, height: Int
    /// Row-major, top row first.
    public let cells: [Slot]

    /// Base legend: `.` clear, the 7.5 letters above, `o` ink, and fixed roles `1` chalk, `2` mist, `3` stone,
    /// `4` slate, `5` shade, `6` paper, `7` woodLight, `8` woodMid, `9` woodDark, `c` cork, `m` hairDark,
    /// `f` leaf, `F` leafDark, `i` leafLight, `y` alertYellow, `Y` alertOrange, `g` screenGlow, `G` okGreen,
    /// `r` errorRed, `v` thinkLilac, `w` lampWarm, `k` skyDay, `n` skyNight, `z` floorLight, `Z` floorDark.
    /// `legend` adds or overrides letters for one map.
    public static let baseLegend: [Character: Slot] = [
        ".": .clear,
        "P": .hueBase, "L": .hueLight, "D": .hueDark,
        "s": .skin, "S": .skinShade, "q": .skinOutline,
        "h": .hair, "H": .hairShade, "j": .hairOutline,
        "t": .top, "T": .topShade, "u": .topOutline,
        "p": .bottom, "b": .bottomShade,
        "e": .eye,
        "a": .accessory, "A": .accessoryShade,
        "o": .role(.ink),
        "1": .role(.chalk), "2": .role(.mist), "3": .role(.stone), "4": .role(.slate), "5": .role(.shade),
        "6": .role(.paper), "7": .role(.woodLight), "8": .role(.woodMid), "9": .role(.woodDark),
        "c": .role(.cork), "m": .role(.hairDark),
        "f": .role(.leaf), "F": .role(.leafDark), "i": .role(.leafLight),
        "y": .role(.alertYellow), "Y": .role(.alertOrange),
        "g": .role(.screenGlow), "G": .role(.okGreen), "r": .role(.errorRed), "v": .role(.thinkLilac),
        "w": .role(.lampWarm), "k": .role(.skyDay), "n": .role(.skyNight),
        "z": .role(.floorLight), "Z": .role(.floorDark),
    ]

    /// Precondition: cells.count == width·height.
    public init(width: Int, height: Int, cells: [Slot]) {
        precondition(width >= 0 && height >= 0 && cells.count == width * height, "cell count mismatch")
        self.width = width
        self.height = height
        self.cells = cells
    }

    /// Blank first/last lines and the common indentation are ignored, so are trailing spaces and "\r";
    /// every row has the same width.
    public static func parse(_ ascii: String, legend: [Character: Slot] = [:]) throws -> PixelMap {
        var lines = ascii.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            var row = Substring(line)
            while let last = row.last, last == " " || last == "\t" { row.removeLast() }
            return row
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { throw PixelMapError.empty }

        let indent = lines.filter { !$0.isEmpty }
            .map { line in line.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        let rows = lines.map { Array($0.dropFirst(indent)) }
        let width = rows[0].count
        guard width > 0 else { throw PixelMapError.empty }
        if let ragged = rows.firstIndex(where: { $0.count != width }) { throw PixelMapError.raggedRow(ragged) }

        var cells: [Slot] = []
        cells.reserveCapacity(width * rows.count)
        for (r, row) in rows.enumerated() {
            for (c, character) in row.enumerated() {
                guard let slot = legend[character] ?? baseLegend[character] else {
                    throw PixelMapError.unknownCharacter(character, row: r, column: c)
                }
                cells.append(slot)
            }
        }
        return PixelMap(width: width, height: rows.count, cells: cells)
    }

    /// Traps on a malformed map: the art is static code, a typo must fail the first test that draws it.
    public init(_ ascii: String, legend: [Character: Slot] = [:]) {
        do {
            self = try PixelMap.parse(ascii, legend: legend)
        } catch {
            preconditionFailure("malformed PixelMap: \(error)")
        }
    }

    /// Precondition: in bounds.
    public subscript(x: Int, y: Int) -> Slot {
        precondition(x >= 0 && y >= 0 && x < width && y < height, "cell (\(x), \(y)) outside \(width)×\(height)")
        return cells[y * width + x]
    }

    /// Horizontal flip.
    public func mirrored() -> PixelMap {
        var out: [Slot] = []
        out.reserveCapacity(cells.count)
        for y in 0..<height {
            for x in 0..<width { out.append(cells[y * width + width - 1 - x]) }
        }
        return PixelMap(width: width, height: height, cells: out)
    }

    /// `.clear` and nil are transparent.
    public func render(_ paint: (Slot) -> RGBA8?) -> PixelImage {
        var image = PixelImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let slot = cells[y * width + x]
                if slot == .clear { continue }
                if let color = paint(slot) { image[x, y] = color }
            }
        }
        return image
    }

    /// render with `SlotPaint.decor`.
    public func renderDecor(hue: Int? = nil) -> PixelImage {
        render { SlotPaint.decor($0, hue: hue) }
    }
}

public enum SlotPaint {
    /// Decor paint: roles as themselves, P/L/D from `hue` (precondition: hue given when used); character slots trap.
    public static func decor(_ slot: Slot, hue: Int?) -> RGBA8? {
        switch slot {
        case .clear:
            return nil
        case .role(let role):
            return Palette.color(role)
        case .hueBase, .hueLight, .hueDark:
            guard let hue else { preconditionFailure("hue slot \(slot) painted without a project hue") }
            let tones = Palette.hue(hue)
            return slot == .hueBase ? tones.base : (slot == .hueLight ? tones.light : tones.dark)
        case .skin, .skinShade, .skinOutline, .hair, .hairShade, .hairOutline, .top, .topShade, .topOutline,
             .bottom, .bottomShade, .eye, .accessory, .accessoryShade:
            preconditionFailure("character slot \(slot) in a decor map")
        }
    }
}
