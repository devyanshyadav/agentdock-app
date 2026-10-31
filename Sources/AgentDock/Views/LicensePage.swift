import SwiftUI

@MainActor
struct LicensePage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("It’s on us.")
                        .font(.instrumentSerif(size: 38))
                        .foregroundStyle(AgentTheme.foreground)
                    Text("Free and open source. No license key required.")
                        .font(.agentSans(size: 12))
                        .foregroundStyle(AgentTheme.mutedForeground)
                }

                AgentGroupedCard {
                    AgentGroupedRow(position: .single) {
                        HStack(spacing: 14) {
                            AppIcon(.system("gift"), size: 28)
                                .foregroundStyle(AgentTheme.primary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("All features included")
                                    .font(.agentHeading(size: 13, weight: .semibold))
                                Text("No activation. No subscription. Just your agents, within reach.")
                                    .font(.agentSans(size: 11))
                                    .foregroundStyle(AgentTheme.mutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            AgentStatusBadge(text: "Free", isReady: true)
                        }
                    }
                }

                AgentSettingsSection(
                    title: "Built to share",
                    icon: .custom(.openSource)
                ) {
                    AgentGroupedRow(position: .top) {
                        Text("AgentDock is a \(AgentBranding.publisherName) app. Source and issues live on GitHub.")
                            .font(.agentSans(size: 11.5))
                            .foregroundStyle(AgentTheme.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    AgentGroupedRow(position: .bottom) {
                        HStack(spacing: 16) {
                            Link(destination: AgentBranding.repositoryURL) {
                                HStack(spacing: 6) {
                                    AppIcon(.github, size: 14)
                                    Text("View on GitHub")
                                }
                            }
                            Link("Report an issue", destination: AgentBranding.repositoryURL.appendingPathComponent("issues"))
                            Spacer(minLength: 0)
                        }
                        .font(.agentSans(size: 11, weight: .semibold))
                        .foregroundStyle(AgentTheme.agentBlue)
                    }
                }

                Text("MIT licensed. \(AgentBranding.copyrightLine)")
                    .font(.agentSans(size: 11))
                    .foregroundStyle(AgentTheme.mutedForeground)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(28)
        }
    }
}
