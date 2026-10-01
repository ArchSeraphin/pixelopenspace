import Foundation
import Testing
@testable import PixelCore

@Suite struct MilestoneExportTests {
    /// The 15 files of `docs/jalon-visuel/`, in the plan's order.
    static let deliverables = [
        "planche-0-palette.png", "planche-1-sols-murs.png", "planche-2-mobilier-decor.png",
        "planche-3-ecrans-overlays.png", "planche-4-hud-texte.png", "planche-5-personnage.png",
        "planche-6-apparences.png",
        "ilot-x1-jour.png", "ilot-x2-jour.png", "ilot-x3-jour.png",
        "ilot-x1-nuit.png", "ilot-x2-nuit.png", "ilot-x3-nuit.png",
        "vue-ensemble-jour.png", "vue-ensemble-nuit.png",
    ]

    @Test func fileNamesAreTheFifteenDeliverables() {
        #expect(MilestoneExport.fileNames() == Self.deliverables)
        #expect(MilestoneExport.fileNames(parts: [.palette]) == ["planche-0-palette.png"])
        #expect(MilestoneExport.fileNames(parts: [.sheets]) == Array(Self.deliverables[1...6]))
        #expect(MilestoneExport.fileNames(parts: [.island]) == Array(Self.deliverables[7...12]))
        #expect(MilestoneExport.fileNames(parts: [.overview]) == Array(Self.deliverables[13...14]))
        // Output order, whatever the order of the parts asked for.
        #expect(MilestoneExport.fileNames(parts: [.overview, .palette])
                == ["planche-0-palette.png", "vue-ensemble-jour.png", "vue-ensemble-nuit.png"])
        #expect(MilestoneExport.fileNames(parts: []).isEmpty)
        #expect(Set(Self.deliverables).count == 15)
    }

    @Test func eachFileHasItsRender() {
        let items = MilestoneExport.items(parts: Set(MilestoneExport.Part.allCases))
        #expect(items.map(\.fileName) == Self.deliverables)
        let renders = items.map(\.render)
        #expect(Array(renders[0...6]) == ContactSheet.Sheet.allCases.map { .sheet($0) })
        #expect(Array(renders[7...12]) == [
            .island(.x1, night: false), .island(.x2, night: false), .island(.x3, night: false),
            .island(.x1, night: true), .island(.x2, night: true), .island(.x3, night: true),
        ])
        #expect(Array(renders[13...14]) == [.overview(night: false), .overview(night: true)])
    }

    @Test func forEachYieldsTheFilesInOrder() {
        var outputs: [MilestoneExport.Output] = []
        MilestoneExport.forEach(parts: [.sheets, .palette], scale: 1) { outputs.append($0) }
        #expect(outputs.map(\.fileName) == MilestoneExport.fileNames(parts: [.palette, .sheets]))
        let pages = ContactSheet.pages(scale: 1)
        #expect(outputs.map(\.image) == pages.map(\.image))
        #expect(outputs.allSatisfy { $0.pixelsPerMeter == nil })
    }

    @Test func forEachStopsOnAThrow() {
        struct Stop: Error {}
        var seen = 0
        #expect(throws: Stop.self) {
            try MilestoneExport.forEach(parts: [.palette, .sheets], scale: 1) { _ in
                seen += 1
                throw Stop()
            }
        }
        #expect(seen == 1)
    }

    @Test func paletteFileDecodes() throws {
        var output: MilestoneExport.Output?
        MilestoneExport.forEach(parts: [.palette], scale: 1) { output = $0 }
        let palette = try #require(output)
        #expect(palette.fileName == "planche-0-palette.png")
        let png = palette.pngData()
        #expect(png == palette.image.pngData())
        let decoded = try PNGTestDecoder.decode(png)
        #expect(decoded.width == palette.image.width && decoded.height == palette.image.height)
        #expect(decoded.rgba == palette.image.rgbaBytes)
        #expect(decoded.pixelsPerMeter == nil)
    }

    @Test func overviewHas144dpi() throws {
        // A few tiles of the overview, rendered like the whole one (zoom .overview), to stay fast.
        let crop = GridRect(origin: GridPoint(0, 6), size: GridSize(w: 4, d: 3))
        let day = MilestoneExport.overviewOutput(night: false, crop: crop)
        #expect(day.fileName == "vue-ensemble-jour.png")
        #expect(day.pixelsPerMeter == PNGOptions.dpi144 && PNGOptions.dpi144 == 5669)
        #expect(day.image == SceneCompositor.render(Showcase.overview(), options: RenderOptions(zoom: .overview, crop: crop)))
        let decoded = try PNGTestDecoder.decode(day.pngData())
        #expect(decoded.pixelsPerMeter == 5669)
        #expect(decoded.rgba == day.image.rgbaBytes)
        let night = MilestoneExport.overviewOutput(night: true, crop: crop)
        #expect(night.fileName == "vue-ensemble-nuit.png" && night.pixelsPerMeter == 5669)
        #expect(night.image != day.image)
    }

    @Test func pngDataEncodesThePixels() throws {
        var image = PixelImage(width: 3, height: 2, fill: Palette.color(.paper))
        image[1, 0] = .clear
        image[2, 1] = Palette.color(.errorRed)
        let decoded = try PNGTestDecoder.decode(image.pngData())
        #expect(decoded.rgba == image.rgbaBytes && decoded.pixelsPerMeter == nil)
        #expect(try PNGTestDecoder.decode(image.pngData(pixelsPerMeter: 5669)).pixelsPerMeter == 5669)
        #expect(image.pngData() == PNGEncoder.encode(width: 3, height: 2, rgba: image.rgbaBytes))
    }

    @Test func goldenLinesAreSortedAndUnique() {
        let lines = GoldenFixture.lines
        #expect(lines == lines.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect(Set(lines).count == lines.count)
        let frames = SpriteCatalog.all.reduce(0) { $0 + $1.frames.count }
        #expect(lines.count == frames + 4)
        let names = lines.compactMap { GoldenFixture.split($0)?.name }
        #expect(names.count == lines.count && Set(names).count == names.count)
        #expect(lines.allSatisfy { line in
            guard let fingerprint = GoldenFixture.split(line)?.fingerprint else { return false }
            return fingerprint.count == 16 && fingerprint.allSatisfy { "0123456789abcdef".contains($0) }
        })
        let scenes = names.filter { $0.hasPrefix("scene:") }
        #expect(scenes == ["scene:ilot-1-x1-jour", "scene:ilot-2-x1-jour", "scene:vue-ensemble-jour",
                           "scene:vue-ensemble-nuit"])
        // A frame line carries that frame's fingerprint.
        let desk = SpriteCatalog.sprite(SpriteKey("desk", variant: "light", facing: .ne))!
        #expect(lines.contains("desk~light@ne#0 \(desk.frames[0].fingerprint)"))
        let cast = SceneCompositor.render(Showcase.islandCasts()[0],
                                          options: RenderOptions(zoom: .x1, crop: Showcase.islandCrop()))
        #expect(lines.contains("scene:ilot-1-x1-jour \(cast.fingerprint)"))
    }

    // MARK: Command line

    @Test func optionsDefaults() throws {
        let command = try MilestoneExport.parse([])
        #expect(command == .export(MilestoneExport.Options()))
        let options = MilestoneExport.Options()
        #expect(options.outputDirectory == "docs/jalon-visuel")
        #expect(options.parts == Set(MilestoneExport.Part.allCases))
        #expect(options.scale == 4 && options.goldenOutput == nil)
    }

    @Test func optionsParseEveryFlag() throws {
        let command = try MilestoneExport.parse(["--out", "/tmp/out", "--only", "island,palette", "--scale", "2",
                                                 "--golden-out", "golden.txt"])
        #expect(command == .export(MilestoneExport.Options(outputDirectory: "/tmp/out", parts: [.island, .palette],
                                                             scale: 2, goldenOutput: "golden.txt")))
        #expect(try MilestoneExport.parse(["--help"]) == .help)
        #expect(try MilestoneExport.parse(["-h"]) == .help)
    }

    @Test func optionsRejectBadUsage() {
        let bad: [[String]] = [
            ["--frobnicate"], ["--out"], ["--only"], ["--only", "palette,nope"], ["--only", ""], ["--scale", "0"],
            ["--scale", "x"], ["--scale", "99"], ["--golden-out"], ["stray"],
        ]
        for arguments in bad {
            #expect(throws: MilestoneExport.UsageError.self, "\(arguments)") { try MilestoneExport.parse(arguments) }
        }
        #expect(MilestoneExport.usage.contains("sprite-export [--out <dir>]"))
    }

    @Test func runWritesTheImagesAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprite-export-\(ProcessInfo.processInfo.processIdentifier)-images")
        defer { try? FileManager.default.removeItem(at: directory) }
        var log: [String] = []
        let options = MilestoneExport.Options(outputDirectory: directory.appendingPathComponent("nested").path,
                                              parts: [.palette], scale: 1)
        try MilestoneExport.run(options) { log.append($0) }
        let file = directory.appendingPathComponent("nested/planche-0-palette.png")
        let bytes = [UInt8](try Data(contentsOf: file))
        let page = ContactSheet.page(.palette, scale: 1)
        #expect(bytes == page.image.pngData())
        #expect(log == ["planche-0-palette.png \(page.image.width)×\(page.image.height) \(bytes.count) bytes"])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("nested").path)
        #expect(names == ["planche-0-palette.png"], "no temporary file left behind")
    }

    @Test func runWritesOnlyTheGoldenFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprite-export-\(ProcessInfo.processInfo.processIdentifier)-golden")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let golden = directory.appendingPathComponent("sprites.txt")
        var log: [String] = []
        let options = MilestoneExport.Options(outputDirectory: directory.appendingPathComponent("images").path,
                                              parts: [.palette], goldenOutput: golden.path)
        try MilestoneExport.run(options, goldenLines: { ["a#0 0000000000000001", "b#0 0000000000000002"] }) {
            log.append($0)
        }
        #expect(try String(contentsOf: golden, encoding: .utf8) == "a#0 0000000000000001\nb#0 0000000000000002\n")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("images").path))
        #expect(log == ["\(golden.path) 2 lines"])
    }
}
