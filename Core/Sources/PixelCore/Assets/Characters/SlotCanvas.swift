import Foundation

/// A character frame composed in slot space: the parts of 7.5 are drawn as slots, so a mirror can be flattened and
/// reshaded before any colour exists, and one composition serves every colour of a look.
public struct SlotCanvas: Hashable, Sendable {
    public let width: Int, height: Int
    /// Row-major, top row first.
    public private(set) var cells: [Slot]

    public init(width: Int, height: Int) {
        precondition(width >= 0 && height >= 0, "negative canvas size")
        self.width = width
        self.height = height
        cells = Array(repeating: .clear, count: width * height)
    }

    /// Precondition: in bounds.
    public subscript(x: Int, y: Int) -> Slot {
        get {
            precondition(x >= 0 && y >= 0 && x < width && y < height, "cell (\(x), \(y)) outside \(width)×\(height)")
            return cells[y * width + x]
        }
        set {
            precondition(x >= 0 && y >= 0 && x < width && y < height, "cell (\(x), \(y)) outside \(width)×\(height)")
            cells[y * width + x] = newValue
        }
    }

    /// Non-clear cells of `map` overwrite, its top-left at (x, y); clipped to the canvas.
    public mutating func draw(_ map: PixelMap, x: Int, y: Int) {
        for my in 0..<map.height {
            let cy = y + my
            guard cy >= 0, cy < height else { continue }
            for mx in 0..<map.width {
                let cx = x + mx
                guard cx >= 0, cx < width else { continue }
                let slot = map.cells[my * map.width + mx]
                if slot != .clear { cells[cy * width + cx] = slot }
            }
        }
    }

    /// Horizontal flip.
    public func mirrored() -> SlotCanvas {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out.cells[y * width + x] = cells[y * width + width - 1 - x] }
        }
        return out
    }

    /// Shade slots back to their base: S→s, H→h, T→t, b→p, A→a. Outlines, eyes and fixed roles stay.
    public func flattened() -> SlotCanvas {
        var out = self
        for index in cells.indices {
            if let material = Material(cells[index]), cells[index] == material.shade { out.cells[index] = material.base }
        }
        return out
    }

    /// 1-px shade band on the right edge of every horizontal run of a material (≥ 3 px), under the chin and under
    /// the fringe (7.5): light stays top-left after a mirror. An eye belongs to the face run but is never recoloured;
    /// "under the chin" is a skin pixel below a skin outline, "under the fringe" a skin pixel below hair.
    public func reshaded() -> SlotCanvas {
        var out = self
        for y in 0..<height {
            var x = 0
            while x < width {
                guard let material = Material(cells[y * width + x]) else {
                    x += 1
                    continue
                }
                let start = x
                while x < width, Material(cells[y * width + x]) == material { x += 1 }
                let last = y * width + x - 1
                if x - start >= 3, cells[last] != .eye { out.cells[last] = material.shade }
            }
        }
        for y in 1..<max(height, 1) {
            for x in 0..<width {
                let slot = cells[y * width + x]
                guard slot == .skin || slot == .skinShade else { continue }
                switch cells[(y - 1) * width + x] {
                case .hair, .hairShade, .hairOutline, .skinOutline:
                    out.cells[y * width + x] = .skinShade
                default:
                    break
                }
            }
        }
        return out
    }

    /// Colours from `look`; clear cells (and slots the look leaves empty) are transparent.
    public func render(_ look: ResolvedLook) -> PixelImage {
        var pixels = [RGBA8](repeating: .clear, count: cells.count)
        var cache: [Slot: RGBA8] = [:]
        for (index, slot) in cells.enumerated() where slot != .clear {
            if let color = cache[slot] {
                pixels[index] = color
            } else if let color = look.color(slot) {
                cache[slot] = color
                pixels[index] = color
            }
        }
        return PixelImage(width: width, height: height, pixels: pixels)
    }

    /// The shaded materials of a character (7.5); the eye counts as part of the face (skin).
    private enum Material: Hashable {
        case skin, hair, top, bottom, accessory

        init?(_ slot: Slot) {
            switch slot {
            case .skin, .skinShade, .eye: self = .skin
            case .hair, .hairShade: self = .hair
            case .top, .topShade: self = .top
            case .bottom, .bottomShade: self = .bottom
            case .accessory, .accessoryShade: self = .accessory
            default: return nil
            }
        }

        var base: Slot {
            switch self {
            case .skin: return .skin
            case .hair: return .hair
            case .top: return .top
            case .bottom: return .bottom
            case .accessory: return .accessory
            }
        }

        var shade: Slot {
            switch self {
            case .skin: return .skinShade
            case .hair: return .hairShade
            case .top: return .topShade
            case .bottom: return .bottomShade
            case .accessory: return .accessoryShade
            }
        }
    }
}
