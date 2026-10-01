import CoreGraphics
import PixelCore
import SwiftUI

/// A Core sprite frame as a SwiftUI image at the UI scale (2 pt per texel, 7.3), never smoothed; rotations by
/// multiples of 90° only (clockwise, done on the pixels: the texels stay on their grid, never turned by 45°).
struct SpriteImage: View {
    /// Points per texel of the interface (7.3): the HUD over the scene, whatever the scene's zoom.
    static let pointsPerTexel: CGFloat = 2

    private enum Source {
        case sprite(SpriteKey, frame: Int, quarterTurns: Int)
        case composed(PixelImage)
        case image(CGImage)
    }

    private let source: Source

    init(_ key: SpriteKey, frame: Int = 0, quarterTurns: Int = 0) {
        source = .sprite(key, frame: frame, quarterTurns: quarterTurns)
    }

    /// A composed image (a name plate, a 9-slice), same scale; its texture is cached by its pixels.
    init(composed image: PixelImage) {
        source = .composed(image)
    }

    /// An image already converted, one pixel per texel (the minimap's, recomposed only when the world changes).
    init(image: CGImage) {
        source = .image(image)
    }

    var body: some View {
        if let image = resolved {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: CGFloat(image.width) * Self.pointsPerTexel,
                       height: CGFloat(image.height) * Self.pointsPerTexel)
        }
    }

    private var resolved: CGImage? {
        switch source {
        case .sprite(let key, let frame, let turns): return SpriteImageCache.image(key, frame: frame, quarterTurns: turns)
        case .composed(let image): return SpriteImageCache.image(composed: image)
        case .image(let image): return image
        }
    }

    /// Size in points of a sprite at the UI scale, after `quarterTurns`; zero for an unknown key.
    static func size(of key: SpriteKey, quarterTurns: Int = 0) -> CGSize {
        guard let def = SpriteCatalog.sprite(key) else { return .zero }
        let turned = quarterTurns % 2 != 0
        let width = CGFloat(turned ? def.height : def.width), height = CGFloat(turned ? def.width : def.height)
        return CGSize(width: width * pointsPerTexel, height: height * pointsPerTexel)
    }

    /// Size in points of a composed image at the UI scale.
    static func size(of image: PixelImage) -> CGSize {
        CGSize(width: CGFloat(image.width) * pointsPerTexel, height: CGFloat(image.height) * pointsPerTexel)
    }
}

/// The textures of the HUD: catalog frames by (key, frame, turns), kept for the app's life (a few dozen at most);
/// composed images by fingerprint, forgotten past `composedLimit`.
@MainActor
enum SpriteImageCache {
    static let composedLimit = 128

    private struct Key: Hashable {
        var key: SpriteKey
        var frame: Int
        var turns: Int
    }

    private static var sprites: [Key: CGImage] = [:]
    private static var composed: [String: CGImage] = [:]
    private static var nameplates: [String: CGImage] = [:]

    /// `HUDSprites.nameplate(text, off: false)`, composed once per text (the edge arrows redraw while the camera
    /// moves).
    static func nameplate(_ text: String) -> CGImage? {
        if let cached = nameplates[text] { return cached }
        guard let image = HUDSprites.nameplate(text, off: false).cgImage() else { return nil }
        if nameplates.count >= composedLimit { nameplates.removeAll(keepingCapacity: true) }
        nameplates[text] = image
        return image
    }

    static func image(_ key: SpriteKey, frame: Int, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        let cacheKey = Key(key: key, frame: frame, turns: turns)
        if let cached = sprites[cacheKey] { return cached }
        guard let def = SpriteCatalog.sprite(key), !def.frames.isEmpty else { return nil }
        let pixels = def.frames[min(max(frame, 0), def.frames.count - 1)].rotatedClockwise(turns)
        guard let image = pixels.cgImage() else { return nil }
        sprites[cacheKey] = image
        return image
    }

    static func image(composed pixels: PixelImage) -> CGImage? {
        let key = pixels.fingerprint
        if let cached = composed[key] { return cached }
        guard let image = pixels.cgImage() else { return nil }
        if composed.count >= composedLimit { composed.removeAll(keepingCapacity: true) }
        composed[key] = image
        return image
    }
}

extension PixelImage {
    /// The image turned clockwise by `quarterTurns` × 90° (negative: counter-clockwise), pixel for pixel.
    func rotatedClockwise(_ quarterTurns: Int) -> PixelImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        let source = pixels, w = width, h = height
        let outWidth = turns == 2 ? w : h, outHeight = turns == 2 ? h : w
        var out = [RGBA8](repeating: .clear, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let (nx, ny): (Int, Int)
                switch turns {
                case 1: (nx, ny) = (h - 1 - y, x)            // the top row becomes the right column
                case 2: (nx, ny) = (w - 1 - x, h - 1 - y)
                default: (nx, ny) = (y, w - 1 - x)           // the top row becomes the left column
                }
                out[ny * outWidth + nx] = source[y * w + x]
            }
        }
        return PixelImage(width: outWidth, height: outHeight, pixels: out)
    }
}
