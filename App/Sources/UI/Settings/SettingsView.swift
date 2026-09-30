import PixelCore
import SwiftUI

/// Réglages (mockup 6(h)). Every change is applied at once through `AppModel.updateSettings(_:)` and saved in
/// `state/settings.json`. Each tab edits a local copy (`draft`) that follows the model.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var draft = AppSettings()
    @State private var loaded = false

    var body: some View {
        TabView {
            ClaudeCodeSettingsTab(draft: $draft)
                .tabItem { Label("Claude Code", systemImage: "terminal") }
            NotificationSettingsTab(draft: $draft)
                .tabItem { Label("Notifications", systemImage: "bell") }
            TerminalSettingsTab(draft: $draft)
                .tabItem { Label("Terminal", systemImage: "character.cursor.ibeam") }
            AdvancedSettingsTab()
                .tabItem { Label("Avancé", systemImage: "gearshape.2") }
        }
        .frame(width: 620)
        .frame(minHeight: 420)
        .onAppear {
            draft = model.settings
            loaded = true
        }
        .onChange(of: draft) { _, newValue in
            guard loaded, newValue != model.settings else { return }
            model.updateSettings(newValue)
        }
        .onChange(of: model.settings) { _, newValue in
            if newValue != draft { draft = newValue }
        }
    }
}

/// Notifications tab: waits always notified, turn done in the background or out of sight, details hidden.
struct NotificationSettingsTab: View {
    @Binding var draft: AppSettings

    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Prévenir quand un agent attend ma réponse, même quand l'app est au premier plan",
                       isOn: $draft.notifications.waitingAlways)
                Toggle("Prévenir de la fin d'un tour quand l'app est en arrière-plan ou l'agent hors de vue",
                       isOn: $draft.notifications.turnDoneWhenInBackground)
                Toggle("Masquer les détails (commande, chemin) dans les notifications",
                       isOn: $draft.notifications.hideDetails)
            } footer: {
                Text("Avec les détails masqués, une notification dit seulement « Nova attend ta réponse » : utile "
                    + "avec l'écran verrouillé et le Centre de notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.notificationsDenied {
                Section {
                    Label("Les notifications de Pixel Open Space sont refusées dans Réglages Système. Le badge du "
                        + "Dock compte quand même les agents qui attendent.", systemImage: "bell.slash")
                        .foregroundStyle(StateStyle.tint(for: .waitingInput))
                }
            }
        }
        .formStyle(.grouped)
    }
}
