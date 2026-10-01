import Foundation

/// The 32 base colours of 7.1, in table order. Sprites are drawn with roles, never with raw colours.
public enum PaletteRole: String, CaseIterable, Codable, Sendable {
    case ink, shade, slate, stone, mist, paper, chalk, skin1, skin2, skin3, skin4, hairDark,
         woodDark, woodMid, woodLight, cork, floorLight, floorDark, leafDark, leaf, leafLight,
         skyDay, skyNight, uiTitle, uiFace, alertYellow, alertOrange, screenGlow, okGreen, errorRed, thinkLilac, lampWarm
}

/// The three tones of a project hue: `light` for top faces, `base` for left faces, `dark` for right faces and
/// for the outline of objects of that colour (7.1, 7.2).
public struct HueTones: Hashable, Sendable {
    public let name: String
    public let base: RGBA8
    public let light: RGBA8
    public let dark: RGBA8

    public init(name: String, base: RGBA8, light: RGBA8, dark: RGBA8) {
        self.name = name
        self.base = base
        self.light = light
        self.dark = dark
    }
}

/// The only place where colours live (7.1). Values are original and frozen here; the contact sheet of the
/// visual milestone is where they get tuned by eye.
public enum Palette {
    public static func color(_ role: PaletteRole) -> RGBA8 {
        switch role {
        case .ink: return RGBA8(hex: 0x1C1B2E)
        case .shade: return RGBA8(hex: 0x2F2E4A)
        case .slate: return RGBA8(hex: 0x4B4F6B)
        case .stone: return RGBA8(hex: 0x7C8098)
        case .mist: return RGBA8(hex: 0xB5B9CB)
        case .paper: return RGBA8(hex: 0xE8E4D8)
        case .chalk: return RGBA8(hex: 0xFAF8F2)
        case .skin1: return RGBA8(hex: 0xF3CFAE)
        case .skin2: return RGBA8(hex: 0xD9A27B)
        case .skin3: return RGBA8(hex: 0xA8704E)
        case .skin4: return RGBA8(hex: 0x6A4432)
        case .hairDark: return RGBA8(hex: 0x3B2A24)
        case .woodDark: return RGBA8(hex: 0x6E4631)
        case .woodMid: return RGBA8(hex: 0xA0683F)
        case .woodLight: return RGBA8(hex: 0xD09A63)
        case .cork: return RGBA8(hex: 0xC49A68)
        case .floorLight: return RGBA8(hex: 0xD7D0C0)
        case .floorDark: return RGBA8(hex: 0xB5AC98)
        case .leafDark: return RGBA8(hex: 0x2E6A45)
        case .leaf: return RGBA8(hex: 0x4F9B55)
        case .leafLight: return RGBA8(hex: 0x92CD6E)
        case .skyDay: return RGBA8(hex: 0x62ACE3)
        case .skyNight: return RGBA8(hex: 0x27406E)
        case .uiTitle: return RGBA8(hex: 0x3F5BA9)
        case .uiFace: return RGBA8(hex: 0xD3CEC3)
        case .alertYellow: return RGBA8(hex: 0xFFD23F)
        case .alertOrange: return RGBA8(hex: 0xE3851C)
        case .screenGlow: return RGBA8(hex: 0x58C8F2)
        case .okGreen: return RGBA8(hex: 0x4CB963)
        case .errorRed: return RGBA8(hex: 0xD6453D)
        case .thinkLilac: return RGBA8(hex: 0xA58BE6)
        case .lampWarm: return RGBA8(hex: 0xFFBE73)
        }
    }

    /// P0 Tomate … P9 Ardoise. Light and dark tones are `mix(base, chalk, 0.45)` and `mix(base, ink, 0.45)`,
    /// frozen here (a test recomputes them). No hue is a bright yellow: waiting must stay recognisable.
    public static let projectHues: [HueTones] = [
        HueTones(name: "Tomate", base: RGBA8(hex: 0xE4572E), light: RGBA8(hex: 0xEE9F86), dark: RGBA8(hex: 0x8A3C2E)),
        HueTones(name: "Mandarine", base: RGBA8(hex: 0xF29E4C), light: RGBA8(hex: 0xF6C697), dark: RGBA8(hex: 0x92633E)),
        HueTones(name: "Olive", base: RGBA8(hex: 0x8AB17D), light: RGBA8(hex: 0xBCD1B2), dark: RGBA8(hex: 0x586E59)),
        HueTones(name: "Menthe", base: RGBA8(hex: 0x2A9D8F), light: RGBA8(hex: 0x88C6BC), dark: RGBA8(hex: 0x246263)),
        HueTones(name: "Lagune", base: RGBA8(hex: 0x3A86C8), light: RGBA8(hex: 0x90B9DB), dark: RGBA8(hex: 0x2C5683)),
        HueTones(name: "Indigo", base: RGBA8(hex: 0x5E60CE), light: RGBA8(hex: 0xA4A4DE), dark: RGBA8(hex: 0x404186)),
        HueTones(name: "Prune", base: RGBA8(hex: 0x9B5DE5), light: RGBA8(hex: 0xC6A3EB), dark: RGBA8(hex: 0x623F93)),
        HueTones(name: "Framboise", base: RGBA8(hex: 0xD6336C), light: RGBA8(hex: 0xE68CA8), dark: RGBA8(hex: 0x822850)),
        HueTones(name: "Cacao", base: RGBA8(hex: 0x8D6346), light: RGBA8(hex: 0xBEA693), dark: RGBA8(hex: 0x5A433B)),
        HueTones(name: "Ardoise", base: RGBA8(hex: 0x5C6B7A), light: RGBA8(hex: 0xA3AAB0), dark: RGBA8(hex: 0x3F4758)),
    ]

    /// Clamped to 0...9 (`Workspace.projectHueCount` hues).
    public static func hue(_ index: Int) -> HueTones {
        projectHues[min(max(index, 0), projectHues.count - 1)]
    }

    /// a + (b − a)·t per channel in Double, rounded to nearest even: reproduces every frozen tone of 7.1
    /// (Menthe dark: 98.5 → 98). IEEE arithmetic, so the result is the same on every platform.
    public static func mix(_ a: RGBA8, _ b: RGBA8, _ t: Double) -> RGBA8 {
        func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
            let value = (Double(x) + (Double(y) - Double(x)) * t).rounded(.toNearestOrEven)
            return UInt8(min(max(value, 0), 255))
        }
        return RGBA8(r: channel(a.r, b.r), g: channel(a.g, b.g), b: channel(a.b, b.b), a: channel(a.a, b.a))
    }

    /// Cast shadows: ink at 30 %, applied once to the whole shadow layer (7.3, rule 4).
    public static let shadowAlpha: UInt8 = 77
    /// Night light pools: lampWarm at 35 %, additive.
    public static let lightPoolAlpha: UInt8 = 89
    /// Night veil (multiply), 0.55.
    public static let nightVeilAlpha: UInt8 = 140
    /// Night veil with "Reduce transparency" or "Increase contrast", 0.35.
    public static let nightVeilAlphaReduced: UInt8 = 89

    public static let nightVeil = RGBA8(hex: 0x3A3F6E)
    public static let uiFaceDark = RGBA8(hex: 0x34334F)
    public static let uiTitleDark = RGBA8(hex: 0x2B3F78)

    /// Key colours of replacement PNGs (7.7): base, light and dark of the project hue. Never in a generated sprite.
    public static let keyBase = RGBA8(hex: 0xFF00FF)
    public static let keyLight = RGBA8(hex: 0xFF80FF)
    public static let keyDark = RGBA8(hex: 0x800080)
    public static let keyColors: Set<RGBA8> = [keyBase, keyLight, keyDark]

    /// The colours a generated sprite may use: the 32 roles and the 30 hue tones, opaque.
    public static let spriteColors: Set<RGBA8> = {
        var colors = Set(PaletteRole.allCases.map(color))
        for tones in projectHues { colors.formUnion([tones.base, tones.light, tones.dark]) }
        return colors
    }()

    /// The only sprite ids that may contain alertYellow: ov.bang, ov.bang.halo, ov.edgeArrow, screen.waiting,
    /// monitor.back (its led.waiting variant only), hud.state.waitingInput, minimap.dot.waitingInput.
    public static let alertYellowSprites: Set<SpriteID> = [
        "ov.bang", "ov.bang.halo", "ov.edgeArrow", "screen.waiting", "monitor.back",
        "hud.state.waitingInput", "minimap.dot.waitingInput",
    ]

    /// Whether the sprite of `key` may contain alertYellow: an id of `alertYellowSprites`, and for monitor.back
    /// only the `led.waiting` variant.
    public static func allowsAlertYellow(_ key: SpriteKey) -> Bool {
        guard alertYellowSprites.contains(key.id) else { return false }
        return key.id != "monitor.back" || key.variant == "led.waiting"
    }
}
