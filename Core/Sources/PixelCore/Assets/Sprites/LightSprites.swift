import Foundation

/// Cast shadows and night lights (7.2, 7.8, décision 10). Every sprite is opaque: shadows are `ink` and receive
/// their 30 % once, over the whole shadow layer; lights are `lampWarm` or `screenGlow` and receive
/// `Palette.lightPoolAlpha` at compositing, additively. All are anchored at their centre.
///
/// - `shadow.tile` (56×28): a floor diamond under furniture; `shadow.char` (20×8) and `shadow.small` (16×8): pixel
///   ellipses under characters, chairs and plants.
/// - `light.cone` (48×32): the lamp's light, a beam 8 px wide at the top that widens 2 px per side and row, inside
///   a 48×32 ellipse; `light.screenGlow` (24×16): a 24×12 ellipse in front of a lit screen.
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
            SpriteDef(key: SpriteKey("light.cone"), category: .lights, anchor: PixelPoint(24, 16), frames: [cone()]),
            SpriteDef(key: SpriteKey("light.screenGlow"), category: .lights, anchor: PixelPoint(12, 8), frames: [screenGlow()]),
        ]
        let twinkle = AnimationClock.holds(fps: 1, frames: 2)
        defs.append(SpriteDef(key: SpriteKey("fx.star", variant: "small"), category: .lights, anchor: PixelPoint(0, 0),
                              frames: [star(big: false, bright: true), star(big: false, bright: false)], holds: twinkle))
        defs.append(SpriteDef(key: SpriteKey("fx.star", variant: "big"), category: .lights, anchor: PixelPoint(1, 1),
                              frames: [star(big: true, bright: true), star(big: true, bright: false)], holds: twinkle))
        return defs.sorted { $0.key < $1.key }
    }()

    static func cone() -> PixelImage {
        let pool = Draw.ellipse(width: 48, height: 32, fill: Palette.color(.lampWarm))
        var image = PixelImage(width: 48, height: 32)
        for y in 0..<32 {
            for x in 0..<48 where pool[x, y].a != 0 && abs(2 * x + 1 - 48) <= 8 + 4 * y { image[x, y] = pool[x, y] }
        }
        return image
    }

    static func screenGlow() -> PixelImage {
        var image = PixelImage(width: 24, height: 16)
        image.blit(Draw.ellipse(width: 24, height: 12, fill: Palette.color(.screenGlow)), x: 0, y: 2)
        return image
    }

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
