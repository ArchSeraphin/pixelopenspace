import AppKit
import PixelCore
import SpriteKit
import SwiftUI

/// The SpriteKit view in SwiftUI. Each appearance builds a view and its scene; the stage (camera, textures,
/// coordinator) outlives them and fills the new scene with the whole plan.
struct WorldViewRepresentable: NSViewRepresentable {
    let stage: WorldStage

    func makeNSView(context: Context) -> WorldView {
        let view = WorldView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scene = WorldScene(size: view.bounds.size)
        scene.isFrozen = SnapshotHooks.shared.isEnabled
        view.isCaptureMode = SnapshotHooks.shared.isEnabled
        view.presentScene(scene)
        stage.attach(view: view, scene: scene)
        return view
    }

    func updateNSView(_ nsView: WorldView, context: Context) {}

    static func dismantleNSView(_ nsView: WorldView, coordinator: ()) {
        nsView.stage?.detach(view: nsView)
        nsView.presentScene(nil)
    }
}
