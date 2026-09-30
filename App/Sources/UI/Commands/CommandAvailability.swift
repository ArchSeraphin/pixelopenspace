import PixelCore
import SwiftUI

/// Snapshot of which commands apply now, published by the focused window (`focusedSceneValue`), so that menu items
/// are enabled or greyed out as the model changes. A command that would replace or hide the main window's open sheet
/// is greyed out while it is open (`WorkbenchState.isAvailable`).
struct CommandAvailability: Equatable {
    var enabled: Set<AppCommand>
    /// Live projects in sidebar order, for "Aller au projet 1…9".
    var projectNames: [String]

    @MainActor
    init(model: AppModel, workbench: WorkbenchState) {
        enabled = Set(AppCommand.allCases.filter { workbench.isAvailable($0) })
        projectNames = model.projects.map(\.name)
    }

    func isEnabled(_ command: AppCommand) -> Bool {
        enabled.contains(command)
    }
}

struct CommandAvailabilityKey: FocusedValueKey {
    typealias Value = CommandAvailability
}

extension FocusedValues {
    var commandAvailability: CommandAvailability? {
        get { self[CommandAvailabilityKey.self] }
        set { self[CommandAvailabilityKey.self] = newValue }
    }
}
