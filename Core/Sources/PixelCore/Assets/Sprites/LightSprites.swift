import Foundation

/// Cast shadows and night lights (7.2, 7.8, décision 10). Every sprite is opaque: shadows are `ink` and receive
/// their 30 % once, over the whole shadow layer; lights receive `Palette.lightPoolAlpha` at compositing, additively,
/// so their falloff is drawn with the 50 % checkerboard (7.2) and with dimmer colours, never with alpha.
///
/// - `shadow.tile` (56×28): a floor diamond under furniture; `shadow.char` (20×8) and `shadow.small` (16×8): pixel
///   ellipses under characters, chairs and plants. Anchored at their centre.
/// - `light.cone` (28×14, anchor (14, 7)): the pool of a lit desk lamp on the desk top, a 2:1 ellipse (an iso circle
///   of 5 units) centred on its anchor, which goes on the desk top under the lamp
///   (`FurnitureSprites.lightConeOffset`). Solid `alertOrange` inside, a checkerboard on its outer ring: added at
///   35 %, `alertOrange` is the palette colour that stays warmest on a veiled floor (`lampWarm` turns grey mauve on
///   the blue carpets). One colour only, so that two pools that overlap (the lamps of facing desks) merge without
///   a seam. Écarts to 7.1 and 7.4 (milestone revision): 28×14 instead of 48×32, which lit the floor like a
///   spotlight, and `alertOrange` instead of `lampWarm` for the pool.
/// - `light.screenGlow` (24×16, anchor (12, 8)): the light of a working screen on the desk, a 24×12 ellipse fading
///   out: solid `screenGlow` in the middle, then a checkerboard of `screenGlow` and `uiTitle`, then `uiTitle` alone
///   on every other pixel.
/// - `fx.star` (`small` 1×1, `big` 3×3, 2 × 1 fps): stars of the night windows, bright then dim.
public enum LightSprites {
    public static func all() -> [SpriteDef] { catalog }

    private static let catalog: [SpriteDef] = {
        let ink = Palette.color(.ink)
        var defs: [SpriteDef] = [
            SpriteDef(key: SpriteKey("shadow.tile"), category: .lights, anchor: PixelPoint(28, 14),
                      frames: [Draw.isoDiamond(width: 56, fill: ink)]),
            SpriteDef(key: SpriteKey("shadow.char"), category: .lights, anchor: PixelPoint(10, 4),
                      frames: [Draw.ellipse(width: 20, height: 8, fill: ink)]),
            SpriteDef(key: SpriteKey("shadow.small"), category: .lights, anchor: PixelPoint(8, 4),
                      frames: [Draw.ellipse(width: 16, height: 8, fill: ink)]),
            SpriteDef(key: SpriteKey("light.cone"), category: .lights, anchor: coneAnchor, frames: [cone()]),
            SpriteDef(key: SpriteKey("light.screenGlow"), category: .lights, anchor: glowAnchor, frames: [screenGlow()]),
        ]
        let twinkle = AnimationClock.holds(fps: 1, frames: 2)
        defs.append(SpriteDef(key: SpriteKey("fx.star", variant: "small"), category: .lights, anchor: PixelPoint(0, 0),
                              frames: [star(big: false, bright: true), star(big: false, bright: false)], holds: twinkle))
        defs.append(SpriteDef(key: SpriteKey("fx.star", variant: "big"), category: .lights, anchor: PixelPoint(1, 1),
                              frames: [star(big: true, bright: true), star(big: true, bright: false)], holds: twinkle))
        return defs.sorted { $0.key < $1.key }
    }()

    /// Squared distance of the centre of pixel (x, y) from the centre of the width × height ellipse, in units of
    /// the ellipse: 1 on its edge.
    static func ellipseDistance(_ x: Int, _ y: Int, width: Int, height: Int) -> Double {
        let dx = Double(2 * x + 1 - width) / Double(width), dy = Double(2 * y + 1 - height) / Double(height)
        return dx * dx + dy * dy
    }

    // MARK: Lamp pool

    static let coneSize = (width: 28, height: 14)
    static let coneAnchor = PixelPoint(14, 7)
    /// Squared ellipse distance up to which the pool is solid; the checkerboard beyond, up to the edge.
    static let coneSolid = 0.5

    static func cone() -> PixelImage {
        let (w, h) = coneSize
        let warm = Palette.color(.alertOrange)
        var image = PixelImage(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let d = ellipseDistance(x, y, width: w, height: h)
                if d <= coneSolid || (d <= 1 && (x + y) % 2 == 0) { image[x, y] = warm }
            }
        }
        return image
    }

    // MARK: Screen glow

    static let glowAnchor = PixelPoint(12, 8)
    /// Squared ellipse distances: solid screenGlow up to `solid`, the two blues in a checkerboard up to `mixed`,
    /// then uiTitle on every other pixel up to the edge.
    static let glowRings = (solid: 0.2, mixed: 0.55)

    static func screenGlow() -> PixelImage {
        var image = PixelImage(width: 24, height: 16)
        let glow = Palette.color(.screenGlow), dim = Palette.color(.uiTitle)
        for y in 0..<12 {
            for x in 0..<24 {
                let d = ellipseDistance(x, y, width: 24, height: 12)
                let even = (x + y) % 2 == 0
                let color: RGBA8?
                if d <= glowRings.solid {
                    color = glow
                } else if d <= glowRings.mixed {
                    color = even ? glow : dim
                } else if d <= 1 {
                    color = even ? dim : nil
                } else {
                    color = nil
                }
                if let color { image[x, y + 2] = color }
            }
        }
        return image
    }

    // MARK: Stars

    /// Bright: a chalk point (small) or a chalk plus (big); dim: a single mist point.
    static func star(big: Bool, bright: Bool) -> PixelImage {
        let size = big ? 3 : 1, c = size / 2
        var image = PixelImage(width: size, height: size)
        guard bright else {
            image[c, c] = Palette.color(.mist)
            return image
        }
        let chalk = Palette.color(.chalk)
        image[c, c] = chalk
        if big { for (x, y) in [(0, 1), (2, 1), (1, 0), (1, 2)] { image[x, y] = chalk } }
        return image
    }
}
