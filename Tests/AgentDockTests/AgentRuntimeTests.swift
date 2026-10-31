import Testing
@testable import AgentDock

@MainActor
struct AgentRuntimeTests {
    @Test func activityServicesStartWithoutActivationAndDoNotDuplicate() {
        var starts = 0
        var stops = 0
        let runtime = AgentRuntime(start: { starts += 1 }, stop: { stops += 1 })
        runtime.start()
        runtime.start()
        #expect(starts == 1)
        #expect(stops == 0)
        runtime.stop()
        runtime.stop()
        #expect(stops == 1)
        runtime.start()
        #expect(starts == 2)
        runtime.stop()
        #expect(stops == 2)
    }

    @Test func stoppingBeforeLaunchDoesNotStopUnstartedServices() {
        var stops = 0
        let runtime = AgentRuntime(start: {}, stop: { stops += 1 })
        runtime.stop()
        #expect(stops == 0)
    }
}
