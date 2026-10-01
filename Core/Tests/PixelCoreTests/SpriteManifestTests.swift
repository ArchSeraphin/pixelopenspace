import Foundation
import Testing
@testable import PixelCore

@Suite struct SpriteManifestTests {
    static let defs = SpriteCatalog.all
    static let atlas = AtlasPacker.pack(SpriteCatalog.all)
    static let manifest = SpriteManifest(atlas: atlas, defs: defs)

    @Test func header() {
        let manifest = Self.manifest
        #expect(manifest.format == "pixelopenspace-atlas" && manifest.version == 1 && manifest.theme == "day")
        #expect(manifest.pages == Self.atlas.pages.indices.map {
            SpriteManifest.Page(file: "atlas-\($0).png", size: [2048, 2048])
        })
        #expect(manifest.sprites.count == Self.atlas.entries.count)
        for (name, entry) in Self.atlas.entries {
            let sprite = manifest.sprites[name]
            #expect(sprite?.page == entry.page, "\(name)")
            #expect(sprite?.rect == [entry.rect.x, entry.rect.y, entry.rect.width, entry.rect.height], "\(name)")
            #expect(sprite?.anchor == [entry.anchor.x, entry.anchor.y], "\(name)")
        }
        #expect(SpriteManifest(atlas: Self.atlas, defs: Self.defs, theme: "night").theme == "night")
    }

    @Test func masksOfClickableSprites() {
        let sprites = Self.manifest.sprites
        for def in Self.defs {
            let clickable = ![SpriteCategory.floors, .lights, .effects].contains(def.category)
            for index in def.frames.indices {
                #expect(sprites[def.key.frameName(index)]?.mask == clickable, "\(def.key.frameName(index))")
            }
        }
        #expect(sprites["desk~light@se#0"]?.mask == true)
        #expect(sprites["floor.hover#0"]?.mask == false)
    }

    @Test func jsonRoundTrip() throws {
        let data = try Self.manifest.encoded()
        let back = try JSONDecoder().decode(SpriteManifest.self, from: data)
        #expect(back == Self.manifest)
    }

    @Test func sameBytesEveryTime() throws {
        let first = try Self.manifest.encoded()
        let second = try SpriteManifest(atlas: AtlasPacker.pack(Self.defs), defs: Self.defs).encoded()
        #expect(first == second)
        let text = String(decoding: first, as: UTF8.self)
        // Sorted keys: "animations" comes first.
        #expect(text.hasPrefix("{\"animations\":"))
        #expect(text.contains("\"format\":\"pixelopenspace-atlas\""))
    }

    @Test func mirrorsAreListed() {
        let flat = Self.defs.filter { $0.derivation == .mirror }
        #expect(!flat.isEmpty)
        #expect(Self.manifest.mirrors.count == flat.count)
        for def in flat {
            #expect(Self.manifest.mirrors[def.key.name] == def.source?.name, "\(def.key)")
            // The mirror still has its own frames in the atlas (décision 5).
            #expect(Self.manifest.sprites[def.key.frameName(0)] != nil)
        }
        // Reshaded characters are sprites of their own, not plain mirrors (7.6).
        for def in Self.defs where def.derivation == .mirrorReshaded {
            #expect(Self.manifest.mirrors[def.key.name] == nil)
        }
    }

    @Test func animationsMatchTheHolds() {
        let animated = Self.defs.filter { $0.frames.count > 1 }
        #expect(!animated.isEmpty)
        #expect(Self.manifest.animations.count == animated.count)
        for def in animated {
            let expected = AtlasAnimation(frames: def.frames.indices.map { def.key.frameName($0) }, holds: def.holds,
                                          loops: def.loops)
            #expect(Self.manifest.animations[def.key.name] == expected, "\(def.key)")
        }
    }

    @Test func tintedIDs() {
        let tinted = Self.manifest.tinted
        #expect(tinted == Array(Set(tinted)).sorted())
        #expect(tinted.contains("floor.carpet") && tinted.contains("chair"))
        let hued = Set(Self.defs.filter { $0.key.variant?.hasPrefix("hue") == true }.map(\.key.id.rawValue))
        #expect(Set(tinted) == hued)
        #expect(!tinted.contains("desk"))
    }

    @Test func exportFilesOfASmallAtlas() throws {
        // A 44 × 44 cell fills page 0; the two frames of "small" open page 1.
        let defs = [atlasTestSprite("big", width: 40, height: 40),
                    atlasTestSprite("small", width: 8, height: 8, frames: 2, holds: [12, 12])]
        let outputs = try AtlasExport.outputs(defs: defs, pageSize: 48)
        #expect(outputs.map(\.name) == ["atlas-0.png", "atlas-1.png", "manifest.json"])
        let atlas = AtlasPacker.pack(defs, pageSize: 48)
        #expect(outputs[0].bytes == atlas.pages[0].pngData())
        #expect(outputs[1].bytes == atlas.pages[1].pngData())
        let manifest = try JSONDecoder().decode(SpriteManifest.self, from: Data(outputs[2].bytes))
        #expect(manifest == SpriteManifest(atlas: atlas, defs: defs))
        #expect(manifest.pages.map(\.file) == ["atlas-0.png", "atlas-1.png"])
        #expect(outputs[0].summary == "atlas-0.png 48×48 \(outputs[0].bytes.count) bytes")
        #expect(outputs[2].summary == "manifest.json \(outputs[2].bytes.count) bytes")

        // Written to a folder, one log line per file.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pos-atlas-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var lines: [String] = []
        try AtlasExport.write(outputs, to: directory.path) { lines.append($0) }
        #expect(lines == outputs.map(\.summary))
        for output in outputs {
            let written = try Data(contentsOf: directory.appendingPathComponent(output.name))
            #expect([UInt8](written) == output.bytes)
        }
    }

    @Test func exportFilesOfTheCatalog() throws {
        let files = try AtlasExport.files()
        let pages = Self.atlas.pages.count
        #expect(files.map(\.name) == (0..<pages).map { "atlas-\($0).png" } + ["manifest.json"])
        #expect(files.last?.bytes == [UInt8](try Self.manifest.encoded()))
        // Each page is a 2048 × 2048 PNG (IHDR width and height, big endian).
        for file in files.dropLast() {
            let bytes = file.bytes
            #expect(Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
            let width = bytes[16..<20].reduce(0) { $0 << 8 | Int($1) }, height = bytes[20..<24].reduce(0) { $0 << 8 | Int($1) }
            #expect(width == 2048 && height == 2048)
        }
    }
}
