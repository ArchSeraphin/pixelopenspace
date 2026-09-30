import AppKit
import PixelCore
import SwiftUI

/// "Terminal" tab: font size, Option as Meta, scrollback.
struct TerminalSettingsTab: View {
    static let fontSizes: ClosedRange<Double> = 9...24
    static let scrollbackRange: ClosedRange<Int> = 500...50_000

    @Binding var draft: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Taille de la police") {
                    Stepper(value: $draft.terminal.fontSize, in: Self.fontSizes, step: 1) {
                        Text("\(Int(draft.terminal.fontSize)) pt")
                            .monospacedDigit()
                    }
                }
                Text("Aperçu : > claude --resume")
                    .font(.system(size: CGFloat(draft.terminal.fontSize), design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                LabeledContent("Historique") {
                    Stepper(value: $draft.terminal.scrollback, in: Self.scrollbackRange, step: 500) {
                        Text("\(draft.terminal.scrollback) lignes")
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("La police et l'historique s'appliquent aux terminaux ouverts ensuite (à la prochaine relance "
                    + "d'un agent) : les changer sur une session en cours la réinitialiserait.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Utiliser Option comme touche Méta", isOn: $draft.terminal.optionAsMeta)
            } footer: {
                Text("Activé, ⌥ envoie Échap + touche (raccourcis Meta) au lieu des caractères spéciaux (@, #, |…). "
                    + "S'applique tout de suite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
