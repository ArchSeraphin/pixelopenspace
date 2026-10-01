import Foundation

/// What `sprite-export` writes (section 8, visual milestone): the 15 PNG files of `docs/jalon-visuel/` (contact
/// sheets, the island at ×1, ×2 and ×3 by day and by night, the overview by day and by night) and the golden
/// fingerprints of the tests. The executable only parses its arguments and calls `run`.
public enum MilestoneExport {
    public enum Part: String, CaseIterable, Sendable {
        /// planche-0.
        case palette
        /// planche-1 to planche-6.
        case sheets
        /// ilot-x1-jour … ilot-x3-nuit.
        case island
        /// vue-ensemble-jour, vue-ensemble-nuit.
        case overview
    }

    public struct Output: Sendable {
        public let fileName: String
        public let image: PixelImage
        /// pHYs of the PNG: 144 ppp for the overview (0.5 pt per texel on a Retina screen), nil otherwise.
        public let pixelsPerMeter: Int?

        public init(fileName: String, image: PixelImage, pixelsPerMeter: Int?) {
            self.fileName = fileName
            self.image = image
            self.pixelsPerMeter = pixelsPerMeter
        }

        public func pngData() -> [UInt8] { image.pngData(pixelsPerMeter: pixelsPerMeter) }
    }

    /// The file names of `parts`, in output order (whatever the order of the set).
    public static func fileNames(parts: Set<Part> = Set(Part.allCases)) -> [String] {
        items(parts: parts).map(\.fileName)
    }

    /// One image at a time (memory), in `fileNames` order. `scale` applies to the contact sheets; the island has its
    /// own zooms and the overview is 1 pixel per texel.
    public static func forEach(parts: Set<Part> = Set(Part.allCases), scale: Int = ContactSheet.defaultScale,
                               _ body: (Output) throws -> Void) rethrows {
        for item in items(parts: parts) {
            try body(output(item, scale: scale))
        }
    }

    /// "<key>#<frame> <fingerprint>" for every frame of `SpriteCatalog.all`, then "scene:<name> <fingerprint>" for
    /// ilot-1-x1-jour, ilot-2-x1-jour, vue-ensemble-jour and vue-ensemble-nuit; sorted (UTF-8 order).
    public static func goldenLines() -> [String] {
        var lines: [String] = []
        for def in SpriteCatalog.all {
            for (index, frame) in def.frames.enumerated() {
                lines.append("\(def.key.frameName(index)) \(frame.fingerprint)")
            }
        }
        let crop = Showcase.islandCrop()
        for (index, cast) in Showcase.islandCasts().enumerated() {
            let image = SceneCompositor.render(cast, options: RenderOptions(zoom: .x1, night: false, crop: crop))
            lines.append("scene:ilot-\(index + 1)-x1-jour \(image.fingerprint)")
        }
        for night in [false, true] {
            lines.append("scene:\(overviewName(night: night)) \(Showcase.overviewImage(night: night).fingerprint)")
        }
        return lines.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    // MARK: Items

    /// How a file is rendered.
    enum Render: Equatable, Sendable {
        case sheet(ContactSheet.Sheet)
        case island(SceneZoom, night: Bool)
        case overview(night: Bool)
    }

    /// Every file of `parts` with its render, in the order of the deliverable.
    static func items(parts: Set<Part>) -> [(fileName: String, render: Render)] {
        var out: [(fileName: String, render: Render)] = []
        if parts.contains(.palette) { out.append((ContactSheet.Sheet.palette.fileName, .sheet(.palette))) }
        if parts.contains(.sheets) {
            for sheet in ContactSheet.Sheet.allCases where sheet != .palette { out.append((sheet.fileName, .sheet(sheet))) }
        }
        if parts.contains(.island) {
            for night in [false, true] {
                for zoom in [SceneZoom.x1, .x2, .x3] {
                    out.append(("ilot-x\(zoom.rawValue)-\(dayOrNight(night)).png", .island(zoom, night: night)))
                }
            }
        }
        if parts.contains(.overview) {
            for night in [false, true] { out.append(("\(overviewName(night: night)).png", .overview(night: night))) }
        }
        return out
    }

    static func output(_ item: (fileName: String, render: Render), scale: Int) -> Output {
        switch item.render {
        case .sheet(let sheet):
            return Output(fileName: item.fileName, image: ContactSheet.page(sheet, scale: scale).image, pixelsPerMeter: nil)
        case .island(let zoom, let night):
            return Output(fileName: item.fileName, image: Showcase.islandSheet(zoom: zoom, night: night), pixelsPerMeter: nil)
        case .overview(let night):
            return overviewOutput(night: night)
        }
    }

    /// The overview at 1 pixel per texel and 144 ppp; `crop` renders only those tiles (tests).
    static func overviewOutput(night: Bool, crop: GridRect? = nil) -> Output {
        let image = crop.map {
            SceneCompositor.render(Showcase.overview(), options: RenderOptions(zoom: .overview, night: night, crop: $0))
        } ?? Showcase.overviewImage(night: night)
        return Output(fileName: "\(overviewName(night: night)).png", image: image, pixelsPerMeter: PNGOptions.dpi144)
    }

    static func dayOrNight(_ night: Bool) -> String { night ? "nuit" : "jour" }
    static func overviewName(night: Bool) -> String { "vue-ensemble-\(dayOrNight(night))" }

    // MARK: Command line

    public struct Options: Equatable, Sendable {
        public static let defaultOutputDirectory = "docs/jalon-visuel"
        public static let scales = 1...8

        /// Relative to the current directory unless absolute.
        public var outputDirectory: String
        public var parts: Set<Part>
        public var scale: Int
        /// When set, only the golden lines are written, to this file, and no image.
        public var goldenOutput: String?

        public init(outputDirectory: String = defaultOutputDirectory, parts: Set<Part> = Set(Part.allCases),
                    scale: Int = ContactSheet.defaultScale, goldenOutput: String? = nil) {
            self.outputDirectory = outputDirectory
            self.parts = parts
            self.scale = scale
            self.goldenOutput = goldenOutput
        }
    }

    public enum Command: Equatable, Sendable {
        case export(Options)
        case help
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public static let usage = """
        usage: sprite-export [--out <dir>] [--only palette,sheets,island,overview] [--scale <n>] [--golden-out <file>]

          --out <dir>          where the PNG files go (default: docs/jalon-visuel, relative to the current directory)
          --only <parts>       comma-separated parts to render (default: all)
          --scale <n>          pixels per texel of the contact sheets, 1 to 8 (default: 4)
          --golden-out <file>  write the golden fingerprints to <file> instead of any image

        """

    public static func parse(_ arguments: [String]) throws -> Command {
        var options = Options()
        var rest = arguments[...]
        func value(for flag: String) throws -> String {
            guard let next = rest.popFirst(), !next.hasPrefix("--") else { throw UsageError("\(flag) needs a value") }
            return next
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h":
                return .help
            case "--out":
                options.outputDirectory = try value(for: argument)
            case "--only":
                let names = try value(for: argument).split(separator: ",", omittingEmptySubsequences: false)
                var parts = Set<Part>()
                for name in names {
                    guard let part = Part(rawValue: String(name)) else { throw UsageError("unknown part \"\(name)\"") }
                    parts.insert(part)
                }
                options.parts = parts
            case "--scale":
                let text = try value(for: argument)
                guard let scale = Int(text), Options.scales.contains(scale) else {
                    throw UsageError("--scale takes a whole number from 1 to 8, not \"\(text)\"")
                }
                options.scale = scale
            case "--golden-out":
                options.goldenOutput = try value(for: argument)
            default:
                throw UsageError("unknown argument \"\(argument)\"")
            }
        }
        return .export(options)
    }

    /// Writes the golden file, or every image of `options.parts`, each file atomically; `log` gets one line per
    /// file ("name width×height size bytes", or "path n lines").
    public static func run(_ options: Options, goldenLines: () -> [String] = MilestoneExport.goldenLines,
                           log: (String) -> Void) throws {
        if let golden = options.goldenOutput {
            let lines = goldenLines()
            let url = URL(fileURLWithPath: golden)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url, options: .atomic)
            log("\(golden) \(lines.count) lines")
            return
        }
        let directory = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try forEach(parts: options.parts, scale: options.scale) { output in
            let png = output.pngData()
            try Data(png).write(to: directory.appendingPathComponent(output.fileName), options: .atomic)
            log("\(output.fileName) \(output.image.width)×\(output.image.height) \(png.count) bytes")
        }
    }
}
