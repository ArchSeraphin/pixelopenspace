import Foundation

/// One schema step, from `from` to `from + 1`, on the raw JSON object. `schemaVersion` is set by `Migrator`.
public struct MigrationStep: Sendable {
    public let from: Int
    public let migrate: @Sendable ([String: Any]) throws -> [String: Any]

    public init(from: Int, migrate: @escaping @Sendable ([String: Any]) throws -> [String: Any]) {
        self.from = from
        self.migrate = migrate
    }
}

/// Step-by-step migrations of the persisted files (proposal 3.14, 4.5). Each future step comes with a fixture
/// test (JSON of version n → expected n + 1).
public enum Migrator {
    /// `workspace.json`: v1 is the first version, nothing to migrate yet.
    public static let workspaceSteps: [MigrationStep] = []
    /// `settings.json`: v1 is the first version, nothing to migrate yet.
    public static let settingsSteps: [MigrationStep] = []

    /// `schemaVersion` of a JSON object, read before any typed decoding; `nil` when absent.
    /// Throws `corrupt` when the data is not a JSON object or the version is not an integer.
    public static func schemaVersion(of data: Data) throws -> Int? {
        do {
            return try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
        } catch {
            throw PersistenceError.corrupt("Fichier illisible : \(error)")
        }
    }

    /// Applies the steps `version → version + 1` up to `target`, in order.
    /// Throws `corrupt` when a step is missing (or fails), `newerSchema` when `version > target`.
    public static func migrate(_ object: [String: Any], from version: Int, to target: Int,
                               steps: [MigrationStep]) throws -> [String: Any] {
        guard version <= target else { throw PersistenceError.newerSchema(found: version, supported: target) }
        var object = object
        var current = version
        while current < target {
            guard let step = steps.first(where: { $0.from == current }) else {
                throw PersistenceError.corrupt("Aucune migration de la version \(current) vers \(current + 1).")
            }
            do {
                object = try step.migrate(object)
            } catch let error as PersistenceError {
                throw error
            } catch {
                throw PersistenceError.corrupt("Migration \(current) → \(current + 1) impossible : \(error)")
            }
            current += 1
            object["schemaVersion"] = current
        }
        return object
    }

    private struct VersionProbe: Decodable {
        var schemaVersion: Int?
    }
}
