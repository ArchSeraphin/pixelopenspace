import CoreGraphics
import PixelCore
import SwiftUI

/// The agent's portrait in its window (mockup 6(d)): the frames of its state's animation (`AgentPresenter.scene`),
/// facing the viewer, enlarged ×2 without interpolation. A `TimelineView` plays them at the animation's own cadence
/// (24 ticks per second, holds of 7.4.4); frozen on frame 0 with Reduce Motion and in the snapshot harness (the key
/// pose, décision 17). Offline (the jacket is on the chair in the scene): the standing pose, greyed. Decorative: the
/// window's text says the state.
struct AgentPortraitView: View {
    /// Points per texel.
    static let scale: CGFloat = 2

    let look: AgentLook
    let projectHue: Int
    /// nil: offline, no avatar at the desk.
    let animation: CharacterAnimation?
    let frozen: Bool

    var body: some View {
        let shown = animation ?? .stand
        let frames = AgentPortraitFrames.frames(look: look, projectHue: projectHue, animation: shown)
        let animated = !frozen && animation != nil && frames.count > 1
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: AgentPortraitFrames.interval(shown))) { context in
                    frameImage(frames, index: AgentPortraitFrames.frameIndex(shown, at: context.date))
                }
            } else {
                frameImage(frames, index: 0)
            }
        }
        .frame(width: CGFloat(CharacterSprites.frameWidth) * Self.scale,
               height: CGFloat(CharacterSprites.frameHeight) * Self.scale)
        .saturation(animation == nil ? 0 : 1)
        .opacity(animation == nil ? 0.45 : 1)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(ProjectHue.color(projectHue).opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(ProjectHue.color(projectHue).opacity(0.45), lineWidth: 1))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func frameImage(_ frames: [CGImage], index: Int) -> some View {
        if frames.indices.contains(index) {
            Image(decorative: frames[index], scale: 1)
                .resizable()
                .interpolation(.none)
        } else {
            Color.clear
        }
    }
}

/// The portrait's frames, composed from the character parts (`CharacterSprites.canvas`, facing SE) and cached by
/// look, hue and animation.
@MainActor
enum AgentPortraitFrames {
    private struct Key: Hashable {
        var look: AgentLook
        var hue: Int
        var animation: CharacterAnimation
    }

    /// A handful of agents' windows at once, a few states each.
    private static let capacity = 64
    private static var cache: [Key: [CGImage]] = [:]

    static func frames(look: AgentLook, projectHue: Int, animation: CharacterAnimation) -> [CGImage] {
        let key = Key(look: look, hue: projectHue, animation: animation)
        if let cached = cache[key] { return cached }
        let resolved = ResolvedLook(look, projectHue: projectHue)
        let images = (0..<animation.framesPerFacing).compactMap { frame in
            CharacterSprites.canvas(animation, .se, frame: frame, look: resolved)?.render(resolved).cgImage()
        }
        if cache.count >= capacity { cache.removeAll() }
        cache[key] = images
        return images
    }

    /// One frame's hold, in seconds (the holds of a character animation are all equal).
    static func interval(_ animation: CharacterAnimation) -> TimeInterval {
        let hold = animation.holds.min() ?? AnimationClock.ticksPerSecond
        return TimeInterval(max(hold, 1)) / TimeInterval(AnimationClock.ticksPerSecond)
    }

    /// The frame shown at `date`: the loop's position on the 24-tick clock; a one-shot animation holds its last frame.
    static func frameIndex(_ animation: CharacterAnimation, at date: Date) -> Int {
        let holds = animation.holds
        let cycle = holds.reduce(0, +)
        guard cycle > 0, !holds.isEmpty else { return 0 }
        guard animation.loops else { return holds.count - 1 }
        let ticks = Int((date.timeIntervalSinceReferenceDate * Double(AnimationClock.ticksPerSecond)).rounded(.down))
        var tick = ((ticks % cycle) + cycle) % cycle
        for (index, hold) in holds.enumerated() {
            if tick < hold { return index }
            tick -= hold
        }
        return 0
    }
}
