import Foundation
import PixelCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// `sprite-export`: renders the visual milestone (contact sheets, island, overview) or its golden fingerprints, or
// writes the sprite atlas and its manifest.
//
//   sprite-export [--out <dir>] [--only palette,sheets,island,overview] [--scale <n>] [--golden-out <file>]
//   sprite-export --atlas <dir>
//
// One line per file written on stdout. Exit codes: 0 success, 1 bad usage, 2 a file could not be written.

func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

let atlasUsage = """

       or: sprite-export --atlas <dir>

      --atlas <dir>        write the sprite atlas (atlas-0.png…) and manifest.json to <dir>, and no other image

    """

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--atlas") {
    guard arguments.count == 2, arguments[0] == "--atlas", !arguments[1].hasPrefix("--") else {
        writeError("sprite-export: --atlas takes a folder and no other option\n\(MilestoneExport.usage)\(atlasUsage)")
        exit(1)
    }
    do {
        try AtlasExport.write(to: arguments[1]) { print($0) }
    } catch {
        writeError("sprite-export: \(error)\n")
        exit(2)
    }
    exit(0)
}

let command: MilestoneExport.Command
do {
    command = try MilestoneExport.parse(arguments)
} catch {
    writeError("sprite-export: \(error)\n\(MilestoneExport.usage)\(atlasUsage)")
    exit(1)
}

switch command {
case .help:
    print(MilestoneExport.usage + atlasUsage, terminator: "")
case .export(let options):
    do {
        try MilestoneExport.run(options) { print($0) }
    } catch {
        writeError("sprite-export: \(error)\n")
        exit(2)
    }
}
