import Foundation

/// `manifest.json` of the atlas (7.6), written next to its pages by `sprite-export --atlas`: the template of the
/// PNG replacement of stage 4 (décision 6).
///
/// Departures from 7.6: animations give their `holds` in ticks of the 24 ticks/s clock instead of an fps (exact,
/// every cadence of 7.3 is a whole number of ticks); every sprite name carries its frame ("desk@se#0", like the
/// atlas entries); mirrors have their own entries in the atlas (décision 5), and `mirrors` only says where the plain
/// ones come from.
public struct SpriteManifest: Codable, Equatable, Sendable {
    /// "pixelopenspace-atlas".
    public var format: String
    /// 1.
    public var version: Int
    /// "day".
    public var theme: String
    public var pages: [Page]
    public struct Page: Codable, Equatable, Sendable {
        /// "atlas-0.png"…
        public var file: String
        /// [width, height] in pixels.
        public var size: [Int]

        public init(file: String, size: [Int]) {
            self.file = file
            self.size = size
        }
    }

    /// By frame name.
    public var sprites: [String: Sprite]
    public struct Sprite: Codable, Equatable, Sendable {
        public var page: Int
        /// [x, y, width, height] in pixels of the page, padding left out.
        public var rect: [Int]
        /// [x, y] in pixels from the top-left of the frame.
        public var anchor: [Int]
        /// The sprite can be clicked in the scene: its alpha mask is the hit test (3.9). False for floors and their
        /// marks, shadows and lights, and effects.
        public var mask: Bool

        public init(page: Int, rect: [Int], anchor: [Int], mask: Bool) {
            self.page = page
            self.rect = rect
            self.anchor = anchor
            self.mask = mask
        }
    }

    /// By SpriteKey.name, sprites of more than one frame.
    public var animations: [String: AtlasAnimation]
    /// Derived sprite name → source name, for the plain mirrors (`Derivation.mirror`, flat sprites of 7.4); the
    /// reshaded characters are sprites of their own.
    public var mirrors: [String: String]
    /// Ids generated per project hue (variants "hue0"…"hue9"), sorted.
    public var tinted: [String]

    public static let formatName = "pixelopenspace-atlas"
    public static let currentVersion = 1

    /// The page file of index `index`: "atlas-0.png"…
    public static func pageFileName(_ index: Int) -> String {
        "atlas-\(index).png"
    }

    /// Categories whose sprites are never a click target.
    static let unmaskedCategories: Set<SpriteCategory> = [.floors, .lights, .effects]

    /// Describes `atlas`, packed from `defs`: one sprite per frame of `defs` found in the atlas.
    public init(atlas: Atlas, defs: [SpriteDef], theme: String = "day") {
        format = Self.formatName
        version = Self.currentVersion
        self.theme = theme
        pages = atlas.pages.indices.map {
            Page(file: Self.pageFileName($0), size: [atlas.pages[$0].width, atlas.pages[$0].height])
        }
        var sprites: [String: Sprite] = [:]
        var animations: [String: AtlasAnimation] = [:]
        var mirrors: [String: String] = [:]
        var tinted = Set<String>()
        for def in defs {
            let mask = !Self.unmaskedCategories.contains(def.category)
            for index in def.frames.indices {
                let name = def.key.frameName(index)
                guard let entry = atlas.entries[name] else { continue }
                sprites[name] = Sprite(page: entry.page, rect: [entry.rect.x, entry.rect.y, entry.rect.width, entry.rect.height],
                                       anchor: [entry.anchor.x, entry.anchor.y], mask: mask)
            }
            if let animation = atlas.animations[def.key.name] { animations[def.key.name] = animation }
            if def.derivation == .mirror, let source = def.source { mirrors[def.key.name] = source.name }
            if def.key.variant?.hasPrefix("hue") == true { tinted.insert(def.key.id.rawValue) }
        }
        self.sprites = sprites
        self.animations = animations
        self.mirrors = mirrors
        self.tinted = tinted.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Compact JSON, sorted keys, slashes unescaped: same bytes every time.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
