import Foundation
import Testing
@testable import AgentDock

@Suite(.serialized)
struct ClaudeHookTests {
    @Test @MainActor func interactiveToolsWaitUntilTheirMatchingResult() {
        let adapter = ClaudeCodeAdapter.shared
        let state = AgentStateManager.shared
        let id = UUID().uuidString
        func send(_ event: String, _ fields: [String: Any] = [:]) {
            var payload = fields
            payload["hook_event_name"] = event
            payload["session_id"] = id
            adapter.consumeHook(payload)
        }
        defer {
            send("SessionEnd")
            state.removeSession(agent: .claude, sessionID: id)
        }
        send("UserPromptSubmit")
        let question: [String: Any] = ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Which framework?"]]]]
        send("PreToolUse", question)
        #expect(state.status == .waitingApproval)
        #expect(state.message == "Question: Which framework?")
        send("PermissionRequest", question) // Duplicate notification must not create another pending request.
        send("PostToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/tmp/file"]])
        #expect(state.status == .waitingApproval)
        send("PostToolUse", question)
        #expect(state.status == .working)
        let plan: [String: Any] = ["tool_name": "ExitPlanMode", "tool_input": ["planFilePath": "/tmp/plan.md"]]
        send("PreToolUse", plan)
        #expect(state.status == .waitingApproval)
        send("PostToolUseFailure", plan)
        #expect(state.status == .working)
        send("PreToolUse", question)
        send("Stop")
        #expect(state.status == .completed)
        send("UserPromptSubmit")
        #expect(state.status == .working)
    }

    @Test @MainActor func transcriptShowsLatestActivityAndProtectsPendingRequests() throws {
        let adapter = ClaudeCodeAdapter.shared
        let state = AgentStateManager.shared
        let id = UUID().uuidString
        func send(_ event: String, _ fields: [String: Any] = [:]) {
            var payload = fields
            payload["session_id"] = id; payload["hook_event_name"] = event
            adapter.consumeHook(payload)
        }
        func transcript(_ blocks: [[String: Any]], sidechain: Bool = false) throws {
            let data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "isSidechain": sidechain,
                "message": ["content": blocks]])
            adapter.consumeTranscript(String(decoding: data, as: UTF8.self), key: id)
        }
        defer { send("SessionEnd"); state.removeSession(agent: .claude, sessionID: id) }
        send("UserPromptSubmit")
        try transcript([["type": "thinking", "thinking": "Checking the relevant implementation"]])
        #expect(state.message == "Thought: Checking the relevant implementation")
        try transcript([["type": "thinking", "thinking": "Earlier thought"],
                        ["type": "tool_use", "name": "Bash", "input": ["description": "Running regression tests", "command": "swift test"]]])
        #expect(state.message == "Bash: Running regression tests")
        try transcript([["type": "text", "text": "  \n  The tests passed.\nOther details"]])
        #expect(state.message == "Response: The tests passed.")
        try transcript([["type": "text", "text": "Other agent"]], sidechain: true)
        #expect(state.message == "Response: The tests passed.")
        try transcript([["type": "future_block", "text": "Unknown schema"], ["type": "text", "text": "   "]])
        #expect(state.message == "Response: The tests passed.")
        try transcript([["type": "text", "text": String(repeating: "x", count: 300_000)]])
        #expect(state.message == "Response: The tests passed.")
        send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "swift test"]])
        let pending = state.message
        try transcript([["type": "text", "text": "Late activity"]])
        #expect(state.status == .waitingApproval)
        #expect(state.message == pending)
        send("Stop")
        let completed = state.message
        try transcript([["type": "text", "text": "Late response"]])
        #expect(state.status == .completed)
        #expect(state.message == completed)
    }

    @Test func installationPreservesOtherHooksAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("settings.json")
        let source = root.appendingPathComponent("source.sh")
        let destination = root.appendingPathComponent("observer.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: source)
        let other: [String: Any] = ["matcher": "Read", "hooks": [["type": "command", "command": "competitor-hook"]]]
        let command = "'" + destination.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let legacyOwned: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 1]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [other], "MessageDisplay": [legacyOwned]], "unrelated": true]).write(to: config)
        try ClaudeHookInstaller.install(base: root, destination: destination, source: source)
        let before = try Data(contentsOf: config)
        try ClaudeHookInstaller.install(base: root, destination: destination, source: source)
        #expect(try Data(contentsOf: config) == before)
        let json = try #require(JSONSerialization.jsonObject(with: before) as? [String: Any])
        #expect(json["unrelated"] as? Bool == true)
        let events = try #require(json["hooks"] as? [String: [[String: Any]]])
        #expect(Set(events.keys) == Set(ClaudeCodeAdapter.installedEvents))
        #expect(events["MessageDisplay"] == nil)
        let pre = try #require(events["PreToolUse"])
        #expect(pre.count == 2)
        #expect(NSDictionary(dictionary: pre[0]).isEqual(to: other))
    }

    @Test @MainActor func toolRejectionsApiErrorsAndBasenameFormattingWorkCleanly() throws {
        let adapter = ClaudeCodeAdapter.shared
        let state = AgentStateManager.shared
        let id = UUID().uuidString
        func send(_ event: String, _ fields: [String: Any] = [:]) {
            var payload = fields
            payload["session_id"] = id; payload["hook_event_name"] = event
            adapter.consumeHook(payload)
        }
        @MainActor func status(for sessionID: String) -> AgentStatus {
            state.beginAgentEvent(agent: .claude, sessionID: sessionID)
            return state.status
        }
        defer { send("SessionEnd"); state.removeSession(agent: .claude, sessionID: id) }

        send("UserPromptSubmit")
        send("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/Users/dev/project/ClaudeCodeAdapter.swift"]])
        state.beginAgentEvent(agent: .claude, sessionID: id)
        #expect(state.message == "Read: ClaudeCodeAdapter.swift")

        send("PreToolUse", ["tool_name": "TodoWrite", "tool_input": [
            "todos": [["status": "in_progress", "activeForm": "Auditing Claude Code hooks"]]
        ]])
        state.beginAgentEvent(agent: .claude, sessionID: id)
        #expect(state.message == "Task: Auditing Claude Code hooks")

        // User rejects a tool call in the terminal; transcript records UPA/tJA without firing Stop.
        let rejection = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "isSidechain": false,
            "message": [
                "role": "user",
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": "toolu_123",
                    "is_error": true,
                    "content": "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
                ]]
            ]
        ])
        adapter.consumeTranscript(String(decoding: rejection, as: UTF8.self), key: id)
        #expect(status(for: id) == .idle)

        // Start a new turn that encounters a synthetic API billing error in the transcript.
        send("UserPromptSubmit")
        #expect(status(for: id) == .working)
        let apiError = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "isSidechain": false,
            "isApiErrorMessage": true,
            "error": "billing_error",
            "message": [
                "model": "<synthetic>",
                "content": [["type": "text", "text": "Credit balance is too low"]]
            ]
        ])
        adapter.consumeTranscript(String(decoding: apiError, as: UTF8.self), key: id)
        #expect(status(for: id) == .error)
        #expect(state.message == "Error: Credit balance is too low")
    }
}
