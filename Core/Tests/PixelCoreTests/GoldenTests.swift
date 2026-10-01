import Foundation
import Testing
@testable import PixelCore

/// The golden fingerprints (7.5): every frame of the catalog and four key scenes. A change to a sprite or to the
/// compositor shows up here; when it is intended, the file is regenerated and the images re-rendered.
enum GoldenFixture {
    /// Computed once per test run (a few seconds in debug).
    static let lines = MilestoneExport.goldenLines()

    static let repositoryPath = "Core/Tests/PixelCoreTests/Fixtures/golden/sprites.txt"

    static let regenerate = """
        from the repository root: swift run --package-path Core sprite-export --golden-out \(repositoryPath), \
        then re-render the images: swift run --package-path Core -c release sprite-export --out "$PWD/docs/jalon-visuel"
        """

    /// The committed lines, blank lines left out.
    static func committed() throws -> [String] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/golden/sprites.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// "name fingerprint" → (name, fingerprint).
    static func split(_ line: String) -> (name: String, fingerprint: String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Names whose fingerprint differs, or that only one side has, sorted.
    static func differences(_ committed: [String], _ current: [String]) -> [String] {
        func table(_ lines: [String]) -> [String: String] {
            Dictionary(lines.compactMap(split), uniquingKeysWith: { first, _ in first })
        }
        let old = table(committed), new = table(current)
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    }
}

@Suite struct GoldenTests {
    @Test func spritesAndScenesMatchGolden() throws {
        let committed = try GoldenFixture.committed()
        let current = GoldenFixture.lines
        guard committed != current else { return }
        let changed = GoldenFixture.differences(committed, current)
        let listed = changed.prefix(20).joined(separator: ", ") + (changed.count > 20 ? ", …" : "")
        Issue.record("""
            \(changed.count) golden fingerprint(s) differ: \(listed). \
            If the change is intended, regenerate \(GoldenFixture.regenerate).
            """)
    }

    @Test func goldenFileIsWellFormed() throws {
        let committed = try GoldenFixture.committed()
        #expect(!committed.isEmpty)
        #expect(committed.allSatisfy { line in
            guard let (name, fingerprint) = GoldenFixture.split(line) else { return false }
            return !name.isEmpty && fingerprint.count == 16
                && fingerprint.allSatisfy { "0123456789abcdef".contains($0) }
        })
        #expect(committed == committed.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        #expect(Set(committed).count == committed.count)
    }

    @Test func differencesNameChangedAddedAndRemovedKeys() {
        let old = ["a#0 0000000000000001", "b#0 0000000000000002", "c#0 0000000000000003"]
        let new = ["a#0 0000000000000001", "b#0 00000000000000ff", "d#0 0000000000000004"]
        #expect(GoldenFixture.differences(old, new) == ["b#0", "c#0", "d#0"])
        #expect(GoldenFixture.differences(old, old).isEmpty)
    }
}
