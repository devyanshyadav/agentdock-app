import Foundation
import Testing
@testable import AgentDock

@Suite(.serialized)
struct CursorHookTests {
    private func event(_ name: String, id: String = "test", generation: String? = "turn", fields: [String: Any] = [:]) -> [String: Any] {
        var json = fields
        json["hook_event_name"] = name
        json["conversation_id"] = id
        json["generation_id"] = generation
        return json
    }

    @MainActor private func status(for id: String) -> AgentStatus {
        // Inspect this session without assuming it wins over another provider's approval.
        AgentStateManager.shared.beginAgentEvent(agent: .cursor, sessionID: "cursor-hook:" + id)
        return AgentStateManager.shared.status
    }

    @Test func sourceActivityAndEmptyDescriptionFallback() {
        let thought = CursorActivityEvent.decode(event("afterAgentThought", fields: ["text": "Checking the parser"]))
        #expect(thought?.text == "Thought: Checking the parser")
        let shell = CursorActivityEvent.decode(event("preToolUse", fields: ["tool_name": "Shell",
            "agent_message": "  ", "tool_input": ["command": "swift test"]]))
        #expect(shell?.text == "Shell: swift test")
        let read = CursorActivityEvent.decode(event("preToolUse", fields: ["tool_name": "Read",
            "tool_input": ["file_path": "/Users/dev/project/CursorAgentAdapter.swift"]]))
        #expect(read?.text == "Explore: CursorAgentAdapter.swift")
        let write = CursorActivityEvent.decode(event("preToolUse", fields: ["tool_name": "StrReplace",
            "tool_input": ["path": "/Users/dev/project/CursorAgentAdapter.swift"]]))
        #expect(write?.text == "Edit: CursorAgentAdapter.swift")
        let glob = CursorActivityEvent.decode(event("preToolUse", fields: ["tool_name": "Glob",
            "tool_input": ["glob_pattern": "**/*.swift", "target_directory": "/Users/dev/project"]]))
        #expect(glob?.text == "Explore: **/*.swift")
        let response = CursorActivityEvent.decode(event("afterAgentResponse", fields: ["text": "[REDACTED]"]))
        #expect(response?.text == nil)
        #expect(CursorActivityEvent.decode(event("beforeSubmitPrompt", fields: ["prompt": "Private prompt"]))?.text == nil)
        #expect(CursorActivityEvent.decode(event("futureHook")) == nil)
    }

    @Test func previewsAreBoundedAndSkipBlankLines() {
        #expect(CursorActivityEvent.preview(" \n  Hello\nMore text") == "Hello")
        #expect(CursorActivityEvent.preview(String(repeating: "x", count: 1_000_000)).count == 220)
    }

    @Test func runtimeDecoderRequiresExplicitLifecycleSignals() {
        let prefix = "2026-10-24 10:00:00.000 [info] [ComposerWakelockManager] "
        #expect(CursorRuntimeEvent.decode(prefix + "Released wakelock composerId=test reason=\"user-approval-requested\"")?.status == .waitingApproval)
        #expect(CursorRuntimeEvent.decode(prefix + "Released wakelock composerId=test reason=\"generation-ended\"")?.status == .completed)
        #expect(CursorRuntimeEvent.decode(prefix + "Released wakelock composerId=test reason=\"aborted\"")?.status == .idle)
        #expect(CursorRuntimeEvent.decode(prefix + "Acquired wakelock composerId=test reason=\"agent-loop-resumed\"")?.status == .working)
        #expect(CursorRuntimeEvent.decode(prefix + "Acquired wakelock composerId=test reason=\"unknown\"") == nil)
        #expect(CursorRuntimeEvent.decode("invalid date [ComposerWakelockManager] Released wakelock composerId=test reason=\"generation-ended\"") == nil)
    }

    @Test @MainActor func forceStopViaWakelockReleaseOrAbortedHookClosesTurnAgainstLateHooks() {
        let adapter = CursorAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString
        defer { state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + id) }
        adapter.consumeHook(event("beforeSubmitPrompt", id: id, generation: "gen-1"))
        #expect(status(for: id) == .working)
        let stopDate = Date().addingTimeInterval(0.05)
        adapter.consumeRuntime(CursorRuntimeEvent(conversationID: id, status: .idle, date: stopDate))
        #expect(status(for: id) == .idle)
        // Late tool or thought hooks carrying the retired generation must not reopen the turn.
        adapter.consumeHook(event("afterShellExecution", id: id, generation: "gen-1", fields: ["command": "sleep 5"]))
        adapter.consumeHook(event("afterAgentThought", id: id, generation: "gen-1", fields: ["text": "Late thought"]))
        #expect(status(for: id) == .idle)
        // A new submission starts a fresh turn.
        adapter.consumeHook(event("beforeSubmitPrompt", id: id, generation: "gen-2"))
        #expect(status(for: id) == .working)
        state.endSession(agent: .cursor, sessionID: "cursor-hook:" + id)
        #expect(status(for: id) == .idle)
        #expect(!adapter.isActive)
    }

    @Test @MainActor func staleRuntimeAndLateGenerationCannotReviveCompletion() {
        let adapter = CursorAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString
        defer { state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + id) }
        adapter.consumeHook(event("beforeSubmitPrompt", id: id))
        adapter.consumeHook(event("stop", id: id, fields: ["status": "completed"]))
        #expect(status(for: id) == .completed)
        adapter.consumeRuntime(CursorRuntimeEvent(conversationID: id, status: .working, date: .distantPast))
        adapter.consumeHook(event("afterAgentResponse", id: id, fields: ["text": "Late response"]))
        #expect(status(for: id) == .completed)
        adapter.consumeHook(event("beforeSubmitPrompt", id: id, generation: "next"))
        #expect(status(for: id) == .working)
        adapter.consumeHook(event("stop", id: id, fields: ["status": "completed"]))
        #expect(status(for: id) == .working)
        adapter.consumeHook(event("stop", id: id, generation: "next", fields: ["status": "completed"]))
    }

    @Test @MainActor func logCompletionSurvivesDelayedThoughtButCannotEndNextTurn() {
        let adapter = CursorAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString
        defer { state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + id) }
        adapter.consumeHook(event("beforeSubmitPrompt", id: id))
        // Cursor ends the turn, then a buffered thought hook reaches the bridge before the log watcher.
        let ended = Date()
        adapter.consumeHook(event("afterAgentThought", id: id, fields: ["text": "Final thought arriving late"]))
        adapter.consumeRuntime(CursorRuntimeEvent(conversationID: id, status: .completed, date: ended))
        #expect(status(for: id) == .completed)
        adapter.consumeHook(event("afterAgentResponse", id: id, fields: ["text": "Late response"]))
        #expect(status(for: id) == .completed)
        let previousTurnEnd = Date()
        adapter.consumeHook(event("beforeSubmitPrompt", id: id, generation: "next"))
        adapter.consumeRuntime(CursorRuntimeEvent(conversationID: id, status: .completed, date: previousTurnEnd))
        #expect(status(for: id) == .working)
        adapter.consumeHook(event("stop", id: id, generation: "next", fields: ["status": "completed"]))
    }

    @Test @MainActor func pendingApprovalSurvivesActivityAndOtherSessions() {
        let adapter = CursorAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString, other = UUID().uuidString
        defer {
            state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + id)
            state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + other)
        }
        adapter.consumeHook(event("beforeSubmitPrompt", id: id))
        adapter.consumeRuntime(CursorRuntimeEvent(conversationID: id, status: .waitingApproval, date: Date()))
        #expect(state.status == .waitingApproval)
        let pending = state.message
        adapter.consumeHook(event("afterAgentThought", id: id, fields: ["text": "Background thought"]))
        #expect(state.status == .waitingApproval)
        #expect(state.message == pending)
        adapter.consumeHook(event("beforeSubmitPrompt", id: other))
        #expect(state.status == .waitingApproval)
        adapter.consumeHook(event("stop", id: other, fields: ["status": "completed"]))
        adapter.consumeRuntime(CursorRuntimeEvent(conversationID: id, status: .working, date: Date()))
        #expect(status(for: id) == .working)
        adapter.consumeHook(event("stop", id: id, fields: ["status": "completed"]))
    }

    @Test @MainActor func duplicateToolEventsAndSubagentCompletionStayIsolated() {
        let adapter = CursorAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString, child = UUID().uuidString
        defer {
            state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + id)
            state.removeSessions(prefix: "cursor-subagent:" + id + ":")
        }
        adapter.consumeHook(event("beforeSubmitPrompt", id: id))
        let tool = event("preToolUse", id: id, fields: ["tool_name": "Read", "tool_use_id": "call",
            "tool_input": ["path": "/tmp/file"]])
        adapter.consumeHook(tool)
        let published = adapter.lastActivityDate
        adapter.consumeHook(tool)
        #expect(adapter.lastActivityDate == published)
        adapter.consumeHook(event("subagentStart", id: id, fields: ["parent_conversation_id": id, "subagent_id": child, "task": "Review files"]))
        adapter.consumeHook(event("subagentStop", id: id, fields: ["parent_conversation_id": id, "subagent_id": child, "status": "completed"]))
        state.beginAgentEvent(agent: .cursor, sessionID: "cursor-hook:" + id)
        #expect(state.status == .working)
        adapter.consumeHook(event("stop", id: id, fields: ["status": "completed"]))
    }

    @Test @MainActor func completedHistoryStaysBounded() {
        let adapter = CursorAgentAdapter.shared, state = AgentStateManager.shared
        for _ in 0..<300 {
            let id = UUID().uuidString
            adapter.consumeHook(event("beforeSubmitPrompt", id: id))
            adapter.consumeHook(event("stop", id: id, fields: ["status": "completed"]))
            state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + id)
        }
        for key in ["conversations", "generations", "runtimeStates", "runtimeDates", "hookDates", "turnStartDates", "subagents", "closedSubagents"] {
            #expect((adapter.retainedLifecycleCounts[key] ?? 0) <= 256)
        }
        #expect((adapter.retainedLifecycleCounts["retired"] ?? 0) <= 1024)
    }

    @Test func installerPreservesOtherHooksAndAvoidsRepeatedBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("hooks.json"), source = root.appendingPathComponent("source.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: source)
        let foreign: [String: Any] = ["command": "other-observer", "timeout": 5]
        try JSONSerialization.data(withJSONObject: ["version": 1, "custom": true, "hooks": ["stop": [foreign]]]).write(to: config)
        try CursorHookInstaller.install(in: root, source: source)
        let first = try Data(contentsOf: config)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try CursorHookInstaller.install(in: root, source: source)
        #expect(try Data(contentsOf: config) == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == files.sorted())
        let json = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(json["custom"] as? Bool == true)
        let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == Set(CursorHookInstaller.observationEvents))
        #expect(hooks["stop"]?.count == 2)
        #expect(hooks["stop"]?.first?["command"] as? String == "other-observer")
    }

    @Test func malformedConfigLeavesObserverAndSettingsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        let config = root.appendingPathComponent("hooks.json"), script = root.appendingPathComponent("hooks/agentdock.sh")
        let source = root.appendingPathComponent("source.sh")
        let original = Data("{\"version\":1,\"hooks\":{\"stop\":42}}".utf8)
        try original.write(to: config)
        try Data("old observer".utf8).write(to: script)
        try Data("new observer".utf8).write(to: source)
        do {
            try CursorHookInstaller.install(in: root, source: source)
            Issue.record("Malformed hooks must reject installation")
        } catch {}
        #expect(try Data(contentsOf: config) == original)
        #expect(try String(contentsOf: script, encoding: .utf8) == "old observer")
    }

    @Test func permissionObserversProduceNoDecision() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/CursorHooks/agentdock.sh")
        let port = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: port) }
        try Data("0\n".utf8).write(to: port)
        for name in ["preToolUse", "beforeSubmitPrompt", "subagentStart"] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [source.path, name]
            var environment = ProcessInfo.processInfo.environment
            environment["AGENTDOCK_PORT_FILE"] = port.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }
    }

    @Test @MainActor func stepSuffixedGenerationIDAndTranscriptApprovalWorkCleanly() throws {
        let adapter = CursorAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString
        let baseGen = UUID().uuidString.lowercased()
        let thoughtGen = "\(baseGen)-0-m895"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            state.removeSession(agent: .cursor, sessionID: "cursor-hook:" + id)
        }
        let transcriptURL = root.appendingPathComponent("\(id).jsonl")
        let transcriptLine = """
        {"role":"assistant","message":{"content":[{"type":"text","text":"[REDACTED]"},{"type":"tool_use","name":"AskQuestion","input":{"title":"Output preference","questions":[{"id":"output_style","prompt":"How should I format answers in this workspace?"}]}}]}}
        """
        try Data((transcriptLine + "\n").utf8).write(to: transcriptURL)

        adapter.consumeHook(event("beforeSubmitPrompt", id: id, generation: baseGen, fields: ["transcript_path": transcriptURL.path]))
        #expect(status(for: id) == .working)

        // Cursor 3.27+ emits afterAgentThought with `<uuid>-0-<hash>`; this must not retire `baseGen`.
        adapter.consumeHook(event("afterAgentThought", id: id, generation: thoughtGen, fields: ["text": "I will ask whether output should be concise or detailed."]))
        state.beginAgentEvent(agent: .cursor, sessionID: "cursor-hook:" + id)
        #expect(state.status == .working)
        #expect(state.message == "Thought: I will ask whether output should be concise or detailed.")

        // ComposerWakelockManager releases wakelock with reason="user-approval-requested"
        adapter.consumeRuntime(CursorRuntimeEvent(conversationID: id, status: .waitingApproval, date: Date()))
        state.beginAgentEvent(agent: .cursor, sessionID: "cursor-hook:" + id)
        #expect(state.status == .waitingApproval)
        #expect(state.message == "Question: How should I format answers in this workspace?")

        // User answers/cancels and stop hook arrives with baseGen -> must close turn cleanly!
        adapter.consumeHook(event("stop", id: id, generation: baseGen, fields: ["status": "aborted"]))
        #expect(status(for: id) == .idle)
    }

    @Test @MainActor func claudeAdapterIgnoresCursorForwardedPayloads() {
        let id = UUID().uuidString
        defer { AgentStateManager.shared.removeSession(agent: .claude, sessionID: id) }
        let receipt = ClaudeCodeAdapter.shared.consumeHook([
            "hook_event_name": "UserPromptSubmit",
            "session_id": id,
            "cursor_version": "3.27.12"
        ])
        #expect(receipt == .invalid)
    }
}
