import SwiftUI

@MainActor
struct ControlCenterView: View {
    @ObservedObject var model: ControlCenterModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        controlCenter
        .background(AgentTheme.background)
        .ignoresSafeArea(.all)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in model.refresh() }
        .alert(item: $model.notice) { notice in
            if notice.offersReconnect {
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("Connect again")) {
                        Task { await model.setUpDetectedProviders(presentResult: true, reconnect: true) }
                    },
                    secondaryButton: .cancel(Text("Done"))
                )
            }
            return Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK")))
        }
    }

    private var controlCenter: some View {
        VStack(spacing: 0) {
            // Native macOS Window Drag & Traffic Light Region
            HStack {
                Spacer()
            }
            .frame(height: 38)
            .contentShape(Rectangle())

            // Main Content Area: Floating Inset Sidebar + Right Canvas
            HStack(spacing: 0) {
                // Modern Floating Inset Sidebar with Connected Google Tiles
                sidebarView
                    .frame(width: 242)
                    .padding(.leading, 18)
                    .padding(.bottom, 18)
                    .padding(.trailing, 8)

                pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page ?? .overview {
        case .overview: OverviewPage(model: model)
        case .providers: ProvidersPage(model: model)
        case .usage: UsagePage(model: model)
        case .settings: AgentSettingsPage(model: model)
        case .license: LicensePage()
        case .about: AboutPage(model: model)
        }
    }

    // MARK: - Left Sidebar (Google Connected Tiles Layout)
    private var sidebarView: some View {
        VStack(spacing: 2.5) {
            sidebarHeaderTile
            sidebarBodyTile
        }
    }

    private var sidebarHeaderTile: some View {
        let shape = UnevenRoundedCornerShape(
            topLeading: 18,
            topTrailing: 18,
            bottomLeading: 4,
            bottomTrailing: 4
        )
        return HStack(spacing: 12) {
            // App Mascot Logo
            AppLogoView(size: 36, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text("AgentDock")
                    .font(.agentHeading(size: 16.5, weight: .semibold))
                    .foregroundColor(AgentTheme.foreground)
                Text("Agent activity")
                    .font(.agentSans(size: 10.5, weight: .medium))
                    .foregroundColor(AgentTheme.mutedForeground)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(AgentTheme.sidebar)
                .overlay(
                    shape
                        .stroke(AgentTheme.sidebarBorder, lineWidth: 0.8)
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.05),
                    radius: colorScheme == .dark ? 8 : 4,
                    x: 0,
                    y: colorScheme == .dark ? 2 : 1
                )
        )
        .clipShape(shape)
    }

    private var sidebarBodyTile: some View {
        let shape = UnevenRoundedCornerShape(
            topLeading: 4,
            topTrailing: 4,
            bottomLeading: 18,
            bottomTrailing: 18
        )
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(ControlCenterModel.Page.allCases) { page in
                        let isSelected = (model.page ?? .overview) == page
                        SidebarTabButton(
                            title: page.rawValue,
                            icon: page.icon,
                            isSelected: isSelected
                        ) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                model.page = page
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)
            }

            // Mini Status Card in Sidebar (Live Agent Activity)
            sidebarActivityCard
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            shape
                .fill(AgentTheme.sidebar)
                .overlay(
                    shape
                        .stroke(AgentTheme.sidebarBorder, lineWidth: 0.8)
                )
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.05),
                    radius: colorScheme == .dark ? 10 : 6,
                    x: 0,
                    y: colorScheme == .dark ? 4 : 2
                )
        )
        .clipShape(shape)
    }

    // MARK: - Mini Sidebar Status Card
    private var sidebarActivityCard: some View {
        let state = model.activity
        let isLive = state.status.isLive
        let isApproval = state.status == .waitingApproval

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isApproval ? AgentTheme.warning : (isLive ? AgentTheme.success : AgentTheme.mutedForeground))
                    .frame(width: 7, height: 7)

                Text(isLive ? state.activeAgent.displayName : "Quiet for now")
                    .font(.agentHeading(size: 11.5, weight: .semibold))
                    .foregroundColor(AgentTheme.foreground)

                Spacer()

                if isLive {
                    Text(isApproval ? "Needs approval" : "Working")
                        .font(.agentSans(size: 9.5, weight: .bold))
                        .foregroundColor(isApproval ? AgentTheme.warning : AgentTheme.success)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(isApproval ? AgentTheme.warning.opacity(0.15) : AgentTheme.success.opacity(0.15))
                        )
                }
            }

            Text(isLive ? (isApproval ? "Needs your approval" : "Working in the background") : "Start a session to see activity.")
                .font(.agentSans(size: 10))
                .foregroundColor(AgentTheme.mutedForeground)
                .lineLimit(1)

            if isLive {
                Pushable3DButton(
                    variant: isApproval ? .warning : .secondary,
                    cornerRadius: AgentTheme.radiusXs
                ) {
                    AgentFocusCoordinator.shared.focusActiveAgent()
                } content: {
                    HStack(spacing: 4) {
                        Image(systemName: isApproval ? "hand.raised.fill" : "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .bold))
                        Text(isApproval ? "Review approval" : "Open agent")
                            .font(.agentSans(size: 10.5, weight: .semibold))
                    }
                    .padding(.vertical, 4.5)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AgentTheme.radiusSm, style: .continuous)
                .fill(AgentTheme.muted)
                .overlay(
                    RoundedRectangle(cornerRadius: AgentTheme.radiusSm, style: .continuous)
                        .strokeBorder(AgentTheme.border, lineWidth: 0.8)
                )
        )
    }
}
