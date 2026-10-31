import SwiftUI
import ServiceManagement

/// First-run guidance styled with the application's unified connected-tile design system.
@MainActor
struct OnboardingView: View {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, providers, finish, success
        var id: Self { self }
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .providers: return "Your agents"
            case .finish: return "Preferences"
            case .success: return "Ready"
            }
        }
        var heading: String {
            switch self {
            case .welcome: return "Your agents.\nWithin reach."
            case .providers: return "Connect the agents\non your Mac."
            case .finish: return "Ready when\nyou are."
            case .success: return "Hurrah!\nYou’re all set."
            }
        }
        var detail: String {
            switch self {
            case .welcome: return "Follow your coding agents from the notch. Know when they need you."
            case .providers: return "Follow their progress and know when they need your attention."
            case .finish: return "Choose how AgentDock fits into your day."
            case .success: return "Your coding agents, within reach."
            }
        }
    }

    @ObservedObject var model: ControlCenterModel
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step
    @State private var providersChecked = false
    let onFinish: () -> Void

    init(model: ControlCenterModel, initialStep: Step = .welcome,
         onFinish: @escaping () -> Void) {
        self.model = model
        self._step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    private var wallpaperImage: NSImage? {
        NSImage(named: NSImage.Name("wallpaper"))
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Ambient Top Mesh Glow Background
            meshGlowBackground

            VStack(spacing: 0) {
                // Drag Region matching ControlCenterView
                HStack {
                    Spacer()
                }
                .frame(height: 38)
                .contentShape(Rectangle())

                // Main Content Area: Free Floating Sidebar + Right Content Canvas
                HStack(spacing: 0) {
                    sidebarView
                        .frame(width: 236)
                        .padding(.leading, 18)
                        .padding(.bottom, 18)
                        .padding(.trailing, 8)

                    // Right Main Content Canvas
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                introduction
                                stepContent
                            }
                            .frame(maxWidth: 540, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 14)
                            .padding(.bottom, 24)
                            .id(step)
                        }

                        footer
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(AgentTheme.background)
        .ignoresSafeArea(.all)
        .onAppear {
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: step)
    }

    // MARK: - Ambient Mesh Glow Background (Same as app, anchored to top)
    private var meshGlowBackground: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                // Responsive Primary Radiant Center at Top
                RadialGradient(
                    colors: [
                        AgentTheme.primary.opacity(0.35),
                        AgentTheme.primary.opacity(0.12),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 20,
                    endRadius: max(proxy.size.width * 0.50, 240)
                )
                .frame(width: proxy.size.width, height: 320)
                .blur(radius: 60)

                // Warm Orange/Amber accent glow (left side, matching main app)
                Circle()
                    .fill(Color(red: 255 / 255, green: 130 / 255, blue: 45 / 255).opacity(0.20))
                    .frame(width: min(proxy.size.width * 0.45, 280), height: min(proxy.size.width * 0.45, 280))
                    .offset(x: -proxy.size.width * 0.22, y: -60)
                    .blur(radius: 65)

                // Tech Blue / Agent Blue accent glow (right side, matching main app)
                Circle()
                    .fill(AgentTheme.agentBlue.opacity(0.18))
                    .frame(width: min(proxy.size.width * 0.45, 280), height: min(proxy.size.width * 0.45, 280))
                    .offset(x: proxy.size.width * 0.22, y: -40)
                    .blur(radius: 65)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Free Floating Sidebar (No tile background or border)
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header: App Icon & Name
            HStack(spacing: 12) {
                AppLogoView(size: 36, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AgentDock")
                        .font(.agentHeading(size: 16.5, weight: .semibold))
                        .foregroundColor(AgentTheme.foreground)
                    Text("Quick setup")
                        .font(.agentSans(size: 10.5, weight: .medium))
                        .foregroundColor(AgentTheme.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)

            // Step List
            VStack(spacing: 6) {
                ForEach(Step.allCases) { item in
                    let isCurrent = item == step
                    let isCompleted = item.rawValue < step.rawValue

                    Button {
                        if item.rawValue <= step.rawValue {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                step = item
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                if isCompleted {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(AgentTheme.success)
                                } else if isCurrent {
                                    Circle()
                                        .fill(
                                            AgentTheme.dynamic(
                                                light: (14, 42, 115),
                                                dark: (18, 50, 140)
                                            )
                                        )
                                        .frame(width: 7.5, height: 7.5)
                                } else {
                                    Circle()
                                        .stroke(AgentTheme.mutedForeground.opacity(0.35), lineWidth: 1.5)
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .frame(width: 16, height: 16)

                            Text(item.title)
                                .font(.agentSans(size: 13, weight: isCurrent ? .bold : .medium))
                                .foregroundColor(isCurrent ? AgentTheme.sidebarPrimaryForeground : AgentTheme.foreground.opacity(item.rawValue <= step.rawValue ? 0.85 : 0.45))

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7.5)
                        .frame(maxWidth: .infinity)
                        .background(
                            isCurrent ?
                                AnyView(
                                    RoundedRectangle(cornerRadius: AgentTheme.radiusSm)
                                        .fill(
                                            LinearGradient(
                                                colors: [AgentTheme.sidebarPrimary, AgentTheme.sidebarPrimary.opacity(0.88)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: AgentTheme.radiusSm)
                                                .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.8)
                                        )
                                ) :
                                AnyView(Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: AgentTheme.radiusSm))
                    }
                    .buttonStyle(.plain)
                    .disabled(item.rawValue > step.rawValue)
                }
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Introduction Header
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(step.rawValue + 1) of \(Step.allCases.count)  ·  \(step.title.uppercased())")
                .font(.agentSans(size: 10, weight: .semibold))
                .foregroundColor(AgentTheme.primary)
            Text(step.heading)
                .font(.instrumentSerif(size: 38))
                .foregroundColor(AgentTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(step.detail)
                .font(.agentSans(size: 12))
                .foregroundColor(AgentTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step Contents
    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome: welcome
        case .providers: providers
        case .finish: finishingTouches
        case .success: success
        }
    }

    // Step 1: Welcome with Monterey Notch Preview Canvas
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            let previewGeometry = NotchGeometry.current(
                displayID: preferences.displayID,
                showsBottomText: preferences.showsBottomText,
                compactness: preferences.notchCompactness,
                style: preferences.notchStyle
            )

            AgentGroupedCard {
                AgentGroupedRow(position: .top, paddingVertical: 12, paddingHorizontal: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            AppIcon(.preview)
                                .foregroundColor(AgentTheme.agentBlue)
                            Text("Agent activity at a glance")
                                .font(.agentHeading(size: 12.5, weight: .semibold))
                                .foregroundColor(AgentTheme.foreground)
                            Spacer()
                            Text("Preview")
                                .font(.agentSans(size: 10, weight: .medium))
                                .foregroundColor(AgentTheme.mutedForeground)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(AgentTheme.muted))
                        }

                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 130)
                            .background {
                                if let wallpaper = wallpaperImage {
                                    Image(nsImage: wallpaper)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.85, green: 0.35, blue: 0.40),
                                            Color(red: 0.50, green: 0.20, blue: 0.55),
                                            Color(red: 0.20, green: 0.25, blue: 0.60)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                }
                            }
                            .overlay(alignment: .top) {
                                NotchPillView(
                                    geometry: previewGeometry,
                                    previewText: "Reviewing your changes"
                                )
                                .allowsHitTesting(false)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: AgentTheme.radiusSm, style: .continuous))
                            .allowsHitTesting(false)
                    }
                }

                AgentGroupedRow(position: .bottom, paddingVertical: 12, paddingHorizontal: 14) {
                    featureRow(
                        .activity,
                        title: "Keep your agents in sight",
                        detail: "See live progress and know when an agent needs your attention."
                    )
                }

            }
        }
    }

    // Step 3: Detected Providers
    private var providers: some View {
        VStack(alignment: .leading, spacing: 14) {
            let detected = model.providers.filter(\.detected)
            if detected.isEmpty {
                AgentGroupedCard {
                    AgentGroupedRow(position: .single, paddingVertical: 16, paddingHorizontal: 14) {
                        featureRow(
                            .processor,
                            title: "No agents found yet",
                            detail: "Install Claude Code, Cursor, Codex, Antigravity, or OpenCode, then connect it in AgentDock."
                        )
                    }
                }
            } else {
                AgentGroupedCard {
                    ForEach(Array(detected.enumerated()), id: \.element.id) { index, report in
                        let position: GroupedRowPosition = detected.count == 1 ? .single : (index == 0 ? .top : (index == detected.count - 1 ? .bottom : .middle))
                        let isConnected = report.installation == .configured

                        AgentGroupedRow(position: position, paddingVertical: 12, paddingHorizontal: 14) {
                            HStack(spacing: 12) {
                                ProviderAppIconTile(
                                    provider: report.id.rawValue,
                                    name: report.id.displayName,
                                    size: 28,
                                    isInteractive: false
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(report.id.displayName)
                                        .font(.agentHeading(size: 13.5, weight: .semibold))
                                        .foregroundColor(AgentTheme.foreground)
                                    Text(isConnected ? "Activity tracking ready" : "Detected on this Mac")
                                        .font(.agentSans(size: 10.5))
                                        .foregroundColor(AgentTheme.mutedForeground)
                                }

                                Spacer()

                                if model.activeSetupProvider == report.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    AgentStatusBadge(text: providerStatus(report), isReady: isConnected)
                                }
                            }
                        }
                    }
                }
            }

            if let message = model.setupProgress ?? model.setupMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundColor(AgentTheme.foreground)
                    Text(message)
                        .font(.agentSans(size: 11))
                        .foregroundColor(AgentTheme.mutedForeground)
                }
            }
        }
    }

    // Preferences / Finishing Touches
    private var finishingTouches: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentGroupedCard {
                AgentGroupedRow(position: .top, paddingVertical: 12, paddingHorizontal: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { enabled in
                            Task { await model.setLaunchAtLogin(enabled) }
                        })) {
                            Text("Launch AgentDock at login")
                                .font(.agentSans(size: 12, weight: .medium))
                        }
                        .disabled(model.updatingLogin)

                        if model.loginStatus == .requiresApproval {
                            Pushable3DButton(variant: .warning, cornerRadius: AgentTheme.radiusXs) {
                                SMAppService.openSystemSettingsLoginItems()
                            } content: {
                                Text("Approve in Login Items…")
                                    .font(.agentSans(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4.5)
                            }
                        }
                    }
                }

                AgentGroupedRow(position: .bottom, paddingVertical: 12, paddingHorizontal: 14) {
                    Toggle(isOn: $preferences.notchEnabled) {
                        Text("Show agent activity in the notch")
                            .font(.agentSans(size: 12, weight: .medium))
                    }
                }

            }
        }
    }

    // Success
    private var success: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentGroupedCard {
                AgentGroupedRow(position: .single, paddingVertical: 24, paddingHorizontal: 18) {
                    HStack(spacing: 16) {
                        Image(systemName: "checkmark.seal.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .foregroundColor(AgentTheme.success)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("You're all set!")
                                .font(.agentHeading(size: 15, weight: .semibold))
                                .foregroundColor(AgentTheme.foreground)

                            Text("Connect more agents or customize your notch anytime in Settings.")
                                .font(.agentSans(size: 11.5))
                                .foregroundColor(AgentTheme.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer Navigation Bar
    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome && step != .success {
                Pushable3DButton(
                    variant: .ghost,
                    cornerRadius: AgentTheme.radiusSm
                ) {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                } content: {
                    Text("Back")
                        .font(.agentSans(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .disabled(model.providerActionInProgress || model.updatingLogin)
            }

            Spacer()

            Pushable3DButton(
                variant: .primary,
                cornerRadius: AgentTheme.radiusSm
            ) {
                if needsProviderSetup {
                    Task {
                        await model.setUpDetectedProviders()
                        providersChecked = true
                    }
                } else if step == .success {
                    onFinish()
                } else {
                    step = Step(rawValue: step.rawValue + 1) ?? .success
                }
            } content: {
                HStack(spacing: 6) {
                    if needsProviderSetup {
                        AppIcon(.connect, size: 16)
                    }
                    Text(primaryActionTitle)
                        .font(.agentSans(size: 12.5, weight: .bold))
                    if step != .success && !needsProviderSetup {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 7.5)
            }
            .disabled(model.providerActionInProgress || model.updatingLogin)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color.clear)
    }

    private var needsProviderSetup: Bool {
        step == .providers && !providersChecked && model.providers.contains(where: \.detected)
    }

    private var primaryActionTitle: String {
        if step == .success { return "Open AgentDock" }
        if step == .welcome { return "Get started" }
        if needsProviderSetup { return model.isSettingUp ? "Connecting…" : "Connect agents" }
        return "Continue"
    }

    private func providerStatus(_ report: ControlCenterModel.ProviderReport) -> String {
        if model.setupErrors[report.id] != nil { return "Needs attention" }
        return report.installation == .configured ? "Connected" : "Not connected"
    }

    private func featureRow(_ icon: AppIcon.Name, title: String, detail: String, iconColor: Color = AgentTheme.primary) -> some View {
        HStack(spacing: 12) {
            AppIcon(icon)
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.agentSans(size: 12, weight: .semibold))
                    .foregroundColor(AgentTheme.foreground)
                Text(detail)
                    .font(.agentSans(size: 11))
                    .foregroundColor(AgentTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
