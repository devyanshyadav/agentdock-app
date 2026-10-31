import SwiftUI

@MainActor
struct InstallClaudeCLIButton: View {
    @ObservedObject var model: ControlCenterModel

    var body: some View {
        Pushable3DButton(variant: .secondary, cornerRadius: AgentTheme.radiusXs) {
            Task { await model.installClaudeCLI() }
        } content: {
            HStack(spacing: 5) {
                if model.isInstallingClaudeCLI { ProgressView().controlSize(.small) }
                Text(model.isInstallingClaudeCLI ? "Installing…" : "Install CLI")
                    .font(.agentSans(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
        }
        .disabled(model.providerActionInProgress)
        .help("Install the latest Claude Code CLI from Anthropic. Sign in afterward in Terminal.")
        .accessibilityLabel(model.isInstallingClaudeCLI ? "Installing Claude Code CLI" : "Install latest Claude Code CLI")
    }
}
