import PixelCore
import SwiftUI

/// The open space in the main window (scene mode, the default; ⌘L shows the list instead): the SpriteKit view, and,
/// while there is no project, the card of the empty world (6(r)) over the hall. Starts and stops the coordinator
/// with its appearance.
struct WorldAreaView: View {
    let stage: WorldStage

    @Environment(AppModel.self) private var model

    var body: some View {
        WorldViewRepresentable(stage: stage)
            .overlay {
                if model.projects.isEmpty {
                    EmptyWorldCard()
                        .padding(24)
                }
            }
            .onAppear { stage.coordinator?.start() }
            .onDisappear { stage.coordinator?.stop() }
    }
}
