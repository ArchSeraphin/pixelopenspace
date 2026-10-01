import CoreGraphics
import Foundation

/// The command line of the snapshot harness and of the demo mode (step 3, task 1):
/// `--snapshot <dossier> [--scenario <id,id…>] [--size LxH] [--keep-state]` or `--demo [--size LxH] [--keep-state]`.
/// Both run on a temporary, isolated state; without either, the app launches normally.
struct SnapshotOptions: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case snapshot(output: URL, scenarios: [SnapshotScenario.ID])
        case demo
    }

    /// A French message for stderr, followed by `SnapshotOptions.usage`.
    struct ParseError: Error, Equatable, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    var mode: Mode
    /// --size 1440x900 (default): the main window's content, in points.
    var windowSize: CGSize
    /// --keep-state: leave the temporary state folder, its path in the report.
    var keepState: Bool

    static let defaultWindowSize = CGSize(width: 1440, height: 900)
    static let minimumWindowSize = CGSize(width: 400, height: 300)
    static let maximumWindowSize = CGSize(width: 7680, height: 4320)

    static var usage: String {
        let scenarios = SnapshotScenario.ID.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        Utilisation :
          PixelOpenSpace --snapshot <dossier> [--scenario <id,id…>] [--size LxH] [--keep-state]
          PixelOpenSpace --demo [--size LxH] [--keep-state]
        Scénarios : \(scenarios), all (par défaut : all).
        Taille de la fenêtre en points, par défaut 1440x900.
        """
    }

    /// `arguments` without the executable path (`CommandLine.arguments.dropFirst()`). nil when neither --snapshot nor
    /// --demo is given (normal launch). Unknown arguments starting with a single "-" that AppKit or Xcode add
    /// (-NSDocumentRevisionsDebugMode YES, -ApplePersistenceIgnoreState YES, -psn_…) are ignored with their value.
    static func parse(_ arguments: [String]) throws -> SnapshotOptions? {
        var output: String?
        var demo = false
        var scenarios: [SnapshotScenario.ID]?
        var size: CGSize?
        var keepState = false

        var index = 0
        func value(for option: String) throws -> String {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                throw ParseError(message: "\(option) attend une valeur.")
            }
            index += 1
            return arguments[index]
        }
        func once<T>(_ current: T?, _ option: String) throws {
            if current != nil { throw ParseError(message: "\(option) est donné deux fois.") }
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--snapshot":
                try once(output, argument)
                output = try value(for: argument)
            case "--demo":
                if demo { throw ParseError(message: "--demo est donné deux fois.") }
                demo = true
            case "--scenario":
                try once(scenarios, argument)
                scenarios = try parseScenarios(try value(for: argument))
            case "--size":
                try once(size, argument)
                size = try parseSize(try value(for: argument))
            case "--keep-state":
                keepState = true
            default:
                if argument.hasPrefix("--") {
                    throw ParseError(message: "Option inconnue : \(argument).")
                } else if argument.hasPrefix("-psn_") {
                    // Finder's process serial number: no value.
                } else if argument.hasPrefix("-"), argument.count > 1 {
                    // An AppKit or Xcode default (-Key value): skipped with its value.
                    if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") { index += 1 }
                } else {
                    throw ParseError(message: "Argument inattendu : \(argument).")
                }
            }
            index += 1
        }

        if output != nil, demo {
            throw ParseError(message: "--snapshot et --demo ne vont pas ensemble.")
        }
        if scenarios != nil, output == nil {
            throw ParseError(message: "--scenario ne s'emploie qu'avec --snapshot.")
        }
        let windowSize = size ?? defaultWindowSize
        if let output {
            let url = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
            return SnapshotOptions(mode: .snapshot(output: url, scenarios: scenarios ?? SnapshotScenario.ID.allCases),
                                   windowSize: windowSize, keepState: keepState)
        }
        if demo {
            return SnapshotOptions(mode: .demo, windowSize: windowSize, keepState: keepState)
        }
        if size != nil || keepState {
            throw ParseError(message: "--size et --keep-state ne s'emploient qu'avec --snapshot ou --demo.")
        }
        return nil
    }

    /// "zooms,list" → in the given order, without repeats; "all" anywhere → every scenario, in the order of `all`.
    /// Case-insensitive ("agentWindow" is "agentwindow").
    static func parseScenarios(_ text: String) throws -> [SnapshotScenario.ID] {
        let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { throw ParseError(message: "--scenario attend au moins un scénario.") }
        if names.contains("all") { return SnapshotScenario.ID.allCases }
        var result: [SnapshotScenario.ID] = []
        for name in names {
            guard let id = SnapshotScenario.ID(rawValue: name) else {
                let known = SnapshotScenario.ID.allCases.map(\.rawValue).joined(separator: ", ")
                throw ParseError(message: "Scénario inconnu : \(name) (connus : \(known), all).")
            }
            if !result.contains(id) { result.append(id) }
        }
        return result
    }

    /// "1440x900" (or "1440X900"), in points, within `minimumWindowSize` … `maximumWindowSize`.
    static func parseSize(_ text: String) throws -> CGSize {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            throw ParseError(message: "--size attend une taille LxH en points, par exemple 1440x900 (reçu : \(text)).")
        }
        let size = CGSize(width: width, height: height)
        guard size.width >= minimumWindowSize.width, size.height >= minimumWindowSize.height,
              size.width <= maximumWindowSize.width, size.height <= maximumWindowSize.height else {
            throw ParseError(message: "--size : \(text) sort des limites (de 400x300 à 7680x4320).")
        }
        return size
    }
}
