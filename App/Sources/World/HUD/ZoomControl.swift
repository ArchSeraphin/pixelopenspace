import PixelCore
import SwiftUI

/// The zoom of the open space in the status bar (décision 12, mockups 6(k), 6(q)): "½ | ×1 | ×2 | ×3", the zooms at
/// rest only (7.3); "½", the overview, only on a Retina screen (`WorldCamera.availableZooms`). It shows the camera's
/// zoom, whatever changed it (⌘+ ⌘− ⌘0, the pinch, the wheel), and sets it about the view's centre.
struct ZoomControl: View {
    let camera: WorldCamera

    var body: some View {
        let zooms = camera.availableZooms
        HStack(spacing: 6) {
            Text("Zoom")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker("Zoom", selection: selection) {
                ForEach(zooms, id: \.self) { zoom in
                    Text(Self.title(zoom))
                        .monospacedDigit()
                        .accessibilityLabel(Self.spokenTitle(zoom))
                        .tag(zoom)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .help("Zoom de l'open space : ⌘+ et ⌘− changent de palier, ⌘0 fait tout voir")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom de l'open space")
    }

    private var selection: Binding<SceneZoom> {
        Binding(get: { camera.pose.zoom }, set: { zoom in
            camera.setZoom(zoom, about: nil, animated: true)
        })
    }

    /// "½" (the overview: half a point per texel), "×1", "×2", "×3".
    static func title(_ zoom: SceneZoom) -> String {
        zoom == .overview ? "½" : "×\(zoom.rawValue)"
    }

    static func spokenTitle(_ zoom: SceneZoom) -> String {
        zoom == .overview ? "Vue d'ensemble" : "Zoom \(zoom.rawValue)"
    }
}
