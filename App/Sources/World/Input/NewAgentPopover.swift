import AppKit
import SwiftUI

/// "Nouvel agent ici ?" (3.9): the small popover a click on a free desk opens, anchored on that desk. A click never
/// creates an agent: only "Créer" (↩) does, at that desk, and starts its session; "Annuler", Escape or a click
/// elsewhere closes it. One at a time.
@MainActor
final class NewAgentPopover {
    private var popover: NSPopover?

    var isShown: Bool { popover?.isShown ?? false }

    /// `rect`: the desk, in `view`'s coordinates.
    func show(projectName: String, relativeTo rect: CGRect, of view: NSView,
              create: @escaping @MainActor () -> Void) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let content = NewAgentPopoverContent(projectName: projectName,
                                             onCreate: { [weak self] in
                                                 self?.close()
                                                 create()
                                             },
                                             onCancel: { [weak self] in self?.close() })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        self.popover = popover
        popover.show(relativeTo: rect.insetBy(dx: -2, dy: -2), of: view, preferredEdge: .maxY)
        // Return and Escape reach the popover's buttons.
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        guard let popover else { return }
        self.popover = nil
        if popover.isShown { popover.performClose(nil) }
    }
}

private struct NewAgentPopoverContent: View {
    let projectName: String
    let onCreate: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nouvel agent ici ?")
                .font(.headline)
            Text("Un agent du projet \(projectName) s'installe à ce poste, et sa session démarre.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Créer", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .help("Créer l'agent à ce poste et lancer sa session (↩)")
            }
        }
        .padding(14)
        .frame(width: 260)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nouvel agent dans \(projectName)")
    }
}
