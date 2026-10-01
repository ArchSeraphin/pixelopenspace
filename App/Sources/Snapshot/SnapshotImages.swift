import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PixelCore
import UniformTypeIdentifiers

/// Images of the snapshot harness: window captures, PNG files, the software reference and its comparison with a
/// capture of the scene (décision 3: tolerance of 1 per channel, transparent reference pixels ignored).
enum SnapshotImages {
    /// A pixel is a mismatch when one channel differs by more than this, where the reference is opaque.
    static let tolerance = 1

    /// The comparison of a scene capture with its reference.
    struct Comparison {
        var mismatches: Int
        /// Opaque reference pixels compared.
        var compared: Int
        /// The reference cropped to the visible rect, scaled to the capture.
        var reference: CGImage
        /// The reference darkened by half, the mismatches in magenta.
        var diff: CGImage
        /// Set when the capture is not `visibleCanvasRect × pixelsPerTexel` pixels: only the common part is compared.
        var sizeNote: String?
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: Windows and files

    /// The window's content drawn by `bitmapImageRepForCachingDisplay(in:)` and `cacheDisplay(in:to:)`, at the
    /// window's backing scale, laid on the window's background.
    @MainActor
    static func capture(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let content = rep.cgImage else { return nil }
        return onBackground(content, of: window) ?? content
    }

    /// `cacheDisplay` draws the content view only: the window's background, drawn by its frame view, is missing
    /// under translucent views (the waiting tray and the banners are tints of 10 to 14 %). Fills it in, in the
    /// window's appearance (dark or light), as on screen.
    @MainActor
    static func onBackground(_ content: CGImage, of window: NSWindow) -> CGImage? {
        var fill: CGColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = window.backgroundColor.cgColor
        }
        guard let fill else { return nil }
        let width = content.width, height = content.height
        var space = sRGB
        if let own = content.colorSpace, own.model == .rgb, own.supportsOutput { space = own }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(fill)
        context.fill(frame)
        context.interpolationQuality = .none
        context.draw(content, in: frame)
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Conversions

    /// R G B A bytes (straight alpha), rows top to bottom.
    static func bytes(_ image: PixelImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        image.pixels.withUnsafeBufferPointer { source in
            bytes.withUnsafeMutableBufferPointer { out in
                for i in 0..<source.count {
                    let p = source[i]
                    out[4 * i] = p.r
                    out[4 * i + 1] = p.g
                    out[4 * i + 2] = p.b
                    out[4 * i + 3] = p.a
                }
            }
        }
        return bytes
    }

    /// An sRGB image of straight-alpha R G B A bytes.
    static func cgImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// `image` scaled by `scale` (nearest neighbour), as an sRGB image.
    static func cgImage(_ image: PixelImage, scale: Int = 1) -> CGImage? {
        guard let base = cgImage(bytes: bytes(image), width: image.width, height: image.height) else { return nil }
        guard scale > 1 else { return base }
        let width = image.width * scale, height = image.height * scale
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The image's R G B A bytes, read in its own colour space (no conversion); premultiplied, which leaves opaque
    /// pixels as they are.
    static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var space = sRGB
        if let own = image.colorSpace, own.model == .rgb, own.supportsOutput { space = own }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    // MARK: Comparison

    /// Reference = `canvas` (the whole world at 1 pixel per texel: `SceneCompositor.render` at `.overview` or `.x1`)
    /// cropped to `capture.visibleCanvasRect`, scaled to the nearest by `capture.pixelsPerTexel`. A pixel is a
    /// mismatch when a channel differs by more than `tolerance` and the reference is opaque.
    static func compare(_ capture: SceneCapture, canvas: PixelImage) -> Comparison? {
        let rect = capture.visibleCanvasRect
        let scale = max(capture.pixelsPerTexel, 1)
        let expectedWidth = rect.width * scale, expectedHeight = rect.height * scale
        let captureWidth = capture.image.width, captureHeight = capture.image.height
        let width = min(expectedWidth, captureWidth), height = min(expectedHeight, captureHeight)
        guard width > 0, height > 0, let captured = rgbaBytes(of: capture.image) else { return nil }
        var sizeNote: String?
        if expectedWidth != captureWidth || expectedHeight != captureHeight {
            sizeNote = "capture de \(captureWidth) × \(captureHeight) px pour \(expectedWidth) × \(expectedHeight) px "
                + "attendus : seule la partie commune est comparée"
        }

        var reference = [UInt8](repeating: 0, count: width * height * 4)
        var diff = [UInt8](repeating: 0, count: width * height * 4)
        var mismatches = 0
        var compared = 0
        let tolerance = Self.tolerance
        canvas.pixels.withUnsafeBufferPointer { texels in
            captured.withUnsafeBufferPointer { shot in
                reference.withUnsafeMutableBufferPointer { ref in
                    diff.withUnsafeMutableBufferPointer { out in
                        for y in 0..<height {
                            let ty = rect.y + y / scale
                            let rowInside = ty >= 0 && ty < canvas.height
                            for x in 0..<width {
                                let tx = rect.x + x / scale
                                let o = (y * width + x) * 4
                                guard rowInside, tx >= 0, tx < canvas.width else { continue }
                                let p = texels[ty * canvas.width + tx]
                                ref[o] = p.r
                                ref[o + 1] = p.g
                                ref[o + 2] = p.b
                                ref[o + 3] = p.a
                                guard p.a == 255 else { continue }
                                compared += 1
                                let c = (y * captureWidth + x) * 4
                                let differs = abs(Int(shot[c]) - Int(p.r)) > tolerance
                                    || abs(Int(shot[c + 1]) - Int(p.g)) > tolerance
                                    || abs(Int(shot[c + 2]) - Int(p.b)) > tolerance
                                if differs {
                                    mismatches += 1
                                    out[o] = 255
                                    out[o + 1] = 0
                                    out[o + 2] = 255
                                } else {
                                    out[o] = p.r / 2
                                    out[o + 1] = p.g / 2
                                    out[o + 2] = p.b / 2
                                }
                                out[o + 3] = 255
                            }
                        }
                    }
                }
            }
        }
        guard let referenceImage = cgImage(bytes: reference, width: width, height: height),
              let diffImage = cgImage(bytes: diff, width: width, height: height) else { return nil }
        return Comparison(mismatches: mismatches, compared: compared, reference: referenceImage, diff: diffImage,
                          sizeNote: sizeNote)
    }

    /// `selftest`: a reference compared with itself (0 mismatches expected) and with a copy shifted by one texel
    /// (mismatches expected), through the same path as a scene capture (CGImage, crop, scale ×2). The French verdict
    /// starts with "outil de comparaison : OK" when both hold.
    static func selfTest(canvas: PixelImage, input: SceneInput) -> (ok: Bool, text: String, diff: CGImage?) {
        let width = min(360, canvas.width - 2), height = min(240, canvas.height)
        guard width > 0, height > 0 else {
            return (false, "outil de comparaison : ÉCHEC : référence vide (\(canvas.width) × \(canvas.height))", nil)
        }
        let rect = PixelRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
        var shiftedRect = rect
        shiftedRect.x += 1
        guard let same = cgImage(canvas.cropped(rect), scale: 2),
              let shifted = cgImage(canvas.cropped(shiftedRect), scale: 2) else {
            return (false, "outil de comparaison : ÉCHEC : images de contrôle impossibles à construire", nil)
        }
        func capture(_ image: CGImage) -> SceneCapture {
            SceneCapture(image: image, input: input, overview: false, visibleCanvasRect: rect, pixelsPerTexel: 2,
                         stats: [:])
        }
        guard let identical = compare(capture(same), canvas: canvas),
              let moved = compare(capture(shifted), canvas: canvas) else {
            return (false, "outil de comparaison : ÉCHEC : comparaison impossible", nil)
        }
        let details = "identique : \(identical.mismatches) écart sur \(identical.compared) pixels comparés ; "
            + "décalé d'un texel : \(moved.mismatches) écarts"
        if identical.compared > 0, identical.mismatches == 0, moved.mismatches > 0, identical.sizeNote == nil {
            return (true, "outil de comparaison : OK (\(details))", moved.diff)
        }
        return (false, "outil de comparaison : ÉCHEC (\(details))", moved.diff)
    }
}

/// The software references of the harness, rendered once per scene and zoom kind.
@MainActor
final class SnapshotReferences {
    private var canvases: [(input: SceneInput, overview: Bool, image: PixelImage)] = []
    private var files: [(input: SceneInput, zoom: SceneZoom, png: Data, width: Int, height: Int)] = []

    /// The whole world at 1 pixel per texel: `SceneCompositor.render` at `.overview` or `.x1`.
    func canvas(_ input: SceneInput, overview: Bool) -> PixelImage {
        if let hit = canvases.first(where: { $0.overview == overview && $0.input == input }) { return hit.image }
        let image = SceneCompositor.render(input, options: RenderOptions(zoom: overview ? .overview : .x1))
        canvases.append((input, overview, image))
        if canvases.count > 4 { canvases.removeFirst() }
        return image
    }

    /// The whole world at `zoom`, as a PNG (the same bytes as `SceneCompositor.render(input, zoom)`), with its size.
    func png(_ input: SceneInput, zoom: SceneZoom) -> (data: Data, width: Int, height: Int)? {
        if let hit = files.first(where: { $0.zoom == zoom && $0.input == input }) {
            return (hit.png, hit.width, hit.height)
        }
        let canvas = canvas(input, overview: zoom == .overview)
        guard let image = SnapshotImages.cgImage(canvas, scale: zoom.pixelsPerTexel),
              let data = SnapshotImages.pngData(image) else { return nil }
        files.append((input, zoom, data, image.width, image.height))
        if files.count > 6 { files.removeFirst() }
        return (data, image.width, image.height)
    }
}
