import Foundation

/// What `sprite-export --atlas <dir>` writes (7.6): the pages of the atlas of `SpriteCatalog.all` and their manifest.
public enum AtlasExport {
    /// "atlas-0.png"… and "manifest.json" for SpriteCatalog.all, in that order.
    public static func files() throws -> [(name: String, bytes: [UInt8])] {
        try outputs(defs: SpriteCatalog.all).map { ($0.name, $0.bytes) }
    }

    /// Writes `files()` into `directory` (created when missing), each file atomically; `log` gets one line per file
    /// ("atlas-0.png 2048×2048 n bytes", "manifest.json n bytes").
    public static func write(to directory: String, log: (String) -> Void) throws {
        try write(outputs(defs: SpriteCatalog.all), to: directory, log: log)
    }

    // MARK: Internals (tests use a small set of sprites)

    struct Output: Sendable {
        var name: String
        var bytes: [UInt8]
        /// The log line.
        var summary: String
    }

    static func outputs(defs: [SpriteDef], pageSize: Int = 2048) throws -> [Output] {
        let atlas = AtlasPacker.pack(defs, pageSize: pageSize)
        var out: [Output] = []
        for (index, page) in atlas.pages.enumerated() {
            let name = SpriteManifest.pageFileName(index)
            let png = page.pngData()
            out.append(Output(name: name, bytes: png, summary: "\(name) \(page.width)×\(page.height) \(png.count) bytes"))
        }
        let manifest = [UInt8](try SpriteManifest(atlas: atlas, defs: defs).encoded())
        out.append(Output(name: "manifest.json", bytes: manifest, summary: "manifest.json \(manifest.count) bytes"))
        return out
    }

    static func write(_ outputs: [Output], to directory: String, log: (String) -> Void) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for output in outputs {
            try Data(output.bytes).write(to: folder.appendingPathComponent(output.name), options: .atomic)
            log(output.summary)
        }
    }
}
