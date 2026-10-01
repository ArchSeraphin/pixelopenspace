import Foundation

/// Base decor (7.4.9): the small plant (one per island, one in the hall) and the coffee machine of the hall,
/// both anchored at the centre of their tile and drawn toward the viewer (`sw`, 3.8).
public enum DecorSprites {
    public static func all() -> [SpriteDef] { catalog }

    private static let catalog: [SpriteDef] = [coffeeMachine(), plantSmall()].sorted { $0.key < $1.key }

    // MARK: Plant

    /// Terracotta pot (soil on top, lit rim) under a bush of leaves outlined in leafDark; frame 1 sways the top.
    static let leaves = PixelMap("""
        ......FFF.......
        .....FiifF..FF..
        ..FF.FiffF.FiiF.
        .FiiFFfffFFiffF.
        .FifFiFffFfiffF.
        FiffFiifFFiffFF.
        FifffiffFiffFFF.
        FifffffFFfffFF..
        .FfffffFFffFFF..
        .FFfffFFfffFF...
        ..FFFFFFFFFF....
        ....FFFFFF......
        """)

    static let potRamp = Ramp(top: Palette.color(.hairDark), left: Palette.color(.woodMid), right: Palette.color(.woodDark),
                              outline: Palette.color(.hairDark), highlight: Palette.color(.woodLight))

    static func plantSmall() -> SpriteDef {
        var canvas = SceneryKit.Canvas(width: 16, height: 24, anchor: PixelPoint(8, 23))
        let probe = canvas.box(SceneryKit.Box(u: -3, v: -3, z: 0, w: 3, d: 3, height: 6), ramp: potRamp)
        let bush = leaves.renderDecor()
        var still = canvas.image
        still.blit(bush, x: 0, y: 2)
        // Sway: the top five rows of leaves move 1 px to the right.
        var swayed = canvas.image
        swayed.blit(bush.cropped(PixelRect(x: 0, y: 5, width: 16, height: 7)), x: 0, y: 7)
        swayed.blit(bush.cropped(PixelRect(x: -1, y: 0, width: 16, height: 5)), x: 0, y: 2)
        return SpriteDef(key: SpriteKey("decor.plantSmall"), category: .decor, anchor: canvas.anchor, frames: [still, swayed],
                         holds: AnimationClock.holds(fps: 1, frames: 2), outlineColors: [potRamp.outline], lightProbe: probe)
    }

    // MARK: Coffee machine

    /// Brushed metal body (the dark dispenser stands out on it), dark metal bean hopper, wooden counter.
    static let machineRamp = Ramp.neutral
    static let hopperRamp = FurnitureSprites.metal
    static let counter = SceneryKit.Box(u: -4, v: -5, z: 0, w: 7, d: 6, height: 14)
    static let machine = SceneryKit.Box(u: -3, v: -5, z: 14, w: 5, d: 3, height: 18)
    static let hopper = SceneryKit.Box(u: -2, v: -5, z: 32, w: 2, d: 2, height: 4)
    static let cup = SceneryKit.Box(u: -1, v: -2, z: 14, w: 1, d: 1, height: 3)

    /// Front of the machine (on its face toward the viewer): display, two buttons, the dark dispenser with its nozzle.
    static let machineFront = PixelMap("""
        .ggg.G.1..
        .ggg......
        ..........
        ..55555...
        ..5335o...
        ..55o55...
        ..55555...
        ..55555...
        ..55555...
        ..ooooo...
        """).renderDecor()

    /// The cabinet door of the counter, on its face toward the viewer.
    static let counterDoor = PixelMap("""
        ..............
        .999999999999.
        .9..........9.
        .9..........9.
        .9........6.9.
        .9........6.9.
        .9..........9.
        .9..........9.
        .999999999999.
        """).renderDecor()

    /// Two wisps over the cup, one position per frame (rising and swaying).
    static let steam: [[(Int, Int, PaletteRole)]] = [
        [(17, 22, .mist), (18, 20, .chalk), (17, 18, .chalk), (18, 16, .mist)],
        [(18, 22, .chalk), (17, 20, .chalk), (18, 18, .mist), (17, 15, .mist)],
        [(17, 21, .chalk), (18, 19, .mist), (18, 17, .chalk), (17, 16, .mist)],
        [(18, 21, .mist), (17, 19, .chalk), (17, 17, .mist), (18, 14, .chalk)],
    ]

    static func coffeeMachine() -> SpriteDef {
        var canvas = SceneryKit.Canvas(width: 32, height: 48, anchor: PixelPoint(16, 44))
        let probe = canvas.box(counter, ramp: .woodLight)
        canvas.paste(counterDoor, on: counter, face: .left, column: 0, row: 2)
        canvas.box(machine, ramp: machineRamp)
        canvas.paste(machineFront, on: machine, face: .left, column: 0, row: 1)
        canvas.box(hopper, ramp: hopperRamp)
        canvas.box(cup, ramp: DeskItemSprites.mugRamp)
        let frames = steam.map { dots -> PixelImage in
            var frame = canvas.image
            for (x, y, role) in dots { frame[x, y] = Palette.color(role) }
            return frame
        }
        return SpriteDef(key: SpriteKey("decor.coffeeMachine"), category: .decor, anchor: canvas.anchor, frames: frames,
                         holds: AnimationClock.holds(fps: 6, frames: 4), outlineColors: [Ramp.woodLight.outline],
                         lightProbe: probe)
    }
}
