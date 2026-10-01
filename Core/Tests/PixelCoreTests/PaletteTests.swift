import Foundation
import Testing
@testable import PixelCore

@Suite struct PaletteTests {
    /// The 32 base colours of 7.1, in table order.
    static let roles: [(PaletteRole, UInt32)] = [
        (.ink, 0x1C1B2E), (.shade, 0x2F2E4A), (.slate, 0x4B4F6B), (.stone, 0x7C8098), (.mist, 0xB5B9CB),
        (.paper, 0xE8E4D8), (.chalk, 0xFAF8F2), (.skin1, 0xF3CFAE), (.skin2, 0xD9A27B), (.skin3, 0xA8704E),
        (.skin4, 0x6A4432), (.hairDark, 0x3B2A24), (.woodDark, 0x6E4631), (.woodMid, 0xA0683F),
        (.woodLight, 0xD09A63), (.cork, 0xC49A68), (.floorLight, 0xD7D0C0), (.floorDark, 0xB5AC98),
        (.leafDark, 0x2E6A45), (.leaf, 0x4F9B55), (.leafLight, 0x92CD6E), (.skyDay, 0x62ACE3),
        (.skyNight, 0x27406E), (.uiTitle, 0x3F5BA9), (.uiFace, 0xD3CEC3), (.alertYellow, 0xFFD23F),
        (.alertOrange, 0xE3851C), (.screenGlow, 0x58C8F2), (.okGreen, 0x4CB963), (.errorRed, 0xD6453D),
        (.thinkLilac, 0xA58BE6), (.lampWarm, 0xFFBE73),
    ]

    /// Project hues of 7.1: name, base, light, dark.
    static let hues: [(String, UInt32, UInt32, UInt32)] = [
        ("Tomate", 0xE4572E, 0xEE9F86, 0x8A3C2E),
        ("Mandarine", 0xF29E4C, 0xF6C697, 0x92633E),
        ("Olive", 0x8AB17D, 0xBCD1B2, 0x586E59),
        ("Menthe", 0x2A9D8F, 0x88C6BC, 0x246263),
        ("Lagune", 0x3A86C8, 0x90B9DB, 0x2C5683),
        ("Indigo", 0x5E60CE, 0xA4A4DE, 0x404186),
        ("Prune", 0x9B5DE5, 0xC6A3EB, 0x623F93),
        ("Framboise", 0xD6336C, 0xE68CA8, 0x822850),
        ("Cacao", 0x8D6346, 0xBEA693, 0x5A433B),
        ("Ardoise", 0x5C6B7A, 0xA3AAB0, 0x3F4758),
    ]

    @Test func thirtyTwoRolesInTableOrder() {
        #expect(PaletteRole.allCases.count == 32)
        #expect(PaletteRole.allCases == Self.roles.map(\.0))
        for (role, hex) in Self.roles {
            #expect(Palette.color(role) == RGBA8(hex: hex), "\(role)")
            #expect(Palette.color(role).isOpaque, "\(role)")
        }
    }

    @Test func thirtyHueTones() {
        #expect(Palette.projectHues.count == Workspace.projectHueCount)
        for (index, (name, base, light, dark)) in Self.hues.enumerated() {
            let tones = Palette.projectHues[index]
            #expect(tones.name == name)
            #expect(tones.base == RGBA8(hex: base), "\(name) base")
            #expect(tones.light == RGBA8(hex: light), "\(name) light")
            #expect(tones.dark == RGBA8(hex: dark), "\(name) dark")
            #expect(Palette.hue(index) == tones)
        }
    }

    @Test func hueIndexIsClamped() {
        #expect(Palette.hue(-3) == Palette.projectHues[0])
        #expect(Palette.hue(10) == Palette.projectHues[9])
        #expect(Palette.hue(99) == Palette.projectHues[9])
    }

    @Test func hueTonesFollowMixFormula() {
        let chalk = Palette.color(.chalk), ink = Palette.color(.ink)
        for tones in Palette.projectHues {
            #expect(Palette.mix(tones.base, chalk, 0.45) == tones.light, "\(tones.name) light")
            #expect(Palette.mix(tones.base, ink, 0.45) == tones.dark, "\(tones.name) dark")
        }
        // Menthe dark: green channel 157 + (27 - 157) * 0.45 = 98.5 rounds to the even 98 (0x62), not 99.
        #expect(Palette.mix(RGBA8(hex: 0x2A9D8F), ink, 0.45) == RGBA8(hex: 0x246263))
        #expect(Palette.mix(chalk, ink, 0) == chalk)
        #expect(Palette.mix(chalk, ink, 1) == ink)
    }

    /// HSV hue in degrees and saturation of an opaque colour.
    static func hsv(_ c: RGBA8) -> (hue: Double, saturation: Double) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        let saturation = maxC == 0 ? 0 : delta / maxC
        guard delta > 0 else { return (0, saturation) }
        var hue: Double
        if maxC == r {
            hue = 60 * ((g - b) / delta)
        } else if maxC == g {
            hue = 60 * ((b - r) / delta + 2)
        } else {
            hue = 60 * ((r - g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, saturation)
    }

    static func isBrightYellow(_ c: RGBA8) -> Bool {
        let (hue, saturation) = hsv(c)
        return hue >= 40 && hue <= 75 && saturation >= 0.5
    }

    @Test func noProjectHueIsBrightYellow() {
        // Control: the waiting colour itself is caught by the rule.
        #expect(Self.isBrightYellow(Palette.color(.alertYellow)))
        for tones in Palette.projectHues {
            #expect(!Self.isBrightYellow(tones.base), "\(tones.name)")
        }
    }

    @Test func spriteColorsAreTheSixtyTwoEntries() {
        #expect(Palette.spriteColors.count == 62)
        for role in PaletteRole.allCases { #expect(Palette.spriteColors.contains(Palette.color(role))) }
        for tones in Palette.projectHues {
            #expect(Palette.spriteColors.isSuperset(of: [tones.base, tones.light, tones.dark]))
        }
        for key in [Palette.keyBase, Palette.keyLight, Palette.keyDark] {
            #expect(!Palette.spriteColors.contains(key))
        }
        #expect(!Palette.spriteColors.contains(Palette.nightVeil))
        #expect(Palette.spriteColors.allSatisfy { $0.isOpaque })
    }

    @Test func derivedAndKeyColors() {
        #expect(Palette.nightVeil == RGBA8(hex: 0x3A3F6E))
        #expect(Palette.uiFaceDark == RGBA8(hex: 0x34334F))
        #expect(Palette.uiTitleDark == RGBA8(hex: 0x2B3F78))
        #expect(Palette.keyBase == RGBA8(hex: 0xFF00FF))
        #expect(Palette.keyLight == RGBA8(hex: 0xFF80FF))
        #expect(Palette.keyDark == RGBA8(hex: 0x800080))
        #expect(Palette.keyColors == [Palette.keyBase, Palette.keyLight, Palette.keyDark])
    }

    @Test func alphaConstants() {
        #expect(Palette.shadowAlpha == 77)
        #expect(Palette.lightPoolAlpha == 89)
        #expect(Palette.nightVeilAlpha == 140)
        #expect(Palette.nightVeilAlphaReduced == 89)
    }

    @Test func alertYellowIsReservedToWaitingSprites() {
        let expected: Set<SpriteID> = [
            "ov.bang", "ov.bang.halo", "ov.edgeArrow", "screen.waiting", "monitor.back",
            "hud.state.waitingInput", "minimap.dot.waitingInput",
        ]
        #expect(Palette.alertYellowSprites == expected)
        #expect(Palette.allowsAlertYellow(SpriteKey("ov.bang", variant: "xl")))
        #expect(Palette.allowsAlertYellow(SpriteKey("screen.waiting", facing: .ne)))
        #expect(Palette.allowsAlertYellow(SpriteKey("monitor.back", variant: "led.waiting", facing: .se)))
        #expect(!Palette.allowsAlertYellow(SpriteKey("monitor.back", variant: "led.idle", facing: .se)))
        #expect(!Palette.allowsAlertYellow(SpriteKey("monitor.back")))
        #expect(!Palette.allowsAlertYellow(SpriteKey("desk", variant: "light", facing: .se)))
        #expect(!Palette.allowsAlertYellow(SpriteKey("hud.state.working")))
    }

    @Test func colorBasics() {
        let ink = Palette.color(.ink)
        #expect(ink.hexString == "#1C1B2E")
        #expect(RGBA8(hex: 0x0A0B0C).hexString == "#0A0B0C")
        #expect(ink.luma == 2126 * 0x1C + 7152 * 0x1B + 722 * 0x2E)
        #expect(Palette.color(.stone).luma > Palette.color(.slate).luma)
        #expect(RGBA8.clear == RGBA8(r: 0, g: 0, b: 0, a: 0))
        #expect(!RGBA8.clear.isOpaque)
        #expect(RGBA8(hex: 0x102030, alpha: 7) == RGBA8(r: 0x10, g: 0x20, b: 0x30, a: 7))
    }

    @Test func colorOrderIsByChannels() {
        let sorted = [RGBA8(r: 2, g: 0, b: 0), RGBA8(r: 1, g: 9, b: 9), RGBA8(r: 1, g: 9, b: 8),
                      RGBA8(r: 1, g: 9, b: 8, a: 3)].sorted()
        #expect(sorted == [RGBA8(r: 1, g: 9, b: 8, a: 3), RGBA8(r: 1, g: 9, b: 8), RGBA8(r: 1, g: 9, b: 9),
                           RGBA8(r: 2, g: 0, b: 0)])
    }
}
