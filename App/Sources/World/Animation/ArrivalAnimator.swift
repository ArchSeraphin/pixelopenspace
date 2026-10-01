import Foundation
import PixelCore
import QuartzCore
import SpriteKit

/// The timeline of one walk between the elevator and a seat (7.4.4, 6(o)). Pure: the walker's place, direction and
/// frame, the elevator doors and the ding all derive from the time since the start, so that a live walk and a
/// frozen snapshot show the same thing.
///
/// The way: from the doorway (the middle of the elevator's two tiles, on the wall line) half a tile straight out,
/// then along `WalkPath.route` from the elevator's floor tile that gives the shorter way, tile centre by tile
/// centre, to the seat; a departure walks it backwards. 2.5 tiles per second.
///
/// Arrival: the doors open (frames 0 to 5 at 12 fps) with a ding, the walker steps out once they are open, walks,
/// then sits down (or stays standing when the plan shows it standing: a session that is starting); the doors close
/// behind it. Departure: a wave and `sitDown` backwards (standUp) when it was seated, the walk, the doors open in
/// time to let it in, then close.
struct WalkScript: Sendable {
    enum Direction: Sendable {
        case arrival, departure
    }

    /// A one-shot at the seat: `sitDown` (arrival), or `wave` then `sitDown` backwards (departure).
    struct Gesture: Hashable, Sendable {
        var animation: CharacterAnimation
        var reversed: Bool
        var start: TimeInterval
        var duration: TimeInterval
    }

    /// What the walker shows at a time.
    struct Pose: Hashable, Sendable {
        var visible: Bool
        /// Whole texels.
        var point: CGPoint
        var spot: GridSpot
        var animation: CharacterAnimation
        var facing: Facing
        /// `sitDown` played backwards.
        var reversed: Bool
        /// Seconds into `animation`.
        var time: TimeInterval
        /// On the seat: the depth of a seated avatar (behind the backrest when it turns its back to the viewer).
        var atSeat: Bool
    }

    static let tilesPerSecond = 2.5
    /// One tile along i or j, in scene texels: √(32² + 16²).
    static let tileStep = Double(hypot(Double(IsoMath.tileWidth / 2), Double(IsoMath.tileHeight / 2)))
    static var speed: Double { tilesPerSecond * tileStep }
    /// `elevator`: 6 frames at 12 fps, from closed to open.
    static let doorFrames = 6
    static let doorFrameTime = 1.0 / 12
    static var doorsTravel: TimeInterval { Double(doorFrames) * doorFrameTime }
    /// The ding starts while the doors open.
    static let dingDelay: TimeInterval = 0.3
    static var dingDuration: TimeInterval {
        let ticks = SpriteCatalog.sprite(SpriteKey("fx.ding"))?.holds.reduce(0, +) ?? 9
        return Double(ticks) / Double(AnimationClock.ticksPerSecond)
    }

    let direction: Direction
    /// The way, doorway first for an arrival, seat first for a departure.
    let spots: [GridSpot]
    let path: SnappedPath
    /// The direction of each segment of `spots`.
    let facings: [Facing]
    /// The walker's direction at the seat.
    let seatFacing: Facing
    /// Arrival: sits down at the end; departure: stands up first.
    let seated: Bool
    let walkStart: TimeInterval
    let walkEnd: TimeInterval
    let gestures: [Gesture]
    let doorsOpen: TimeInterval
    let doorsClose: TimeInterval
    let ding: TimeInterval?
    let duration: TimeInterval

    /// The way from the elevator to `seat` (doorway first), nil when there is none.
    static func way(toSeat seat: GridPoint, layout: WorldLayoutResult) -> [GridSpot]? {
        let elevator = layout.elevator
        guard !elevator.isEmpty else { return nil }
        let blocked = WalkPath.blockedTiles(layout)
        var best: [GridPoint]?
        for tile in elevator.tiles where !blocked.contains(tile) {
            guard let route = WalkPath.route(from: tile, to: seat, layout: layout) else { continue }
            if best.map({ route.count < $0.count }) ?? true { best = route }
        }
        guard let best else { return nil }
        // The middle of the doors, on the wall line (i = origin), then half a tile out of the elevator.
        let doorway = GridSpot(Double(elevator.origin.i), Double(elevator.origin.j) + Double(elevator.size.d) / 2)
        let outside = GridSpot(doorway.i + 0.5, doorway.j)
        return [doorway, outside] + best.map { GridSpot(centreOf: $0) }
    }

    static func arrival(way: [GridSpot], seatFacing: Facing, sits: Bool) -> WalkScript {
        let walkStart = doorsTravel
        let path = SnappedPath(way.map(\.scenePoint))
        let walkEnd = walkStart + path.duration(speed: speed)
        var gestures: [Gesture] = []
        if sits {
            gestures.append(Gesture(animation: .sitDown, reversed: false, start: walkEnd,
                                    duration: Self.duration(of: .sitDown)))
        }
        // The doors close once the walker is a tile away from them.
        let doorsClose = walkStart + 1 / tilesPerSecond + 0.1
        let end = max(walkEnd + gestures.reduce(0) { $0 + $1.duration }, doorsClose + doorsTravel)
        return WalkScript(direction: .arrival, spots: way, path: path, facings: Self.facings(way),
                          seatFacing: seatFacing, seated: sits, walkStart: walkStart, walkEnd: walkEnd,
                          gestures: gestures, doorsOpen: 0, doorsClose: doorsClose, ding: dingDelay, duration: end)
    }

    static func departure(way: [GridSpot], seatFacing: Facing, seated: Bool) -> WalkScript {
        let back = Array(way.reversed())
        var gestures: [Gesture] = []
        var t: TimeInterval = 0
        if seated {
            for (animation, reversed) in [(CharacterAnimation.wave, false), (.sitDown, true)] {
                let length = Self.duration(of: animation)
                gestures.append(Gesture(animation: animation, reversed: reversed, start: t, duration: length))
                t += length
            }
        }
        let path = SnappedPath(back.map(\.scenePoint))
        let walkStart = t
        let walkEnd = walkStart + path.duration(speed: speed)
        // Open when the walker is half a tile from the doorway, closed just after it went in.
        let doorsOpen = max(0, walkEnd - 0.5 / tilesPerSecond - doorsTravel)
        let doorsClose = walkEnd + 0.15
        return WalkScript(direction: .departure, spots: back, path: path, facings: Self.facings(back),
                          seatFacing: seatFacing, seated: seated, walkStart: walkStart, walkEnd: walkEnd,
                          gestures: gestures, doorsOpen: doorsOpen, doorsClose: doorsClose, ding: nil,
                          duration: doorsClose + doorsTravel)
    }

    static func duration(of animation: CharacterAnimation) -> TimeInterval {
        Double(animation.holds.reduce(0, +)) / Double(AnimationClock.ticksPerSecond)
    }

    /// +i: se, +j: sw, −i: nw, −j: ne (the larger step decides).
    static func facing(from a: GridSpot, to b: GridSpot) -> Facing {
        let di = b.i - a.i, dj = b.j - a.j
        if abs(di) >= abs(dj) { return di >= 0 ? .se : .nw }
        return dj > 0 ? .sw : .ne
    }

    private static func facings(_ spots: [GridSpot]) -> [Facing] {
        guard spots.count > 1 else { return [] }
        return (0..<(spots.count - 1)).map { facing(from: spots[$0], to: spots[$0 + 1]) }
    }

    var seat: GridSpot { direction == .arrival ? spots[spots.count - 1] : spots[0] }

    /// The time of a frozen arrival at `progress` of its walk (0: in the doorway, doors open; 1: seated).
    func time(atProgress progress: Double) -> TimeInterval {
        let sitting = gestures.reduce(0) { $0 + $1.duration }
        return walkStart + min(max(progress, 0), 1) * (walkEnd - walkStart + sitting)
    }

    /// The characters the walker shows: (animation, facing, backwards).
    var clips: [(CharacterAnimation, Facing, Bool)] {
        var out: [(CharacterAnimation, Facing, Bool)] = []
        for facing in Set(facings).sorted(by: { $0.rawValue < $1.rawValue }) { out.append((.walk, facing, false)) }
        for gesture in gestures {
            out.append((gesture.animation, CharacterClip.facing(gesture.animation, wanted: seatFacing), gesture.reversed))
        }
        if direction == .arrival && !seated { out.append((.stand, CharacterClip.facing(.stand, wanted: seatFacing), false)) }
        return out
    }

    func pose(at t: TimeInterval) -> Pose {
        let seatSpot = seat
        func atSeat(_ animation: CharacterAnimation, reversed: Bool, time: TimeInterval) -> Pose {
            Pose(visible: true, point: seatSpot.scenePoint, spot: seatSpot, animation: animation,
                 facing: CharacterClip.facing(animation, wanted: seatFacing), reversed: reversed, time: max(time, 0),
                 atSeat: true)
        }
        if t >= walkStart && t < walkEnd && spots.count > 1 {
            let sample = path.sample(at: (t - walkStart) * Self.speed)
            let a = spots[sample.segment], b = spots[sample.segment + 1]
            let spot = GridSpot(a.i + (b.i - a.i) * sample.fraction, a.j + (b.j - a.j) * sample.fraction)
            return Pose(visible: true, point: sample.point, spot: spot, animation: .walk,
                        facing: facings[sample.segment], reversed: false, time: t - walkStart, atSeat: false)
        }
        switch direction {
        case .arrival:
            if t < walkStart {
                return Pose(visible: false, point: spots[0].scenePoint, spot: spots[0], animation: .walk,
                            facing: facings.first ?? .se, reversed: false, time: 0, atSeat: false)
            }
            if let gesture = gestures.last { return atSeat(gesture.animation, reversed: gesture.reversed, time: t - gesture.start) }
            return atSeat(.stand, reversed: false, time: t - walkEnd)
        case .departure:
            if t >= walkEnd {
                let last = spots[spots.count - 1]
                return Pose(visible: false, point: last.scenePoint, spot: last, animation: .walk,
                            facing: facings.last ?? .nw, reversed: false, time: 0, atSeat: false)
            }
            let gesture = gestures.last { $0.start <= t } ?? gestures.first
            guard let gesture else { return atSeat(.stand, reversed: false, time: t) }
            return atSeat(gesture.animation, reversed: gesture.reversed, time: t - gesture.start)
        }
    }

    /// The elevator's frame at `t`: 0 closed … 5 open.
    func doorFrame(at t: TimeInterval) -> Int {
        guard t >= doorsOpen else { return 0 }
        let epsilon = 1e-9
        let opened = min(Self.doorFrames - 1, Int(((min(t, doorsClose) - doorsOpen) / Self.doorFrameTime + epsilon).rounded(.down)))
        guard t > doorsClose else { return opened }
        return max(0, opened - Int(((t - doorsClose) / Self.doorFrameTime + epsilon).rounded(.down)))
    }

    /// Seconds into the ding at `t`, nil when it does not show.
    func dingTime(at t: TimeInterval) -> TimeInterval? {
        guard let ding, t >= ding, t < ding + Self.dingDuration else { return nil }
        return t - ding
    }
}

/// The agents arriving by the elevator and leaving by it (7.4.4, 6(o)): while an agent walks, the plan leaves it
/// out (`WorldInteractionState.hiddenAgents`: avatar, shadow, overlays; its chair stays) and a walker of its look
/// goes between the elevator and its seat (`WalkScript`), with its shadow (`shadow.char` at 30 %), the doors of the
/// elevator (`wall:elevator`, shared by every walker) and the ding (`fx.ding`). Positions are whole texels at every
/// frame (7.3, rule 1), depths those of the tile under the walker's feet (`SceneDepth`). At the seat the agent
/// leaves `hiddenAgents` and the plan takes over; the walker stays until the plan's avatar is on screen. Without a
/// way from the elevator, the agent appears at once.
@MainActor
final class ArrivalAnimator {
    /// Two agents arriving together leave the elevator this far apart.
    static let stagger: TimeInterval = 1.2
    static let walkKey = "walk"
    static let handOffKey = "walk.handOff"
    /// Where the ding rings, from the elevator's LED (scene texels, y up).
    static let ledToDing = CGPoint(x: 0, y: 6)
    /// The cast shadow's offset of 7.2, (+2, +1) on the canvas (y down), as the compositor bakes it.
    static let shadowOffset = CGPoint(x: 2, y: -1)

    private weak var stage: WorldStage?
    private let transitions: TransitionPlayer
    private var walks: [AgentID: Walk] = [:]
    /// The agents this animator left out of the plan.
    private var hidden: Set<AgentID> = []
    /// Arrived standing while the plan now shows them seated: they sit down once the plan shows them.
    private var pendingSitDown: Set<AgentID> = []
    private let doors = ElevatorDoors()
    private var lastEnergyNote: TimeInterval = 0

    init(stage: WorldStage, transitions: TransitionPlayer) {
        self.stage = stage
        self.transitions = transitions
    }

    // MARK: Before the plan is applied

    /// The arrivals of `events` that walk: the agent has a seat and a way from the elevator. The coordinator leaves
    /// them out of the plan it applies, so that no avatar shows at its seat first.
    func walkingArrivals(_ events: [WorldEvent], input: SceneInput) -> [AgentID] {
        events.compactMap { event -> AgentID? in
            guard case .agentArrived(let agent) = event, let seat = Self.desk(of: agent, in: input.layout)?.desk.seatTile,
                  WalkScript.way(toSeat: seat, layout: input.layout) != nil else { return nil }
            return agent
        }
    }

    /// Leaves `agents` out of the plan (the coordinator plans again with them hidden).
    func hide(_ agents: [AgentID]) {
        guard let interaction = stage?.interaction else { return }
        for agent in agents {
            cancelWalk(agent)
            hidden.insert(agent)
            if !interaction.hiddenAgents.contains(agent) { interaction.hiddenAgents.insert(agent) }
        }
    }

    /// What a leaving agent looked like, read before the plan without it is applied.
    struct Departure {
        var agent: AgentID
        var look: AgentLook
        var hue: Int
        var animation: CharacterAnimation
        var facing: Facing
        var seat: GridPoint
        /// The avatar's texture and depth when it left: the walker shows them until its frames are composed.
        var texture: SKTexture?
        var zPosition: CGFloat
    }

    /// The departures of `events` that walk: the avatar was in the previous plan, its seat is still there, and a way
    /// leads to the elevator. An agent leaving while it walked in just goes.
    func departures(_ events: [WorldEvent], previous: WorldScenePlan?, input: SceneInput,
                    scene: WorldScene) -> [Departure] {
        var out: [Departure] = []
        for event in events {
            guard case .agentLeft(let agent) = event else { continue }
            if walks[agent] != nil || hidden.contains(agent) {
                cancelWalk(agent)
                continue
            }
            let id = SceneNodeID("agent:\(agent)/avatar")
            guard let node = previous?.node(id), let seat = node.tile,
                  case .character(let look, let hue, let animation, let facing) = node.sprite,
                  Self.desk(at: seat, in: input.layout) != nil,
                  WalkScript.way(toSeat: seat, layout: input.layout) != nil else { continue }
            let sprite = scene.node(for: id)
            out.append(Departure(agent: agent, look: look, hue: hue, animation: animation, facing: facing, seat: seat,
                                 texture: sprite?.texture, zPosition: sprite?.zPosition ?? CGFloat(node.zOrder)))
        }
        return out
    }

    // MARK: After the plan is applied

    /// The walks of hidden arrivals, one after the other.
    func startArrivals(_ agents: [AgentID], input: SceneInput) {
        guard let stage else { return }
        for (index, agent) in agents.enumerated() {
            guard let walk = makeArrival(agent, input: input) else {
                unhide(agent)
                continue
            }
            walks[agent] = walk
            let registry = stage.registry
            let refs = walk.characterRefs
            let delay = Double(index) * Self.stagger
            Task { @MainActor [weak self, weak walk, registry] in
                await registry.prepare(characters: refs)
                registry.prepareNow(characters: refs)
                guard let self, let walk, self.walks[agent] === walk else { return }
                walk.loadClips(registry: registry)
                self.run(walk, delay: delay)
            }
        }
    }

    func startDepartures(_ departures: [Departure], input: SceneInput) {
        guard let stage, let scene = stage.scene else { return }
        for departure in departures {
            guard let way = WalkScript.way(toSeat: departure.seat, layout: input.layout) else { continue }
            let seated = !CharacterClip.isStanding(departure.animation)
            let script = WalkScript.departure(way: way, seatFacing: departure.facing, seated: seated)
            let walk = Walk(agent: departure.agent, script: script, look: departure.look, hue: departure.hue,
                            seatZ: seatDepth(departure.seat, facing: departure.facing, scene: scene, input: input))
            add(walk, to: scene)
            // The avatar as it left, until the walk's frames are composed.
            walk.walker.texture = departure.texture
            walk.walker.position = GridSpot(centreOf: departure.seat).scenePoint
            walk.walker.zPosition = departure.zPosition
            walk.walker.isHidden = departure.texture == nil
            walk.shadow.position = walk.walker.position + Self.shadowOffset
            walk.shadow.isHidden = walk.walker.isHidden
            walks[departure.agent] = walk
            let registry = stage.registry
            let refs = walk.characterRefs
            let agent = departure.agent
            Task { @MainActor [weak self, weak walk, registry] in
                await registry.prepare(characters: refs)
                registry.prepareNow(characters: refs)
                guard let self, let walk, self.walks[agent] === walk else { return }
                walk.loadClips(registry: registry)
                self.run(walk, delay: 0)
            }
        }
    }

    /// The plan or its background changed on screen: a walker whose agent the plan shows again goes.
    func planShown() {
        guard let stage, let scene = stage.scene, let plan = stage.plan else { return }
        let baked = !scene.needsBackground(plan)
        for (agent, walk) in walks where walk.handingOff {
            guard baked, let avatar = TransitionPlayer.avatar(agent, in: scene), !avatar.isHidden else { continue }
            remove(walk)
            if pendingSitDown.remove(agent) != nil { transitions.play(.sitDown, agent: agent) }
        }
    }

    /// Every walk stops, every agent comes back to the plan, the doors close (a new scene, a snapshot step).
    func cancelAll() {
        for walk in walks.values { remove(walk) }
        walks = [:]
        if let interaction = stage?.interaction, !hidden.isEmpty {
            interaction.hiddenAgents.subtract(hidden)
        }
        hidden = []
        pendingSitDown = []
        doors.reset(scene: stage?.scene, registry: stage?.registry)
    }

    // MARK: Snapshots

    /// Whether `agent` can walk from the elevator in `input`.
    func canWalk(_ agent: AgentID, input: SceneInput) -> Bool {
        !walkingArrivals([.agentArrived(agent)], input: input).isEmpty
    }

    /// A frozen arrival at `progress` of its walk, the agent already left out of the plan applied (`hide`). Returns
    /// where the walker stands.
    @discardableResult
    func pose(_ agent: AgentID, progress: Double, input: SceneInput) -> CGPoint? {
        guard let stage, let walk = makeArrival(agent, input: input) else { return nil }
        stage.registry.prepareNow(characters: walk.characterRefs)
        walk.loadClips(registry: stage.registry)
        walks[agent] = walk
        render(walk, at: walk.script.time(atProgress: progress), live: false)
        return walk.walker.position
    }

    // MARK: Walks

    private func makeArrival(_ agent: AgentID, input: SceneInput) -> Walk? {
        guard let scene = stage?.scene, let placed = Self.desk(of: agent, in: input.layout),
              let sceneAgent = input.agents[agent],
              let way = WalkScript.way(toSeat: placed.desk.seatTile, layout: input.layout) else { return nil }
        let presentation = sceneAgent.presentation
        let animation = presentation.animation ?? .stand
        let wanted = presentation.facesViewer && !placed.desk.facing.isTowardViewer
            ? placed.desk.facing.opposite : placed.desk.facing
        let facing = CharacterClip.facing(animation, wanted: wanted)
        let script = WalkScript.arrival(way: way, seatFacing: facing, sits: !CharacterClip.isStanding(animation))
        let hue = min(max(input.projects[placed.island.projectID]?.hueIndex ?? 0, 0), Palette.projectHues.count - 1)
        let walk = Walk(agent: agent, script: script, look: sceneAgent.look, hue: hue,
                        seatZ: seatDepth(placed.desk.seatTile, facing: facing, scene: scene, input: input))
        add(walk, to: scene)
        return walk
    }

    private func add(_ walk: Walk, to scene: WorldScene) {
        let registry = stage?.registry
        walk.shadow.texture = registry?.texture(SpriteKey("shadow.char"), frame: 0)
        walk.shadow.zPosition = SceneDepth.floorShadow
        let led = scene.node(for: SceneNodeID("wall:elevator/led")) ?? scene.node(for: SceneNodeID("wall:elevator"))
        walk.ding.position = (led?.position ?? .zero) + Self.ledToDing
        walk.ding.zPosition = (led?.zPosition ?? 0) + 1
        scene.addEffect(walk.shadow)
        scene.addEffect(walk.walker)
        scene.addEffect(walk.ding)
    }

    /// Plays the script from its start after `delay`, then hands the agent back to the plan (arrival) or goes
    /// (departure).
    private func run(_ walk: Walk, delay: TimeInterval) {
        let script = walk.script
        let play = SKAction.customAction(withDuration: script.duration) { [weak self, weak walk] _, elapsed in
            MainActor.assumeIsolated {
                guard let self, let walk else { return }
                self.render(walk, at: Double(elapsed), live: true)
            }
        }
        let done = SKAction.run { [weak self, weak walk] in
            MainActor.assumeIsolated {
                guard let self, let walk else { return }
                self.finish(walk)
            }
        }
        var steps: [SKAction] = []
        if delay > 0 { steps.append(.wait(forDuration: delay)) }
        steps += [play, done]
        walk.walker.run(.sequence(steps), withKey: Self.walkKey)
    }

    private func render(_ walk: Walk, at t: TimeInterval, live: Bool) {
        guard let stage, let scene = stage.scene else { return }
        let script = walk.script
        let pose = script.pose(at: t)
        if pose.visible {
            if let clip = walk.clip(pose.animation, facing: pose.facing, reversed: pose.reversed) {
                walk.walker.texture = clip.texture(at: pose.time)
            }
            walk.walker.position = pose.point
            walk.walker.zPosition = pose.atSeat ? walk.seatZ : SceneDepth.walker(i: pose.spot.i, j: pose.spot.j)
            walk.walker.isHidden = walk.walker.texture == nil
        } else {
            walk.walker.isHidden = true
        }
        walk.shadow.position = walk.walker.position + Self.shadowOffset
        walk.shadow.isHidden = walk.walker.isHidden
        if let time = script.dingTime(at: t),
           let def = SpriteCatalog.sprite(SpriteKey("fx.ding")) {
            let frame = def.frameIndex(atTick: Int((time * Double(AnimationClock.ticksPerSecond)).rounded(.down)))
            walk.ding.texture = stage.registry.texture(SpriteKey("fx.ding"), frame: frame)
            walk.ding.isHidden = walk.ding.texture == nil
        } else {
            walk.ding.isHidden = true
        }
        doors.set(script.doorFrame(at: t), for: walk, scene: scene, registry: stage.registry)
        if live { noteEnergy() }
    }

    private func finish(_ walk: Walk) {
        guard walks[walk.agent] === walk else { return }
        doors.release(walk, scene: stage?.scene, registry: stage?.registry)
        walk.ding.isHidden = true
        switch walk.script.direction {
        case .departure:
            remove(walk)
            walks[walk.agent] = nil
        case .arrival:
            walk.handingOff = true
            let agent = walk.agent
            if !walk.script.seated, let animation = stage?.input?.agents[agent]?.presentation.animation,
               !CharacterClip.isStanding(animation) {
                pendingSitDown.insert(agent)
            }
            unhide(agent)
            // Whatever happens to the plan, the walker does not stay longer than this.
            let timeout = SKAction.sequence([.wait(forDuration: 1), .run { [weak self, weak walk] in
                MainActor.assumeIsolated {
                    guard let self, let walk, self.walks[walk.agent] === walk else { return }
                    self.remove(walk)
                    self.pendingSitDown.remove(walk.agent)
                }
            }])
            walk.walker.run(timeout, withKey: Self.handOffKey)
            planShown()
        }
    }

    private func cancelWalk(_ agent: AgentID) {
        if let walk = walks[agent] { remove(walk) }
        unhide(agent)
        pendingSitDown.remove(agent)
    }

    private func remove(_ walk: Walk) {
        walk.walker.removeAllActions()
        walk.walker.removeFromParent()
        walk.shadow.removeFromParent()
        walk.ding.removeFromParent()
        doors.release(walk, scene: stage?.scene, registry: stage?.registry)
        if walks[walk.agent] === walk { walks[walk.agent] = nil }
    }

    private func unhide(_ agent: AgentID) {
        guard hidden.remove(agent) != nil, let interaction = stage?.interaction,
              interaction.hiddenAgents.contains(agent) else { return }
        interaction.hiddenAgents.remove(agent)
    }

    /// 60 frames per second while someone walks (the view's interaction budget, renewed twice a second).
    private func noteEnergy() {
        let now = CACurrentMediaTime()
        guard now - lastEnergyNote > 0.5 else { return }
        lastEnergyNote = now
        stage?.view?.noteInteraction()
    }

    /// The depth of a seated avatar: in front of its chair when it faces the viewer, behind the backrest otherwise
    /// (as the plan orders them).
    private func seatDepth(_ seat: GridPoint, facing: Facing, scene: WorldScene, input: SceneInput) -> CGFloat {
        let front = SceneDepth.world(tile: seat, level: .character, place: 0)
        guard !facing.isTowardViewer else { return front }
        if let placed = Self.desk(at: seat, in: input.layout),
           let chair = scene.node(for: SceneNodeID("post:\(placed.island.projectID)/\(placed.desk.index)/chair")) {
            return chair.zPosition - 0.5
        }
        return SceneDepth.world(tile: seat, level: .furniture, place: 0) - 0.5
    }

    static func desk(of agent: AgentID, in layout: WorldLayoutResult) -> (island: IslandPlacement, desk: DeskPlacement)? {
        for island in layout.islands {
            if let desk = island.desks.first(where: { $0.agentID == agent }) { return (island, desk) }
        }
        return nil
    }

    static func desk(at seat: GridPoint, in layout: WorldLayoutResult) -> (island: IslandPlacement, desk: DeskPlacement)? {
        for island in layout.islands {
            if let desk = island.desks.first(where: { $0.seatTile == seat }) { return (island, desk) }
        }
        return nil
    }
}

/// One walker: its script, its sprites and the clips of its look.
@MainActor
private final class Walk {
    let agent: AgentID
    let script: WalkScript
    let look: AgentLook
    let hue: Int
    /// zPosition at the seat.
    let seatZ: CGFloat
    let walker: SKSpriteNode
    let shadow: SKSpriteNode
    let ding: SKSpriteNode
    private var clips: [String: CharacterClip] = [:]
    /// Arrived: the agent is back in the plan, the walker waits for its avatar to show.
    var handingOff = false

    init(agent: AgentID, script: WalkScript, look: AgentLook, hue: Int, seatZ: CGFloat) {
        self.agent = agent
        self.script = script
        self.look = look
        self.hue = hue
        self.seatZ = seatZ
        walker = Self.sprite(name: "walk:\(agent)", width: CharacterSprites.frameWidth,
                             height: CharacterSprites.frameHeight, anchor: CharacterSprites.anchor)
        let shadowDef = SpriteCatalog.sprite(SpriteKey("shadow.char"))
        shadow = Self.sprite(name: "walk:\(agent)/shadow", width: shadowDef?.width ?? 20, height: shadowDef?.height ?? 8,
                             anchor: shadowDef?.anchor ?? PixelPoint(10, 4))
        shadow.alpha = CGFloat(Palette.shadowAlpha) / 255
        let dingDef = SpriteCatalog.sprite(SpriteKey("fx.ding"))
        ding = Self.sprite(name: "walk:\(agent)/ding", width: dingDef?.width ?? 12, height: dingDef?.height ?? 12,
                           anchor: dingDef?.anchor ?? PixelPoint(6, 12))
        walker.isHidden = true
        shadow.isHidden = true
        ding.isHidden = true
    }

    var characterRefs: Set<CharacterRef> {
        Set(script.clips.map { CharacterRef(look: look, hue: hue, animation: $0.0, facing: $0.1) })
    }

    func loadClips(registry: SpriteRegistry) {
        for (animation, facing, reversed) in script.clips {
            let ref = CharacterRef(look: look, hue: hue, animation: animation, facing: facing)
            if let clip = CharacterClip(ref, reversed: reversed, registry: registry) {
                clips[Self.key(animation, facing, reversed)] = clip
            }
        }
    }

    func clip(_ animation: CharacterAnimation, facing: Facing, reversed: Bool) -> CharacterClip? {
        clips[Self.key(animation, facing, reversed)]
    }

    private static func key(_ animation: CharacterAnimation, _ facing: Facing, _ reversed: Bool) -> String {
        "\(animation.rawValue)@\(facing.rawValue)\(reversed ? "~back" : "")"
    }

    /// A sprite anchored like the catalog's (px from the top-left), never smoothed.
    static func sprite(name: String, width: Int, height: Int, anchor: PixelPoint) -> SKSpriteNode {
        let sprite = SKSpriteNode(texture: nil, color: .clear, size: CGSize(width: width, height: height))
        sprite.name = name
        sprite.anchorPoint = CGPoint(x: Double(anchor.x) / Double(max(width, 1)),
                                     y: 1 - Double(anchor.y) / Double(max(height, 1)))
        sprite.blendMode = .alpha
        sprite.colorBlendFactor = 0
        return sprite
    }
}

/// The doors of the elevator (`wall:elevator`, frame 0 in the plan), shared by every walker: each asks for a frame,
/// the doors show the most open one; back to the plan's frame when nobody asks.
@MainActor
private final class ElevatorDoors {
    private static let id = SceneNodeID("wall:elevator")
    private var requests: [ObjectIdentifier: Int] = [:]
    private var shown = 0

    func set(_ frame: Int, for owner: AnyObject, scene: WorldScene, registry: SpriteRegistry) {
        requests[ObjectIdentifier(owner)] = frame
        update(scene: scene, registry: registry)
    }

    func release(_ owner: AnyObject, scene: WorldScene?, registry: SpriteRegistry?) {
        guard requests.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        guard let scene, let registry else { return }
        update(scene: scene, registry: registry)
    }

    func reset(scene: WorldScene?, registry: SpriteRegistry?) {
        requests = [:]
        if shown != 0, let scene, let registry, let node = scene.node(for: Self.id) as? PlanSpriteNode {
            node.refreshLook(registry: registry, frozen: scene.isFrozen)
        }
        shown = 0
    }

    private func update(scene: WorldScene, registry: SpriteRegistry) {
        let frame = requests.values.max() ?? 0
        guard let node = scene.node(for: Self.id) as? PlanSpriteNode else { return }
        if frame == 0 {
            if shown != 0 { node.refreshLook(registry: registry, frozen: scene.isFrozen) }
        } else if case .sprite(let key, _)? = node.planNode?.sprite, let texture = registry.texture(key, frame: frame) {
            node.texture = texture
        }
        shown = frame
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}
