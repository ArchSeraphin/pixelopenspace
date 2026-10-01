import AppKit
import Foundation

/// The only `@main`. Parses the command line, then runs the snapshot harness (`--snapshot`) or the demo mode
/// (`--demo`), both on a temporary, isolated state, or the normal app. A command line it cannot read: a French message
/// and the usage on stderr, exit code 1. A normal launch evaluates nothing of the isolated modes, and they never
/// evaluate `AppEnvironment.shared`.
@main
enum AppEntry {
    @MainActor
    static func main() {
        let options: SnapshotOptions?
        do {
            options = try SnapshotOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("PixelOpenSpace : \(error)\n\n\(SnapshotOptions.usage)\n".utf8))
            exit(1)
        }
        guard let options else {
            PixelOpenSpaceApp.main()
            return
        }
        switch options.mode {
        case .snapshot:
            SnapshotRunner.run(options)
        case .demo:
            DemoMode.run(options)
        }
    }
}
