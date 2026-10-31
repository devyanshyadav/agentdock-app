import Foundation
import Testing
@testable import AgentDock

@Suite(.serialized)
struct OpenCodeHookTests {
    private func snapshot(_ id: String, source: String, started: Double = 1000, turn: Int = 1,
                          sequence: Int, status: AgentStatus, text: String = "") -> [String: Any] {
        ["sessionID": id, "sourceID": source, "sourceStartedAt": started, "turn": turn, "sequence": sequence,
         "status": status.rawValue, "message": text, "model": "provider/model", "environment": "cli"]
    }
    @MainActor private func state(_ id: String) -> AgentStateManager {
        let state = AgentStateManager.shared
        state.beginAgentEvent(agent: .opencode, sessionID: id)
        return state
    }
    @MainActor private func cleanup(_ source: String, ids: [String]) {
        OpenCodeAgentAdapter.shared.consume(["event": "disconnect", "sourceID": source], ownerPID: nil)
        for id in ids { AgentStateManager.shared.removeSession(agent: .opencode, sessionID: id) }
    }

    @Test @MainActor func fullStateRecoversWithoutStartAndSequenceProtectsCompletion() {
        let adapter = OpenCodeAgentAdapter.shared
        let id = "ses_" + UUID().uuidString, source = UUID().uuidString
        defer { cleanup(source, ids: [id]) }
        #expect(adapter.consume(snapshot(id, source: source, sequence: 10, status: .waitingApproval, text: "Question: Which file?"), ownerPID: nil))
        #expect(state(id).status == .waitingApproval)
        #expect(state(id).message == "Question: Which file?")
        adapter.consume(snapshot(id, source: source, sequence: 11, status: .completed), ownerPID: nil)
        adapter.consume(snapshot(id, source: source, sequence: 9, status: .working), ownerPID: nil)
        adapter.consume(snapshot(id, source: source, sequence: 12, status: .working), ownerPID: nil)
        #expect(state(id).status == .completed)
        adapter.consume(snapshot(id, source: source, turn: 2, sequence: 13, status: .working), ownerPID: nil)
        #expect(state(id).status == .working)
        adapter.consume(snapshot(id, source: source, turn: 1, sequence: 99, status: .completed), ownerPID: nil)
        #expect(state(id).status == .working)
    }

    @Test @MainActor func duplicateSnapshotsDoNotPublishAndOlderObserverCannotReplaceCurrentRun() {
        let adapter = OpenCodeAgentAdapter.shared
        let id = "ses_" + UUID().uuidString, old = UUID().uuidString, current = UUID().uuidString
        defer { cleanup(old, ids: []); cleanup(current, ids: [id]) }
        let first = snapshot(id, source: old, sequence: 1, status: .working, text: "Running tests")
        adapter.consume(first, ownerPID: nil)
        let date = adapter.lastActivityDate
        adapter.consume(first, ownerPID: nil)
        #expect(adapter.lastActivityDate == date)
        adapter.consume(snapshot(id, source: current, started: 2000, sequence: 1, status: .working, text: "New observer"), ownerPID: nil)
        adapter.consume(snapshot(id, source: old, sequence: 20, status: .working, text: "Stale observer"), ownerPID: nil)
        #expect(state(id).message == "New observer")
        adapter.consume(["event": "disconnect", "sourceID": old], ownerPID: nil)
        #expect(state(id).status == .working)
        adapter.consume(snapshot(id, source: old, started: 3000, sequence: 21, status: .working), ownerPID: nil)
        #expect(state(id).message == "New observer")
    }

    @Test @MainActor func disconnectIsScopedAndLateTrafficCannotReopenIt() {
        let adapter = OpenCodeAgentAdapter.shared
        let source = UUID().uuidString, otherSource = UUID().uuidString
        let ids = (0..<3).map { _ in "ses_" + UUID().uuidString }
        defer { cleanup(source, ids: Array(ids.prefix(2))); cleanup(otherSource, ids: [ids[2]]) }
        for id in ids.prefix(2) {
            adapter.consume(snapshot(id, source: source, sequence: 1, status: .waitingApproval), ownerPID: nil)
        }
        adapter.consume(snapshot(ids[2], source: otherSource, sequence: 1, status: .working), ownerPID: nil)
        adapter.consume(["event": "disconnect", "sourceID": source], ownerPID: nil)
        #expect(state(ids[0]).status == .idle)
        #expect(state(ids[1]).status == .idle)
        #expect(state(ids[2]).status == .working)
        adapter.consume(snapshot(ids[0], source: source, sequence: 2, status: .working), ownerPID: nil)
        #expect(state(ids[0]).status == .idle)
    }

    @Test @MainActor func validatesSnapshotsAndBoundsDisplayedContent() {
        let adapter = OpenCodeAgentAdapter.shared
        let id = "ses_" + UUID().uuidString, source = UUID().uuidString
        defer { cleanup(source, ids: [id]) }
        #expect(!adapter.consume(snapshot("../../invalid", source: source, sequence: 1, status: .working), ownerPID: nil))
        #expect(!adapter.consume(snapshot(id, source: source, sequence: 0, status: .working), ownerPID: nil))
        var malformed = snapshot(id, source: source, sequence: 1, status: .working)
        malformed["sourceStartedAt"] = -1
        #expect(!adapter.consume(malformed, ownerPID: nil))
        malformed["sourceStartedAt"] = 1000
        malformed["status"] = "unknown"
        #expect(!adapter.consume(malformed, ownerPID: nil))
        adapter.consume(snapshot(id, source: source, sequence: 1, status: .working, text: String(repeating: "x", count: 1_000_000)), ownerPID: nil)
        #expect(state(id).message.count == 240)
    }

    @Test @MainActor func sessionCapacityProtectsLiveWorkAndAllowsCompletedHistoryToBeReused() {
        let adapter = OpenCodeAgentAdapter.shared
        let source = UUID().uuidString
        var retained: [String] = []
        defer { cleanup(source, ids: retained) }
        for _ in 0..<300 {
            let id = "ses_" + UUID().uuidString
            if adapter.consume(snapshot(id, source: source, sequence: 1, status: .working), ownerPID: nil) { retained.append(id) }
        }
        #expect(retained.count == 256)
        for id in retained {
            adapter.consume(snapshot(id, source: source, sequence: 2, status: .completed), ownerPID: nil)
            AgentStateManager.shared.removeSession(agent: .opencode, sessionID: id)
        }
        let id = "ses_" + UUID().uuidString
        #expect(adapter.consume(snapshot(id, source: source, sequence: 3, status: .working), ownerPID: nil))
        retained.append(id)
    }

    @Test func installationIsIdempotentAndPreservesOtherPlugins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.js"), destination = root.appendingPathComponent("agentdock.js")
        let other = root.appendingPathComponent("other.js")
        try Data("new observer".utf8).write(to: source)
        try Data("old observer".utf8).write(to: destination)
        try Data("other plugin".utf8).write(to: other)
        try OpenCodeIntegration.install(destination: destination, source: source)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        try OpenCodeIntegration.install(destination: destination, source: source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == files)
        #expect(try Data(contentsOf: source) == Data(contentsOf: destination))
        #expect(try String(contentsOf: other, encoding: .utf8) == "other plugin")
    }
}
