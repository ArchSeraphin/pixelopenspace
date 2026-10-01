import Foundation

/// A sprite id of 7.4: "desk", "screen.working", "ov.tool.bash"…
public struct SpriteID: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByStringLiteral,
                        CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public var description: String { rawValue }

    public static func < (lhs: SpriteID, rhs: SpriteID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One sprite of the catalog: an id, an optional variant, an optional direction (7.6 naming).
public struct SpriteKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var id: SpriteID
    /// "hue3", "hue3.jacket", "led.waiting", "night"…
    public var variant: String?
    public var facing: Facing?

    public init(_ id: SpriteID, variant: String? = nil, facing: Facing? = nil) {
        self.id = id
        self.variant = variant
        self.facing = facing
    }

    /// "chair~hue3.jacket@ne": id, then "~variant", then "@direction".
    public var name: String {
        var out = id.rawValue
        if let variant { out += "~" + variant }
        if let facing { out += "@" + facing.rawValue }
        return out
    }

    /// "screen.working#2".
    public func frameName(_ frame: Int) -> String { "\(name)#\(frame)" }

    public var description: String { name }

    /// By id, then variant (none first), then direction (none first): sorted catalogs and golden files.
    public static func < (lhs: SpriteKey, rhs: SpriteKey) -> Bool {
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.variant != rhs.variant {
            guard let l = lhs.variant else { return true }
            guard let r = rhs.variant else { return false }
            return l < r
        }
        guard let l = lhs.facing else { return rhs.facing != nil }
        guard let r = rhs.facing else { return false }
        return l.rawValue < r.rawValue
    }
}

/// How a sprite was obtained from `SpriteDef.source`: a plain horizontal mirror (flat sprites only), or a mirror
/// followed by the reshading pass of the characters (7.5).
public enum Derivation: String, Codable, Sendable { case mirror, mirrorReshaded }

public enum SpriteCategory: String, CaseIterable, Codable, Sendable {
    case floors, walls, furniture, deskItems, decor, lights, monitors, screens, overlays, effects, hud, characters
}

/// The animation clock of 7.3: 24 ticks per second, every frame lasts a whole number of ticks.
public enum AnimationClock {
    public static let ticksPerSecond = 24
    /// Ticks per frame of the allowed cadences: 12, 8, 6, 4, 3, 2, 1.5 and 1 fps.
    public static let allowedHolds: Set<Int> = [2, 3, 4, 6, 8, 12, 16, 24]
    /// The allowed cadences, fastest first.
    public static let allowedFPS: [Double] = [12, 8, 6, 4, 3, 2, 1.5, 1]

    /// Ticks per frame at `fps`; nil when the cadence is not allowed.
    public static func hold(forFPS fps: Double) -> Int? {
        guard fps > 0 else { return nil }
        let ticks = Double(ticksPerSecond) / fps
        let rounded = ticks.rounded()
        guard abs(ticks - rounded) < 1e-9, allowedHolds.contains(Int(rounded)) else { return nil }
        return Int(rounded)
    }

    /// One hold per frame; [] for a single frame. Precondition: an allowed cadence when frames > 1.
    public static func holds(fps: Double, frames: Int) -> [Int] {
        guard frames > 1 else { return [] }
        guard let hold = hold(forFPS: fps) else { preconditionFailure("\(fps) fps is not an allowed cadence") }
        return Array(repeating: hold, count: frames)
    }
}

/// A generated sprite: its frames, anchor and timing, and what the lint needs to check it (7.1 to 7.3).
public struct SpriteDef: Sendable {
    public var key: SpriteKey
    public var category: SpriteCategory
    /// Pixels from the top-left (7.3).
    public var anchor: PixelPoint
    /// Same size; frame 0 is the key pose shown by static renders.
    public var frames: [PixelImage]
    /// Ticks per frame; [] when one frame.
    public var holds: [Int]
    public var loops: Bool
    /// Set on a mirror; the frames are built from `source`.
    public var derivation: Derivation?
    public var source: SpriteKey?
    /// Material outline tones (q, j, u…), left out of the 12-colour cap like ink.
    public var outlineColors: Set<RGBA8>
    /// Lit volume: the left face must be lighter than the right face.
    public var lightProbe: LightProbe?

    public init(key: SpriteKey, category: SpriteCategory, anchor: PixelPoint, frames: [PixelImage], holds: [Int] = [],
                loops: Bool = true, derivation: Derivation? = nil, source: SpriteKey? = nil,
                outlineColors: Set<RGBA8> = [], lightProbe: LightProbe? = nil) {
        self.key = key
        self.category = category
        self.anchor = anchor
        self.frames = frames
        self.holds = holds
        self.loops = loops
        self.derivation = derivation
        self.source = source
        self.outlineColors = outlineColors
        self.lightProbe = lightProbe
    }

    public var width: Int { frames.first?.width ?? 0 }
    public var height: Int { frames.first?.height ?? 0 }

    /// The frame shown at `tick` (24 per second): wraps when the sprite loops, else stays on the last frame.
    public func frameIndex(atTick tick: Int) -> Int {
        guard frames.count > 1, holds.count == frames.count else { return 0 }
        let total = holds.reduce(0, +)
        guard total > 0 else { return 0 }
        var t: Int
        if loops {
            t = ((tick % total) + total) % total
        } else {
            if tick < 0 { return 0 }
            if tick >= total { return frames.count - 1 }
            t = tick
        }
        for (index, hold) in holds.enumerated() {
            if t < hold { return index }
            t -= hold
        }
        return frames.count - 1
    }
}
