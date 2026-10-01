import Foundation

/// Desk monitors and their screen contents (7.4.3).
///
/// Row A looks `ne` (−j): the screen faces +j, so it is the left face of the panel and the viewer sees it lit.
/// Row B looks `sw` (+j): the viewer sees the back of the panel, with an LED in the colour and blink pattern of
/// the screen state. `monitor.front` therefore exists toward `ne` and `nw` only, `monitor.back` toward `se` and
/// `sw` only (decision 5). Every monitor is built from `Draw.isoBox` volumes in its own direction, never mirrored.
///
/// The screen content follows the plane of the face: a flat 12×8 picture sheared 2:1 (each column pair 1 px
/// lower), hence 12×13 instead of the 16×10 of 7.4.3 (decision 8). `screen.*@ne` is drawn, `@nw` is its mirror.
public enum MonitorSprites {
    public static let screenWidth = 12
    /// Height of the flat picture before the shear.
    public static let screenFlatHeight = 8
    public static let screenHeight = screenFlatHeight + (screenWidth - 1) / 2
    /// Bottom centre of the sheared picture.
    public static let screenAnchor = PixelPoint(6, 13)
    /// Pixels of the LED on the back of a monitor (2×2).
    public static let ledPixelCount = 4

    public static func all() -> [SpriteDef] { catalog }

    /// "screen.<state>@<facing>".
    public static func screenKey(_ state: ScreenState, facing: Facing) -> SpriteKey {
        SpriteKey(state.spriteID, facing: facing)
    }

    /// "monitor.back~led.<state>@<facing>".
    public static func ledKey(_ state: ScreenState, facing: Facing) -> SpriteKey {
        SpriteKey("monitor.back", variant: "led.\(state.rawValue)", facing: facing)
    }

    /// Where the screen anchor goes, from the anchor of `monitor.front` of the same facing (px, y down);
    /// nil toward `se` and `sw`, where the screen is out of sight.
    public static func screenOffset(facing: Facing) -> PixelPoint? {
        switch facing {
        case .ne, .nw: return PixelPoint(screenOrigin.x + screenAnchor.x - anchor.x, screenOrigin.y + screenAnchor.y - anchor.y)
        case .se, .sw: return nil
        }
    }

    // MARK: Geometry

    private static let size = 24
    private static let anchor = PixelPoint(12, 22)
    /// Panel: a 7×1-unit slab 11 px tall (16×19 px), at (4, 0). Its long face carries the glass.
    private static let panelOrigin = PixelPoint(4, 0)
    private static let panelHeight = 11
    /// Top-left of the sheared screen in the monitor frame (both facings: the panels mirror each other).
    private static let screenOrigin = PixelPoint(6, 4)
    private static let neckOrigin = PixelPoint(10, 15)
    private static let baseOrigin = PixelPoint(6, 17)

    /// Whether the long face of the panel is its left face (ne, sw) or its right face (nw, se).
    private static func longFaceIsLeft(_ facing: Facing) -> Bool { facing == .ne || facing == .sw }

    private static let catalog: [SpriteDef] = {
        var defs: [SpriteDef] = []
        for facing in [Facing.ne, .nw] { defs.append(front(facing)) }
        for facing in [Facing.se, .sw] {
            for state in ScreenState.allCases { defs.append(back(facing, state: state)) }
        }
        for state in ScreenState.allCases {
            let frames = screenFrames(state)
            let ne = SpriteDef(key: screenKey(state, facing: .ne), category: .screens, anchor: screenAnchor, frames: frames,
                               holds: state.holds)
            defs.append(ne)
            defs.append(SpriteDef(key: screenKey(state, facing: .nw), category: .screens,
                                  anchor: PixelPoint(screenWidth - screenAnchor.x, screenAnchor.y),
                                  frames: frames.map { $0.mirrored() }, holds: state.holds, derivation: .mirror, source: ne.key))
        }
        return defs.sorted { $0.key < $1.key }
    }()

    // MARK: Monitors

    private static func panel(_ facing: Facing) -> IsoBox {
        longFaceIsLeft(facing)
            ? Draw.isoBox(w: 7, d: 1, height: panelHeight, ramp: .neutral)
            : Draw.isoBox(w: 1, d: 7, height: panelHeight, ramp: .neutral)
    }

    private static func stand(into image: inout PixelImage) {
        image.blit(Draw.isoBox(w: 3, d: 3, height: 1, ramp: .neutral).image, x: baseOrigin.x, y: baseOrigin.y)
    }

    private static let neck = Draw.isoBox(w: 1, d: 1, height: 4, ramp: .neutral).image

    private static func front(_ facing: Facing) -> SpriteDef {
        var image = PixelImage(width: size, height: size)
        stand(into: &image)
        image.blit(neck, x: neckOrigin.x, y: neckOrigin.y)          // behind the panel: the screen faces us
        image.blit(panel(facing).image, x: panelOrigin.x, y: panelOrigin.y)
        let off = screenFrames(.off)[0]
        image.blit(facing == .ne ? off : off.mirrored(), x: screenOrigin.x, y: screenOrigin.y)
        // Probes on the casing: the 1-px bezel column beside the glass and the 2-px side of the slab.
        let bezel = PixelRect(x: panelOrigin.x + 1, y: facing == .ne ? 3 : 9, width: 1, height: 8)
        let side = PixelRect(x: panelOrigin.x + 14, y: facing == .ne ? 9 : 3, width: 1, height: 8)
        return SpriteDef(key: SpriteKey("monitor.front", facing: facing), category: .monitors, anchor: anchor,
                         frames: [image], lightProbe: LightProbe(left: bezel, right: side))
    }

    private static func back(_ facing: Facing, state: ScreenState) -> SpriteDef {
        var casing = PixelImage(width: size, height: size)
        stand(into: &casing)
        let box = panel(facing)
        var slab = box.image
        // Two vents parallel to the top edge, in the shade of the face they are cut in.
        let left = longFaceIsLeft(facing)
        let vent = Palette.color(left ? .slate : .shade)
        for x in 2...7 {
            let column = left ? x : 15 - x
            let faceTop = 2 + x / 2
            slab[column, faceTop + 2] = vent
            slab[column, faceTop + 4] = vent
        }
        casing.blit(slab, x: panelOrigin.x, y: panelOrigin.y)
        casing.blit(neck, x: neckOrigin.x, y: neckOrigin.y)         // in front of the panel: we see its back
        let ledX = panelOrigin.x + (left ? 10 : 4), ledY = 14
        let frames = ledFrames(state).map { pattern -> PixelImage in
            var image = casing
            for (index, role) in pattern.enumerated() {
                image[ledX + index % 2, ledY + index / 2] = Palette.color(role)
            }
            return image
        }
        let probe = LightProbe(left: moved(box.lightProbe.left, by: panelOrigin), right: moved(box.lightProbe.right, by: panelOrigin))
        return SpriteDef(key: ledKey(state, facing: facing), category: .monitors, anchor: anchor, frames: frames,
                         holds: AnimationClock.holds(fps: 2, frames: 2), lightProbe: probe)
    }

    private static func moved(_ rect: PixelRect, by offset: PixelPoint) -> PixelRect {
        PixelRect(x: rect.x + offset.x, y: rect.y + offset.y, width: rect.width, height: rect.height)
    }

    /// The 2×2 LED (row-major) in its two frames: a colour and a blink pattern per state; unlit pixels are shade.
    private static func ledFrames(_ state: ScreenState) -> [[PaletteRole]] {
        let o = PaletteRole.shade
        func all(_ role: PaletteRole) -> [PaletteRole] { [role, role, role, role] }
        switch state {
        case .off: return [all(o), all(o)]
        case .boot: return [[.screenGlow, .screenGlow, o, o], [o, o, .screenGlow, .screenGlow]]
        case .idle: return [all(.mist), all(.mist)]
        case .thinking: return [all(.thinkLilac), [.thinkLilac, o, o, .thinkLilac]]
        case .working: return [all(.screenGlow), [.screenGlow, o, .screenGlow, o]]
        case .waiting: return [all(.alertYellow), all(o)]
        case .done: return [all(.okGreen), all(.okGreen)]
        case .error: return [all(.errorRed), [.errorRed, o, o, .errorRed]]
        case .quota: return [all(.lampWarm), [.lampWarm, .lampWarm, o, o]]
        case .background: return [all(.skyDay), [o, .skyDay, .skyDay, o]]
        }
    }

    // MARK: Screens

    /// Each column x of the flat picture moves down by x / 2: the plane of the left face of the panel.
    private static func sheared(_ flat: PixelImage) -> PixelImage {
        var out = PixelImage(width: screenWidth, height: screenHeight)
        for x in 0..<flat.width {
            for y in 0..<flat.height { out[x, y + x / 2] = flat[x, y] }
        }
        return out
    }

    private static let legend: [Character: Slot] = ["B": .role(.uiTitle)]

    private static func picture(_ rows: [String]) -> PixelImage {
        precondition(rows.count == screenFlatHeight && rows.allSatisfy { $0.count == screenWidth }, "bad screen \(rows)")
        return sheared(PixelMap(rows.joined(separator: "\n"), legend: legend).renderDecor())
    }

    private static func screenFrames(_ state: ScreenState) -> [PixelImage] {
        switch state {
        case .off:
            return [picture([
                "555555555555",
                "544555555555",
                "545555555555",
                "555555555555",
                "555555555555",
                "555555555555",
                "555555555555",
                "555555555555",
            ])]
        case .boot:
            return (0..<4).map { k in
                let bar = "55" + String(repeating: "g", count: 2 * (k + 1)) + String(repeating: "4", count: 6 - 2 * k) + "55"
                return picture([
                    "555555555555",
                    "555551155555",
                    "555551155555",
                    "555555555555",
                    "555555555555",
                    bar,
                    "555555555555",
                    "555555555555",
                ])
            }
        case .idle:
            return [true, false].map { cursor in
                picture([
                    "BBBBBBBBBBBB",
                    "B4444444BkkB",
                    "B6666666BkkB",
                    cursor ? "B6333o66BBBB" : "B6333666BBBB",
                    "B6666666BkkB",
                    "B6666666BkkB",
                    "BBBBBBBBBBBB",
                    "BBBBBBBBBBBB",
                ])
            }
        case .thinking:
            return (0..<3).map { k in
                var dots = Array("55vv5vv5vv55")
                for x in [2 + 3 * k, 3 + 3 * k] { dots[x] = "1" }
                let row = String(dots)
                return picture([
                    "555555555555",
                    "555555555555",
                    "555555555555",
                    row,
                    row,
                    "555555555555",
                    "555555555555",
                    "555555555555",
                ])
            }
        case .working:
            // A listing that scrolls up 2 rows per frame: indent, length and colour of each line.
            let listing: [(indent: Int, length: Int, ink: Character)] = [
                (1, 6, "g"), (2, 7, "g"), (2, 4, "1"), (3, 6, "g"), (1, 3, "g"), (0, 0, "g"), (1, 8, "g"), (2, 5, "1"),
            ]
            return (0..<4).map { k in
                let rows = (0..<screenFlatHeight).map { r -> String in
                    let line = listing[(2 * k + r) % listing.count]
                    var row = Array(repeating: Character("5"), count: screenWidth)
                    for x in 0..<line.length { row[1 + line.indent + x] = line.ink }
                    return String(row)
                }
                return picture(rows)
            }
        case .waiting:
            let lit = [
                "yyyyyyyyyyyy",
                "yyyyyooyyyyy",
                "yyyyyooyyyyy",
                "yyyyyooyyyyy",
                "yyyyyooyyyyy",
                "yyyyyyyyyyyy",
                "yyyyyooyyyyy",
                "yyyyyyyyyyyy",
            ]
            let dark = lit.map { row in String(row.map { $0 == "o" ? "y" : "5" }) }
            return [picture(lit), picture(dark)]
        case .done:
            return [picture([
                "555555555555",
                "55555555G555",
                "5555555GG555",
                "55G555GG5555",
                "55GG5GG55555",
                "555GGG555555",
                "5555G5555555",
                "555555555555",
            ])]
        case .error:
            return [
                picture([
                    "rrrrrrrrrrrr",
                    "rrrrrrrrrrrr",
                    "rrrr1rr1rrrr",
                    "rrrrr11rrrrr",
                    "rrrrr11rrrrr",
                    "rrrr1rr1rrrr",
                    "rrrrrrrrrrrr",
                    "rrrrrrrrrrrr",
                ]),
                picture([
                    "rrrrrrrrrrrr",
                    "555555rrrrrr",
                    "rrrrrr1rr1rr",
                    "rrrrr11rrrrr",
                    "rrr11rrrrrrr",
                    "rrrr1rr1rrrr",
                    "rrrrrr555555",
                    "rrrrrrrrrrrr",
                ]),
                picture([
                    "555555555555",
                    "555555555555",
                    "5555r55r5555",
                    "55555rr55555",
                    "55555rr55555",
                    "5555r55r5555",
                    "555555555555",
                    "555555555555",
                ]),
            ]
        case .quota:
            return [
                picture([
                    "555555555555",
                    "5555wwww5555",
                    "555w1o11w555",
                    "555w1o11w555",
                    "555w1ooow555",
                    "555w1111w555",
                    "5555wwww5555",
                    "555555555555",
                ]),
                picture([
                    "555555555555",
                    "5555wwww5555",
                    "555w1o11w555",
                    "555w1o11w555",
                    "555w1oo1w555",
                    "555w11o1w555",
                    "5555wwww5555",
                    "555555555555",
                ]),
            ]
        case .background:
            // Hourglass of mist glass between woodMid caps, woodLight sand flowing down; frame 0 is mid-flow.
            let bulbs: [[String]] = [
                ["555227722555", "555577775555", "555557255555", "555527225555", "555227722555"],
                ["555222222555", "555527725555", "555557255555", "555527725555", "555777777555"],
                ["555777777555", "555577775555", "555552255555", "555522225555", "555222222555"],
            ]
            return bulbs.map { rows in picture(["555555555555", "555888888555"] + rows + ["555888888555"]) }
        }
    }
}
