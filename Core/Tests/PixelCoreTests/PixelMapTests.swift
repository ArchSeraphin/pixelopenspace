import Foundation
import Testing
@testable import PixelCore

@Suite struct PixelMapTests {
    @Test func parsesWithCommonIndentation() throws {
        let map = try PixelMap.parse("""

                ..oo..
                .oPPo.
                ..oo..

            """)
        #expect(map.width == 6 && map.height == 3)
        #expect(map[0, 0] == .clear && map[2, 0] == .role(.ink) && map[3, 0] == .role(.ink) && map[5, 0] == .clear)
        #expect(map[1, 1] == .role(.ink) && map[2, 1] == .hueBase && map[5, 1] == .clear)
        #expect(map.cells.count == 18)
    }

    @Test func extraIndentationIsNotPartOfTheCommonIndentation() {
        // Only the indentation shared by every row is dropped: a deeper row keeps its spaces, which are not pixels.
        #expect(throws: PixelMapError.unknownCharacter(" ", row: 1, column: 0)) {
            try PixelMap.parse("""
                oo
                 o
                """)
        }
    }

    @Test func trailingSpacesAndCRLFAreIgnored() throws {
        let map = try PixelMap.parse("o. \r\n.o\t\r\n")
        #expect(map.width == 2 && map.height == 2)
        #expect(map.cells == [.role(.ink), .clear, .clear, .role(.ink)])
    }

    @Test func baseLegend() {
        let expected: [Character: Slot] = [
            ".": .clear, "P": .hueBase, "L": .hueLight, "D": .hueDark,
            "s": .skin, "S": .skinShade, "q": .skinOutline, "h": .hair, "H": .hairShade, "j": .hairOutline,
            "t": .top, "T": .topShade, "u": .topOutline, "p": .bottom, "b": .bottomShade, "e": .eye,
            "a": .accessory, "A": .accessoryShade, "o": .role(.ink),
            "1": .role(.chalk), "2": .role(.mist), "3": .role(.stone), "4": .role(.slate), "5": .role(.shade),
            "6": .role(.paper), "7": .role(.woodLight), "8": .role(.woodMid), "9": .role(.woodDark),
            "c": .role(.cork), "m": .role(.hairDark), "f": .role(.leaf), "F": .role(.leafDark), "i": .role(.leafLight),
            "y": .role(.alertYellow), "Y": .role(.alertOrange), "g": .role(.screenGlow), "G": .role(.okGreen),
            "r": .role(.errorRed), "v": .role(.thinkLilac), "w": .role(.lampWarm), "k": .role(.skyDay),
            "n": .role(.skyNight), "z": .role(.floorLight), "Z": .role(.floorDark),
        ]
        #expect(PixelMap.baseLegend == expected)
    }

    @Test func raggedRowIsReported() {
        #expect(throws: PixelMapError.raggedRow(2)) {
            try PixelMap.parse("""
                ooo
                ooo
                oo
                ooo
                """)
        }
    }

    @Test func unknownCharacterHasRowAndColumn() {
        #expect(throws: PixelMapError.unknownCharacter("X", row: 1, column: 2)) {
            try PixelMap.parse("""
                  ....
                  ..X.
                """)
        }
    }

    @Test func emptyMapIsAnError() {
        #expect(throws: PixelMapError.empty) { try PixelMap.parse("") }
        #expect(throws: PixelMapError.empty) { try PixelMap.parse("\n   \n\n") }
    }

    @Test func legendAddsAndOverrides() throws {
        let map = try PixelMap.parse("xo", legend: ["x": .role(.skin1), "o": .role(.slate)])
        #expect(map.cells == [.role(.skin1), .role(.slate)])
        #expect(throws: PixelMapError.unknownCharacter("x", row: 0, column: 0)) { try PixelMap.parse("xo") }
    }

    @Test func renderPaintsEachSlot() {
        let map = PixelMap("""
            .oP
            LD6
            """)
        let image = map.render { SlotPaint.decor($0, hue: 4) }
        #expect(image.width == 3 && image.height == 2)
        #expect(image[0, 0] == .clear)
        #expect(image[1, 0] == Palette.color(.ink))
        #expect(image[2, 0] == Palette.hue(4).base)
        #expect(image[0, 1] == Palette.hue(4).light && image[1, 1] == Palette.hue(4).dark)
        #expect(image[2, 1] == Palette.color(.paper))
        #expect(map.renderDecor(hue: 4) == image)
        let skipped = map.render { $0 == .role(.ink) ? nil : Palette.color(.chalk) }
        #expect(skipped[1, 0] == .clear, "nil paints a transparent pixel")
        #expect(skipped[0, 0] == .clear, ".clear is always transparent")
    }

    @Test func mirrored() {
        let map = PixelMap("""
            o.6
            P..
            """)
        let mirrored = map.mirrored()
        #expect(mirrored.cells == [.role(.paper), .clear, .role(.ink), .clear, .clear, .hueBase])
        #expect(mirrored.mirrored() == map)
        #expect(map.mirrored().render { SlotPaint.decor($0, hue: 0) } == map.render { SlotPaint.decor($0, hue: 0) }.mirrored())
    }

    @Test func decorPaintMapsRolesAndHues() {
        #expect(SlotPaint.decor(.clear, hue: nil) == nil)
        #expect(SlotPaint.decor(.role(.cork), hue: nil) == Palette.color(.cork))
        #expect(SlotPaint.decor(.hueLight, hue: 0) == Palette.hue(0).light)
        #expect(SlotPaint.decor(.hueDark, hue: 9) == Palette.hue(9).dark)
    }

    @Test func explicitCells() {
        let map = PixelMap(width: 2, height: 1, cells: [.eye, .clear])
        #expect(map[0, 0] == .eye && map[1, 0] == .clear)
    }
}
