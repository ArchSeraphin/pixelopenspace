import Foundation

/// Runs a short helper command (login shell, `claude --version`) off the main thread, with a deadline.
///
/// stdin is `/dev/null`, stderr is discarded, stdout goes to a private temporary file (0600, in a 0700 folder) read
/// after the process ends: a pipe could fill up and block the child, and a daemon started by a shell rc file would
/// keep a pipe open forever. The file is deleted at once (the environment it holds may contain secrets).
enum ProcessRunner {
    struct Outcome: Sendable {
        /// Exit status; `nil` when killed by a signal, timed out or never started.
        var exitCode: Int32?
        var output: Data
        var timedOut: Bool
        /// Set when the process could not be started.
        var launchError: String?
    }

    /// Largest output kept.
    static let maxOutputBytes = 4 << 20

    static func run(executable: String, arguments: [String], environment: [String: String],
                    timeout: TimeInterval, scratchDirectory: URL) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = runBlocking(executable: executable, arguments: arguments, environment: environment,
                                          timeout: timeout, scratchDirectory: scratchDirectory)
                continuation.resume(returning: outcome)
            }
        }
    }

    private static func runBlocking(executable: String, arguments: [String], environment: [String: String],
                                    timeout: TimeInterval, scratchDirectory: URL) -> Outcome {
        let manager = FileManager.default
        let outputURL = scratchDirectory.appendingPathComponent("process-\(UUID().uuidString).out", isDirectory: false)
        guard manager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let outputHandle = try? FileHandle(forWritingTo: outputURL)
        else {
            return Outcome(exitCode: nil, output: Data(), timedOut: false,
                           launchError: "Fichier temporaire impossible dans \(scratchDirectory.path)")
        }
        defer {
            try? outputHandle.close()
            try? manager.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return Outcome(exitCode: nil, output: Data(), timedOut: false, launchError: error.localizedDescription)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        var output = (try? Data(contentsOf: outputURL)) ?? Data()
        if output.count > maxOutputBytes { output = output.prefix(maxOutputBytes) }
        let exitCode: Int32?
        if timedOut || process.isRunning || process.terminationReason == .uncaughtSignal {
            exitCode = nil
        } else {
            exitCode = process.terminationStatus
        }
        return Outcome(exitCode: exitCode, output: output, timedOut: timedOut, launchError: nil)
    }
}
