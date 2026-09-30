import Foundation

/// Short agent names ("Nova", "Bip"…). Invented or everyday words only: no brand, no famous character.
/// Short enough for a desk label; French-friendly spelling.
public enum NameGenerator {
    public static let names: [String] = [
        "Nova", "Bip", "Lune", "Kiwi", "Oslo", "Pixou", "Tao", "Mika", "Lou", "Zéphyr",
        "Rio", "Sol", "Ivo", "Plume", "Galet", "Brume", "Comète", "Nuage", "Pépin", "Cajou",
        "Figue", "Olive", "Radis", "Praline", "Noisette", "Filou", "Zazou", "Hibou", "Tilleul", "Anis",
        "Sésame", "Pistache", "Litchi", "Orso", "Timo", "Nilo", "Lila", "Zibo", "Tuli", "Pako",
        "Kalo", "Voxel", "Octet", "Bitou", "Opale", "Agate", "Ambre", "Perle", "Jaspe", "Silex",
        "Givre", "Flocon", "Rosée", "Écume", "Safran", "Muscade", "Cumulus", "Grelot", "Loupiot", "Frimousse",
    ]

    /// Deterministic: the same seed and the same names in use give the same name. Walks the list from
    /// `seed % names.count` and returns the first name not in `avoiding` (compared case-insensitively);
    /// when all are taken, "Agent N" with the smallest free N ≥ 1.
    public static func name(seed: UInt64, avoiding: Set<String>) -> String {
        let taken = Set(avoiding.map { $0.lowercased() })
        let start = Int(seed % UInt64(names.count))
        for offset in 0..<names.count {
            let candidate = names[(start + offset) % names.count]
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        var n = 1
        while taken.contains("agent \(n)") { n += 1 }
        return "Agent \(n)"
    }

    /// A seed derived from an agent's identity (its first 8 UUID bytes), so a new agent's name is reproducible.
    public static func seed(for id: AgentID) -> UInt64 {
        let b = id.raw.uuid
        return [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
