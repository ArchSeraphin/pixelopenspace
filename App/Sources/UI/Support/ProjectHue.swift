import PixelCore
import SwiftUI

/// The 10 project hues of palette 7.1 (P0…P9), base tone. Never bright yellow: yellow means "waiting".
enum ProjectHue {
    private static let entries: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("Tomate", 0xE4, 0x57, 0x2E),
        ("Mandarine", 0xF2, 0x9E, 0x4C),
        ("Olive", 0x8A, 0xB1, 0x7D),
        ("Menthe", 0x2A, 0x9D, 0x8F),
        ("Lagune", 0x3A, 0x86, 0xC8),
        ("Indigo", 0x5E, 0x60, 0xCE),
        ("Prune", 0x9B, 0x5D, 0xE5),
        ("Framboise", 0xD6, 0x33, 0x6C),
        ("Cacao", 0x8D, 0x63, 0x46),
        ("Ardoise", 0x5C, 0x6B, 0x7A),
    ]

    static var count: Int { entries.count }

    static var all: [Int] { Array(entries.indices) }

    static func color(_ index: Int) -> Color {
        let entry = entries[clamped(index)]
        return Color(red: entry.red / 255, green: entry.green / 255, blue: entry.blue / 255)
    }

    /// "Lagune": the color's name, for menus and VoiceOver.
    static func name(_ index: Int) -> String {
        entries[clamped(index)].name
    }

    /// The hue a new project gets by default: the least used among live projects, lowest index on ties
    /// (same rule as `Workspace.addProject`).
    static func leastUsed(among projects: [Project]) -> Int {
        var counts = Array(repeating: 0, count: entries.count)
        for project in projects {
            counts[clamped(project.hueIndex)] += 1
        }
        let minimum = counts.min() ?? 0
        return counts.firstIndex(of: minimum) ?? 0
    }

    private static func clamped(_ index: Int) -> Int {
        min(max(index, 0), entries.count - 1)
    }
}

/// The small colored square of a project (sidebar, section headers, sheets).
struct ProjectHueSquare: View {
    let hueIndex: Int
    var size: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(ProjectHue.color(hueIndex))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
