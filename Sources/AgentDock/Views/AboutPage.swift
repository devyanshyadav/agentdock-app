import SwiftUI

// MARK: - About Page (Independent Top-Level Tab)
@MainActor
struct AboutPage: View {
    @ObservedObject var model: ControlCenterModel

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var architecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "Universal"
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Hero Brand Card
                AgentGroupedCard {
                    AgentGroupedRow(position: .single, paddingVertical: 18, paddingHorizontal: 20) {
                        HStack(alignment: .top, spacing: 16) {
                            AppLogoView(size: 52, cornerRadius: 13)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("AgentDock")
                                        .font(.agentHeading(size: 18, weight: .bold))
                                        .foregroundColor(AgentTheme.foreground)

                                    Text("v\(appVersion)")
                                        .font(.agentSans(size: 11, weight: .medium))
                                        .foregroundColor(AgentTheme.mutedForeground)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(Color.white.opacity(0.06))
                                        )
                                }

                                Text("Your agents. Beyond their windows.")
                                    .font(.agentSans(size: 12.5, weight: .medium))
                                    .foregroundColor(AgentTheme.mutedForeground)
                            }
                        }
                    }
                }

                // Section: System
                AgentSettingsSection(
                    title: "System",
                    icon: .system("laptopcomputer")
                ) {
                    AgentGroupedRow(position: .single) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Operating system")
                                    .font(.agentSans(size: 12, weight: .medium))
                                Text(osVersion)
                                    .font(.agentSans(size: 11))
                                    .foregroundColor(AgentTheme.mutedForeground)
                            }
                            Spacer()
                            Text(architecture)
                                .font(.agentSans(size: 11, weight: .medium))
                                .foregroundColor(AgentTheme.foreground)
                        }
                    }
                }

                AgentSettingsSection(
                    title: "Updates",
                    icon: .system("arrow.down.circle")
                ) {
                    AgentGroupedRow(position: .single) {
                        HStack {
                            Text("AgentDock \(AppVersion.short)")
                                .font(.agentSans(size: 12))
                                .foregroundStyle(AgentTheme.mutedForeground)
                            Spacer()
                            Pushable3DButton(variant: .secondary, cornerRadius: AgentTheme.radiusXs) {
                                UpdateService.shared.checkForUpdates()
                            } content: {
                                Text("Check for Updates…")
                                    .font(.agentSans(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4.5)
                            }
                        }
                    }
                }

                // Section: Privacy & Support
                AgentSettingsSection(
                    title: "Privacy & support",
                    icon: .custom(.shieldCheck)
                ) {
                    AgentGroupedRow(position: .top) {
                        HStack(alignment: .top, spacing: 10) {
                            AppIcon(.shieldCheck, size: 18)
                                .foregroundColor(AgentTheme.success)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Activity stays on your Mac")
                                    .font(.agentSans(size: 12, weight: .semibold))
                                    .foregroundColor(AgentTheme.foreground)
                                Text("No activity uploads or analytics tracking.")
                                    .font(.agentSans(size: 11))
                                    .foregroundColor(AgentTheme.mutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    AgentGroupedRow(position: .bottom) {
                        HStack(spacing: 8) {
                            Pushable3DButton(variant: .secondary, cornerRadius: AgentTheme.radiusXs) {
                                model.copyDiagnostics()
                            } content: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 10))
                                    Text(model.diagnosticsCopied ? "Diagnostics copied" : "Copy diagnostics")
                                        .font(.agentSans(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                            }

                            Link(destination: AgentBranding.productURL) {
                                HStack(spacing: 4) {
                                    Text("Website")
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8.5))
                                }
                                .font(.agentSans(size: 11, weight: .semibold))
                                .foregroundColor(AgentTheme.agentBlue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                            }
                        }
                    }
                }

                AgentSettingsSection(
                    title: "More productive apps",
                    icon: .custom(.productiveApps)
                ) {
                    AgentGroupedRow(position: .single) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("From \(AgentBranding.publisherName)")
                                    .font(.agentSans(size: 12, weight: .semibold))
                                    .foregroundColor(AgentTheme.foreground)
                                Text("Explore other native Mac apps built for focus and flow.")
                                    .font(.agentSans(size: 11))
                                    .foregroundColor(AgentTheme.mutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Link(destination: AgentBranding.publisherURL) {
                                HStack(spacing: 4) {
                                    Text("siliconapps.dev")
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 8.5))
                                }
                                .font(.agentSans(size: 11, weight: .semibold))
                                .foregroundColor(AgentTheme.agentBlue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: AgentTheme.radiusXs, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 0) {
                    Text("Made with ❤️ by ")
                    Link(AgentBranding.authorName, destination: AgentBranding.authorURL)
                }
                .font(.agentSans(size: 11))
                .foregroundStyle(AgentTheme.mutedForeground)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }
}
