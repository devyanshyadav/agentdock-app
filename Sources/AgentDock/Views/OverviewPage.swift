import SwiftUI

// MARK: - Overview Page (Clean, Minimal Hero Deck)
@MainActor
struct OverviewPage: View {
    @ObservedObject var model: ControlCenterModel
    @ObservedObject private var preferences = AppPreferences.shared
    private var state: ControlCenterModel.Activity { model.activity }

    private let providerDeck: [(id: String, name: String, angle: Double, yOffset: CGFloat)] = [
        ("antigravity", "Antigravity", -11, 14),
        ("claude", "Claude Code", -5.5, 4),
        ("codex", "Codex", 0, -3),
        ("cursor", "Cursor", 5.5, 4),
        ("opencode", "OpenCode", 11, 14)
    ]

    var body: some View {
        ZStack {
            // Ambient Primary Mesh Aura Glow (Expansive to fill sides)
            meshGlowBackground

            // Center Hero Content
            VStack(spacing: 32) {
                Spacer()

                Text("Your agents. Beyond\ntheir windows.")
                    .font(.instrumentSerif(size: 46))
                    .foregroundColor(AgentTheme.foreground)
                    .multilineTextAlignment(.center)

                // Overlapping Provider Icon Fan Deck (Curvier, more compact presentation)
                HStack(spacing: -10) {
                    ForEach(Array(providerDeck.enumerated()), id: \.offset) { index, item in
                        let isConnecting = model.activeSetupProvider?.rawValue == item.id || model.installing?.rawValue == item.id
                        ProviderAppIconTile(
                            provider: item.id,
                            name: item.name,
                            isConnecting: isConnecting,
                            size: 96,
                            onConfigure: {
                                model.targetedProviderId = item.id
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.page = .providers
                                }
                            }
                        )
                        .rotationEffect(.degrees(item.angle))
                        .offset(y: item.yOffset)
                        .zIndex(isConnecting ? 100 : Double(index))
                    }
                }
                .padding(.vertical, 12)

                // Primary actions.
                HStack(spacing: 16) {
                    Pushable3DButton(
                        variant: .primary,
                        cornerRadius: AgentTheme.radiusMd
                    ) {
                        Task { await model.setUpDetectedProviders(presentResult: true) }
                    } content: {
                        HStack(spacing: 9) {
                            if model.isSettingUp {
                                ProgressView().controlSize(.small)
                            } else {
                                AppIcon(.connect, size: 18)
                            }
                            Text(model.isSettingUp ? "Connecting…" : "Connect agents")
                                .font(.agentSans(size: 14, weight: .bold))
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                    .disabled(model.providerActionInProgress)

                    Pushable3DButton(
                        variant: .secondary,
                        cornerRadius: AgentTheme.radiusMd
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            model.page = .providers
                        }
                    } content: {
                        HStack(spacing: 8) {
                            AppIcon(.processor, size: 18)
                            Text("Manage agents")
                                .font(.agentSans(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                    }
                }

                Spacer()

                // Footer status with minimal 5-LED Status Rail
                VStack(spacing: 8) {
                    AgentLEDStatusRail(
                        providers: providerDeck.map { ($0.id, $0.name) },
                        model: model
                    )

                    Group {
                        if let progress = model.setupProgress {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(progress)
                            }
                        } else {
                            Text(model.connectionSummary)
                        }
                    }
                    .font(.agentSans(size: 12))
                    .foregroundColor(AgentTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
                .padding(.bottom, 22)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ambient Mesh Glow Background
    private var meshGlowBackground: some View {
        GeometryReader { proxy in
            ZStack {
                // Responsive Primary Radiant Center
                RadialGradient(
                    colors: [
                        AgentTheme.primary.opacity(0.35),
                        AgentTheme.primary.opacity(0.12),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: max(proxy.size.width * 0.45, 180)
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .blur(radius: 60)

                // Warm Orange/Amber accent glow (left side)
                Circle()
                    .fill(Color(red: 255 / 255, green: 130 / 255, blue: 45 / 255).opacity(0.20))
                    .frame(width: min(proxy.size.width * 0.45, 280), height: min(proxy.size.width * 0.45, 280))
                    .offset(x: -proxy.size.width * 0.22, y: -30)
                    .blur(radius: 65)

                // Tech Blue / Violet accent glow (right side)
                Circle()
                    .fill(AgentTheme.agentBlue.opacity(0.18))
                    .frame(width: min(proxy.size.width * 0.45, 280), height: min(proxy.size.width * 0.45, 280))
                    .offset(x: proxy.size.width * 0.22, y: 30)
                    .blur(radius: 65)
            }
        }
        .allowsHitTesting(false)
    }
}

