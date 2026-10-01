import Foundation

/// The look tables of 7.4.4: 4 skins × 6 haircuts × 8 hair colours × 16 outfits × 4 accessories. Every tone is a
/// palette entry (7.1); none is alertYellow, which stays reserved to waiting.
public enum CharacterPalette {
    public static let skinCount = 4, hairStyleCount = 6, hairColorCount = 8, outfitCount = 16, accessoryCount = 4

    /// Base, shade and outline of one material.
    struct Tones: Hashable, Sendable {
        let base: RGBA8
        let shade: RGBA8
        let outline: RGBA8

        init(_ base: RGBA8, _ shade: RGBA8, _ outline: RGBA8) {
            self.base = base
            self.shade = shade
            self.outline = outline
        }

        init(_ base: PaletteRole, _ shade: PaletteRole, _ outline: PaletteRole) {
            self.init(Palette.color(base), Palette.color(shade), Palette.color(outline))
        }
    }

    /// s / S / q: the shade is the next skin tone, the outline the one after (7.2).
    static func skin(_ index: Int) -> Tones {
        switch clamp(index, skinCount) {
        case 0: return Tones(.skin1, .skin2, .skin3)
        case 1: return Tones(.skin2, .skin3, .skin4)
        case 2: return Tones(.skin3, .skin4, .hairDark)
        default: return Tones(.skin4, .hairDark, .ink)
        }
    }

    /// h / H / j.
    static func hair(_ index: Int) -> Tones {
        switch clamp(index, hairColorCount) {
        case 0: return Tones(.hairDark, .ink, .ink)
        case 1: return Tones(.woodMid, .woodDark, .hairDark)
        case 2: return Tones(.woodLight, .woodMid, .woodDark)
        case 3: return Tones(.stone, .slate, .shade)
        case 4: return Tones(.paper, .mist, .stone)
        case 5: return Tones(Palette.hue(0).base, Palette.hue(0).dark, Palette.color(.ink))
        case 6: return Tones(Palette.hue(1).base, Palette.hue(1).dark, Palette.color(.woodDark))
        default: return Tones(Palette.hue(6).base, Palette.hue(6).dark, Palette.color(.ink))
        }
    }

    /// t / T / u. 0…9: a project hue (base, dark, dark); 10…15: the six neutral outfits.
    static func top(_ index: Int) -> Tones {
        let index = clamp(index, outfitCount)
        if index < Palette.projectHues.count {
            let tones = Palette.hue(index)
            return Tones(tones.base, tones.dark, tones.dark)
        }
        switch index {
        case 10: return Tones(.paper, .mist, .stone)
        case 11: return Tones(.stone, .slate, .shade)
        case 12: return Tones(.slate, .shade, .ink)
        case 13: return Tones(.woodMid, .woodDark, .hairDark)
        case 14: return Tones(.leaf, .leafDark, .ink)
        default: return Tones(.uiTitle, .shade, .ink)
        }
    }

    /// p / b: trousers; shoes are drawn in shade with an ink outline.
    static let bottom = Tones(.slate, .shade, .ink)

    /// a / A for accessories 1 (glasses), 2 (headphones) and 3 (beanie); nil for 0 (none).
    static func accessory(_ index: Int) -> Tones? {
        switch clamp(index, accessoryCount) {
        case 1: return Tones(.slate, .shade, .ink)
        case 2: return Tones(Palette.hue(7).base, Palette.hue(7).dark, Palette.color(.ink))
        case 3: return Tones(Palette.hue(3).base, Palette.hue(3).dark, Palette.color(.ink))
        default: return nil
        }
    }

    static func clamp(_ value: Int, _ count: Int) -> Int { min(max(value, 0), count - 1) }
}

/// AgentLook + project hue → colour of every character slot (values out of range are clamped).
public struct ResolvedLook: Hashable, Sendable {
    public let skin: Int
    public let hairStyle: Int
    public let hairColor: Int
    /// 0…9: a project hue (the agent's own project when `AgentLook.outfitPaletteIndex` is nil); 10…15: neutrals.
    public let outfit: Int
    /// 0: none, 1: glasses, 2: headphones, 3: beanie.
    public let accessory: Int

    public init(_ look: AgentLook, projectHue: Int) {
        skin = CharacterPalette.clamp(look.skin, CharacterPalette.skinCount)
        hairStyle = CharacterPalette.clamp(look.hairStyle, CharacterPalette.hairStyleCount)
        hairColor = CharacterPalette.clamp(look.hairColor, CharacterPalette.hairColorCount)
        let hue = CharacterPalette.clamp(projectHue, Palette.projectHues.count)
        outfit = CharacterPalette.clamp(look.outfitPaletteIndex ?? hue, CharacterPalette.outfitCount)
        accessory = CharacterPalette.clamp(look.accessory ?? 0, CharacterPalette.accessoryCount)
    }

    /// nil for a clear cell, and for accessory slots when the look has no accessory. Character maps never use the
    /// project hue slots (P L D): the outfit already carries the hue.
    public func color(_ slot: Slot) -> RGBA8? {
        switch slot {
        case .clear: return nil
        case .role(let role): return Palette.color(role)
        case .skin: return CharacterPalette.skin(skin).base
        case .skinShade: return CharacterPalette.skin(skin).shade
        case .skinOutline: return CharacterPalette.skin(skin).outline
        case .hair: return CharacterPalette.hair(hairColor).base
        case .hairShade: return CharacterPalette.hair(hairColor).shade
        case .hairOutline: return CharacterPalette.hair(hairColor).outline
        case .top: return CharacterPalette.top(outfit).base
        case .topShade: return CharacterPalette.top(outfit).shade
        case .topOutline: return CharacterPalette.top(outfit).outline
        case .bottom: return CharacterPalette.bottom.base
        case .bottomShade: return CharacterPalette.bottom.shade
        case .eye: return Palette.color(.ink)
        case .accessory: return CharacterPalette.accessory(accessory)?.base
        case .accessoryShade: return CharacterPalette.accessory(accessory)?.shade
        case .hueBase, .hueLight, .hueDark:
            preconditionFailure("project hue slot \(slot) in a character map")
        }
    }

    /// q, j and u tones: material outlines, left out of the 12-colour cap like ink (7.1).
    public var outlineColors: Set<RGBA8> {
        [CharacterPalette.skin(skin).outline, CharacterPalette.hair(hairColor).outline,
         CharacterPalette.top(outfit).outline]
    }

    /// "s0h2c1op4a0": skin, hair style, hair colour, outfit ("p<n>" for a project hue, the index for a neutral),
    /// accessory.
    public var variantName: String {
        let outfitToken = outfit < Palette.projectHues.count ? "p\(outfit)" : "\(outfit)"
        return "s\(skin)h\(hairStyle)c\(hairColor)o\(outfitToken)a\(accessory)"
    }
}
