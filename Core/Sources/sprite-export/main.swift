import Foundation
import PixelCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// `sprite-export`: renders the visual milestone (contact sheets, island, overview) or its golden fingerprints.
//
//   sprite-export [--out <dir>] [--only palette,sheets,island,overview] [--scale <n>] [--golden-out <file>]
//
// One line per file written on stdout. Exit codes: 0 success, 1 bad usage, 2 a file could not be written.

func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

let command: MilestoneExport.Command
do {
    command = try MilestoneExport.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    writeError("sprite-export: \(error)\n\(MilestoneExport.usage)")
    exit(1)
}

switch command {
case .help:
    print(MilestoneExport.usage, terminator: "")
case .export(let options):
    do {
        try MilestoneExport.run(options) { print($0) }
    } catch {
        writeError("sprite-export: \(error)\n")
        exit(2)
    }
}
