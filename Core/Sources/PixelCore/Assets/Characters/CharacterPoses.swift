import Foundation

/// Every frame of the 14 animations of 7.4.4, toward SE (front) and NE (back), as parts posed at integer offsets:
/// legs on the floor, then torso, arms, head, hair and accessory. Head bobs and alternating hands are offsets and
/// arm layers; nothing is interpolated.
enum CharacterPoses {
    typealias Arms = CharacterParts.Arms
    typealias Legs = CharacterParts.Legs
    typealias Eyes = CharacterParts.Eyes

    struct Pose: Sendable {
        var legs: Legs
        /// Top-left of the torso map (12×14).
        var torso: PixelPoint
        /// Top-left of the head map (14×14); hair and accessory sit 2 px above.
        var head: PixelPoint
        var eyes: Eyes
        var arms: Arms
        /// Bent over the desk (sleep): `CharacterParts.torsoLean`, and from the back the head, lower than the
        /// shoulders, is drawn before them.
        var lean = false
    }

    /// Standing: feet on y 53, head from y 5 (49 px, 3.5 heads of 14 px).
    static let standTorso = PixelPoint(10, 19), standHead = PixelPoint(9, 5)
    /// Seated on the chair of 7.3 (seat 16 px above the floor, y 37): the upper body is 3 px lower.
    static let seatTorso = PixelPoint(10, 22), seatHead = PixelPoint(9, 8)

    static func standing(_ arms: Arms, legs: Legs = .stand, dy: Int = 0, headDY: Int = 0) -> Pose {
        Pose(legs: legs, torso: PixelPoint(standTorso.x, standTorso.y + dy),
             head: PixelPoint(standHead.x, standHead.y + dy + headDY), eyes: .open, arms: arms)
    }

    static func seated(_ arms: Arms, dy: Int = 0, headDY: Int = 0, eyes: Eyes = .open) -> Pose {
        Pose(legs: .seated, torso: PixelPoint(seatTorso.x, seatTorso.y + dy),
             head: PixelPoint(seatHead.x, seatHead.y + dy + headDY), eyes: eyes, arms: arms)
    }

    /// Slumped over the desk (sleep, "avachi" of 7.9): the hips stay on the seat, the torso leans toward the desk
    /// (+x in both drawn views: down-right toward SE, up-right toward NE), the head lies on the folded arms. The desk
    /// edge in front of a seat is at the right edge of the frame, at y 37 toward SE and y 21 toward NE (7.3: seat
    /// 16 px, desk 24 px, half a tile away). From the front the head drops 13 px and moves 8 px toward the desk;
    /// from the back it moves 7 px toward the desk and 5 px down, its crown showing beyond the hunched shoulders.
    static let leanTorsoFront = PixelPoint(12, 27), leanHeadFront = PixelPoint(17, 21)
    static let leanTorsoBack = PixelPoint(10, 19), leanHeadBack = PixelPoint(16, 13)

    /// `breath` lifts the back (and the elbows with it) by that many pixels; the head stays on the arms.
    static func slumped(_ view: CharacterParts.View, breath: Int = 0) -> Pose {
        let torso = view == .front ? leanTorsoFront : leanTorsoBack
        return Pose(legs: .seated, torso: PixelPoint(torso.x, torso.y - breath),
                    head: view == .front ? leanHeadFront : leanHeadBack, eyes: .closed, arms: .fold, lean: true)
    }

    /// The frames of `animation` toward one drawn direction; empty for raiseHand from the back.
    static func frames(_ animation: CharacterAnimation, _ view: CharacterParts.View) -> [Pose] {
        switch animation {
        case .stand:
            return [standing(.rest), standing(.rest, headDY: 1)]
        case .walk:
            return [standing(.swingIn, legs: .stride), standing(.rest, legs: .passLeftDown, dy: -1),
                    standing(.swingOut, legs: .stride), standing(.rest, legs: .passRightDown, dy: -1)]
        case .sitDown:
            let crouch = Pose(legs: .crouch, torso: PixelPoint(seatTorso.x, seatTorso.y - 1),
                              head: PixelPoint(seatHead.x, seatHead.y - 1), eyes: .open, arms: .crouch)
            return [crouch, seated(.lap)]
        case .sitIdle:
            return [seated(.lap), seated(.lap, headDY: 1)]
        case .type:
            return [seated(.typeLeft), seated(.typeDown), seated(.typeRight), seated(.typeDown)]
        case .think:
            return [seated(.chin, eyes: .up), seated(.chin, headDY: 1, eyes: .up)]
        case .stretch:
            return [seated(.stretchHalf), seated(.stretchUp), seated(.stretchUp, dy: -1), seated(.stretchUp),
                    seated(.stretchHalf), seated(.lap)]
        case .coffee:
            return [seated(.mugLow), seated(.mugHigh), seated(.mugHigh, headDY: -1), seated(.mugLow)]
        case .sleep:
            return [slumped(view), slumped(view, breath: 1)]
        case .raiseHand:
            guard view == .front else { return [] }
            return [seated(.raise), seated(.raiseTilt), seated(.raise, headDY: 1), seated(.raiseTilt, headDY: 1)]
        case .celebrate:
            return [seated(.cheer), seated(.cheer, dy: -1), seated(.cheerWide), seated(.cheer, dy: -1),
                    seated(.cheerWide), seated(.lap)]
        case .grab:
            return [seated(.reach), seated(.hold), seated(.stick), seated(.lap)]
        case .cough:
            return [seated(.cough), seated(.cough, dy: 1), seated(.cough), seated(.cough, headDY: 1)]
        case .wave:
            return [seated(.waveLeft), seated(.waveRight)]
        }
    }
}
