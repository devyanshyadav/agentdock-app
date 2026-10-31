import SwiftUI

// MARK: - Minimal 5-LED Status Rail & Custom Hover Tooltip
private enum AgentLEDStatus {
    case connected
    case failed(String = "Connection failed")
    case notConnected(String = "Not connected")
    case notFound

    var color: Color {
        switch self {
        case .connected: return AgentTheme.success
        case .failed: return AgentTheme.destructive
        case .notConnected: return Color(red: 145 / 255, green: 150 / 255, blue: 160 / 255)
        case .notFound: return AgentTheme.warning
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .failed(let reason): return reason
        case .notConnected(let reason): return reason
        case .notFound: return "Not installed"
        }
    }
}

/// Dedicated, clean hover tooltip displaying: [Agent Logo] -> [Foreground Dot] -> [Status]
private struct AgentStatusTooltip: View {
    let id: String
    let status: AgentLEDStatus

    var body: some View {
        HStack(spacing: 6) {
            // Agent logo
            if let image = ProviderIconRegistry.fullImage(for: id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                AppIcon(.processor, size: 13)
                    .foregroundColor(AgentTheme.foreground)
            }

            // Foreground bullet dot
            Circle()
                .fill(AgentTheme.foreground.opacity(0.60))
                .frame(width: 3.5, height: 3.5)

            // Status label
            Text(status.label)
                .font(.agentSans(size: 11, weight: .medium))
                .foregroundColor(AgentTheme.foreground)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: AgentTheme.radiusSm, style: .continuous)
                .fill(Color(red: 22 / 255, green: 24 / 255, blue: 29 / 255).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: AgentTheme.radiusSm, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 3)
        )
        .fixedSize()
        .allowsHitTesting(false)
    }
}

struct AgentLEDStatusRail: View {
    let providers: [(id: String, name: String)]
    @ObservedObject var model: ControlCenterModel
    @State private var hoveredId: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            ForEach(providers, id: \.id) { item in
                let report = model.providers.first { $0.id.rawValue == item.id }
                let status = status(for: report)
                let isHovered = hoveredId == item.id

                Button {
                    model.targetedProviderId = item.id
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.page = .providers
                    }
                } label: {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6.5, height: 6.5)
                        .scaleEffect(isHovered ? 1.25 : 1.0)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.name): \(status.label)")
                .onHover { hovering in
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                        if hovering {
                            hoveredId = item.id
                        } else if hoveredId == item.id {
                            hoveredId = nil
                        }
                    }
                }
                .overlay(alignment: .top) {
                    if isHovered {
                        AgentStatusTooltip(id: item.id, status: status)
                            .offset(y: -26)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)).combined(with: .offset(y: 3)),
                                removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .bottom))
                            ))
                            .zIndex(100)
                    }
                }
            }
        }
    }

    private func status(for report: ControlCenterModel.ProviderReport?) -> AgentLEDStatus {
        guard let report else { return .notFound }
        if !report.detected {
            return .notFound
        }

        // When "Connect agents" is running, agents that haven't finished yet stay gray initially
        if model.isSettingUp {
            if !model.completedSetupProviders.contains(report.id) {
                return .notConnected(model.activeSetupProvider == report.id ? "Connecting…" : "Waiting to connect…")
            }
        }

        // Active individual installation or connection check
        if model.activeSetupProvider == report.id || model.installing == report.id {
            return .notConnected("Connecting…")
        }

        // Hook installation failures
        if model.setupErrors[report.id] != nil {
            return .failed("Connection failed")
        }
        // Configured and connected
        if report.installation == .configured {
            return .connected
        }

        // Detected, but not configured yet (initial unconfigured state -> gray)
        return .notConnected("Not connected")
    }
}

