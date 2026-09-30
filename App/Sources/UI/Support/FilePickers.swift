import AppKit
import Foundation

/// Standard open panels (application-modal: they work from a window or from a sheet).
///
/// A modal panel runs a nested run loop. Nested in a main-queue block (a `Task`, any main-actor job), that loop does
/// not drain the main queue: hooks, the clock and notifications would stop while the panel is open. Button actions
/// are fine (AppKit event handling); code running in a task uses `chooseFolderFromRunLoop`.
@MainActor
enum FilePickers {
    /// "Choisir…" a project folder.
    static func chooseFolder(startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choisir le dossier du projet"
        panel.message = "Choisis le dossier de code dans lequel les agents de ce projet travailleront."
        panel.prompt = "Choisir"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// `chooseFolder`, for a task: the panel is run from the main run loop (outside any main-queue block), so the
    /// main actor keeps working while it is open.
    static func chooseFolderFromRunLoop(startingAt directory: URL? = nil) async -> URL? {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                let url = MainActor.assumeIsolated { FilePickers.chooseFolder(startingAt: directory) }
                continuation.resume(returning: url)
            }
        }
    }

    /// "Indiquer le chemin…" of the `claude` executable (hidden folders shown: `~/.local/bin`).
    static func chooseClaudeExecutable(current: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Indiquer l'exécutable claude"
        panel.message = "Choisis le fichier claude (par exemple ~/.local/bin/claude)."
        panel.prompt = "Utiliser"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let current, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        } else {
            panel.directoryURL = home.appendingPathComponent(".local/bin", isDirectory: true)
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
