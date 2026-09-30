import PixelCore
import SwiftUI

/// The model's short messages (`AppModel.toasts`), newest at the bottom; each disappears after a few seconds.
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .trailing)
        .animation(.easeOut(duration: 0.2), value: model.toasts)
    }
}

private struct ToastView: View {
    let toast: Toast

    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let agentID = toast.agentID, model.agent(agentID) != nil {
                Button("Afficher") {
                    workbench.reveal(agentID)
                    model.dismissToast(toast.id)
                }
                .controlSize(.small)
            }
            Button {
                model.dismissToast(toast.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Fermer le message")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.5), lineWidth: 1))
        .shadow(radius: 3, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityPrefix + toast.text)
    }

    private var symbol: String {
        switch toast.style {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch toast.style {
        case .info: return Color.accentColor
        case .warning: return StateStyle.tint(for: .waitingInput)
        case .error: return StateStyle.tint(for: .error)
        }
    }

    private var accessibilityPrefix: String {
        switch toast.style {
        case .info: return ""
        case .warning: return "Attention : "
        case .error: return "Erreur : "
        }
    }
}
