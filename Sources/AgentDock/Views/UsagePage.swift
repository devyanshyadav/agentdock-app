import SwiftUI

@MainActor
struct UsagePage: View {
    @ObservedObject var model: ControlCenterModel
    @ObservedObject private var store = UsageStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Usage")
                            .font(.agentHeading(size: 19, weight: .bold))
                        Text("Subscription limits and reported session usage.")
                            .font(.agentSans(size: 11.5))
                            .foregroundStyle(AgentTheme.mutedForeground)
                    }
                    Spacer()
                    if model.providers.contains(where: { $0.detected && store.canRefresh($0.id) }) {
                        Pushable3DButton(variant: .secondary) {
                            Task { await refresh(force: true) }
                        } content: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh")
                            }
                            .font(.agentSans(size: 11, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                        .disabled(!store.refreshing.isEmpty)
                        .help("Refresh local allowances and OpenCode statistics. Session reports update from native events.")
                    }
                }

                ForEach(model.providers) { report in
                    ProviderUsageCard(model: model, store: store, report: report)
                }

                Text("Values are reported by your agents, not a bill. Missing figures stay unavailable. Observed tokens cover retained messages received while AgentDock is running.")
                    .font(.agentSans(size: 10.5))
                    .foregroundStyle(AgentTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .task { await refresh(force: false) }
    }

    private func refresh(force: Bool) async {
        model.refresh()
        await store.refresh(model.providers.filter(\.detected).map(\.id), force: force)
    }
}

@MainActor
private struct ProviderUsageCard: View {
    @ObservedObject var model: ControlCenterModel
    @ObservedObject var store: UsageStore
    let report: ControlCenterModel.ProviderReport
    @State private var selectedSession = ""

    private var snapshot: UsageSnapshot { store.snapshots[report.id] ?? UsageSnapshot() }
    private var sessions: [SessionUsage] { store.sessions[report.id] ?? [] }
    private var session: SessionUsage? { sessions.first { $0.id == selectedSession } ?? sessions.first }

    var body: some View {
        AgentGroupedCard {
            AgentGroupedRow(position: report.detected ? .top : .single) {
                HStack(spacing: 10) {
                    ProviderAppIconTile(provider: report.id.rawValue, name: report.id.displayName, size: 32, isInteractive: false)
                    Text(report.id.displayName)
                        .font(.agentHeading(size: 14, weight: .semibold))
                    Spacer()
                    if store.refreshing.contains(report.id) {
                        ProgressView().controlSize(.small)
                    } else if !report.detected {
                        AgentStatusBadge(text: "Not installed", isReady: false)
                        if report.id == .claude { InstallClaudeCLIButton(model: model) }
                    } else if let date = snapshot.updatedAt {
                        Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.agentSans(size: 10))
                            .foregroundStyle(AgentTheme.mutedForeground)
                    }
                }
            }

            if report.detected {
                let showOpenCodeStats = report.id == .opencode && snapshot.statistics != nil
                let showCodexAnalytics = report.id == .codex && snapshot.analytics != nil
                let showLimitsRow = !showOpenCodeStats || !snapshot.windows.isEmpty || snapshot.message != nil
                let hasSessionRow = session != nil

                if showLimitsRow {
                    AgentGroupedRow(position: (showOpenCodeStats || showCodexAnalytics || hasSessionRow) ? .middle : .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(snapshot.report == nil ? "Account limits" : "CLI report · new session")
                                .font(.agentSans(size: 12, weight: .semibold))
                            if let report = snapshot.report {
                                Text(report)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if snapshot.windows.isEmpty {
                                Text(availability)
                                    .font(.agentSans(size: 11))
                                    .foregroundStyle(AgentTheme.mutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                ForEach(snapshot.windows) { window in
                                    UsageWindowRow(window: window)
                                }
                            }
                            if let message = snapshot.message {
                                Text(message)
                                    .font(.agentSans(size: 10.5))
                                    .foregroundStyle(AgentTheme.warning)
                            }
                            HStack(spacing: 14) {
                                if let url = usageURL {
                                    Link(destination: url) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "arrow.up.right")
                                            Text(report.id == .cursor ? "Open usage dashboard" : "Documentation")
                                        }
                                    }
                                }
                            }
                            .font(.agentSans(size: 11, weight: .medium))
                        }
                    }
                }

                if report.id == .codex, let analytics = snapshot.analytics {
                    AgentGroupedRow(position: hasSessionRow ? .middle : .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Usage analytics")
                                    .font(.agentSans(size: 12, weight: .semibold))
                                if let plan = analytics.planType, !plan.isEmpty {
                                    Text(plan.capitalized)
                                        .font(.agentSans(size: 10, weight: .semibold))
                                        .foregroundStyle(AgentTheme.mutedForeground)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(AgentTheme.mutedForeground.opacity(0.12), in: Capsule())
                                }
                            }
                            codexAnalyticsMetrics(analytics)
                        }
                    }
                }

                if report.id == .opencode, let statistics = snapshot.statistics {
                    AgentGroupedRow(position: hasSessionRow ? .middle : .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(statistics.period.map { "\($0.start.formatted(date: .abbreviated, time: .omitted)) – \($0.end.formatted(date: .abbreviated, time: .omitted)) · all projects" } ?? "Usage totals")
                                .font(.agentSans(size: 12, weight: .semibold))
                            usageMetrics(statistics.usage)
                            if let count = statistics.sessions {
                                Text("\(count.formatted()) sessions · reported by OpenCode stats")
                                    .font(.agentSans(size: 10))
                                    .foregroundStyle(AgentTheme.mutedForeground)
                            }
                        }
                    }
                }

                if let session {
                    AgentGroupedRow(position: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(session.observed ? "Observed session usage" : "Session usage")
                                    .font(.agentSans(size: 12, weight: .semibold))
                                Spacer()
                                if sessions.count > 1 {
                                    Picker("Session", selection: Binding(
                                        get: { selectedSession },
                                        set: { selectedSession = $0 }
                                    )) {
                                        Text("Latest session").tag("")
                                        ForEach(sessions) { item in
                                            Text(String(item.id.suffix(12))).tag(item.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 160)
                                }
                            }
                            usageMetrics(session)
                        }
                    }
                }
            }
        }
    }

    private func codexAnalyticsMetrics(_ analytics: CodexAnalytics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 12) {
            if let lifetime = analytics.lifetimeTokens {
                metric("Lifetime tokens", value: formatCompactTokens(lifetime))
            }
            if let peak = analytics.peakDailyTokens {
                metric("Peak daily tokens", value: formatCompactTokens(peak))
            }
            if let longest = analytics.longestTurnSeconds {
                metric("Longest turn", value: formatDuration(longest))
            }
            if let current = analytics.currentStreakDays {
                metric("Current streak", value: "\(current) \(current == 1 ? "day" : "days")")
            }
            if let longestStreak = analytics.longestStreakDays {
                metric("Longest streak", value: "\(longestStreak) \(longestStreak == 1 ? "day" : "days")")
            }
        }
    }

    private func formatCompactTokens(_ count: Double) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard Int(exactly: seconds.rounded(.down)) != nil else { return "Unavailable" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "Unavailable"
    }

    private func usageMetrics(_ usage: SessionUsage) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 12) {
            if let tokens = usage.inputTokens { metric("Input tokens", value: tokens.formatted(.number.precision(.fractionLength(0)))) }
            if let tokens = usage.outputTokens { metric("Output tokens", value: tokens.formatted(.number.precision(.fractionLength(0)))) }
            if let tokens = usage.cacheReadTokens { metric("Cache read", value: tokens.formatted(.number.precision(.fractionLength(0)))) }
            if let tokens = usage.cacheWriteTokens { metric("Cache write", value: tokens.formatted(.number.precision(.fractionLength(0)))) }
            if let tokens = usage.reasoningTokens { metric("Reasoning tokens", value: tokens.formatted(.number.precision(.fractionLength(0)))) }
            if let cost = usage.costUSD { metric("Reported cost", value: cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))) }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.agentSans(size: 10)).foregroundStyle(AgentTheme.mutedForeground)
            Text(value).font(.agentSans(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    private var availability: String {
        switch report.id {
        case .cursor: return "Sign in to Cursor Agent, then refresh to read your plan and model allowances."
        case .opencode: return "Refresh to load recent usage totals from the OpenCode CLI."
        case .claude: return "Refresh for Claude Code’s native usage report. Existing session figures appear separately as you work."
        case .codex: return "Sign in to Codex, then refresh to read your rate limits."
        case .antigravity: return "Sign in with the agy CLI, then refresh to read your model quotas."
        default: return "This agent has not reported subscription limits."
        }
    }

    private var usageURL: URL? {
        switch report.id {
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=usage")
        case .antigravity: return URL(string: "https://antigravity.google/docs/cli/commands/usage")
        case .claude: return URL(string: "https://code.claude.com/docs/en/commands")
        case .opencode: return URL(string: "https://opencode.ai/v2/docs/providers/")
        default: return report.integration.documentationURL(for: .activity)
        }
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title)
                Spacer()
                Text("\(window.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used").monospacedDigit()
            }
            .font(.agentSans(size: 11, weight: .medium))
            ProgressView(value: min(window.usedPercent, 100), total: 100)
                .tint(window.usedPercent >= 100 ? AgentTheme.warning : AgentTheme.primary)
                .accessibilityLabel(window.title)
                .accessibilityValue("\(window.usedPercent.formatted()) percent used")
            if let reset = window.resetsAt {
                Text(reset <= Date() ? "Reset time passed · refresh for current usage" : "Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .font(.agentSans(size: 10))
                    .foregroundStyle(AgentTheme.mutedForeground)
            }
        }
    }
}
