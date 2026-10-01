import Foundation

/// The ASCII parts of a character (7.5), drawn from scratch for this project: heads, six haircuts, accessories,
/// torso, legs and the arm pieces of every gesture, each toward SE (front: face visible) and NE (back). Light comes
/// from the top-left: every material is shaded on its right edge, under the chin and under the fringe.
///
/// Legend (PixelMap): s S q skin, h H j hair, t T u top, p b trousers, e eye, a A accessory, o ink, 5 shoe (shade),
/// 6 paper (mug, sticky note).
enum CharacterParts {
    /// The two drawn directions: front = SE, back = NE. SW and NW are their reshaded mirrors.
    enum View: Sendable { case front, back }

    enum Eyes: Sendable { case open, up, closed }

    enum Legs: Sendable { case stand, stride, passLeftDown, passRightDown, crouch, seated }

    /// The arm gestures of 7.4.4 (hang, swing, lap, typing, chin, stretch, mug, raised hand, cheer, sticky note,
    /// cough, wave, arms folded on the desk under the sleeping head).
    enum Arms: Sendable {
        case rest, swingIn, swingOut, crouch, lap, typeLeft, typeRight, typeDown, chin, stretchHalf, stretchUp,
             mugLow, mugHigh, raise, raiseTilt, cheer, cheerWide, reach, hold, stick, cough, waveLeft, waveRight, fold
    }

    /// A map and its top-left relative to its reference point (legs: the frame origin; arms: the torso origin).
    struct Placed: Sendable {
        let map: PixelMap
        let dx: Int
        let dy: Int
    }

    static let headSize = 14

    // MARK: Heads (14×14, at the head origin)

    static func head(_ view: View, eyes: Eyes) -> PixelMap {
        switch (view, eyes) {
        case (.back, _): return headBack
        case (.front, .open): return headFront
        case (.front, .up): return headFrontEyesUp
        case (.front, .closed): return headFrontEyesClosed
        }
    }

    static let headFront = PixelMap("""
        ..............
        ....qqqqqq....
        ..qqssssssqq..
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qsssssssssSq.
        .qssssesseSSq.
        .qssssesseSSq.
        .qsssssssSSSq.
        ..qssssssSSq..
        ...qsssssSq...
        ....qqqqqq....
        """)

    static let headFrontEyesUp = PixelMap("""
        ..............
        ....qqqqqq....
        ..qqssssssqq..
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qssssessesSq.
        .qssssesseSSq.
        .qssssssssSSq.
        .qsssssssSSSq.
        ..qssssssSSq..
        ...qsssssSq...
        ....qqqqqq....
        """)

    static let headFrontEyesClosed = PixelMap("""
        ..............
        ....qqqqqq....
        ..qqssssssqq..
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qsssssssssSq.
        .qssssssssSSq.
        .qssssesseSSq.
        .qsssssssSSSq.
        ..qssssssSSq..
        ...qsssssSq...
        ....qqqqqq....
        """)

    static let headBack = PixelMap("""
        ..............
        ....qqqqqq....
        ..qqssssssqq..
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qssssssssssq.
        .qsssssssssSq.
        .qsssssssssSq.
        .qssssssssSSq.
        .qssssssssSSq.
        ..qssssssSSq..
        .....qSSq.....
        .....qSSq.....
        """)

    // MARK: Haircuts (14 wide, top-left at the head origin + (0, −2))

    static let hairOffsetY = -2

    /// 0 short, 1 tousled, 2 bob, 3 long, 4 bun, 5 buzz cut.
    static func hair(style: Int, _ view: View) -> PixelMap {
        let index = CharacterPalette.clamp(style, CharacterPalette.hairStyleCount)
        return view == .front ? hairFront[index] : hairBack[index]
    }

    static let hairFront: [PixelMap] = [
        // 0 short
        PixelMap("""
            ..............
            ..............
            ....jjjjjj....
            ..jjhhhhhhjj..
            .jhhhhhhhhhhj.
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhHHHj
            jhhSSSSSSSSHHj
            jhh........hHj
            .jh........Hj.
            .j..........j.
            """),
        // 1 tousled
        PixelMap("""
            ...j..jj..j...
            ..jhjjhhjjhj..
            .jhhhhhhhhhHj.
            .jhhhhhhhhhHj.
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhHHHj
            jhhShhShhShHHj
            jhSSSSSSSSSSHj
            .jh........Hj.
            .j..........j.
            """),
        // 2 bob
        PixelMap("""
            ..............
            ..............
            ...jjjjjjjj...
            ..jhhhhhhhhj..
            .jhhhhhhhhhHj.
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhSSSSSSSShHj
            jhh........hHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jjh........Hjj
            .jj........jj.
            """),
        // 3 long: falls in front of the shoulders
        PixelMap("""
            ..............
            ..............
            ...jjjjjjjj...
            ..jhhhhhhhhj..
            .jhhhhhhhhhHj.
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhSSSSSSSShHj
            jhh........hHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            jhh........HHj
            .jh........Hj.
            ..j........j..
            """),
        // 4 bun
        PixelMap("""
            .....jjjj.....
            ....jhhhHj....
            ....jjjjjj....
            ..jjhhhhhhjj..
            .jhhhhhhhhhHj.
            jhhhhhhhhhhHHj
            jhhhhhhhhhHHHj
            jhSSSSSSSSSSHj
            jh..........Hj
            .j..........j.
            """),
        // 5 buzz cut
        PixelMap("""
            ..............
            ..............
            ....jjjjjj....
            ..jjhhhhhhjj..
            .jhhhhhhhhhHj.
            .jhhhhhhhhHHj.
            .qSSSSSSSSSSq.
            """),
    ]

    /// From behind: strands (outline texels inside the hair, kept by the reshaded mirrors) so that no cut reads
    /// as a helmet or a beanie; the short cuts also show the ears and the nape.
    static let hairBack: [PixelMap] = [
        // 0 short: ears and a bare nape under a tapered hairline
        PixelMap("""
            ..............
            ..............
            ....jjjjjj....
            ..jjhhhhhhjj..
            .jhhhhhhhhhHj.
            jhhhhhhhhhhHHj
            jhhhhhHjhhhHHj
            jhhhhHjhhhHjHj
            qjhhHjhhhhhHjq
            qsjhhhhhhhHjSq
            .qjhhhhhhhHjq.
            .qSjjhhhhjjSq.
            .qsSSSSSSSSSq.
            """),
        // 1 tousled
        PixelMap("""
            ...j..jj..j...
            ..jhjjhhjjhj..
            .jhhhhhhhhhHj.
            .jhhhhhhhhhHj.
            jhhhhhHjhhhHHj
            jhhhhHjhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhhHHj
            jhhhhhhhhhHHHj
            jhhhhhhhhhHHHj
            .jhhhhhhhhHHj.
            .jhhjhhjhhjHj.
            ..jjjjjjjjjj..
            """),
        // 2 bob: ends at the jaw in uneven tips, the neck shows
        PixelMap("""
            ..............
            ..............
            ...jjjjjjjj...
            ..jhhhhhhhhj..
            .jhhhhhhhhhHj.
            jhhhhhhhhhhHHj
            jhhhhhHjhhhHHj
            jhhhhHjhhhhHHj
            jhhhHjhhhHjHHj
            jhhhjhhhhHjHHj
            jhhHjhhhhjhHHj
            jhhjhhhhHjhHHj
            jhHjhhhhjhhHHj
            .jjhjjhjjhjjj.
            """),
        // 3 long: falls down the back
        PixelMap("""
            ..............
            ..............
            ...jjjjjjjj...
            ..jhhhhhhhhj..
            .jhhhhhhhhhHj.
            jhhhhhhhhhhHHj
            jhhhhhHjhhhHHj
            jhhhhHjhhhhHHj
            jhhhHjhhhhHjHj
            jhhhjhhhhhHHHj
            jhhhjhhhhHjHHj
            jhhHjhhhhjHHHj
            jhhjhhhhhjHHHj
            jhhjhhhhHjHHHj
            jhhjhhhhjhHHHj
            jhhjhhhhjhHHHj
            .jhjhhhhjhHHj.
            ..jhhhhhjHHj..
            ..jhhhhhjHHj..
            ..jhhhhhjHHj..
            ..jhhhhhhHHj..
            ..jhhhhhhHHj..
            ..jhhhhhhHHj..
            ..jhhhhhhHHj..
            ...jhhhhHHj...
            ....jjjjjj....
            """),
        // 4 bun: pulled up, ears and nape bare
        PixelMap("""
            .....jjjj.....
            ....jhhhHj....
            ....jjjjjj....
            ..jjhhhhhhjj..
            .jhhhhhhhhhHj.
            jhhhhjhhhhhHHj
            jhhhjhhhhjhHHj
            jhhjhhhhhhjHHj
            qjhhhhhhhhHHjq
            qsjhhhhhhhHjSq
            .qShhhhhhhHSq.
            .qsSSSSSSSSSq.
            """),
        // 5 buzz cut: close to the skull, a grain of short strokes, a soft hairline over a bare nape, the ears
        PixelMap("""
            ..............
            ..............
            ....jjjjjj....
            ..jjhhhhhhjj..
            .jhhhhhhhhhHj.
            .jhhhhhjhhHHj.
            .jhhhhjhhhHHj.
            .jhhhhhhhjHHj.
            qjhhhhhhjhHHjq
            qsjhhhhhhhHjSq
            .qShhhhhhhHSq.
            .qsSSSSSSSSSq.
            """),
    ]

    // MARK: Accessories (14 wide, same origin as the hair)

    /// The accessory index of the beanie, which hides the hair rising above the head.
    static let beanieKind = 3

    /// 1 glasses, 2 headphones, 3 beanie; nil for none.
    static func accessory(_ kind: Int, _ view: View) -> PixelMap? {
        switch (CharacterPalette.clamp(kind, CharacterPalette.accessoryCount), view) {
        case (1, .front): return glassesFront
        case (1, .back): return glassesBack
        case (2, _): return headphones
        case (3, _): return beanie
        default: return nil
        }
    }

    static let glassesFront = PixelMap("""
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        ..aaaaaaaaA...
        .....a.aa.A...
        """)

    static let glassesBack = PixelMap("""
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        ..............
        aa..........AA
        """)

    static let headphones = PixelMap("""
        ..............
        ....aaaaAA....
        ..aa......AA..
        .a..........A.
        .a..........A.
        a............A
        a............A
        aa..........AA
        aa..........AA
        aA..........AA
        aA..........AA
        .A..........A.
        """)

    static let beanie = PixelMap("""
        ..............
        ....AAAAAA....
        ..AAaaaaaaAA..
        .AaaaaaaaaaAA.
        AaaaaaaaaaaAAA
        AAAAAAAAAAAAAA
        AaaaaaaaaaaAAA
        AAAAAAAAAAAAAA
        """)

    // MARK: Torso (12×15, at the torso origin)

    static func torso(_ view: View) -> PixelMap { view == .front ? torsoFront : torsoBack }

    static let torsoFront = PixelMap("""
        ....qSSq....
        ..uutSSTuu..
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .utttttTTTu.
        .uTTTTTTTTu.
        .uuuuuuuuuu.
        """)

    /// Bent over the desk (sleep), at `CharacterPoses.leanTorsoFront` / `leanTorsoBack`.
    static func torsoLean(_ view: View) -> PixelMap { view == .front ? torsoFrontLean : torsoBackLean }

    /// From the front the leaning torso is foreshortened: shorter, shifted toward the desk, mostly hidden by the head.
    static let torsoFrontLean = PixelMap("""
        ..uuuuuuuu..
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .utttttTTTu.
        .uTTTTTTTTu.
        .uuuuuuuuuu.
        """)

    /// From the back: hips on the seat, the back rounded and leaning up-right toward the desk, wider at the
    /// shoulders; no neck (the head, lower than the shoulders, only shows its crown and its right side).
    static let torsoBackLean = PixelMap("""
        .....uuuuuuuu....
        ...uutttttttTTu..
        ..uttttttttttTTu.
        .uttttttttttttTTu
        .uttttttttttttTTu
        .utttttttttttTTu.
        .utttttttttttTTu.
        .uttttttttttTTu..
        .uttttttttttTTu..
        .utttttttttTTu...
        .utttttttttTTu...
        .uttttttttTTu....
        .uttttttttTTu....
        .utttttttTTu.....
        .uttttttTTTu.....
        .uTTTTTTTTu......
        .uuuuuuuuuu......
        """)

    static let torsoBack = PixelMap("""
        ....qSSq....
        ..uuttttuu..
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .uttttttTTu.
        .utttttTTTu.
        .uTTTTTTTTu.
        .uuuuuuuuuu.
        """)

    // MARK: Legs (absolute: the feet define the floor, y 53 when standing)

    static func legs(_ legs: Legs, _ view: View) -> Placed {
        switch (legs, view) {
        case (.stand, _): return Placed(map: legsStand, dx: 11, dy: 33)
        case (.stride, _): return Placed(map: legsStride, dx: 9, dy: 33)
        case (.passLeftDown, _): return Placed(map: legsPassLeftDown, dx: 11, dy: 32)
        case (.passRightDown, _): return Placed(map: legsPassRightDown, dx: 11, dy: 32)
        case (.crouch, _): return Placed(map: legsCrouch, dx: 10, dy: 35)
        case (.seated, .front): return Placed(map: legsSeatedFront, dx: 10, dy: 35)
        case (.seated, .back): return Placed(map: legsSeatedBack, dx: 10, dy: 35)
        }
    }

    static let legsStand = PixelMap("""
        opppppppbo.
        opppppppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        obbbooobbbo
        obbbooobbbo
        oooooooooo.
        o555oo5555o
        o555oo5555o
        ooooooooooo
        """)

    static let legsStride = PixelMap("""
        ..opppppppbo...
        ..opppppppbo...
        ..oppbooppbo...
        ..oppbooppbo...
        ..oppbooppbo...
        ..oppbooppbo...
        ..oppbo.oppbo..
        ..oppbo.oppbo..
        .oppbo..oppbo..
        .oppbo..oppbo..
        .oppbo...oppbo.
        .oppbo...oppbo.
        oppbo....oppbo.
        oppbo....oppbo.
        oppbo....oppbo.
        obbbo....obbbo.
        obbbo....obbbo.
        ooooo....ooooo.
        o555o....o5555o
        o555o....o5555o
        ooooo....oooooo
        """)

    static let legsPassLeftDown = PixelMap("""
        opppppppbo.
        opppppppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        obbbooobbbo
        obbbooobbbo
        oppboo5555o
        oppboo5555o
        oooooooooo.
        o555o......
        o555o......
        ooooo......
        """)

    static let legsPassRightDown = PixelMap("""
        opppppppbo.
        opppppppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        oppbooppbo.
        obbbooobbbo
        obbbooobbbo
        o555ooppbo.
        o555ooppbo.
        ooooooooooo
        .....o5555o
        .....o5555o
        .....oooooo
        """)

    static let legsCrouch = PixelMap("""
        .opppppppbo..
        .oppppppppbo.
        .opppppppppbo
        ..oppbooppbbo
        ...oppbooppbo
        ...oppbooppbo
        ..oppbooppbo.
        ..oppbooppbo.
        ..oppbooppbo.
        ..oppbooppbo.
        ..oppbooppbo.
        ..oppbooppbo.
        .oppbooppbo..
        .oppbooppbo..
        .obbbooobbbo.
        .ooooooooooo.
        .o555oo5555o.
        .o555oo5555o.
        .ooooooooooo.
        """)
    /// Seated toward SE: the thighs come toward the viewer (2:1 lower edge), the shins drop to the floor.
    static let legsSeatedFront = PixelMap("""
        .oppppppppbo.....
        .opppppppppbo....
        .oppppppppppbo...
        .ooppppppppppbo..
        ...oopppppppppbo.
        .....oopppppppbo.
        .......oppboppbo.
        .......oppboppbo.
        .......oppboppbo.
        .......oppboppbo.
        .......oppboppbo.
        .......oppboppbo.
        .......oppboppbo.
        .......obbbobbbo.
        .......obbbobbbo.
        .......ooooooooo.
        .......o555o5555o
        .......o555o5555o
        .......oooooooooo
        """)

    /// Seated toward NE: the lap is hidden by the back, the lower legs show under the seat.
    static let legsSeatedBack = PixelMap("""
        .oppppppppbo....
        .opppppppppbo...
        .opppppppppbo...
        ..obbbbbbbbbo...
        ....oppboppbo...
        ....oppboppbo...
        ....oppboppbo...
        ....oppboppbo...
        ....oppboppbo...
        ....oppboppbo...
        ....oppboppbo...
        ....oppboppbo...
        ....oppboppbo...
        ....obbbobbbo...
        ....obbbobbbo...
        ....ooooooooo...
        ....o555o555o...
        ....o555o555o...
        ....ooooooooo...
        """)

    // MARK: Arms

    /// The layers of one gesture, relative to the torso origin. Standing arms hang from the shoulders; seated
    /// gestures are authored at their seated position (left arm and right arm as separate pieces).
    static func arms(_ arms: Arms, _ view: View) -> [Placed] {
        switch (arms, view) {
        case (.rest, _): return [Placed(map: armsRest, dx: -2, dy: 1)]
        case (.swingIn, _): return [Placed(map: armsSwingIn, dx: -2, dy: 1)]
        case (.swingOut, _): return [Placed(map: armsSwingOut, dx: -3, dy: 1)]
        case (.crouch, .front): return [Placed(map: armsCrouchFront, dx: -2, dy: 1)]
        case (.crouch, .back): return [Placed(map: armsCrouchBack, dx: -2, dy: 1)]

        case (.lap, .front): return [lapLeft, lapRight]
        case (.typeLeft, .front): return [typeLeftUp, typeRightDown]
        case (.typeRight, .front): return [typeLeftDown, typeRightUp]
        case (.typeDown, .front): return [typeLeftDown, typeRightDown]
        case (.chin, .front): return [chinLeft, lapRight]
        case (.cough, .front): return [coughLeft, lapRight]
        case (.mugLow, .front): return [lapLeft, mugLowRight]
        case (.mugHigh, .front): return [lapLeft, mugHighRight]
        case (.reach, .front): return [lapLeft, reachRight]
        case (.hold, .front): return [lapLeft, holdRight]

        case (.lap, .back), (.mugLow, .back): return [lapBackLeft, lapBackRight]
        case (.typeLeft, .back): return [typeBackLeftUp, lapBackRight]
        case (.typeRight, .back): return [lapBackLeft, typeBackRightUp]
        case (.typeDown, .back): return [lapBackLeft, lapBackRight]
        case (.chin, .back), (.cough, .back): return [elbowBackLeft, lapBackRight]
        case (.mugHigh, .back), (.hold, .back): return [lapBackLeft, elbowBackRight]
        case (.reach, .back): return [lapBackLeft, reachBackRight]

        case (.fold, .front): return [foldFront]
        case (.fold, .back): return [foldBackLeft, foldBackRight]

        case (.stretchHalf, _): return [goalLeft, goalRight]
        case (.stretchUp, _): return [upLeft, upRight]
        case (.raise, _): return [lapLeft, upRight]
        case (.raiseTilt, _): return [lapLeft, raiseTiltRight]
        case (.cheer, _): return [cheerLeft, cheerRight]
        case (.cheerWide, _): return [wideLeft, wideRight]
        case (.stick, _): return [view == .front ? lapLeft : lapBackLeft, stickRight]
        case (.waveLeft, _): return [view == .front ? lapLeft : lapBackLeft, waveRightUp]
        case (.waveRight, _): return [view == .front ? lapLeft : lapBackLeft, waveRightOut]
        }
    }

    /// Arms drawn after the head: a hand in front of the face, or arms raised beside it. From the back, a hand
    /// at the face is hidden by the head, so only raised arms come last.
    static func armsOverHead(_ arms: Arms, _ view: View) -> Bool {
        switch arms {
        case .mugHigh, .chin, .cough:
            return view == .front
        case .stretchHalf, .stretchUp, .raise, .raiseTilt, .cheer, .cheerWide, .stick, .waveLeft, .waveRight, .reach:
            return true
        case .rest, .swingIn, .swingOut, .crouch, .lap, .typeLeft, .typeRight, .typeDown, .mugLow, .hold, .fold:
            return false
        }
    }

    /// A seated piece whose top-left is (x, y) in frame pixels when the torso sits at `CharacterPoses.seatTorso`.
    private static func seat(_ x: Int, _ y: Int, _ ascii: String) -> Placed {
        Placed(map: PixelMap(ascii), dx: x - CharacterPoses.seatTorso.x, dy: y - CharacterPoses.seatTorso.y)
    }

    /// A leaning piece whose top-left is (x, y) in frame pixels when the torso sits at the lean origin of `view`.
    private static func lean(_ view: View, _ x: Int, _ y: Int, _ ascii: String) -> Placed {
        let origin = view == .front ? CharacterPoses.leanTorsoFront : CharacterPoses.leanTorsoBack
        return Placed(map: PixelMap(ascii), dx: x - origin.x, dy: y - origin.y)
    }

    // Standing (relative to the torso origin).

    static let armsRest = PixelMap("""
        .uuu........uuu.
        uttu........utTu
        uttu........utTu
        utTu........utTu
        utTu........utTu
        utTu........utTu
        utTu........utTu
        utTu........utTu
        utTu........utTu
        uuuu........uuuu
        qssq........qsSq
        qsSq........qsSq
        .qq..........qq.
        """)

    static let armsSwingIn = PixelMap("""
        .uuu........uuu.
        uttu........utTu
        uttu........utTu
        utTu........utTu
        utTu........utTu
        .utTu......utTu.
        .utTu......utTu.
        .utTu......utTu.
        .uuuu......uuuu.
        .qssq......qsSq.
        .qsSq......qsSq.
        ..qq........qq..
        """)

    static let armsSwingOut = PixelMap("""
        ..uuu........uuu..
        .uttu........utTu.
        .uttu........utTu.
        .utTu........utTu.
        .utTu........utTu.
        utTu..........utTu
        utTu..........utTu
        utTu..........utTu
        uuuu..........uuuu
        qssq..........qsSq
        qsSq..........qsSq
        .qq............qq.
        """)

    static let armsCrouchFront = PixelMap("""
        .uuu........uuu....
        uttu........utTu...
        uttu........utTu...
        utTu........utTu...
        utTu........utTTu..
        uttTu.......uttTTu.
        .uttTu.......uttTu.
        ..uuuu........uuuu.
        ..qssq........qsSq.
        ..qsSq........qsSq.
        ...qq..........qq..
        """)

    static let armsCrouchBack = PixelMap("""
        .uuu........uuu.
        uttu........utTu
        uttu........utTu
        utTu........utTu
        utTu........utTu
        utTu........utTu
        uttu........utTu
        uuuu........uuuu
        """)

    // Seated, toward SE: left arm (screen left) and right arm pieces.

    static let lapLeft = seat(8, 23, """
        .uuu...
        uttu...
        uttu...
        utTu...
        utTu...
        utTu...
        utTu...
        uttTu..
        .uttTu.
        ..uttTu
        ...uuuu
        ...qssq
        ...qsSq
        ....qq.
        """)

    static let lapRight = seat(20, 23, """
        uuu....
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        uttTu..
        .uttTu.
        ..uttTu
        ...uuuu
        ...qsSq
        ...qsSq
        ....qq.
        """)

    static let typeLeftUp = seat(8, 23, """
        .uuu.....
        uttu.....
        uttu.....
        utTu.....
        utTu.....
        uttTu....
        .uttTuu..
        ..uuuqsq.
        .....qsSq
        ......qq.
        """)

    static let typeLeftDown = seat(8, 23, """
        .uuu.....
        uttu.....
        uttu.....
        utTu.....
        utTu.....
        utTu.....
        uttTu....
        .uttTuu..
        ..uuuqsq.
        .....qsSq
        ......qq.
        """)

    static let typeRightUp = seat(20, 23, """
        uuu......
        utTu.....
        utTu.....
        utTu.....
        utTu.....
        uttTu....
        .uttTuu..
        ..uuuqsq.
        .....qsSq
        ......qq.
        """)

    static let typeRightDown = seat(20, 23, """
        uuu......
        utTu.....
        utTu.....
        utTu.....
        utTu.....
        utTu.....
        uttTu....
        .uttTuu..
        ..uuuqsq.
        .....qsSq
        ......qq.
        """)

    /// Hand under the chin (think).
    static let chinLeft = seat(8, 20, """
        ......qqq.
        .....qsssq
        .....qsSSq
        .uuu.uuuu.
        uttu.utTu.
        uttu.utTu.
        utTu.utTu.
        utTuutTu..
        utTuttTu..
        uttTtTu...
        uttttu....
        .uuuu.....
        """)

    /// Fist in front of the mouth (cough).
    static let coughLeft = seat(8, 18, """
        ......qqq.
        .....qsssq
        .....qsSSq
        .....uuuu.
        .....utTu.
        .uuu.utTu.
        uttu.utTu.
        uttu.utTu.
        utTu.utTu.
        utTuutTu..
        utTuttTu..
        uttTtTu...
        uttttu....
        .uuuu.....
        """)

    /// Mug held at the chest (coffee).
    static let mugLowRight = seat(14, 23, """
        ......uuu.
        ......utTu
        .oooo.utTu
        .o66o.utTu
        .o66oqqtTu
        .o66qssqTu
        .oooqsSqTu
        ....uqqutu
        .....uttTu
        ......uuuu
        """)

    /// Mug at the mouth (coffee).
    static let mugHighRight = seat(15, 17, """
        .oooo......
        .o66o......
        .o66oqq....
        .o66qssq...
        .oooqsSq...
        ....uqqtu..
        .....uttTu.
        .....utTTu.
        ......utTu.
        ......utTTu
        ......uttTu
        .......uuuu
        """)

    /// Arm stretched forward to take a sticky note (grab).
    static let reachRight = seat(20, 23, """
        uuu.........
        utTu........
        utTuuuuu.qq.
        uttttttTqssq
        .uuuuuuuqsSq
        ........qsSq
        .........qq.
        """)

    /// Sticky note held in front of the chest (grab).
    static let holdRight = seat(13, 23, """
        .......uuu.
        .......utTu
        .ooooo.utTu
        .o666o.utTu
        .o666oqqtTu
        .o666qssqTu
        .oooooqsSqu
        .....uqqutu
        ......uttTu
        .......uuuu
        """)

    /// Sticky note raised toward the screen (grab).
    static let stickRight = seat(20, 9, """
        .....ooooo.
        .....o666o.
        .....o666o.
        .....qsSqo.
        ....uqsSq..
        ....utTu...
        ....utTu...
        ...utTu....
        ...utTu....
        ..utTu.....
        ..utTu.....
        .utTu......
        .utTu......
        utTu.......
        utTu.......
        utTu.......
        """)

    // Raised arms: outside the head (x 9…22), drawn after it.

    /// Elbows out at the shoulders, forearms up (stretch, first and fifth frames).
    static let goalLeft = seat(3, 13, """
        .qq......
        qssq.....
        qsSq.....
        uuuu.....
        utTu.....
        utTu.....
        utTu.....
        utTu.....
        utTu.....
        utTu.....
        uttuuuuuu
        utttttttu
        uuuuuuuuu
        """)

    static let goalRight = seat(19, 13, """
        .....qq.
        ....qsSq
        ....qsSq
        ....uuuu
        ....utTu
        ....utTu
        ....utTu
        ....utTu
        ....utTu
        ....utTu
        uuuuutTu
        utttttTu
        uuuuuuuu
        """)

    /// Arm straight up beside the head (stretch; raiseHand on the right).
    static let upLeft = seat(5, 2, """
        .qq....
        qssq...
        qsSq...
        uuuu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        utTu...
        .utTu..
        ..utTu.
        ...utTu
        ...uttu
        """)

    static let upRight = seat(20, 2, """
        ....qq.
        ...qsSq
        ...qsSq
        ...uuuu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ...utTu
        ..utTu.
        .utTu..
        utTu...
        utTu...
        """)

    /// Raised hand leaning outward (raiseHand, second beat).
    static let raiseTiltRight = seat(20, 2, """
        .....qq.
        ....qsSq
        ....qsSq
        ....uuuu
        ....utTu
        ....utTu
        ....utTu
        ....utTu
        ....utTu
        ....utTu
        ...utTu.
        ...utTu.
        ...utTu.
        ...utTu.
        ...utTu.
        ...utTu.
        ...utTu.
        ...utTu.
        ...utTu.
        ..utTu..
        .utTu...
        utTu....
        utTu....
        """)

    /// Arms up in a V (celebrate).
    static let cheerLeft = seat(3, 3, """
        .qq......
        qssq.....
        qsSq.....
        uuuu.....
        utTu.....
        utTu.....
        .utTu....
        .utTu....
        .utTu....
        ..utTu...
        ..utTu...
        ..utTu...
        ...utTu..
        ...utTu..
        ...utTu..
        ....utTu.
        ....utTu.
        ....utTu.
        .....utTu
        .....utTu
        .....utTu
        .....uttu
        """)

    static let cheerRight = seat(20, 3, """
        ......qq.
        .....qsSq
        .....qsSq
        .....uuuu
        .....utTu
        .....utTu
        ....utTu.
        ....utTu.
        ....utTu.
        ...utTu..
        ...utTu..
        ...utTu..
        ..utTu...
        ..utTu...
        ..utTu...
        .utTu....
        .utTu....
        .utTu....
        utTu.....
        utTu.....
        utTu.....
        utTu.....
        """)

    /// Arms flung wide (celebrate).
    static let wideLeft = seat(0, 13, """
        .qq.........
        qssq........
        qsSq........
        uuuu........
        .utTu.......
        ..utTu......
        ...utTu.....
        ....utTu....
        .....utTu...
        ......utTu..
        .......utTu.
        ........utTu
        """)

    static let wideRight = seat(20, 13, """
        .........qq.
        ........qsSq
        ........qsSq
        ........uuuu
        .......utTu.
        ......utTu..
        .....utTu...
        ....utTu....
        ...utTu.....
        ..utTu......
        .utTu.......
        utTu........
        """)

    /// Forearm up, hand open beside the head (wave), then leaning out.
    static let waveRightUp = seat(19, 10, """
        ......qq.
        .....qsSq
        .....qsSq
        .....uuuu
        .....utTu
        .....utTu
        .....utTu
        .....utTu
        .....utTu
        .....utTu
        .....utTu
        .....utTu
        .....utTu
        uuuuuutTu
        uttttttTu
        uuuuuuuuu
        """)

    static let waveRightOut = seat(19, 10, """
        .........qq.
        ........qsSq
        ........qsSq
        ........uuuu
        ........utTu
        .......utTu.
        .......utTu.
        ......utTu..
        ......utTu..
        .....utTu...
        .....utTu...
        .....utTu...
        .....utTu...
        uuuuuutTu...
        uttttttTu...
        uuuuuuuuu...
        """)

    /// Asleep toward SE: the left upper arm comes down to the forearms folded on the desk, a band under the chin
    /// (the head, drawn after, lies on it; the right arm is behind the head).
    static let foldFront = lean(.front, 11, 27, """
        .uuu.................
        uttu.................
        uttu.................
        utTu.................
        utTu.................
        uttTu................
        .uutuuuuuuuuuuuuuuuu.
        uttttttttttttttttttTu
        uTTTTTTTTTTTTTTTTTTTu
        .uuuuuuuuuuuuuuuuuuu.
        """)

    /// Asleep toward NE: the arms are folded on the desk, beyond the back; only the elbows stick out on both sides.
    static let foldBackLeft = lean(.back, 8, 22, """
        .uuu.
        uttTu
        uttTu
        .uuu.
        """)

    static let foldBackRight = lean(.back, 26, 21, """
        .uuu.
        uttTu
        uttTu
        uuuu.
        """)

    // Seated, toward NE: from behind the forearms are hidden by the body.

    static let lapBackLeft = seat(8, 23, """
        .uuu
        uttu
        uttu
        utTu
        utTu
        utTu
        utTu
        uttu
        .uuu
        """)

    static let lapBackRight = seat(20, 23, """
        uuu.
        utTu
        utTu
        utTu
        utTu
        utTu
        utTu
        uttu
        uuu.
        """)

    static let typeBackLeftUp = seat(8, 23, """
        .uuu
        uttu
        uttu
        utTu
        utTu
        uttu
        .uuu
        """)

    static let typeBackRightUp = seat(20, 23, """
        uuu.
        utTu
        utTu
        utTu
        utTu
        uttu
        uuu.
        """)

    /// Elbow raised and out, the hand at the face hidden by the head (think, cough).
    static let elbowBackLeft = seat(6, 23, """
        ...uuu
        ..uttu
        .uttTu
        uttTu.
        utTu..
        uttu..
        .uuu..
        """)

    /// Right elbow raised and out (coffee at the mouth, sticky note held up front).
    static let elbowBackRight = seat(20, 23, """
        uuu...
        utTu..
        uttTu.
        .utTTu
        ..utTu
        ..uttu
        ..uuu.
        """)

    /// Arm stretched forward (up-right from behind) to take a sticky note.
    static let reachBackRight = seat(20, 17, """
        .......qq.
        ......qssq
        ......qsSq
        ......uuuu
        .....utTu.
        ....utTu..
        ..uutTu...
        .utttTu...
        .utTTu....
        .uttu.....
        .uuu......
        """)
}
