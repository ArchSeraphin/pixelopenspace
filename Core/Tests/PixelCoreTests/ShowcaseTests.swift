import Foundation
import Testing
@testable import PixelCore

@Suite struct ShowcaseTests {
    static let casts = Showcase.islandCasts()

    /// (presentation, row) of every agent of both casts.
    static var seated: [(name: String, agent: SceneAgent, row: IslandRow)] {
        casts.flatMap { cast in
            cast.layout.islands.flatMap(\.desks).compactMap { desk -> (String, SceneAgent, IslandRow)? in
                guard let id = desk.agentID, let agent = cast.agents[id] else { return nil }
                return (agent.name, agent, desk.row)
            }
        }
    }

    @Test func nowIsTheMilestoneMorning() {
        #expect(Showcase.now == Date(timeIntervalSince1970: 1_790_845_200))
    }

    @Test func castsCoverEveryState() {
        #expect(Self.casts.count == 2)
        let agents = Self.seated
        #expect(Set(agents.map(\.agent.presentation.kind)) == Set(AgentStateKind.allCases))
        #expect(agents.contains { $0.agent.presentation.asleep && $0.agent.presentation.overlay == .zzz })
        #expect(agents.contains { $0.agent.presentation.kind == .idle && !$0.agent.presentation.asleep })
        #expect(agents.contains { $0.agent.presentation.overlay == .bang && $0.agent.presentation.toolIcon == .question })
        #expect(agents.contains { $0.agent.presentation.overlay == .bang && $0.agent.presentation.toolIcon == nil })
        let badges = Set(agents.flatMap(\.agent.presentation.badges))
        #expect(badges.isSuperset(of: [.stale, .draft, .degraded, .unsafe]))
        #expect(agents.contains { $0.agent.presentation.subagents > 0 })
        #expect(agents.contains { $0.agent.extras.cardOnScreenHue != nil })
        #expect(agents.contains { $0.agent.extras.queued > 0 })
        // Waiting, working and thinking show in both rows.
        for kind in [AgentStateKind.waitingInput, .working, .thinking] {
            let rows = Set(agents.filter { $0.agent.presentation.kind == kind }.map(\.row))
            #expect(rows == [.a, .b], "\(kind)")
        }
        // The names of the plan's table, desk by desk.
        let names = Self.casts.map { cast in
            cast.layout.islands[0].desks.map { $0.agentID.flatMap { cast.agents[$0]?.name } ?? "-" }
        }
        #expect(names[0] == ["Nova", "Bip", "Lune", "Oslo", "Zéphyr", "Tao", "Kiwi", "-"])
        #expect(names[1] == ["Pixou", "Sol", "Mika", "Rio", "Lou", "Plume", "-", "Galet"])
    }

    @Test func castStatesFollowThePlan() {
        func presentation(_ name: String) -> AgentPresentation {
            Self.seated.first { $0.name == name }!.agent.presentation
        }
        #expect(presentation("Nova").kind == .waitingInput && presentation("Nova").halo)
        #expect(presentation("Nova").label.contains("rm -rf dist"))
        #expect(presentation("Bip").toolIcon == .bash && presentation("Bip").subagents == 2)
        #expect(presentation("Lune").kind == .thinking && presentation("Oslo").kind == .done)
        #expect(presentation("Zéphyr").kind == .error && presentation("Zéphyr").label.contains("serveurs surchargés"))
        #expect(presentation("Tao").asleep && presentation("Kiwi").kind == .offline && presentation("Kiwi").nameplateOff)
        #expect(presentation("Pixou").toolIcon == .edit)
        #expect(presentation("Sol").toolIcon == .question && presentation("Mika").kind == .waitingBackground)
        #expect(presentation("Rio").kind == .quotaPaused && presentation("Rio").label.contains("40 min"))
        #expect(presentation("Lou").kind == .launching && presentation("Lou").screen == .boot)
        #expect(presentation("Plume").kind == .thinking && presentation("Plume").badges == [.stale, .degraded])
        #expect(presentation("Galet").kind == .idle && !presentation("Galet").asleep)
        #expect(presentation("Galet").badges == [.draft, .unsafe])
        let pixou = Self.seated.first { $0.name == "Pixou" }!.agent.extras
        #expect(pixou.queued == 2 && pixou.cardOnScreenHue != nil)
        #expect(Self.seated.first { $0.name == "Nova" }!.agent.extras.queued == 1)
    }

    @Test func oneFreeDeskPerCast() {
        for (index, cast) in Self.casts.enumerated() {
            #expect(cast.layout.islands.count == 1, "cast \(index + 1)")
            let island = cast.layout.islands[0]
            #expect(island.capacity == 8 && island.size == GridSize(w: 10, d: 7))
            #expect(island.desks.filter { $0.agentID == nil }.map(\.index) == [index == 0 ? 7 : 6])
            #expect(cast.projects[island.projectID] == ProjectVisual(name: "API", hueIndex: 4))
            #expect(island.rect.intersects(Showcase.islandCrop()) && Showcase.islandCrop().contains(island.rect))
        }
        #expect(Showcase.islandCrop() == GridRect(origin: GridPoint(0, 6), size: GridSize(w: 12, d: 9)))
    }

    @Test func looksAreVaried() {
        let looks = Self.seated.map(\.agent.look)
        #expect(Set(looks.map(\.skin)) == [0, 1, 2, 3])
        #expect(Set(looks.map(\.hairStyle)).count >= 5)
        #expect(Set(looks.compactMap(\.accessory)).isSuperset(of: [1, 2, 3]))
        #expect(Set(looks).count >= 10)
        // The overview reuses the same looks for the same names.
        let overview = Showcase.overview()
        for (name, agent, _) in Self.seated {
            if let same = overview.agents.values.first(where: { $0.name == name }) {
                #expect(same.look == agent.look, "\(name)")
            }
        }
    }

    @Test func overviewMatchesMockupQ() {
        let scene = Showcase.overview()
        #expect(scene.agents.count == 20)
        #expect(scene.projects.count == 6)
        let projects = scene.layout.islands.map { scene.projects[$0.projectID]! }
        #expect(projects.map(\.name) == ["API", "INFRA", "SITE", "DATA", "MOBILE", "DOCS"])
        #expect(projects.map(\.hueIndex) == [4, 3, 0, 5, 7, 2])
        #expect(scene.layout.islands.map(\.slot) == [0, 1, 2, 3, 4, 5])
        let waiting = scene.agents.values.filter { $0.presentation.kind == .waitingInput }.map(\.name).sorted()
        #expect(waiting == ["Ivo", "Nova", "Sol"])
        var counts: [AgentStateKind: Int] = [:]
        for agent in scene.agents.values { counts[agent.presentation.kind, default: 0] += 1 }
        #expect(counts == [.waitingInput: 3, .working: 9, .thinking: 2, .done: 2, .idle: 3, .error: 1])
        let perIsland = scene.layout.islands.map { $0.desks.filter { $0.agentID != nil }.count }
        #expect(perIsland == [5, 4, 3, 3, 3, 2])
        #expect(scene.boardCardHues.count == 12)
    }

    @Test func overviewFitsSixSlots() {
        let scene = Showcase.overview()
        #expect(scene.layout.bounds == GridRect(origin: GridPoint(0, 0), size: GridSize(w: 36, d: 24)))
        let size = SceneCompositor.canvasSize(for: scene.layout.bounds)
        #expect(size.width == 1920 && size.height == 1056)
    }

    @Test func islandSheetIsBothCastsCaptioned() {
        let x1 = Showcase.islandSheet(zoom: .x1, night: false)
        let crop = SceneCompositor.canvasSize(for: Showcase.islandCrop())
        #expect(x1.width >= crop.width && x1.height > 2 * crop.height)
        // The scene of cast 1 sits under its caption band.
        let scene = SceneCompositor.render(Self.casts[0], options: RenderOptions(crop: Showcase.islandCrop()))
        let band = x1.height - 2 * crop.height
        #expect(band % 2 == 0)
        #expect(x1.cropped(PixelRect(x: 0, y: band / 2, width: crop.width, height: crop.height)) == scene)
        // A paper band with ink text at the top.
        #expect(x1[0, 0] == Palette.color(.paper))
        #expect(x1.cropped(PixelRect(x: 0, y: 0, width: x1.width, height: band / 2)).pixels.contains(Palette.color(.ink)))
        #expect(Showcase.islandSheet(zoom: .x2, night: false) == x1.scaled(by: 2))
        let night = Showcase.islandSheet(zoom: .x1, night: true)
        #expect(night.width == x1.width && night.height == x1.height && night != x1)
        // Captions are not under the night veil.
        #expect(night.cropped(PixelRect(x: 0, y: 0, width: x1.width, height: band / 2))
                == x1.cropped(PixelRect(x: 0, y: 0, width: x1.width, height: band / 2)))
    }

    @Test func preview() {
        guard DecorSpriteChecks.previewsEnabled else { return }
        for night in [false, true] {
            let suffix = night ? "nuit" : "jour"
            DecorSpriteChecks.write("scene-ilot-x2-\(suffix)", Showcase.islandSheet(zoom: .x2, night: night), scale: 1)
            DecorSpriteChecks.write("scene-vue-ensemble-\(suffix)", Showcase.overviewImage(night: night), scale: 1)
        }
        DecorSpriteChecks.write("scene-ilot-x1-jour", Showcase.islandSheet(zoom: .x1, night: false), scale: 1)
    }
}
