import Foundation

/// One-shot effects of 7.4.8 (stage 3 set): dust when furniture lands, the elevator "ding", a post-it dropped on
/// an agent. Each plays once and ends on a nearly empty frame; the compositor removes it afterwards.
public enum EffectSprites {
    public static func all() -> [SpriteDef] { catalog }

    private static let catalog: [SpriteDef] = [
        effect("fx.ding", anchor: PixelPoint(6, 12), frames: (0..<3).map(ding), fps: 8),
        effect("fx.dust", anchor: PixelPoint(12, 16), frames: (0..<6).map(dust), fps: 12),
        effect("fx.pinDrop", anchor: PixelPoint(6, 8), frames: (0..<3).map(pinDrop), fps: 12),
    ].sorted { $0.key < $1.key }

    private static func effect(_ id: SpriteID, anchor: PixelPoint, frames: [PixelImage], fps: Double) -> SpriteDef {
        SpriteDef(key: SpriteKey(id), category: .effects, anchor: anchor, frames: frames,
                  holds: AnimationClock.holds(fps: fps, frames: frames.count), loops: false)
    }

    // MARK: Dust

    /// Two puffs rolling outward and a third rising, shrinking frame after frame.
    private static func dust(_ frame: Int) -> PixelImage {
        var image = PixelImage(width: 24, height: 16)
        let side = [4, 4, 3, 3, 2, 1][frame], middle = [3, 3, 2, 2, 1, 0][frame]
        let spread = 4 + 3 * frame / 2, rise = frame
        puff(into: &image, cx: 12, cy: 10 - rise, r: middle)
        puff(into: &image, cx: 12 - spread, cy: 12 - rise, r: side)
        puff(into: &image, cx: 12 + spread, cy: 12 - rise, r: side)
        return image
    }

    /// Disc of radius r centred on the pixel corner (cx, cy): paper on its lit top left, mist, stone underneath.
    private static func puff(into image: inout PixelImage, cx: Int, cy: Int, r: Int) {
        guard r > 0 else { return }
        for y in (cy - r)..<(cy + r) {
            for x in (cx - r)..<(cx + r) {
                let dx = 2 * (x - cx) + 1, dy = 2 * (y - cy) + 1
                guard dx * dx + dy * dy <= 4 * r * r else { continue }
                let role: PaletteRole
                if dy >= r { role = .stone }
                else if dx + dy < -r { role = .paper }
                else { role = .mist }
                image.set(x, y, Palette.color(role))
            }
        }
    }

    // MARK: Ding

    /// A small bell with chalk rays that spread, then only the far sparks.
    private static func ding(_ frame: Int) -> PixelImage {
        var image = PixelImage(width: 12, height: 12)
        let bell = OverlayArt.glyph([
            "..##..",
            ".####.",
            ".####.",
            ".####.",
            "######",
        ], color: Palette.color(.lampWarm))
        var shaded = bell
        for y in 0..<bell.height {
            // The right column of each row in woodMid: light from the left.
            if let last = (0..<bell.width).last(where: { bell[$0, y].a != 0 }) { shaded[last, y] = Palette.color(.woodMid) }
        }
        let swing = frame == 1 ? -1 : 0
        image.blit(PixelFont.ringed(shaded, color: Palette.color(.woodDark)), x: 2 + swing, y: 3)
        image[5 + swing, 10] = Palette.color(.woodDark)                    // clapper
        image[6 + swing, 10] = Palette.color(.woodDark)
        let chalk = Palette.color(.chalk)
        let rays: [[(Int, Int)]] = [
            [(5, 1), (6, 1), (1, 3), (0, 2), (10, 3), (11, 2)],
            [(5, 0), (6, 0), (0, 1), (1, 2), (11, 1), (10, 2), (0, 6), (11, 6)],
            [(4, 0), (7, 0), (0, 0), (11, 0), (0, 5), (11, 5)],
        ]
        for (x, y) in rays[frame] { image[x, y] = chalk }
        return image
    }

    // MARK: Pin drop

    /// Impact on the floor: a flat ring that widens, then breaks into dots.
    private static func pinDrop(_ frame: Int) -> PixelImage {
        var image = PixelImage(width: 12, height: 8)
        let (w, h) = [(6, 3), (10, 4), (12, 6)][frame]
        let ring = OverlayArt.outerRing(Draw.ellipse(width: w, height: h, fill: Palette.color(.ink)).alphaMask())
        OverlayArt.paint(ring, into: &image, at: PixelPoint((12 - w) / 2, 8 - h), color: Palette.color(.chalk)) { x, _ in
            frame < 2 || x % 2 == 0
        }
        if frame == 0 {
            for (x, y) in [(3, 2), (8, 2), (6, 0)] { image[x, y] = Palette.color(.chalk) }
        }
        return image
    }
}
