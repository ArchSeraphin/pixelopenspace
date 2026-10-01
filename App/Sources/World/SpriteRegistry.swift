import Foundation
import PixelCore
import SpriteKit

/// One sprite of a character's sheet, as the plan names it (`SceneSprite.character`).
struct CharacterRef: Hashable, Sendable {
    var look: AgentLook
    var hue: Int
    var animation: CharacterAnimation
    var facing: Facing
}

/// The textures of the scene (3.10, 7.6): the core's atlas (`AtlasPacker.pack(SpriteCatalog.all)`, built once), the
/// characters' frames composed off the main actor and packed into dynamic pages, and the composed images of the
/// plan (signs, name plates), cached by fingerprint. Every texture is sampled to the nearest texel, and its
/// transparent pixels are (0, 0, 0, 0): SpriteKit takes texture data as premultiplied.
///
/// Characters: only the (look, hue, animation, facing) the plan shows are composed, with `CharacterSprites.canvas`
/// and `SlotCanvas.render`, exactly as the software compositor composes them; a whole `CharacterSprites.sheet` (184
/// frames) for each look would cost tens of times more for frames the scene may never show.
@MainActor
final class SpriteRegistry {
    /// Largest side of a page of character frames (36 × 60 px cells: 14 × 8 frames); a small batch takes the
    /// smallest page that holds it (128 px: 6 frames, 256 px: 28).
    static let characterPageSize = 512
    /// Composed images kept at most (oldest first out).
    static let composedLimit = 512

    /// The catalog packed once for the whole app (the first access packs it, about half a second in Debug).
    nonisolated static let atlas: Atlas = AtlasPacker.pack(SpriteCatalog.all)

    private let atlas: Atlas
    private let pages: [SKTexture]
    private var frames: [String: SKTexture] = [:]
    private var characters: [CharacterRef: [SKTexture]] = [:]
    private var characterPages = 0
    private var composed: [String: SKTexture] = [:]
    private var composedOrder: [String] = []
    /// Characters being composed off the main actor, so that two plans do not compose the same ones.
    private var pendingCharacters: Set<CharacterRef> = []

    init() {
        atlas = Self.atlas
        pages = atlas.pages.map { Self.makeTexture($0) }
    }

    // MARK: Catalog sprites

    func texture(_ key: SpriteKey, frame: Int) -> SKTexture? {
        let name = key.frameName(frame)
        if let cached = frames[name] { return cached }
        guard let entry = atlas.entries[name], pages.indices.contains(entry.page) else { return nil }
        let texture = Self.subTexture(entry.rect, in: pages[entry.page], pageSize: atlas.pageSize)
        frames[name] = texture
        return texture
    }

    /// The frame a still scene shows at `tick` (24 per second), as `SpriteDef.frameIndex(atTick:)`.
    func frameIndex(_ key: SpriteKey, atTick tick: Int) -> Int {
        SpriteCatalog.sprite(key)?.frameIndex(atTick: tick) ?? 0
    }

    /// Frames and holds at 24 ticks/s (setTexture + wait, décision 17), starting at `tickOffset` and repeated when
    /// the sprite loops; nil for one frame.
    func action(_ key: SpriteKey, tickOffset: Int) -> SKAction? {
        guard let animation = atlas.animations[key.name] else { return nil }
        let textures = animation.frames.indices.compactMap { texture(key, frame: $0) }
        guard textures.count == animation.frames.count else { return nil }
        return Self.animationAction(textures, holds: animation.holds, loops: animation.loops, tickOffset: tickOffset)
    }

    // MARK: Characters

    /// Composes the characters missing from the registry off the main actor, then packs them into a new page.
    func prepare(characters refs: Set<CharacterRef>) async {
        let missing = refs.filter { characters[$0] == nil && !pendingCharacters.contains($0) }
        guard !missing.isEmpty else { return }
        pendingCharacters.formUnion(missing)
        let ordered = Self.sorted(missing)
        let composed = await Task.detached(priority: .userInitiated) {
            ordered.map { ($0, Self.composeFrames($0)) }
        }.value
        pendingCharacters.subtract(missing)
        store(composed.filter { characters[$0.0] == nil })
    }

    /// The same, at once on the main actor (the snapshot harness, or a plan applied before `prepare` finished).
    func prepareNow(characters refs: Set<CharacterRef>) {
        let missing = refs.filter { characters[$0] == nil }
        guard !missing.isEmpty else { return }
        store(Self.sorted(missing).map { ($0, Self.composeFrames($0)) })
    }

    func hasCharacter(_ ref: CharacterRef) -> Bool {
        characters[ref] != nil
    }

    func characterTexture(_ ref: CharacterRef, frame: Int) -> SKTexture? {
        guard let textures = characters[ref], textures.indices.contains(frame) else { return nil }
        return textures[frame]
    }

    /// The frame a still scene shows at `tick`, with the animation's holds (as the software compositor).
    func characterFrameIndex(_ ref: CharacterRef, atTick tick: Int) -> Int {
        Self.characterTiming(ref.animation).frameIndex(atTick: tick)
    }

    /// The animation of the plan, from `tickOffset`; nil when the character is not composed yet.
    func characterAction(_ ref: CharacterRef, tickOffset: Int = 0) -> SKAction? {
        guard let textures = characters[ref] else { return nil }
        return Self.animationAction(textures, holds: ref.animation.holds, loops: ref.animation.loops,
                                    tickOffset: tickOffset)
    }

    private func store(_ composed: [(CharacterRef, [PixelImage])]) {
        guard !composed.isEmpty else { return }
        // One sprite definition per reference, named by its place in the batch: AtlasPacker packs them into pages.
        var defs: [SpriteDef] = []
        for (index, item) in composed.enumerated() where !item.1.isEmpty {
            defs.append(SpriteDef(key: SpriteKey(SpriteID("character.\(index)")), category: .characters,
                                  anchor: CharacterSprites.anchor, frames: item.1))
        }
        let frameCount = defs.reduce(0) { $0 + $1.frames.count }
        let packed = AtlasPacker.pack(defs, pageSize: Self.characterPageSide(frames: frameCount), padding: 2)
        let pageTextures = packed.pages.map { Self.makeTexture($0) }
        characterPages += pageTextures.count
        for (index, item) in composed.enumerated() {
            let key = SpriteKey(SpriteID("character.\(index)"))
            var textures: [SKTexture] = []
            for frame in item.1.indices {
                guard let entry = packed.entry(key, frame: frame), pageTextures.indices.contains(entry.page) else {
                    break
                }
                textures.append(Self.subTexture(entry.rect, in: pageTextures[entry.page], pageSize: packed.pageSize))
            }
            characters[item.0] = textures
        }
    }

    /// The smallest page side (128, 256 or 512) whose grid of 36 × 60 px cells holds `frames` frames.
    static func characterPageSide(frames: Int) -> Int {
        let cell = (width: CharacterSprites.frameWidth + 4, height: CharacterSprites.frameHeight + 4)
        for side in [128, 256] where (side / cell.width) * (side / cell.height) >= frames {
            return side
        }
        return characterPageSize
    }

    /// The frames of `ref` as the software compositor draws them (`CharacterSprites.canvas`, then `render`).
    nonisolated static func composeFrames(_ ref: CharacterRef) -> [PixelImage] {
        let resolved = ResolvedLook(ref.look, projectHue: ref.hue)
        return (0..<ref.animation.framesPerFacing).compactMap { frame in
            CharacterSprites.canvas(ref.animation, ref.facing, frame: frame, look: resolved)?.render(resolved)
        }
    }

    private static func characterTiming(_ animation: CharacterAnimation) -> SpriteDef {
        SpriteDef(key: SpriteKey(animation.spriteID), category: .characters, anchor: CharacterSprites.anchor,
                  frames: Array(repeating: PixelImage(width: 0, height: 0), count: animation.framesPerFacing),
                  holds: animation.holds, loops: animation.loops)
    }

    /// A stable order for a batch (same pages for the same characters).
    private nonisolated static func sorted(_ refs: Set<CharacterRef>) -> [CharacterRef] {
        refs.sorted { a, b in
            let ka = "\(a.animation.rawValue)@\(a.facing.rawValue)~\(a.hue)~\(a.look)"
            let kb = "\(b.animation.rawValue)@\(b.facing.rawValue)~\(b.hue)~\(b.look)"
            return ka < kb
        }
    }

    // MARK: Composed images

    /// A composed image of the plan (sign, name plate, clipped light), cached by its fingerprint.
    func texture(for image: PixelImage) -> SKTexture {
        let key = image.fingerprint
        if let cached = composed[key] { return cached }
        let texture = Self.makeTexture(image)
        composed[key] = texture
        composedOrder.append(key)
        if composedOrder.count > Self.composedLimit {
            composed[composedOrder.removeFirst()] = nil
        }
        return texture
    }

    var stats: [String: Int] {
        ["atlasPages": pages.count, "dynamicPages": characterPages, "composedTextures": composed.count]
    }

    // MARK: Textures

    /// A texture of `image` (rows top to bottom), premultiplied, sampled to the nearest texel.
    static func makeTexture(_ image: PixelImage) -> SKTexture {
        let texture = SKTexture(data: premultipliedBytes(image), size: CGSize(width: image.width, height: image.height),
                                flipped: true)
        texture.filteringMode = .nearest
        return texture
    }

    /// R G B A bytes, premultiplied (SKTexture's data format): a transparent pixel is (0, 0, 0, 0).
    nonisolated static func premultipliedBytes(_ image: PixelImage) -> Data {
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            image.pixels.withUnsafeBufferPointer { pixels in
                for index in 0..<pixels.count {
                    let p = pixels[index], o = index * 4
                    switch p.a {
                    case 0:
                        continue
                    case 255:
                        out[o] = p.r
                        out[o + 1] = p.g
                        out[o + 2] = p.b
                        out[o + 3] = 255
                    default:
                        let a = Int(p.a)
                        out[o] = UInt8((Int(p.r) * a + 127) / 255)
                        out[o + 1] = UInt8((Int(p.g) * a + 127) / 255)
                        out[o + 2] = UInt8((Int(p.b) * a + 127) / 255)
                        out[o + 3] = p.a
                    }
                }
            }
        }
        return data
    }

    /// The pixels `rect` (top-left origin) of a page, as a texture of its own: SpriteKit's unit rect has its origin
    /// at the bottom-left of the page.
    static func subTexture(_ rect: PixelRect, in page: SKTexture, pageSize: Int) -> SKTexture {
        let size = Double(pageSize)
        let unit = CGRect(x: Double(rect.x) / size, y: (size - Double(rect.y + rect.height)) / size,
                          width: Double(rect.width) / size, height: Double(rect.height) / size)
        let texture = SKTexture(rect: unit, in: page)
        texture.filteringMode = .nearest
        return texture
    }

    /// `setTexture` then `wait(hold / 24 s)` for each frame, from `tickOffset`; repeated forever when the animation
    /// loops, else played once and left on the last frame. nil for a single frame.
    static func animationAction(_ textures: [SKTexture], holds: [Int], loops: Bool, tickOffset: Int) -> SKAction? {
        guard textures.count > 1, holds.count == textures.count else { return nil }
        let total = holds.reduce(0, +)
        guard total > 0 else { return nil }
        let tick = Double(AnimationClock.ticksPerSecond)
        func step(_ index: Int, ticks: Int) -> [SKAction] {
            [.setTexture(textures[index]), .wait(forDuration: Double(ticks) / tick)]
        }
        var t = loops ? ((tickOffset % total) + total) % total : max(tickOffset, 0)
        if !loops && t >= total {
            return .setTexture(textures[textures.count - 1])
        }
        var first = 0
        while first < holds.count - 1 && t >= holds[first] {
            t -= holds[first]
            first += 1
        }
        var lead = step(first, ticks: holds[first] - t)
        for index in (first + 1)..<textures.count {
            lead += step(index, ticks: holds[index])
        }
        guard loops else {
            // Played once: the last frame stays (its wait is not needed).
            return .sequence(Array(lead.dropLast()))
        }
        let cycle = SKAction.sequence(textures.indices.flatMap { step($0, ticks: holds[$0]) })
        return .sequence(lead + [.repeatForever(cycle)])
    }
}
