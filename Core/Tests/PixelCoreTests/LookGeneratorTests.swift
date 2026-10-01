import Foundation
import Testing
@testable import PixelCore

/// `AgentLook.generated(for:)`: a varied look for every new agent, reproducible from its identifier.
@Suite struct LookGeneratorTests {
    /// 200 identifiers drawn from a seeded generator.
    static let ids: [AgentID] = {
        var rng = SplitMix64(seed: 0x100C_0001)
        return (0..<200).map { _ in AgentID(WorldLayoutPropertyTests.uuid(&rng)) }
    }()

    static let looks = ids.map(AgentLook.generated(for:))

    @Test func deterministic() {
        for id in Self.ids { #expect(AgentLook.generated(for: id) == AgentLook.generated(for: id)) }
        // The same identifier read back from its text gives the same look.
        for id in Self.ids.prefix(20) {
            #expect(AgentLook.generated(for: AgentID(string: id.description)!) == AgentLook.generated(for: id))
        }
    }

    @Test func valuesStayInsideThePaletteTables() {
        for look in Self.looks {
            #expect((0..<CharacterPalette.skinCount).contains(look.skin))
            #expect((0..<CharacterPalette.hairStyleCount).contains(look.hairStyle))
            #expect((0..<CharacterPalette.hairColorCount).contains(look.hairColor))
            // nil wears the project's colour; otherwise one of the six neutral outfits.
            if let outfit = look.outfitPaletteIndex {
                #expect((Palette.projectHues.count..<CharacterPalette.outfitCount).contains(outfit))
            }
            // nil is no accessory; otherwise glasses, headphones or beanie.
            if let accessory = look.accessory { #expect((1..<CharacterPalette.accessoryCount).contains(accessory)) }
            // The look resolves to itself: nothing is clamped.
            let resolved = ResolvedLook(look, projectHue: 4)
            #expect(resolved.skin == look.skin && resolved.hairStyle == look.hairStyle && resolved.hairColor == look.hairColor)
        }
    }

    @Test func coversTheTables() {
        #expect(Set(Self.looks.map(\.skin)).count == CharacterPalette.skinCount)
        #expect(Set(Self.looks.map(\.hairStyle)).count >= 5)
        #expect(Set(Self.looks.map(\.hairColor)).count >= 6)
        // Both kinds of outfit, and all six neutrals.
        let projectColour = Self.looks.filter { $0.outfitPaletteIndex == nil }.count
        #expect((60...140).contains(projectColour), "about half wear their project's colour: \(projectColour)")
        #expect(Set(Self.looks.compactMap(\.outfitPaletteIndex)).count == 6)
        // With and without an accessory, every accessory used.
        let bare = Self.looks.filter { $0.accessory == nil }.count
        #expect((60...140).contains(bare), "about half have no accessory: \(bare)")
        #expect(Set(Self.looks.compactMap(\.accessory)) == [1, 2, 3])
    }

    /// Identifiers that differ only in their last bytes (the demo's "00000000-…-0000000000NN") still get varied looks.
    @Test func lastBytesCount() {
        let sequential = (1...20).map {
            AgentID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", $0))!)
        }
        let looks = Set(sequential.map(AgentLook.generated(for:)))
        #expect(looks.count >= 15)
    }

    @Test func looksAreMostlyDistinct() {
        #expect(Set(Self.looks).count >= 180)
    }
}
