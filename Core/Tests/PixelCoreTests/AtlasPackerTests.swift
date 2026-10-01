import Foundation
import Testing
@testable import PixelCore

/// A one-colour sprite of `frames` frames (each a different shade), anchored at its bottom centre.
func atlasTestSprite(_ id: String, width: Int, height: Int, frames: Int = 1, holds: [Int] = [], loops: Bool = true,
                 facing: Facing? = nil, category: SpriteCategory = .furniture) -> SpriteDef {
    let images = (0..<frames).map { index in
        PixelImage(width: width, height: height, fill: RGBA8(r: UInt8(10 * index + 40), g: UInt8(width * 9 % 256),
                                                             b: UInt8(height * 13 % 256)))
    }
    return SpriteDef(key: SpriteKey(SpriteID(id), facing: facing), category: category,
                     anchor: PixelPoint(width / 2, height), frames: images, holds: holds, loops: loops)
}

@Suite struct AtlasPackerTests {
    static let defs = SpriteCatalog.all
    static let atlas = AtlasPacker.pack(SpriteCatalog.all)
    static let padding = 2

    /// Every (entry, frame) of the catalog.
    static var frames: [(name: String, entry: AtlasEntry, image: PixelImage)] {
        var out: [(name: String, entry: AtlasEntry, image: PixelImage)] = []
        for def in defs {
            for (index, image) in def.frames.enumerated() {
                if let entry = atlas.entry(def.key, frame: index) { out.append((def.key.frameName(index), entry, image)) }
            }
        }
        return out
    }

    @Test func everyFrameHasAnEntry() {
        var count = 0
        for def in Self.defs {
            for (index, frame) in def.frames.enumerated() {
                count += 1
                guard let entry = Self.atlas.entry(def.key, frame: index) else {
                    Issue.record("no entry for \(def.key.frameName(index))")
                    continue
                }
                #expect(entry.rect.width == frame.width && entry.rect.height == frame.height, "\(def.key)")
                #expect(entry.anchor == def.anchor, "\(def.key)")
                #expect(Self.atlas.pages.indices.contains(entry.page))
                #expect(Self.atlas.entries[def.key.frameName(index)] == entry)
            }
        }
        #expect(Self.atlas.entries.count == count)
        #expect(Self.atlas.entry(Self.defs[0].key, frame: 99) == nil)
        // Mirrors have their own frames (décision 5).
        let mirrors = Self.defs.filter { $0.derivation != nil }
        #expect(!mirrors.isEmpty && mirrors.allSatisfy { Self.atlas.entry($0.key, frame: 0) != nil })
    }

    @Test func entriesDoNotOverlap() {
        let pad = Self.padding, size = Self.atlas.pageSize
        let cells = Self.frames.map { item -> (page: Int, x0: Int, y0: Int, x1: Int, y1: Int) in
            let r = item.entry.rect
            return (item.entry.page, r.x - pad, r.y - pad, r.x + r.width + pad, r.y + r.height + pad)
        }
        for cell in cells {
            #expect(cell.x0 >= 0 && cell.y0 >= 0 && cell.x1 <= size && cell.y1 <= size)
        }
        var overlaps = 0
        for a in cells.indices {
            for b in cells.indices where b > a && cells[a].page == cells[b].page {
                let p = cells[a], q = cells[b]
                if p.x0 < q.x1 && q.x0 < p.x1 && p.y0 < q.y1 && q.y0 < p.y1 { overlaps += 1 }
            }
        }
        #expect(overlaps == 0)
    }

    @Test func pixelsAreCopiedExactly() {
        for item in Self.frames {
            #expect(Self.atlas.pages[item.entry.page].cropped(item.entry.rect) == item.image, "\(item.name)")
        }
    }

    @Test func paddingRepeatsTheEdgePixels() {
        let pad = Self.padding
        for item in Self.frames {
            let page = Self.atlas.pages[item.entry.page], r = item.entry.rect, image = item.image
            var wrong = 0
            for y in (r.y - pad)..<(r.y + r.height + pad) {
                for x in (r.x - pad)..<(r.x + r.width + pad) where !r.contains(x: x, y: y) {
                    let sx = min(max(x - r.x, 0), image.width - 1), sy = min(max(y - r.y, 0), image.height - 1)
                    if page[x, y] != image[sx, sy] { wrong += 1 }
                }
            }
            #expect(wrong == 0, "\(item.name)")
        }
    }

    @Test func deterministic() {
        let again = AtlasPacker.pack(Self.defs)
        #expect(again == Self.atlas)
        // Sorted by size then name: the input order does not matter.
        #expect(AtlasPacker.pack(Self.defs.reversed()) == Self.atlas)
    }

    @Test func catalogFitsInAtMostThreePages() {
        #expect(Self.atlas.pageSize == 2048)
        #expect((1...3).contains(Self.atlas.pages.count))
        #expect(Self.atlas.pages.allSatisfy { $0.width == 2048 && $0.height == 2048 })
    }

    @Test func shelvesThenPages() {
        let defs = [atlasTestSprite("a", width: 6, height: 4), atlasTestSprite("b", width: 6, height: 4),
                    atlasTestSprite("c", width: 3, height: 6), atlasTestSprite("d", width: 5, height: 5),
                    atlasTestSprite("e", width: 14, height: 9)]
        let atlas = AtlasPacker.pack(defs, pageSize: 16, padding: 1)
        #expect(atlas.pageSize == 16 && atlas.pages.count == 2)
        // Tallest first: e fills the first shelf of page 0; c does not fit under it and opens page 1.
        #expect(atlas.entries["e#0"] == AtlasEntry(page: 0, rect: PixelRect(x: 1, y: 1, width: 14, height: 9),
                                                   anchor: PixelPoint(7, 9)))
        #expect(atlas.entries["c#0"]?.page == 1 && atlas.entries["c#0"]?.rect == PixelRect(x: 1, y: 1, width: 3, height: 6))
        #expect(atlas.entries["d#0"]?.rect == PixelRect(x: 6, y: 1, width: 5, height: 5))
        // a and b: same size, by name, on a second shelf of page 1.
        #expect(atlas.entries["a#0"]?.rect == PixelRect(x: 1, y: 9, width: 6, height: 4))
        #expect(atlas.entries["b#0"]?.rect == PixelRect(x: 9, y: 9, width: 6, height: 4))
        #expect(atlas.entries["b#0"]?.page == 1)
        // Outside the cells, the page is transparent (0, 0, 0, 0).
        var cells: [Int: [PixelRect]] = [:]
        for entry in atlas.entries.values {
            let r = entry.rect
            cells[entry.page, default: []].append(PixelRect(x: r.x - 1, y: r.y - 1, width: r.width + 2, height: r.height + 2))
        }
        for (index, page) in atlas.pages.enumerated() {
            for y in 0..<16 {
                for x in 0..<16 where !(cells[index] ?? []).contains(where: { $0.contains(x: x, y: y) }) {
                    #expect(page[x, y] == .clear, "page \(index) (\(x), \(y))")
                }
            }
        }
        #expect(atlas.animations.isEmpty)
    }

    @Test func animationsOfSpritesWithSeveralFrames() {
        let defs = [atlasTestSprite("anim", width: 4, height: 4, frames: 4, holds: [2, 4, 2, 4], facing: .se),
                    atlasTestSprite("once", width: 3, height: 5, frames: 2, holds: [6, 6], loops: false),
                    atlasTestSprite("still", width: 2, height: 2)]
        let atlas = AtlasPacker.pack(defs, pageSize: 64)
        #expect(atlas.animations == [
            "anim@se": AtlasAnimation(frames: ["anim@se#0", "anim@se#1", "anim@se#2", "anim@se#3"], holds: [2, 4, 2, 4],
                                      loops: true),
            "once": AtlasAnimation(frames: ["once#0", "once#1"], holds: [6, 6], loops: false),
        ])
        #expect(atlas.entries.count == 7)
        // Each frame keeps its own pixels.
        for index in 0..<4 {
            let entry = atlas.entry(defs[0].key, frame: index)!
            #expect(atlas.pages[entry.page].cropped(entry.rect) == defs[0].frames[index])
        }
    }

    @Test func noSpriteNoPage() {
        let atlas = AtlasPacker.pack([])
        #expect(atlas.pages.isEmpty && atlas.entries.isEmpty && atlas.animations.isEmpty)
    }
}
