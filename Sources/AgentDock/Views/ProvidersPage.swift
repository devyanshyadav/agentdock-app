import SwiftUI

// MARK: - Provider Setup Hero Action
@MainActor
private struct ProviderSetupAction: View {
    @ObservedObject var model: ControlCenterModel

    var body: some View {
        Pushable3DButton(
            variant: .primary,
            cornerRadius: AgentTheme.radiusSm
        ) {
            Task { await model.setUpDetectedProviders(presentResult: true) }
        } content: {
            HStack(spacing: 8) {
                if model.isSettingUp {
                    ProgressView().controlSize(.small)
                } else {
                    AppIcon(.connect, size: 16)
                }
                Text(model.isSettingUp ? "Connecting…" : "Connect agents")
                    .font(.agentSans(size: 12.5, weight: .bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .disabled(model.providerActionInProgress)
    }
}

// MARK: - Providers Page
@MainActor
struct ProvidersPage: View {
    @ObservedObject var model: ControlCenterModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // Header Banner
                    AgentGroupedCard {
                        AgentGroupedRow(position: .single, paddingVertical: 14, paddingHorizontal: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 16) {
                                    Text("Bring your agents together")
                                        .font(.agentHeading(size: 15, weight: .semibold))
                                        .foregroundColor(AgentTheme.cardForeground)
                                    Spacer(minLength: 0)
                                    ProviderSetupAction(model: model)
                                        .fixedSize()
                                }

                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(AgentTheme.warning)
                                        .padding(.top, 2)
                                    Text("Keep your agent’s CLI, IDE, or app up to date. Older versions may be incompatible. Use the link beside each agent for update instructions.")
                                        .font(.agentSans(size: 11.5))
                                        .foregroundStyle(AgentTheme.mutedForeground)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    // Detected Providers List
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your agents")
                                .font(.agentHeading(size: 14, weight: .semibold))
                                .foregroundColor(AgentTheme.foreground)

                            Text("Manage activity tracking for your agents.")
                                .font(.agentSans(size: 11.5))
                                .foregroundColor(AgentTheme.mutedForeground)
                        }

                        let detected = model.providers.filter(\.detected)
                        if detected.isEmpty {
                            AgentGroupedCard {
                                AgentGroupedRow(position: .single, paddingVertical: 16) {
                                    Text("No agents found yet. Install a supported agent, then connect it here.")
                                        .font(.agentSans(size: 11.5))
                                        .foregroundColor(AgentTheme.mutedForeground)
                                }
                            }
                        } else {
                            AgentGroupedCard {
                                ForEach(Array(detected.enumerated()), id: \.element.id) { index, report in
                                    let position: GroupedRowPosition = detected.count == 1 ? .single : (index == 0 ? .top : (index == detected.count - 1 ? .bottom : .middle))
                                    AgentGroupedRow(
                                        position: position,
                                        paddingVertical: 14,
                                        paddingHorizontal: 16
                                    ) {
                                        ProviderSetupRow(model: model, report: report)
                                            .id(report.id.rawValue)
                                    }
                                }
                            }
                        }
                    }

                    // Other Supported Providers
                    let missing = model.providers.filter { !$0.detected }
                    if !missing.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("More supported agents")
                                    .font(.agentHeading(size: 14, weight: .semibold))
                                    .foregroundColor(AgentTheme.foreground)

                                Text("Install an agent to connect it here.")
                                    .font(.agentSans(size: 11.5))
                                    .foregroundColor(AgentTheme.mutedForeground)
                            }

                            AgentGroupedCard {
                                ForEach(Array(missing.enumerated()), id: \.element.id) { index, report in
                                    let position: GroupedRowPosition = missing.count == 1 ? .single : (index == 0 ? .top : (index == missing.count - 1 ? .bottom : .middle))
                                    AgentGroupedRow(
                                        position: position,
                                        paddingVertical: 14,
                                        paddingHorizontal: 16
                                    ) {
                                        ProviderSetupRow(model: model, report: report)
                                            .id(report.id.rawValue)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .onAppear { revealTarget(using: proxy) }
            .onChange(of: model.targetedProviderId) { _ in revealTarget(using: proxy) }
        }
    }

    private func revealTarget(using proxy: ScrollViewProxy) {
        if let target = model.targetedProviderId { proxy.scrollTo(target, anchor: .top) }
    }
}

// MARK: - Provider Setup
@MainActor
private struct ProviderSetupRow: View {
    @ObservedObject var model: ControlCenterModel
    let report: ControlCenterModel.ProviderReport
    @State private var isNameHovered = false
    @FocusState private var isDocumentationFocused: Bool

    private var activityReady: Bool {
        report.installation == .configured && model.setupErrors[report.id] == nil
    }

    private var help: (message: String, title: String, topic: ProviderIntegration.HelpTopic)? {
        if !report.detected {
            return ("Install \(report.id.displayName), then connect it here.", "Installation guide", .installation)
        }
        if model.setupErrors[report.id] != nil {
            return ("Activity tracking couldn't be set up. Try again or follow the guide.", "Setup help", .activity)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Row: Overview-style Squircle Icon with neutral specular lining, Title & Overall Status Badge
            HStack(spacing: 12) {
                ProviderAppIconTile(
                    provider: report.id.rawValue,
                    name: report.id.displayName,
                    size: 38,
                    isInteractive: false
                )

                HStack(spacing: 4) {
                    Text(report.id.displayName)
                        .font(.agentHeading(size: 14, weight: .semibold))
                        .foregroundColor(AgentTheme.foreground)
                    if let url = report.integration.documentationURL(for: .installation) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(AgentTheme.agentBlue)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                                .opacity(isNameHovered || isDocumentationFocused ? 1 : 0)
                        }
                        .focused($isDocumentationFocused)
                        .help("Open \(report.id.displayName) documentation")
                        .accessibilityLabel("Open \(report.id.displayName) documentation")
                    }
                }
                .contentShape(Rectangle())
                .onHover { isNameHovered = $0 }

                Spacer()

                if model.installing == report.id {
                    ProgressView().controlSize(.small)
                } else if !report.detected {
                    AgentStatusBadge(text: "Not installed", isReady: false)
                    if report.id == .claude { InstallClaudeCLIButton(model: model) }
                } else if activityReady {
                    AgentStatusBadge(text: "Connected", isReady: true)
                } else {
                    AgentStatusBadge(text: "Not connected", isReady: false)
                    Pushable3DButton(
                        variant: .primary,
                        cornerRadius: AgentTheme.radiusXs
                    ) {
                        Task { await model.install(report.integration) }
                    } content: {
                        HStack(spacing: 4) {
                            AppIcon(.connect, size: 14)
                            Text(report.installation == .missing ? "Set up" : "Reconnect")
                                .font(.agentSans(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                    }
                    .disabled(model.providerActionInProgress)
                }
            }

            if report.detected {
                if activityReady && report.id == .codex {
                    let settingsURL = URL(string: "codex://settings")!
                    let canOpenSettings = NSWorkspace.shared.urlForApplication(toOpen: settingsURL) != nil
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10.5))
                            .foregroundColor(AgentTheme.foreground)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(canOpenSettings
                                 ? "In Codex Settings, choose Hooks and approve AgentDock. Then start a new chat."
                                 : "Open /hooks in Codex, approve AgentDock, then start a new chat.")
                                .foregroundColor(AgentTheme.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                            if canOpenSettings {
                                Link("Open Codex settings", destination: settingsURL)
                            }
                        }
                        .font(.agentSans(size: 10.5))
                    }
                    .padding(.top, 2)
                }
            }

            if let help {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11.5))
                        .foregroundColor(AgentTheme.warning)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(help.message)
                            .font(.agentSans(size: 11))
                            .foregroundColor(AgentTheme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = report.integration.documentationURL(for: help.topic) {
                            Link(destination: url) {
                                HStack(spacing: 4) {
                                    Text(help.title)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9))
                                }
                                .font(.agentSans(size: 11, weight: .semibold))
                                .foregroundColor(AgentTheme.agentBlue)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: AgentTheme.radiusXs)
                        .fill(AgentTheme.warning.opacity(0.08))
                )
            }
        }
    }
}

