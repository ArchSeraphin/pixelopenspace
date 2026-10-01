import Foundation

/// Where one frame lies in the atlas.
public struct AtlasEntry: Hashable, Sendable {
    public var page: Int
    /// Pixels of the page, padding left out.
    public var rect: PixelRect
    /// The sprite's anchor, pixels from the top-left of the frame (7.3).
    public var anchor: PixelPoint

    public init(page: Int, rect: PixelRect, anchor: PixelPoint) {
        self.page = page
        self.rect = rect
        self.anchor = anchor
    }
}

/// The frames of an animated sprite, in order, with their holds in ticks of the 24 ticks/s clock (7.3).
public struct AtlasAnimation: Hashable, Codable, Sendable {
    /// Frame names ("screen.working@se#0"…).
    public var frames: [String]
    public var holds: [Int]
    public var loops: Bool

    public init(frames: [String], holds: [Int], loops: Bool) {
        self.frames = frames
        self.holds = holds
        self.loops = loops
    }
}

/// The sprites packed into square pages (3.10, 7.6): what the app turns into textures.
public struct Atlas: Equatable, Sendable {
    public var pageSize: Int
    /// Transparent background, pixels (0, 0, 0, 0).
    public var pages: [PixelImage]
    /// By frame name ("desk~light@ne#0").
    public var entries: [String: AtlasEntry]
    /// By SpriteKey.name, sprites of more than one frame.
    public var animations: [String: AtlasAnimation]

    public init(pageSize: Int, pages: [PixelImage], entries: [String: AtlasEntry], animations: [String: AtlasAnimation]) {
        self.pageSize = pageSize
        self.pages = pages
        self.entries = entries
        self.animations = animations
    }

    public func entry(_ key: SpriteKey, frame: Int) -> AtlasEntry? {
        entries[key.frameName(frame)]
    }
}

public enum AtlasPacker {
    /// Shelf packing of every frame (mirrors included, décision 5), sorted by height, width (both descending), then
    /// name; `padding` px around each frame filled by extruding its edge pixels; deterministic. A key listed twice
    /// keeps its first definition. Precondition: every frame fits in a page with its padding.
    public static func pack(_ defs: [SpriteDef], pageSize: Int = 2048, padding: Int = 2) -> Atlas {
        precondition(pageSize > 0 && padding >= 0, "page size must be positive and padding not negative")
        var items: [(name: String, image: PixelImage, anchor: PixelPoint)] = []
        var animations: [String: AtlasAnimation] = [:]
        var seen = Set<SpriteKey>()
        for def in defs where seen.insert(def.key).inserted {
            for (index, frame) in def.frames.enumerated() {
                items.append((def.key.frameName(index), frame, def.anchor))
            }
            if def.frames.count > 1 {
                animations[def.key.name] = AtlasAnimation(frames: def.frames.indices.map { def.key.frameName($0) },
                                                          holds: def.holds, loops: def.loops)
            }
        }
        items.sort { a, b in
            if a.image.height != b.image.height { return a.image.height > b.image.height }
            if a.image.width != b.image.width { return a.image.width > b.image.width }
            return a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
        }

        var pages: [[RGBA8]] = []
        var entries: [String: AtlasEntry] = [:]
        var x = 0, y = 0, shelf = 0
        for item in items {
            let width = item.image.width, height = item.image.height
            let cellWidth = width + 2 * padding, cellHeight = height + 2 * padding
            precondition(cellWidth <= pageSize && cellHeight <= pageSize,
                         "\(item.name) (\(width)×\(height)) does not fit in a \(pageSize) px page")
            if pages.isEmpty { pages.append(blankPage(pageSize)) }
            if x + cellWidth > pageSize {
                x = 0
                y += shelf
                shelf = 0
            }
            if y + cellHeight > pageSize {
                pages.append(blankPage(pageSize))
                x = 0
                y = 0
                shelf = 0
            }
            let rect = PixelRect(x: x + padding, y: y + padding, width: width, height: height)
            entries[item.name] = AtlasEntry(page: pages.count - 1, rect: rect, anchor: item.anchor)
            if width > 0 && height > 0 {
                drawExtruded(item.image, cellX: x, cellY: y, padding: padding, into: &pages[pages.count - 1],
                             pageSize: pageSize)
            }
            x += cellWidth
            shelf = max(shelf, cellHeight)
        }
        return Atlas(pageSize: pageSize, pages: pages.map { PixelImage(width: pageSize, height: pageSize, pixels: $0) },
                     entries: entries, animations: animations)
    }

    private static func blankPage(_ size: Int) -> [RGBA8] {
        [RGBA8](repeating: .clear, count: size * size)
    }

    /// The frame and its padding ring, each ring pixel a copy of the nearest edge pixel (corners included), so that
    /// a texture sampled on a frame's edge never reads its neighbour.
    private static func drawExtruded(_ image: PixelImage, cellX: Int, cellY: Int, padding: Int, into page: inout [RGBA8],
                                     pageSize: Int) {
        let width = image.width, height = image.height
        let source = image.pixels
        for cy in 0..<(height + 2 * padding) {
            let sy = min(max(cy - padding, 0), height - 1)
            let row = (cellY + cy) * pageSize + cellX
            for cx in 0..<(width + 2 * padding) {
                let sx = min(max(cx - padding, 0), width - 1)
                page[row + cx] = source[sy * width + sx]
            }
        }
    }
}
