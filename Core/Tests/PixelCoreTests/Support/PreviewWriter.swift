import Foundation
import Testing
@testable import PixelCore

/// Writes `<PIXEL_PREVIEW_DIR>/<name>.png` (nearest upscale by `scale`) when the variable is set; no-op otherwise.
/// Drawing tests call it from their `preview()` test so a person (or the agent writing the sprites) can look at
/// the result; previews are never committed.
enum PreviewWriter {
    static let environmentKey = "PIXEL_PREVIEW_DIR"

    static func write(_ name: String, width: Int, height: Int, rgba: [UInt8], scale: Int = 1) {
        guard let directory = directory(in: ProcessInfo.processInfo.environment) else { return }
        write(name, width: width, height: height, rgba: rgba, scale: scale, to: directory)
    }

    /// The preview directory named by `PIXEL_PREVIEW_DIR`, nil when it is unset or empty.
    static func directory(in environment: [String: String]) -> String? {
        guard let value = environment[environmentKey], !value.isEmpty else { return nil }
        return value
    }

    /// Writes `<directory>/<name>.png`, creating the directory; a "/" in `name` becomes "_". A failed write is
    /// recorded as a test issue: someone asked for previews and would otherwise not get them.
    static func write(_ name: String, width: Int, height: Int, rgba: [UInt8], scale: Int = 1, to directory: String) {
        let scaled = upscale(width: width, height: height, rgba: rgba, scale: scale)
        let png = PNGEncoder.encode(width: width * scale, height: height * scale, rgba: scaled)
        let fileName = name.replacingOccurrences(of: "/", with: "_") + ".png"
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(png).write(to: folder.appendingPathComponent(fileName), options: .atomic)
        } catch {
            Issue.record("preview \(fileName) not written to \(directory): \(error)")
        }
    }

    /// Nearest-neighbour upscale by an integer factor: each texel becomes a `scale`×`scale` block.
    static func upscale(width: Int, height: Int, rgba: [UInt8], scale: Int) -> [UInt8] {
        precondition(scale >= 1, "scale must be at least 1")
        precondition(rgba.count == 4 * width * height, "rgba must hold 4·width·height bytes")
        guard scale > 1 else { return rgba }
        var output: [UInt8] = []
        output.reserveCapacity(rgba.count * scale * scale)
        var row: [UInt8] = []
        row.reserveCapacity(4 * width * scale)
        for y in 0..<height {
            row.removeAll(keepingCapacity: true)
            for x in 0..<width {
                let pixel = rgba[(4 * (y * width + x))..<(4 * (y * width + x) + 4)]
                for _ in 0..<scale { row.append(contentsOf: pixel) }
            }
            for _ in 0..<scale { output.append(contentsOf: row) }
        }
        return output
    }
}
