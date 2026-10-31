import Foundation
import Testing
@testable import AgentDock

@Suite(.serialized)
final class CodexTranscriptTests {
    private var fixtures: [URL] = []
    deinit { for root in fixtures { try? FileManager.default.removeItem(at: root) } }
    private func expectNil<T>(_ value: T?) { #expect(value == nil) }
    private func expectEqual<T: Equatable>(_ value: T, _ expected: T) { #expect(value == expected) }
    private func line(_ type: String, _ payload: [String: Any], at date: Date = Date()) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["type": type,
            "timestamp": Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date), "payload": payload])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    private func metadata(_ id: String, cwd: String = "/renamed/missing-project") throws -> String {
        try line("session_meta", ["id": id, "cwd": cwd, "originator": "Codex Desktop", "source": "vscode"])
    }
    private func fixture(_ text: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout-test.jsonl")
        try Data(text.utf8).write(to: file)
        fixtures.append(root)
        return (root, file)
    }
    @Test
    func testSnapshotDoesNotReplayHistoricalCompletion() throws {
        let past = Date().addingTimeInterval(-30)
        let text = try metadata("history") + line("event_msg", ["type": "task_started", "turn_id": "old"], at: past)
            + line("event_msg", ["type": "task_complete", "turn_id": "old"], at: past.addingTimeInterval(1))
        let (root, file) = try fixture(text)
        let result = try #require(CodexTranscriptSnapshot.load(path: file.path, root: root.path, startedAt: Date()))
        #expect(result.events.isEmpty)
    }
    @Test
    func testSnapshotRecoversRunningTurnDespiteMissingProjectFolder() throws {
        let past = Date().addingTimeInterval(-5)
        let (root, file) = try fixture(metadata("running") + line("event_msg", ["type": "task_started", "turn_id": "t"], at: past))
        let result = try #require(CodexTranscriptSnapshot.load(path: file.path, root: root.path, startedAt: Date()))
        let event = try #require(result.events.first)
        expectEqual(result.events.count, 1)
        #expect(event.startsTurn)
        expectEqual(event.status, .working)
    }
    @Test
    func testPartialLineIsLeftForTailer() throws {
        let prefix = try metadata("partial")
        let (root, file) = try fixture(prefix + "{\"type\":\"event_msg\"")
        let result = try #require(CodexTranscriptSnapshot.load(path: file.path, root: root.path, startedAt: Date()))
        expectEqual(result.offset, UInt64(prefix.utf8.count))
    }
    @Test
    func testOutOfRootFilesAreExcluded() throws {
        let (root, file) = try fixture(metadata("private", cwd: "/private"))
        expectNil(CodexTranscriptSnapshot.load(path: file.path, root: root.appendingPathComponent("other").path, startedAt: Date()))
    }
    @Test
    func testUnknownMalformedAndUserRecordsDoNotCreateActivity() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "test"]))
        expectNil(decoder.decode("not json"))
        expectNil(decoder.decode(try line("event_msg", ["type": "unknown"])))
        expectNil(decoder.decode(try line("response_item", ["type": "message", "role": "user"])))
    }
    @Test
    func testInvalidTimestampCannotChangeTheCurrentTurn() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "test"]))
        let invalid = "{\"type\":\"event_msg\",\"timestamp\":\"invalid\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"invalid-turn\"}}"
        expectNil(decoder.decode(invalid))
        let event = try #require(decoder.decode(try line("response_item", ["type": "reasoning"])))
        expectNil(event.turnID)
    }
    @Test
    func testFinalAssistantMessageIsNotCompletion() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "test"]))
        let event = decoder.decode(try line("response_item", ["type": "message", "role": "assistant"]))
        expectEqual(event?.status, .working)
    }
    @Test
    func testPublicReasoningSummaryIsUsedWithoutEncryptedContent() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "summary"]))
        let event = try #require(decoder.decode(try line("response_item", ["type": "reasoning",
            "summary": [["type": "summary_text", "text": "Checking the settings flow"]], "encrypted_content": "unreadable"])))
        expectEqual(event.text, "Checking the settings flow")
        let encryptedOnly = try #require(decoder.decode(try line("response_item", ["type": "reasoning",
            "summary": [], "encrypted_content": "never display this"])))
        expectEqual(encryptedOnly.text, "Thinking…")
    }
    @Test
    func testCommentaryAndToolDescriptionsProvideBoundedActivity() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "activity"]))
        let progress = try #require(decoder.decode(try line("response_item", ["type": "message", "role": "assistant",
            "phase": "commentary", "content": [["type": "output_text", "text": "Reviewing\n the recent changes"]]])))
        expectEqual(progress.text, "Reviewing the recent changes")
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["description": "Building the updated app"]), as: UTF8.self)
        let tool = try #require(decoder.decode(try line("response_item", ["type": "function_call", "name": "exec", "arguments": arguments])))
        expectEqual(tool.text, "Building the updated app")
        let long = try #require(decoder.decode(try line("response_item", ["type": "reasoning",
            "summary": [["type": "summary_text", "text": String(repeating: "x", count: 1000)]]])))
        expectEqual(long.text.count, 220)
    }
    @Test
    func testCompletedToolItemsDescribeReadsAndSearchesWithoutEndingTurn() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "items"]))
        for (command, expected) in [(["type": "read", "name": "Settings.swift"], "Read Settings.swift"),
                                    (["type": "search", "query": "hook state"], "Searched for hook state")] {
            let event = try #require(decoder.decode(try line("event_msg", ["type": "item_completed",
                "item": ["type": "CommandExecution", "parsed_cmd": [command]]])))
            expectEqual(event.text, expected); expectEqual(event.status, .working)
        }
        expectNil(decoder.decode(try line("event_msg", ["type": "item_completed", "item": ["type": "UserMessage"]])))
    }
    @MainActor
    @Test
    func testTranscriptEnrichesMissingHookDetailWithoutChangingHookState() async {
        let id = UUID().uuidString, turn = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeHook(["hook_event_name": "UserPromptSubmit", "session_id": id, "turn_id": turn])
        let detail = CodexTranscriptEvent(sessionID: id, turnID: turn, date: Date(), status: .working,
            text: "Read Settings.swift", model: "", surface: .dedicatedWindow, startsTurn: false)
        adapter.consumeTranscript(detail)
        expectEqual(AgentStateManager.shared.message, "Read Settings.swift")
        expectEqual(AgentStateManager.shared.status, .working)
        adapter.consumeHook(["hook_event_name": "Stop", "session_id": id, "turn_id": turn])
    }
    @Test
    func testNewActivityRecordsIncludeCommentaryWebAndMCPDetails() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "details"]))
        let items: [([String: Any], String)] = [
            (["type": "AgentMessage", "phase": "commentary", "content": [["type": "Text", "text": "Reviewing the hook installer"]]], "Reviewing the hook installer"),
            (["type": "Extension", "kind": "web.search", "action": ["type": "search", "query": "Codex hooks"]], "Searching the web for Codex hooks"),
            (["type": "McpToolCall", "tool": "read", "arguments": ["path": "/project/Settings.swift"]], "read: Settings.swift")]
        for (item, expected) in items {
            let event = try #require(decoder.decode(try line("event_msg", ["type": "item_started", "item": item])))
            expectEqual(event.text, expected); expectEqual(event.status, .working)
        }
    }
    @Test
    func testPatchActivityUsesFileNamesWithoutDisplayingPatchContent() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "patch"]))
        let patch = "*** Begin Patch\n*** Update File: /project/Settings.swift\n@@\n+private source content\n*** End Patch"
        let event = try #require(decoder.decode(try line("response_item", ["type": "custom_tool_call", "name": "apply_patch", "input": patch])))
        expectEqual(event.text, "Editing Settings.swift")
    }
    @Test
    func testDetailClassificationUsesSourceFieldsRatherThanDisplayWords() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "detail-source"]))
        let generic = try #require(decoder.decode(try line("response_item", ["type": "reasoning", "summary": []])))
        #expect(!generic.hasDetail)
        let explicit = try #require(decoder.decode(try line("response_item", ["type": "reasoning",
            "summary": [["type": "summary_text", "text": "Thinking…"]]])))
        #expect(explicit.hasDetail)
    }
    @Test
    func testModelTurnAndInterruptionAreDecoded() throws {
        var decoder = try #require(CodexTranscriptDecoder(metadata: ["id": "test", "source": "cli"]))
        expectNil(decoder.decode(try line("turn_context", ["model": "test-model", "turn_id": "turn"])))
        let event = try #require(decoder.decode(try line("event_msg", ["type": "turn_aborted"])))
        expectEqual(event.turnID, "turn"); expectEqual(event.model, "test-model")
        expectEqual(event.status, .idle); expectEqual(event.surface, .cli)
    }
    @MainActor
    @Test
    func testApprovalWinsOverTranscriptProgressAndCompletionIsDeduplicated() async throws {
        let id = UUID().uuidString, turn = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeHook(["hook_event_name": "UserPromptSubmit", "session_id": id, "turn_id": turn])
        adapter.consumeHook(["hook_event_name": "PermissionRequest", "session_id": id, "turn_id": turn,
                             "tool_name": "Bash", "tool_input": ["command": "test"]])
        adapter.consumeTranscript(event(id, turn, .working))
        expectEqual(AgentStateManager.shared.status, .waitingApproval)
        adapter.consumeTranscript(event(id, turn, .completed))
        try await waitUntil { AgentStateManager.shared.status == .completed }
        expectEqual(AgentStateManager.shared.status, .completed)
        let message = AgentStateManager.shared.message
        adapter.consumeHook(["hook_event_name": "Stop", "session_id": id, "turn_id": turn, "last_assistant_message": "duplicate"])
        adapter.consumeTranscript(event(id, turn, .working, starts: true))
        expectEqual(AgentStateManager.shared.status, .completed)
        expectEqual(AgentStateManager.shared.message, message)
    }
    @MainActor
    @Test
    func testHookToolDetailsWinOverTranscriptProgress() async throws {
        let id = UUID().uuidString, turn = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeHook(["hook_event_name": "PreToolUse", "session_id": id, "turn_id": turn,
                             "tool_name": "Bash", "tool_input": ["command": "native hook details"]])
        let nativeMessage = AgentStateManager.shared.message
        try await Task.sleep(nanoseconds: 1_100_000_000)
        adapter.consumeTranscript(event(id, turn, .working))
        expectEqual(AgentStateManager.shared.message, nativeMessage)
        adapter.consumeHook(["hook_event_name": "Stop", "session_id": id, "turn_id": turn])
    }
    @MainActor
    @Test
    func testRecoveredStartPreservesApprovalWhenPromptHookWasMissed() async throws {
        let id = UUID().uuidString, turn = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeHook(["hook_event_name": "PermissionRequest", "session_id": id, "turn_id": turn,
                             "tool_name": "Bash", "tool_input": ["command": "test"]])
        adapter.consumeTranscript(event(id, turn, .working, starts: true))
        try await Task.sleep(nanoseconds: 1_100_000_000)
        expectEqual(AgentStateManager.shared.status, .waitingApproval)
        adapter.consumeHook(["hook_event_name": "Stop", "session_id": id, "turn_id": turn])
    }
    @MainActor
    @Test
    func testNativeStopWinsOverPendingTranscriptCompletion() async throws {
        let id = UUID().uuidString, turn = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeHook(["hook_event_name": "UserPromptSubmit", "session_id": id, "turn_id": turn])
        // A long quiet turn still gives its native Stop the delivery grace.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        adapter.consumeTranscript(event(id, turn, .completed))
        expectEqual(AgentStateManager.shared.status, .working)
        adapter.consumeHook(["hook_event_name": "Stop", "session_id": id, "turn_id": turn,
                             "last_assistant_message": "Native completion"])
        let nativeMessage = AgentStateManager.shared.message
        try await Task.sleep(nanoseconds: 1_100_000_000)
        expectEqual(AgentStateManager.shared.status, .completed)
        expectEqual(AgentStateManager.shared.message, nativeMessage)
    }
    @MainActor
    @Test
    func testAsyncQuestionStaysVisibleAfterStopAndTranscriptCompletion() async throws {
        let id = UUID().uuidString, turn = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeHook(["hook_event_name": "UserPromptSubmit", "session_id": id, "turn_id": turn])
        adapter.consumeHook(["hook_event_name": "PreToolUse", "session_id": id, "turn_id": turn,
            "tool_name": "request_user_input_async", "tool_input": ["questions": [["title": "Which option?"]]]])
        adapter.consumeHook(["hook_event_name": "PostToolUse", "session_id": id, "turn_id": turn,
            "tool_name": "request_user_input_async", "tool_input": ["questions": [["title": "Which option?"]]]])
        adapter.consumeHook(["hook_event_name": "Stop", "session_id": id, "turn_id": turn])
        adapter.consumeTranscript(event(id, turn, .completed))
        try await Task.sleep(nanoseconds: 1_100_000_000)
        expectEqual(AgentStateManager.shared.status, .waitingApproval)
        #expect(AgentStateManager.shared.isIndicatorVisible)
        adapter.consumeHook(["hook_event_name": "UserPromptSubmit", "session_id": id, "turn_id": UUID().uuidString])
        expectEqual(AgentStateManager.shared.status, .working)
        adapter.consumeHook(["hook_event_name": "Interrupt", "session_id": id])
    }
    @MainActor
    @Test
    func testPendingApprovalDoesNotExpireByInactivity() async throws {
        let id = UUID().uuidString
        let state = AgentStateManager.shared
        state.update(agent: .codex, status: .waitingApproval, message: "Approval required", sessionID: id,
            startsTurn: true, quietLimit: 0.02)
        try await Task.sleep(nanoseconds: 80_000_000)
        expectEqual(state.status, .waitingApproval)
        #expect(state.isIndicatorVisible)
        state.endSession(agent: .codex, sessionID: id)
    }
    @MainActor
    @Test
    func testLateOldTurnCannotFinishNewTurn() async {
        let id = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeTranscript(event(id, "one", .working, starts: true))
        adapter.consumeTranscript(event(id, "two", .working, starts: true))
        adapter.consumeTranscript(event(id, "one", .completed))
        expectEqual(AgentStateManager.shared.status, .working)
        adapter.consumeTranscript(event(id, "two", .completed))
        expectEqual(AgentStateManager.shared.status, .completed)
    }
    @MainActor
    @Test
    func testTranscriptStartDoesNotClearApprovalWhenHookOmitsTurnID() async throws {
        let id = UUID().uuidString
        let adapter = CodexAgentAdapter.shared
        adapter.consumeHook(["hook_event_name": "UserPromptSubmit", "session_id": id])
        adapter.consumeHook(["hook_event_name": "PermissionRequest", "session_id": id,
                             "tool_name": "Bash", "tool_input": ["command": "test"]])
        adapter.consumeTranscript(event(id, "recovered-turn", .working, starts: true))
        expectEqual(AgentStateManager.shared.status, .waitingApproval)
        adapter.consumeTranscript(event(id, "recovered-turn", .completed))
        try await waitUntil { AgentStateManager.shared.status == .completed }
    }
    @MainActor
    @Test
    func testNewFileIsDiscoveredWithoutPollingAndStopDetachesWatcher() async throws {
        let (root, file) = try fixture("")
        try FileManager.default.removeItem(at: file)
        var starts = 0, completions = 0
        let monitor = CodexTranscriptMonitor(root: root.path) { event in
            if event.startsTurn { starts += 1 }
            if event.status == .completed { completions += 1 }
        }
        monitor.start(); defer { monitor.stop() }
        let text = try metadata("new-file") + line("event_msg", ["type": "task_started", "turn_id": "t"])
        try Data(text.utf8).write(to: file)
        try await waitUntil { starts == 1 }
        monitor.stop()
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("event_msg", ["type": "task_complete", "turn_id": "t"]).utf8))
        try await Task.sleep(nanoseconds: 250_000_000)
        expectEqual(completions, 0)
    }
    @MainActor
    @Test
    func testFileTruncatedBeforeWatcherAttachmentStartsFromBeginning() async throws {
        let (_, file) = try fixture("replacement line\n")
        var lines: [String] = []
        let watcher = LogStreamWatcher(observesDirectory: false, initialReadOffset: 10_000,
            discoverActiveFile: { (file.path, Date(), nil) }, onLine: { line, _ in lines.append(line) })
        watcher.start(); defer { watcher.stop() }
        try await waitUntil { lines == ["replacement line"] }
        expectEqual(lines, ["replacement line"])
    }
    @MainActor
    @Test
    func testFileWatcherContinuesFromSnapshotIncludingSplitWrites() async throws {
        let id = UUID().uuidString, past = Date().addingTimeInterval(-1)
        let (root, file) = try fixture(metadata(id) + line("event_msg", ["type": "task_started", "turn_id": "t"], at: past))
        var starts = 0
        var completions = 0
        let monitor = CodexTranscriptMonitor(root: root.path) { event in
            if event.startsTurn { starts += 1 }
            if event.status == .completed { completions += 1 }
        }
        monitor.start(); defer { monitor.stop() }
        try await waitUntil { starts == 1 }
        let completion = try line("event_msg", ["type": "task_complete", "turn_id": "t"])
        let data = Data(completion.utf8), midpoint = data.count / 2
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data.prefix(midpoint))
        try await Task.sleep(nanoseconds: 100_000_000)
        expectEqual(completions, 0)
        try handle.write(contentsOf: data.suffix(from: midpoint))
        try await waitUntil { completions == 1 }
        expectEqual(completions, 1)
    }
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(condition())
    }
    private func event(_ id: String, _ turn: String, _ status: AgentStatus, starts: Bool = false) -> CodexTranscriptEvent {
        CodexTranscriptEvent(sessionID: id, turnID: turn, date: Date(), status: status, text: "Test activity",
                             model: "test", surface: .dedicatedWindow, startsTurn: starts)
    }
}
