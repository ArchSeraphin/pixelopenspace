import Foundation

public enum PersistenceError: Error, Equatable, Sendable {
    /// The file was written by a newer app: open read-only, never overwrite (proposal 4.5).
    case newerSchema(found: Int, supported: Int)
    /// Unreadable: set aside as `*.corrupt-<timestamp>.json`, last backup loaded (proposal 3.14).
    case corrupt(String)
}

/// JSON of the files in `state/` (proposal 3.14, 4.5): pretty-printed, sorted keys (diffable, same input →
/// same bytes), dates in ISO 8601 UTC with milliseconds ("2026-09-30T10:12:03.123Z", exact to the millisecond).
public enum PersistenceCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601Millis.format(date))
        }
        return encoder
    }

    /// Accepts ISO 8601 date-times with or without fractional seconds, with "Z" or a numeric offset.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISO8601Millis.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date ISO 8601 invalide : \(text)")
            }
            return date
        }
        return decoder
    }

    // MARK: - Workspace

    public static func encodeWorkspace(_ workspace: Workspace) throws -> Data {
        try makeEncoder().encode(workspace)
    }

    /// Migrates older files (`migratedFrom` = their version); throws `newerSchema` for a newer file unless
    /// `allowNewerSchema` (read-only opening: unknown fields are ignored), `corrupt` for anything unreadable.
    /// Run `WorkspaceValidator.validate` on the result.
    public static func decodeWorkspace(_ data: Data, migrations: [MigrationStep] = Migrator.workspaceSteps,
                                       allowNewerSchema: Bool = false) throws -> (workspace: Workspace, migratedFrom: Int?) {
        let (workspace, from) = try decode(Workspace.self, from: data, current: Workspace.currentSchemaVersion,
                                           migrations: migrations, allowNewerSchema: allowNewerSchema)
        return (workspace, from)
    }

    // MARK: - Settings

    public static func encodeSettings(_ settings: AppSettings) throws -> Data {
        try makeEncoder().encode(settings)
    }

    /// Same rules as `decodeWorkspace`. Missing fields take their defaults.
    public static func decodeSettings(_ data: Data, migrations: [MigrationStep] = Migrator.settingsSteps,
                                      allowNewerSchema: Bool = false) throws -> (settings: AppSettings, migratedFrom: Int?) {
        let (settings, from) = try decode(AppSettings.self, from: data, current: AppSettings.currentSchemaVersion,
                                          migrations: migrations, allowNewerSchema: allowNewerSchema)
        return (settings, from)
    }

    // MARK: - Tasks

    public static func encodeTasks(_ board: TaskBoardState) throws -> Data {
        try makeEncoder().encode(board)
    }

    /// Same rules as `decodeWorkspace`. Missing optional fields take their defaults.
    /// Run `TaskBoardValidator.validate` on the result.
    public static func decodeTasks(_ data: Data, migrations: [MigrationStep] = Migrator.tasksSteps,
                                   allowNewerSchema: Bool = false) throws -> (board: TaskBoardState, migratedFrom: Int?) {
        let (board, from) = try decode(TaskBoardState.self, from: data, current: TaskBoardState.currentSchemaVersion,
                                       migrations: migrations, allowNewerSchema: allowNewerSchema)
        return (board, from)
    }

    // MARK: - Shared

    /// A missing `schemaVersion` reads as the current version (hand-written or truncated-header files).
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, current: Int, migrations: [MigrationStep],
                                     allowNewerSchema: Bool) throws -> (T, Int?) {
        let found = try Migrator.schemaVersion(of: data)
        let version = found ?? current
        if version > current, !allowNewerSchema {
            throw PersistenceError.newerSchema(found: version, supported: current)
        }
        var payload = data
        var migratedFrom: Int?
        if version < current || found == nil {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PersistenceError.corrupt("Le fichier n'est pas un objet JSON.")
            }
            var migrated = object
            if version < current {
                migrated = try Migrator.migrate(object, from: version, to: current, steps: migrations)
                migratedFrom = version
            } else {
                migrated["schemaVersion"] = current
            }
            do {
                payload = try JSONSerialization.data(withJSONObject: migrated)
            } catch {
                throw PersistenceError.corrupt("Contenu JSON invalide : \(error)")
            }
        }
        do {
            return (try makeDecoder().decode(T.self, from: payload), migratedFrom)
        } catch {
            throw PersistenceError.corrupt("Fichier illisible : \(error)")
        }
    }
}

/// ISO 8601 with milliseconds, by integer arithmetic on the proleptic Gregorian calendar (no formatter:
/// identical on macOS and Linux, and no rounding surprise on the last digit).
enum ISO8601Millis {
    static func format(_ date: Date) -> String {
        let totalMillis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = floorDiv(totalMillis, 1000)
        let millis = totalMillis - seconds * 1000
        let days = floorDiv(seconds, 86_400)
        let secondOfDay = seconds - days * 86_400
        let (y, m, d) = civil(fromDays: days)
        return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2) + "T"
            + pad(secondOfDay / 3600, 2) + ":" + pad(secondOfDay % 3600 / 60, 2) + ":" + pad(secondOfDay % 60, 2)
            + "." + pad(millis, 3) + "Z"
    }

    /// "YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM|±HHMM)"; the fraction is rounded to the millisecond.
    static func parse(_ text: String) -> Date? {
        let c = Array(text.utf8)
        var i = 0
        func number(_ digits: Int) -> Int64? {
            guard i + digits <= c.count else { return nil }
            var value: Int64 = 0
            for k in i..<(i + digits) {
                guard c[k] >= 48, c[k] <= 57 else { return nil }
                value = value * 10 + Int64(c[k] - 48)
            }
            i += digits
            return value
        }
        /// Consumes one character among `allowed`.
        func expect(_ allowed: String) -> Bool {
            guard i < c.count, allowed.utf8.contains(c[i]) else { return false }
            i += 1
            return true
        }
        guard let y = number(4), expect("-"), let mo = number(2), expect("-"), let d = number(2), expect("Tt"),
              let h = number(2), expect(":"), let mi = number(2), expect(":"), let s = number(2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61
        else { return nil }

        // Fraction: the first four digits, rounded to the millisecond.
        var millis: Int64 = 0
        if expect(".,") {
            var tenThousandths: Int64 = 0
            var digits = 0
            while i < c.count, c[i] >= 48, c[i] <= 57 {
                if digits < 4 { tenThousandths = tenThousandths * 10 + Int64(c[i] - 48) }
                digits += 1
                i += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<max(digits, 4) { tenThousandths *= 10 }
            millis = (tenThousandths + 5) / 10
        }

        var offsetSeconds: Int64 = 0
        guard i < c.count else { return nil }
        if expect("Zz") {
            // UTC.
        } else if c[i] == UInt8(ascii: "+") || c[i] == UInt8(ascii: "-") {
            let sign: Int64 = c[i] == UInt8(ascii: "+") ? 1 : -1
            i += 1
            guard let oh = number(2) else { return nil }
            _ = expect(":")
            guard let om = number(2), oh < 24, om < 60 else { return nil }
            offsetSeconds = sign * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == c.count else { return nil }

        let seconds = days(fromCivil: y, mo, d) * 86_400 + h * 3600 + mi * 60 + s - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds * 1000 + millis) / 1000)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    /// Days since 1970-01-01 → (year, month, day). H. Hinnant's `civil_from_days`.
    private static func civil(fromDays z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// (year, month, day) → days since 1970-01-01. H. Hinnant's `days_from_civil`.
    private static func days(fromCivil y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
