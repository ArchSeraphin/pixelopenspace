import Foundation

/// The rules of 7.1 to 7.3 that every generated sprite follows. Each sprite test asserts an empty list.
public enum SpriteLint {
    /// At most 12 colours per frame, ink and the declared material outlines left out (7.1).
    public static let colorCap = 12

    /// Empty when the sprite follows 7.1 to 7.3: frames non-empty and of equal size; holds empty for one frame,
    /// else one allowed hold per frame; anchor inside [0, w] × [0, h]; alpha 0 or 255 only; opaque colours in
    /// Palette.spriteColors, never a key colour; alertYellow only for Palette.alertYellowSprites; at most 12 colours
    /// per frame once ink and outlineColors are left out; mean luma of lightProbe.left > lightProbe.right on frame 0.
    /// Every message starts with the sprite name (and "#frame" for a frame rule).
    public static func issues(_ def: SpriteDef) -> [String] {
        let name = def.key.name
        guard let first = def.frames.first else { return ["\(name): no frame"] }
        var out: [String] = []
        let (w, h) = (first.width, first.height)
        if w == 0 || h == 0 { out.append("\(name): empty frame size \(w)×\(h)") }
        for (index, frame) in def.frames.enumerated() where frame.width != w || frame.height != h {
            out.append("\(name)#\(index): size \(frame.width)×\(frame.height) differs from frame 0 (\(w)×\(h))")
        }
        out += holdIssues(def, name: name)
        if def.anchor.x < 0 || def.anchor.x > w || def.anchor.y < 0 || def.anchor.y > h {
            out.append("\(name): anchor (\(def.anchor.x), \(def.anchor.y)) outside [0, \(w)] × [0, \(h)]")
        }
        let yellowAllowed = Palette.allowsAlertYellow(def.key)
        for (index, frame) in def.frames.enumerated() {
            out += frameIssues(frame, label: "\(name)#\(index)", yellowAllowed: yellowAllowed, outlines: def.outlineColors)
        }
        if let probe = def.lightProbe {
            let left = first.meanLuma(in: probe.left), right = first.meanLuma(in: probe.right)
            if let left, let right {
                if !(left > right) {
                    out.append("\(name): light probe: left face (luma \(Int(left))) is not lighter than right face (luma \(Int(right)))")
                }
            } else {
                out.append("\(name): light probe samples no opaque pixel on frame 0")
            }
        }
        return out
    }

    private static func holdIssues(_ def: SpriteDef, name: String) -> [String] {
        if def.frames.count == 1 {
            return def.holds.isEmpty ? [] : ["\(name): holds must be empty for a single frame, got \(def.holds)"]
        }
        if def.holds.count != def.frames.count {
            return ["\(name): \(def.holds.count) holds for \(def.frames.count) frames"]
        }
        let allowed = AnimationClock.allowedHolds.sorted().map(String.init).joined(separator: ", ")
        return def.holds.enumerated().compactMap { index, hold in
            AnimationClock.allowedHolds.contains(hold) ? nil
                : "\(name): holds[\(index)] = \(hold) ticks is not an allowed cadence (\(allowed))"
        }
    }

    private static func frameIssues(_ frame: PixelImage, label: String, yellowAllowed: Bool,
                                    outlines: Set<RGBA8>) -> [String] {
        var out: [String] = []
        var colors = Set<RGBA8>()
        var translucent: (x: Int, y: Int, a: UInt8)?
        var translucentCount = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let p = frame[x, y]
                if p.a == 0 { continue }
                if p.a != 255 {
                    if translucent == nil { translucent = (x, y, p.a) }
                    translucentCount += 1
                    continue
                }
                colors.insert(p)
            }
        }
        if let t = translucent {
            out.append("\(label): \(translucentCount) pixel(s) with an alpha other than 0 or 255, first at (\(t.x), \(t.y)): \(t.a)")
        }
        let sorted = colors.sorted()
        let keys = sorted.filter { Palette.keyColors.contains($0) }
        if !keys.isEmpty {
            out.append("\(label): key colour \(keys.map(\.hexString).joined(separator: ", ")) in a generated sprite")
        }
        let offPalette = sorted.filter { !Palette.spriteColors.contains($0) && !Palette.keyColors.contains($0) }
        if !offPalette.isEmpty {
            let shown = offPalette.prefix(4).map(\.hexString).joined(separator: ", ")
            out.append("\(label): \(offPalette.count) off-palette colour(s): \(shown)\(offPalette.count > 4 ? ", …" : "")")
        }
        if !yellowAllowed && colors.contains(Palette.color(.alertYellow)) {
            out.append("\(label): alertYellow is reserved to the waiting sprites (Palette.alertYellowSprites)")
        }
        let counted = colors.subtracting(outlines).subtracting([Palette.color(.ink)]).count
        if counted > colorCap {
            out.append("\(label): \(counted) colours, at most \(colorCap) once ink and outline colours are left out")
        }
        return out
    }
}
