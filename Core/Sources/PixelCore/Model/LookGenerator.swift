import Foundation

extension AgentLook {
    /// Deterministic from the id (seeded like `NameGenerator`, from all 16 bytes so that identifiers differing only at
    /// the end still differ): every skin, haircut and hair colour; half of the agents wear their project's colour
    /// (`outfitPaletteIndex` nil), the others one of the six neutral outfits (10…15); half wear an accessory
    /// (glasses, headphones or beanie). The look editor arrives at step 6; until then this is every agent's look.
    public static func generated(for id: AgentID) -> AgentLook {
        var random = LookRandom(id: id)
        let skin = random.below(CharacterPalette.skinCount)
        let hairStyle = random.below(CharacterPalette.hairStyleCount)
        let hairColor = random.below(CharacterPalette.hairColorCount)
        let neutrals = CharacterPalette.outfitCount - Palette.projectHues.count
        let outfit = random.below(2) == 0 ? nil : Palette.projectHues.count + random.below(neutrals)
        let accessory = random.below(2) == 0 ? nil : 1 + random.below(CharacterPalette.accessoryCount - 1)
        return AgentLook(skin: skin, hairStyle: hairStyle, hairColor: hairColor, outfitPaletteIndex: outfit,
                         accessory: accessory)
    }
}

/// SplitMix64 seeded from the identifier: `NameGenerator.seed(for:)` (its first 8 bytes) mixed with its last 8 bytes.
private struct LookRandom {
    var state: UInt64

    init(id: AgentID) {
        let b = id.raw.uuid
        let low = [b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        state = NameGenerator.seed(for: id)
        state = next() ^ low
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< count (count ≥ 1).
    mutating func below(_ count: Int) -> Int {
        Int(next() % UInt64(max(count, 1)))
    }
}
