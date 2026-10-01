import AppKit
import CoreGraphics
import Foundation
import Metal
import PixelCore
import QuartzCore
import SpriteKit

/// The hooks of the snapshot harness owned by the scene (step 3, task 7): `listView`, `zoom`, `fitAll`, `focus`,
/// `cameraNudge`, and the scene provider (offscreen capture, still image). Registered with the stage, only when the
/// harness is active. In the harness the scene is frozen on the frames of tick 0 and every step plans at once.
@MainActor
enum WorldSnapshotHooks {
    static let owner = "tâche 7"

    static func register(stage: WorldStage, model: AppModel, workbench: WorkbenchState) {
        let hooks = SnapshotHooks.shared
        guard hooks.isEnabled else { return }
        hooks.register(.listView, owner: owner) { [weak workbench] step in
            guard case .listView(let on) = step, let workbench else { return false }
            workbench.mainView = on ? .list : .scene
            return true
        }
        hooks.register(.zoom, owner: owner) { [weak stage] step in
            guard case .zoom(let zoom) = step, let stage, ready(stage) else { return false }
            stage.camera.setZoom(zoom, about: nil, animated: false)
            stage.settle()
            return true
        }
        hooks.register(.fitAll, owner: owner) { [weak stage] step in
            guard case .fitAll = step, let stage, ready(stage) else { return false }
            stage.camera.fitAll(animated: false)
            stage.settle()
            return true
        }
        hooks.register(.focus, owner: owner) { [weak stage, weak model] step in
            guard let stage, let model, ready(stage) else { return false }
            let target: CameraTarget
            switch step {
            case .focusIsland(let name):
                guard let id = stage.projectID(named: name, in: model) else { return false }
                target = .island(id, part: 0)
            case .focusAgent(let name):
                guard let id = stage.agentID(named: name, in: model) else { return false }
                target = .agent(id)
            case .focusHall:
                target = .hall
            default:
                return false
            }
            guard stage.scenePoint(for: target) != nil else { return false }
            stage.camera.center(on: target)
            stage.settle()
            return true
        }
        hooks.register(.cameraNudge, owner: owner) { [weak stage] step in
            guard case .cameraNudge(let dx, let dy) = step, let stage, ready(stage) else { return false }
            // Texels along the scene axes, not snapped: the camera snaps the pose it shows (7.3, rule 2).
            let p = CameraMath.pointsPerTexel(stage.camera.pose.zoom)
            stage.camera.pan(byViewPoints: SceneVector(dx * p, dy * p))
            stage.settle()
            return true
        }
        hooks.registerScene(stage)
    }

    /// The scene is on screen, planned, and its camera placed.
    private static func ready(_ stage: WorldStage) -> Bool {
        guard stage.view?.window != nil, stage.scene != nil else { return false }
        stage.settle()
        return stage.camera.isPlaced && stage.plan != nil
    }
}

extension WorldStage: SceneCaptureProviding {
    /// The scene as SpriteKit draws it, rendered offscreen by `SKRenderer` with the same scene and camera, at the
    /// display scale, HUD hidden; cropped to whole texels, so that its first pixel is a texel's corner.
    func captureScene() async -> SceneCapture? {
        guard let view, let scene, view.window != nil else { return nil }
        settle()
        guard let plan, let input, camera.isPlaced else { return nil }
        let pose = camera.pose, metrics = camera.view
        let scale = max(1, metrics.backingScale)
        let pixelWidth = Int((metrics.width * Double(scale)).rounded())
        let pixelHeight = Int((metrics.height * Double(scale)).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        // Whole texels inside the view: the snapped pose puts every integer texel edge on a pixel edge.
        let box = CameraMath.visibleBox(pose, view: metrics)
        let pixelsPerTexel = CameraMath.pointsPerTexel(pose.zoom) * Double(scale)
        let epsilon = 1e-6
        let left = (box.minX - epsilon).rounded(.up), right = (box.maxX + epsilon).rounded(.down)
        let top = (box.maxY + epsilon).rounded(.down), bottom = (box.minY - epsilon).rounded(.up)
        let texelsWide = Int(right - left), texelsHigh = Int(top - bottom)
        let k = Int(pixelsPerTexel.rounded())
        guard texelsWide > 0, texelsHigh > 0, k > 0 else { return nil }

        scene.hudLayer.isHidden = true
        let wasPaused = view.isPaused
        view.isPaused = true
        defer {
            scene.hudLayer.isHidden = false
            if view.scene !== scene { view.presentScene(scene) }
            view.isPaused = wasPaused
        }
        let image: CGImage
        var usedFallback = false
        if let full = WorldOffscreenRenderer.render(scene, pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
            let crop = CGRect(x: ((left - box.minX) * pixelsPerTexel).rounded(),
                              y: ((box.maxY - top) * pixelsPerTexel).rounded(),
                              width: Double(texelsWide * k), height: Double(texelsHigh * k))
            guard let cropped = full.cropping(to: crop) else { return nil }
            image = cropped
            lastCapture = (cropped, full)
        } else {
            // Without Metal for SKRenderer: the view renders the whole texels of the visible box (camera ignored),
            // scaled to the nearest pixel. Not pixel exact (about a pixel off at ×1 and above, tried on macOS 26): the
            // report shows its mismatches, and `fallbackCapture` says why.
            let crop = CGRect(x: left, y: bottom, width: Double(texelsWide), height: Double(texelsHigh))
            guard let texture = view.texture(from: scene, crop: crop),
                  let scaled = WorldOffscreenRenderer.resized(texture.cgImage(), width: texelsWide * k,
                                                              height: texelsHigh * k) else { return nil }
            image = scaled
            lastCapture = nil
            usedFallback = true
        }

        let corner = plan.canvasPoint(ScenePoint(x: Int(left), y: Int(top)))
        var stats = registry.stats
        stats["nodes"] = scene.spriteCount
        stats["backgroundTiles"] = scene.backgroundTileCount
        if usedFallback { stats["fallbackCapture"] = 1 }
        return SceneCapture(image: image, input: input, overview: pose.zoom == .overview,
                            visibleCanvasRect: PixelRect(x: corner.x, y: corner.y, width: texelsWide, height: texelsHigh),
                            pixelsPerTexel: k, stats: stats)
    }

    /// The whole view's drawing (not the crop the harness compares) over the Metal view.
    func showStill(_ image: CGImage) -> @MainActor () -> Void {
        guard let view else { return {} }
        let shown = lastCapture.flatMap { $0.cropped === image ? $0.full : nil } ?? image
        // The fallback's image covers whole texels only, a little less than the view: shown stretched.
        return view.showStill(shown)
    }
}

/// `SKRenderer` into a Metal texture, read back as an sRGB image (the values the scene wrote, no colour conversion).
///
/// Found by trial on macOS 26: a renderer draws nothing on its first frame (one frame is drawn and thrown away
/// first); it does not fill the scene's background colour (the clear colour does); and a `.resizeFill` scene takes the
/// viewport's size in pixels, so the scene is switched to `.fill` meanwhile: its size in points maps onto the
/// viewport, `backingScale` pixels per point, as in the view.
@MainActor
enum WorldOffscreenRenderer {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()

    static func render(_ scene: SKScene, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let device, let queue else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixelWidth,
                                                                  height: pixelHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let background = scene.backgroundColor.usingColorSpace(.sRGB) ?? scene.backgroundColor
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: background.redComponent, green: background.greenComponent,
                                                            blue: background.blueComponent, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        let size = scene.size, mode = scene.scaleMode
        scene.scaleMode = .fill
        defer {
            scene.scaleMode = mode
            scene.size = size
        }
        let renderer = SKRenderer(device: device)
        renderer.ignoresSiblingOrder = true
        renderer.scene = scene
        let viewport = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let now = CACurrentMediaTime()
        for pass in [pass, pass] {
            guard let buffer = queue.makeCommandBuffer() else { return nil }
            renderer.update(atTime: now)
            renderer.render(withViewport: viewport, commandBuffer: buffer, renderPassDescriptor: pass)
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.synchronize(resource: texture)
                blit.endEncoding()
            }
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        renderer.scene = nil

        let count = pixelWidth * pixelHeight * 4
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        defer { raw.deallocate() }
        texture.getBytes(raw, bytesPerRow: pixelWidth * 4, from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
                         mipmapLevel: 0)
        var bytes = [UInt8](UnsafeRawBufferPointer(start: raw, count: count))
        // BGRA to RGBA.
        bytes.withUnsafeMutableBufferPointer { out in
            var index = 0
            while index < out.count {
                out.swapAt(index, index + 2)
                index += 4
            }
        }
        return SnapshotImages.cgImage(bytes: bytes, width: pixelWidth, height: pixelHeight)
    }

    /// `image` drawn to the nearest pixel at `width` × `height` (the fallback's texture may come at another scale).
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width && image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: SnapshotImages.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
