import Foundation
import Testing
@testable import AgentDock

struct AgentCommandTests {
    @Test func codexWaitsForInitializationAndKeepsLimitsWhenAnalyticsAreUnsupported() async throws {
        let script = #"""
        read -r initialize
        if read -r -t 0.05 premature; then exit 3; fi
        printf '%s\n' '{"id":1,"result":{}}'
        read -r initialized
        read -r limits
        printf '%s\n' '{"method":"account/updated","params":{}}'
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":300}}}}'
        read -r analytics
        printf '%s\n' '{"id":3,"error":{"code":-32601,"message":"Unsupported"}}'
        """#
        let response = try await AgentCommand.run(executable: "/bin/bash", arguments: ["-c", script]) { try CodexUsageFetcher.query($0) }
        #expect(response.windows.first?.usedPercent == 25)
        #expect(response.analytics == nil)
    }

    @Test func failedInitializationStopsTheExchange() async {
        await #expect(throws: (any Error).self) {
            try await AgentCommand.run(executable: "/bin/bash", arguments: ["-c", #"read -r line; printf '%s\n' '{"id":1,"error":{"message":"Rejected"}}'"#]) { try CodexUsageFetcher.query($0) }
        }
    }

    @Test func closedInputThrowsWithoutChangingGlobalSignalHandling() async {
        await #expect(throws: (any Error).self) {
            try await AgentCommand.run(executable: "/bin/bash", arguments: ["-c", "exec 0<&-; printf 'ready\\n'; sleep 0.2"]) { session in
                _ = try session.readLine()
                try session.writeLine("request")
                return true
            }
        }
    }

    @Test func timeoutStillBoundsReadsWhenAChildInheritsStdout() async {
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await AgentCommand.run(executable: "/bin/bash", arguments: ["-c", "sleep 1 & exit 0"], timeout: 0.1) { try $0.readAll() }
        }
        #expect(Date().timeIntervalSince(start) < 0.8)
    }

    @Test func cancellationStopsWaitingForOutput() async {
        let task = Task {
            try await AgentCommand.run(executable: "/bin/sleep", arguments: ["2"]) { try $0.readAll() }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func outputLimitAndNonzeroExitAreErrors() async {
        for script in ["exit 2", "head -c 2097153 /dev/zero"] {
            await #expect(throws: (any Error).self) {
                try await AgentCommand.run(executable: "/bin/bash", arguments: ["-c", script]) { try $0.readAll() }
            }
        }
    }
}
