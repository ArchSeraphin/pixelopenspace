import Foundation
import Observation
import PixelCore

/// What the pointer and the animations do to the scene, read by the coordinator into `SceneInput` (the plan draws the
/// marks): the hovered target (task 9), the drop target of a dragged post-it (task 12), the agents walking from the
/// elevator, left out of the plan meanwhile (task 11).
@MainActor
@Observable
final class WorldInteractionState {
    var hovered: SceneHitTarget?
    var dropTarget: SceneHitTarget?
    var hiddenAgents: Set<AgentID> = []
}
