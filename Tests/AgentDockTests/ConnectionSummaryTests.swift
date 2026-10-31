import Testing
@testable import AgentDock

@MainActor
struct ConnectionSummaryTests {
    private func report(_ kind: AgentKind, detected: Bool = true,
                        installation: ProviderIntegration.Installation = .configured) -> ControlCenterModel.ProviderReport {
        .init(integration: ProviderIntegration(kind: kind), detected: detected, installation: installation)
    }

    @Test func failedSetupDoesNotCountAsConnected() {
        let reports = [report(.claude), report(.codex), report(.cursor), report(.antigravity), report(.opencode)]
        #expect(ControlCenterModel.connectionSummary(for: reports, errors: [.codex: "Setup failed"])
            == "5 agents detected · 4 connected · 1 failed")
    }

    @Test func staleConfigurationDoesNotCountAnUninstalledAgentAsConnected() {
        let reports = [report(.claude), report(.codex, detected: false)]
        #expect(ControlCenterModel.connectionSummary(for: reports)
            == "1 agent detected · 1 connected · 1 not installed")
    }

    @Test func unconfiguredAgentsAreNotReportedAsFailures() {
        let reports = [report(.claude, installation: .missing), report(.codex, installation: .repair)]
        #expect(ControlCenterModel.connectionSummary(for: reports) == "2 agents detected · 2 not connected")
    }

    @Test func emptySnapshotOmitsZeroStatusCounts() {
        #expect(ControlCenterModel.connectionSummary(for: []) == "0 agents detected")
    }
}
