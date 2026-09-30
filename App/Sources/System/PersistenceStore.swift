import Foundation
import PixelCore

/// A persisted value as loaded at launch, with what the user should be told about it.
struct LoadedFile<Value: Sendable>: Sendable {
    var value: Value
    /// French messages for the load banner: repairs, migration, unreadable file set aside, newer file kept read-only.
    var warnings: [String]
}

/// Single writer of `state/workspace.json`, `state/settings.json` and `state/tasks.json` (proposal 3.14, 4.5).
///
/// Loading is synchronous (a few kilobytes, read once at launch, before the UI shows anything). Saving is debounced
/// (500 ms) and atomic, with mode 0600. Each save carries a version number from the caller: saves that arrive out of
/// order never overwrite a newer state. Before the first write of the day, the previous file is copied to
/// `backups/state/<yyyy-MM-dd>/` (5 days kept). A file written by a newer app (higher `schemaVersion`) is opened
/// read-only and never overwritten. An unreadable file is renamed `<name>.corrupt-<timestamp>.json` and the most
/// recent readable backup is loaded instead, or the defaults.
actor PersistenceStore {
    nonisolated let directories: AppDirectories

    static let debounce: Duration = .milliseconds(500)
    static let backupDaysKept = 5

    private var pendingWorkspace: Workspace?
    private var pendingWorkspaceVersion: UInt64 = 0
    private var writtenWorkspaceVersion: UInt64 = 0
    private var workspaceTask: Task<Void, Never>?

    private var pendingSettings: AppSettings?
    private var pendingSettingsVersion: UInt64 = 0
    private var writtenSettingsVersion: UInt64 = 0
    private var settingsTask: Task<Void, Never>?

    private var pendingBoard: TaskBoardState?
    private var pendingBoardVersion: UInt64 = 0
    private var writtenBoardVersion: UInt64 = 0
    private var boardTask: Task<Void, Never>?

    init(directories: AppDirectories) {
        self.directories = directories
    }

    // MARK: - Loading

    nonisolated func loadWorkspace(now: Date = Date()) -> LoadedFile<Workspace> {
        var loaded = load(file: directories.workspaceFile, label: "l'espace de travail", defaultValue: Workspace(),
                          now: now) { data, allowNewer in
            let (workspace, migratedFrom) = try PersistenceCodec.decodeWorkspace(data, allowNewerSchema: allowNewer)
            return (workspace, migratedFrom)
        }
        let (validated, issues) = WorkspaceValidator.validate(loaded.value)
        loaded.value = validated
        loaded.warnings += issues
        return loaded
    }

    nonisolated func loadSettings(now: Date = Date()) -> LoadedFile<AppSettings> {
        load(file: directories.settingsFile, label: "les réglages", defaultValue: AppSettings(), now: now) { data, allowNewer in
            let (settings, migratedFrom) = try PersistenceCodec.decodeSettings(data, allowNewerSchema: allowNewer)
            return (settings, migratedFrom)
        }
    }

    /// The cork board, repaired against the workspace's agents and projects (`TaskBoardValidator`). A missing
    /// file (first launch) gives an empty board with the starter templates.
    nonisolated func loadTasks(agents: Set<AgentID>, projects: Set<ProjectID>,
                               now: Date = Date()) -> LoadedFile<TaskBoardState> {
        let fresh = TaskBoardState.initial(templateIDs: [PromptTemplateID(), PromptTemplateID(), PromptTemplateID()])
        var loaded = load(file: directories.tasksFile, label: "les post-its", defaultValue: fresh,
                          now: now) { data, allowNewer in
            let (board, migratedFrom) = try PersistenceCodec.decodeTasks(data, allowNewerSchema: allowNewer)
            return (board, migratedFrom)
        }
        let (validated, issues) = TaskBoardValidator.validate(loaded.value, agents: agents, projects: projects)
        loaded.value = validated
        loaded.warnings += issues
        return loaded
    }

    private nonisolated func load<Value: Sendable>(
        file: URL, label: String, defaultValue: Value, now: Date,
        decode: (Data, Bool) throws -> (Value, Int?)
    ) -> LoadedFile<Value> {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return LoadedFile(value: defaultValue, warnings: []) }
        let name = file.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            AppLog.persistence.error("read \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return recover(file: file, label: label, defaultValue: defaultValue, now: now, decode: decode,
                           reason: "fichier illisible")
        }
        do {
            let (value, migratedFrom) = try decode(data, false)
            var warnings: [String] = []
            if let migratedFrom {
                warnings.append("Fichier \(name) mis à jour depuis le format \(migratedFrom).")
            }
            return LoadedFile(value: value, warnings: warnings)
        } catch PersistenceError.newerSchema(let found, _) {
            if let (value, _) = try? decode(data, true) {
                return LoadedFile(value: value, warnings: [
                    "\(name) vient d'une version plus récente de l'app (format \(found)) : ouvert en lecture seule, "
                        + "tes modifications ne seront pas enregistrées.",
                ])
            }
            return recover(file: file, label: label, defaultValue: defaultValue, now: now, decode: decode,
                           reason: "format inconnu")
        } catch {
            AppLog.persistence.error("decode \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return recover(file: file, label: label, defaultValue: defaultValue, now: now, decode: decode,
                           reason: "fichier illisible")
        }
    }

    /// Sets the unreadable file aside, then loads the most recent readable backup, or the defaults.
    private nonisolated func recover<Value: Sendable>(
        file: URL, label: String, defaultValue: Value, now: Date,
        decode: (Data, Bool) throws -> (Value, Int?), reason: String
    ) -> LoadedFile<Value> {
        let name = file.lastPathComponent
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent(Self.corruptName(for: name, now: now), isDirectory: false)
        var message = "\(name) : \(reason)"
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            message += ", mis de côté sous \(aside.lastPathComponent)"
        } catch {
            AppLog.persistence.error("cannot set \(name, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
        }
        for day in backupDays().reversed() {
            let backup = directories.stateBackups.appendingPathComponent(day, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: backup), let (value, _) = try? decode(data, false) else { continue }
            return LoadedFile(value: value, warnings: [message + ". Sauvegarde du \(day) chargée pour \(label)."])
        }
        return LoadedFile(value: defaultValue, warnings: [message + ". Aucune sauvegarde lisible : \(label) repartent de zéro."])
    }

    // MARK: - Saving

    /// Saves `workspace` within `debounce`, unless a save with a higher `version` was already requested.
    func scheduleSave(_ workspace: Workspace, version: UInt64) {
        guard version > writtenWorkspaceVersion, version > pendingWorkspaceVersion else { return }
        pendingWorkspace = workspace
        pendingWorkspaceVersion = version
        guard workspaceTask == nil else { return }
        workspaceTask = Task {
            try? await Task.sleep(for: Self.debounce)
            self.writePendingWorkspace()
        }
    }

    func scheduleSave(_ settings: AppSettings, version: UInt64) {
        guard version > writtenSettingsVersion, version > pendingSettingsVersion else { return }
        pendingSettings = settings
        pendingSettingsVersion = version
        guard settingsTask == nil else { return }
        settingsTask = Task {
            try? await Task.sleep(for: Self.debounce)
            self.writePendingSettings()
        }
    }

    func scheduleSave(_ board: TaskBoardState, version: UInt64) {
        guard version > writtenBoardVersion, version > pendingBoardVersion else { return }
        pendingBoard = board
        pendingBoardVersion = version
        guard boardTask == nil else { return }
        boardTask = Task {
            try? await Task.sleep(for: Self.debounce)
            self.writePendingBoard()
        }
    }

    /// Writes whatever is pending now (app quit).
    func flush() {
        workspaceTask?.cancel()
        settingsTask?.cancel()
        boardTask?.cancel()
        writePendingWorkspace()
        writePendingSettings()
        writePendingBoard()
    }

    private func writePendingWorkspace() {
        workspaceTask = nil
        guard let workspace = pendingWorkspace else { return }
        pendingWorkspace = nil
        let version = pendingWorkspaceVersion
        do {
            let data = try PersistenceCodec.encodeWorkspace(workspace)
            write(data, to: directories.workspaceFile, currentSchema: Workspace.currentSchemaVersion)
            writtenWorkspaceVersion = max(writtenWorkspaceVersion, version)
        } catch {
            AppLog.persistence.error("encode workspace failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func writePendingSettings() {
        settingsTask = nil
        guard let settings = pendingSettings else { return }
        pendingSettings = nil
        let version = pendingSettingsVersion
        do {
            let data = try PersistenceCodec.encodeSettings(settings)
            write(data, to: directories.settingsFile, currentSchema: AppSettings.currentSchemaVersion)
            writtenSettingsVersion = max(writtenSettingsVersion, version)
        } catch {
            AppLog.persistence.error("encode settings failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func writePendingBoard() {
        boardTask = nil
        guard let board = pendingBoard else { return }
        pendingBoard = nil
        let version = pendingBoardVersion
        do {
            let data = try PersistenceCodec.encodeTasks(board)
            write(data, to: directories.tasksFile, currentSchema: TaskBoardState.currentSchemaVersion)
            writtenBoardVersion = max(writtenBoardVersion, version)
        } catch {
            AppLog.persistence.error("encode tasks failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Atomic write, after the daily backup of the previous content. Never overwrites a file of a newer schema.
    private func write(_ data: Data, to file: URL, currentSchema: Int) {
        let name = file.lastPathComponent
        if let existing = try? Data(contentsOf: file) {
            if let version = try? Migrator.schemaVersion(of: existing), version > currentSchema {
                AppLog.persistence.warning("\(name, privacy: .public) has schema \(version), newer than \(currentSchema): not overwritten")
                return
            }
            backUp(existing, name: name, now: Date())
        }
        do {
            try AppDirectories.writePrivateFile(data, to: file)
        } catch {
            AppLog.persistence.error("write \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Backups

    /// Copies the previous content once per day, and keeps the last `backupDaysKept` days.
    private func backUp(_ data: Data, name: String, now: Date) {
        let day = Self.dayName(now)
        let directory = directories.stateBackups.appendingPathComponent(day, isDirectory: true)
        let target = directory.appendingPathComponent(name, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        if let problem = AppDirectories.makePrivateDirectory(directory.path) {
            AppLog.persistence.error("\(problem, privacy: .public)")
            return
        }
        do {
            try AppDirectories.writePrivateFile(data, to: target)
        } catch {
            AppLog.persistence.error("backup \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        let days = backupDays()
        for old in days.dropLast(Self.backupDaysKept) {
            try? FileManager.default.removeItem(at: directories.stateBackups.appendingPathComponent(old, isDirectory: true))
        }
    }

    /// Backup day folders ("yyyy-MM-dd"), oldest first.
    private nonisolated func backupDays() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directories.stateBackups.path)) ?? []
        return names.filter { $0.count == 10 && $0.first?.isNumber == true }.sorted()
    }

    private static func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "workspace.corrupt-2026-09-30T10-12-03Z.json".
    private static func corruptName(for name: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let base = (name as NSString).deletingPathExtension
        return "\(base).corrupt-\(stamp).json"
    }
}
