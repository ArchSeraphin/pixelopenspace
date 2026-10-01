import AppKit
import PixelCore
import SwiftUI

/// Global banners under the status bar (mockup 6(o)): hooks, Claude Code, account, usage limit, degraded mode,
/// shell environment, sessions to relaunch (2.5), pending quit, load warnings, notifications refused. The most serious is shown; the others
/// behind "+ n autres alertes".
struct BannerStackView: View {
    @Environment(AppModel.self) private var model
    @Environment(WorkbenchState.self) private var workbench

    @State private var showsAll = false
    @State private var hidesNotificationWarning = false

    var body: some View {
        let banners = BannerCatalog.banners(model: model, showNotificationWarning: !hidesNotificationWarning)
        if let first = banners.first {
            VStack(spacing: 0) {
                // Identified by the banner, so that a banner coming first "appears".
                BannerRow(banner: first, perform: perform)
                    .onAppear { appeared(first) }
                    .id(first.id)
                if banners.count > 1 {
                    if showsAll {
                        ForEach(banners.dropFirst()) { banner in
                            Divider()
                            BannerRow(banner: banner, perform: perform)
                                .onAppear { appeared(banner) }
                        }
                    }
                    Button(showsAll ? "Masquer les autres alertes" : moreTitle(banners.count - 1)) {
                        showsAll.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
            }
            .background(Self.background(for: first.severity))
        }
    }

    private func moreTitle(_ count: Int) -> String {
        count > 1 ? "+ \(count) autres alertes" : "+ 1 autre alerte"
    }

    static func background(for severity: Banner.Severity) -> Color {
        switch severity {
        case .error: return StateStyle.tint(for: .error).opacity(0.14)
        case .warning: return StateStyle.tint(for: .quotaPaused).opacity(0.14)
        case .info: return Color.accentColor.opacity(0.08)
        }
    }

    /// The relaunch banner shows: what it says is read again from the disk and the processes (it is otherwise read
    /// every 5 s at most, never on a render).
    private func appeared(_ banner: Banner) {
        if banner.id == BannerCatalog.relaunchBannerID { model.refreshRelaunchProbe() }
    }

    private func perform(_ action: BannerAction) {
        switch action {
        case .openOtherInstance:
            model.activateOtherInstanceAndQuit()
        case .chooseClaudePath:
            if let url = FilePickers.chooseClaudeExecutable(current: model.claude.path) {
                model.setClaudePathOverride(url.path(percentEncoded: false))
            }
        case .redetectClaude:
            model.redetectClaude()
        case .showClaudeSetup:
            workbench.present(.claudeSetup)
        case .openTerminal(let agentID):
            workbench.showTerminal(for: agentID, focus: true)
        case .terminateOrphan(let agentID):
            model.terminateOrphan(agentID)
        case .cancelQuitWait:
            model.cancelWaitingForTurns()
        case .relaunchAll:
            model.relaunchAll()
        case .chooseRelaunch:
            workbench.presentRelaunchSheet()
        case .dismissRelaunch:
            model.dismissRelaunchOffer()
        case .dismissLoadWarnings:
            model.dismissLoadWarnings()
        case .openNotificationSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .hideNotificationWarning:
            hidesNotificationWarning = true
        }
    }
}

private struct BannerRow: View {
    let banner: Banner
    let perform: @MainActor (BannerAction) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: banner.symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.callout.weight(.semibold))
                if let message = banner.message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            ForEach(banner.actions, id: \.self) { action in
                Button(action.title) { perform(action) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var color: Color {
        switch banner.severity {
        case .error: return StateStyle.tint(for: .error)
        case .warning: return StateStyle.tint(for: .waitingInput)
        case .info: return Color.accentColor
        }
    }
}
