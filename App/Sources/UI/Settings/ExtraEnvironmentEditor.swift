import PixelCore
import SwiftUI

/// Editor of `AppSettings.extraEnv`: one row per variable. Rows with an invalid or reserved name are kept in the
/// editor but flagged (the launch planner ignores them).
struct ExtraEnvironmentEditor: View {
    @Binding var environment: [String: String]

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    @State private var rows: [Row] = []
    @State private var prepared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("NOM", text: $row.name)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180)
                        .accessibilityLabel("Nom de la variable")
                    Text("=")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("valeur", text: $row.value)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Valeur de \(row.name)")
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Supprimer \(row.name)")
                }
                if let problem = Self.problem(name: row.name, value: row.value) {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(StateStyle.tint(for: .error))
                }
            }
            Button {
                rows.append(Row(name: "", value: ""))
            } label: {
                Label("Ajouter une variable", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .onAppear(perform: prepare)
        .onChange(of: rows) { _, newRows in
            let updated = Self.dictionary(from: newRows)
            if updated != environment { environment = updated }
        }
        .onChange(of: environment) { _, newValue in
            // Changed elsewhere (another window): rebuild the rows unless they already say the same.
            if Self.dictionary(from: rows) != newValue { rows = Self.rows(from: newValue) }
        }
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        rows = Self.rows(from: environment)
    }

    private static func rows(from environment: [String: String]) -> [Row] {
        environment.sorted { $0.key < $1.key }.map { Row(name: $0.key, value: $0.value) }
    }

    /// Named rows only; the last row wins for a repeated name.
    private static func dictionary(from rows: [Row]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[name] = row.value
        }
        return result
    }

    /// Why a variable will be ignored at launch, in French; `nil` when it is fine.
    static func problem(name rawName: String, value: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if !EnvSanitizer.isValidEntry(name: name, value: value) {
            return "Nom invalide (pas de « = ») : variable ignorée."
        }
        if name.hasPrefix("PIXEL_"), !LaunchPlanner.userSettablePixelKeys.contains(name) {
            return "Variable réservée à l'app : ignorée."
        }
        if LaunchPlanner.envDisableAgentView == name || LaunchPlanner.envDisableNonessentialTraffic == name
            || LaunchPlanner.envDisableAlternateScreen == name {
            return "Réglée aussi par une option ci-dessus : cette valeur la remplace."
        }
        return nil
    }
}
