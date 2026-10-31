import Testing
@testable import AgentDock

@MainActor
struct ClaudeCLIInstallerTests {
    @Test func installingShowsBusyStateAndRejectsOverlappingActions() async {
        let model = ControlCenterModel()
        await model.installClaudeCLI {
            await MainActor.run {
                #expect(model.isInstallingClaudeCLI)
                #expect(model.providerActionInProgress)
            }
            await model.installClaudeCLI {
                Issue.record("Overlapping CLI installation must not start")
                return "unexpected"
            }
            return "2.1.999 (Claude Code)"
        }
        #expect(!model.isInstallingClaudeCLI)
        #expect(!model.providerActionInProgress)
        #expect(model.notice?.title == "Claude Code installed")
        #expect(model.notice?.message.contains("2.1.999") == true)
        #expect(model.completedSetupProviders.isEmpty)
    }

    @Test func installationFailureRestoresControlsAndAllowsRetry() async {
        let model = ControlCenterModel()
        await model.installClaudeCLI { throw IntegrationError.message("Fixture failure") }
        #expect(!model.isInstallingClaudeCLI)
        #expect(!model.providerActionInProgress)
        #expect(model.notice?.title == "Couldn’t install Claude Code")
        await model.installClaudeCLI { "2.1.999 (Claude Code)" }
        #expect(model.notice?.title == "Claude Code installed")
    }
}
