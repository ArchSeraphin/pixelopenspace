import AppKit

/// Dock badge = number of agents waiting for the user (proposal 3.12, 3.13). Needs no permission, so it still
/// works when notifications are refused.
@MainActor
enum DockBadge {
    static func update(waiting: Int) {
        let label = waiting > 0 ? String(waiting) : nil
        let tile = NSApplication.shared.dockTile
        if tile.badgeLabel != label {
            tile.badgeLabel = label
        }
    }
}
