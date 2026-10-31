import Testing
@testable import AgentDock

struct AgentSoundTests {
    @Test func startsEveryNewTurnFromInactiveState() {
        for inactive: AgentStatus? in [nil, .idle, .completed, .error] {
            #expect(AgentSoundService.event(from: inactive, to: .working) == .start)
        }
    }

    @Test func progressAndInFlightStepsDoNotReplayStart() {
        #expect(AgentSoundService.event(from: .working, to: .working) == nil)
        #expect(AgentSoundService.event(from: .waitingApproval, to: .working) == nil)
        #expect(AgentSoundService.event(from: .observed, to: .working) == nil)
    }

    @Test func inputRequestHasPriorityAndDuplicateUpdatesAreSilent() {
        #expect(AgentSoundService.event(from: nil, to: .waitingApproval) == .question)
        #expect(AgentSoundService.event(from: .working, to: .waitingApproval) == .question)
        #expect(AgentSoundService.event(from: .waitingApproval, to: .waitingApproval) == nil)
    }

    @Test func terminalCuesRequireARealLiveSession() {
        for terminal in [AgentStatus.idle, .completed, .error] {
            for live in [AgentStatus.working, .waitingApproval] {
                #expect(AgentSoundService.event(from: live, to: terminal) == .stop)
            }
            for inactive: AgentStatus? in [nil, .idle, .observed, .completed, .error] {
                #expect(AgentSoundService.event(from: inactive, to: terminal) == nil)
            }
        }
        #expect(AgentSoundService.event(from: .working, to: .observed) == nil)
    }
}
