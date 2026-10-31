import Foundation
import SQLite3
import Testing
@testable import AgentDock

@Suite(.serialized)
struct AntigravityHookTests {
    @Test func installsScopedRequestHookAndPreservesOtherGroups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"other\":{\"enabled\":false}}".utf8).write(to: config)
        let source = root.appendingPathComponent("source.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: source)
        let destination = root.appendingPathComponent("observer.sh")
        try AntigravityHookInstaller.install(in: root, destination: destination, source: source)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let group = try #require(json["agentdock-observer"] as? [String: Any])
        #expect(Set(group.keys) == Set(["PreInvocation", "PostToolUse", "Stop", "PreToolUse"]))
        #expect((json["other"] as? [String: Any])?["enabled"] as? Bool == false)
        let requests = try #require(group["PreToolUse"] as? [[String: Any]])
        let matcher = try #require(requests.first?["matcher"] as? String)
        let regex = try NSRegularExpression(pattern: matcher)
        for name in ["ask_question", "ask_permission"] {
            #expect(regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil)
        }
        for name in ["run_command", "write_to_file", "prefix_ask_permission", "ask_permission_suffix"] {
            #expect(regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil)
        }
        let before = try Data(contentsOf: config)
        try AntigravityHookInstaller.install(in: root, destination: destination, source: source)
        #expect(try Data(contentsOf: config) == before)
    }
    @Test func transcriptActivityUsesMetadataWithoutLeakingBodies() {
        let file = AntigravityActivityEvent.transcriptText(["type": "VIEW_FILE", "content": "Created At: now\nFile Path: /project/Settings.swift\nprivate file contents"])
        #expect(file == "Reading a file: Settings.swift")
        let command = AntigravityActivityEvent.transcriptText(["type": "RUN_COMMAND", "content": "Created At: now\nCommand: swift test\noutput that must stay out of the notch"])
        #expect(command == "Running a command: swift test")
        #expect(AntigravityActivityEvent.transcriptText(["type": "USER_INPUT", "content": "private user input"]) == nil)
        #expect(AntigravityActivityEvent.transcriptText(["type": "UNKNOWN", "content": "unrecognized content"]) == nil)
    }
    @Test func nativeSummaryAndCurrentToolTakePriorityOverGenericText() {
        let tool: [String: Any] = ["name": "run_command", "toolSummary": "Running the test suite", "args": ["CommandLine": "swift test"]]
        #expect(AntigravityActivityEvent.toolText(tool) == "Command: Running the test suite")
        #expect(AntigravityActivityEvent.transcriptText(["type": "PLANNER_RESPONSE", "tool_calls": [tool], "content": "Earlier response text"]) == "Command: Running the test suite")
        #expect(AntigravityActivityEvent.transcriptText(["type": "PLANNER_RESPONSE", "thinking": "Inspecting SQLite WAL state before running tests"]) == "Thought: Inspecting SQLite WAL state before running tests")
        #expect(AntigravityActivityEvent.transcriptText(["type": "PLANNER_RESPONSE"]) == nil)
    }
    @Test func emptySummaryFallsThroughToAvailableActivity() {
        #expect(AntigravityActivityEvent.toolText(["name": "read", "toolSummary": "  ", "toolAction": "Reading settings", "args": [:]]) == "Reading settings")
        #expect(AntigravityActivityEvent.toolText(["name": "run", "args": ["Description": "", "CommandLine": "swift test"]]) == "run: swift test")
        // Protojson-quoted string values inside args and modern Path/DirectoryPath keys:
        #expect(AntigravityActivityEvent.toolText(["name": "read_file", "args": ["Path": "\"/Users/dev/project/AppDelegate.swift\""]]) == "Read: AppDelegate.swift")
        #expect(AntigravityActivityEvent.toolText(["name": "run_command", "args": ["CommandLine": "\"git status\"", "toolSummary": "\"Git status check\""]]) == "Command: Git status check")
    }
    @Test func invalidSettingsPreserveInstalledObserver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("antigravity-cli"), withIntermediateDirectories: true)
        try Data("{\"statusLine\":42}".utf8).write(to: root.appendingPathComponent("antigravity-cli/settings.json"))
        let source = root.appendingPathComponent("source.sh"), destination = root.appendingPathComponent("installed.sh")
        try Data("new observer".utf8).write(to: source)
        let previous = Data("existing observer".utf8)
        try previous.write(to: destination)
        do {
            try AntigravityHookInstaller.install(in: root, destination: destination, source: source)
            Issue.record("Invalid settings should reject installation")
        } catch {}
        #expect(try Data(contentsOf: destination) == previous)
    }

    @Test func stopAndCancellationEventsDecodeCleanly() {
        let id = UUID().uuidString
        // Stop without fullyIdle still closes the turn cleanly.
        let omittedIdle = AntigravityActivityEvent.decode(["event": "Stop", "conversationId": id, "terminationReason": "model_stop"])
        #expect(omittedIdle?.status == .completed)
        #expect(omittedIdle?.authoritative == true)

        // Force-stop / user cancellation maps to .idle even if fullyIdle is false or omitted.
        let cancelled = AntigravityActivityEvent.decode(["event": "Stop", "conversationId": id, "fullyIdle": false, "terminationReason": "cancelled"])
        #expect(cancelled?.status == .idle)
        #expect(cancelled?.authoritative == true)

        // Official Antigravity ExecutorTerminationReason values: USER_CANCELED and NO_TOOL_CALL.
        let userCanceled = AntigravityActivityEvent.decode(["event": "Stop", "conversationId": id, "fullyIdle": false, "terminationReason": "USER_CANCELED"])
        #expect(userCanceled?.status == .idle)
        #expect(userCanceled?.authoritative == true)

        let noToolCall = AntigravityActivityEvent.decode(["event": "Stop", "conversationId": id, "fullyIdle": true, "terminationReason": "NO_TOOL_CALL"])
        #expect(noToolCall?.status == .completed)
        #expect(noToolCall?.authoritative == true)

        // Intermediate sub-step stop with fullyIdle == false stays non-authoritative working.
        let intermediate = AntigravityActivityEvent.decode(["event": "Stop", "conversationId": id, "fullyIdle": false])
        #expect(intermediate?.status == .working)
        #expect(intermediate?.authoritative == false)
    }

    @Test @MainActor func summaryDatabaseCancellationClosesLiveSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("conversation_summaries.db").path

        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        let createSQL = """
        CREATE TABLE conversation_summaries (
            conversation_id TEXT PRIMARY KEY,
            status TEXT NOT NULL DEFAULT '',
            not_fully_idle NUMERIC NOT NULL DEFAULT 0,
            killed NUMERIC NOT NULL DEFAULT 0,
            last_modified_time TEXT DEFAULT '2026-10-24 00:00:00+00:00'
        );
        """
        #expect(sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK)

        let runningID = UUID().uuidString
        let cancelledID = UUID().uuidString
        let insertSQL = """
        INSERT INTO conversation_summaries (conversation_id, status, not_fully_idle, killed) VALUES
        ('\(runningID)', 'CASCADE_RUN_STATUS_RUNNING', 1, 0),
        ('\(cancelledID)', 'CASCADE_RUN_STATUS_IDLE', 0, 0);
        """
        #expect(sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let states = try #require(AntigravityDatabase.readRuns(path: dbPath, sessionIDs: [runningID, cancelledID]))
        #expect(states[runningID]?.isIdleOrCancelled == false)
        #expect(states[cancelledID]?.isIdleOrCancelled == true)

        let adapter = AntigravityAgentAdapter.shared
        let state = AgentStateManager.shared
        defer {
            state.removeSession(agent: .antigravity, sessionID: runningID)
            state.removeSession(agent: .antigravity, sessionID: cancelledID)
        }
        adapter.consumeHook(["event": "PreInvocation", "conversationId": cancelledID, "modelName": "Gemini 3.8 Flash"])
        state.beginAgentEvent(agent: .antigravity, sessionID: cancelledID)
        #expect(state.status == .working)

        adapter.reconcileSummaryIdleSessions([cancelledID])
        state.beginAgentEvent(agent: .antigravity, sessionID: cancelledID)
        #expect(state.status == .idle)
        #expect(!adapter.isActive)
    }

    @Test @MainActor func stateManagerEndClosesOnlyItsMatchingLiveSession() {
        let adapter = AntigravityAgentAdapter.shared
        let state = AgentStateManager.shared
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        defer {
            state.removeSession(agent: .antigravity, sessionID: firstID)
            state.removeSession(agent: .antigravity, sessionID: secondID)
        }
        // Start first session and end it via AgentStateManager (e.g. power assertion or silence).
        adapter.consumeHook(["event": "PreInvocation", "conversationId": firstID])
        state.endSession(agent: .antigravity, sessionID: firstID)

        // Start a second session and end only that session.
        adapter.consumeHook(["event": "PreInvocation", "conversationId": secondID])
        state.beginAgentEvent(agent: .antigravity, sessionID: secondID)
        #expect(state.status == .working)

        // An authoritative end targets this conversation, never the most recently active one.
        state.endSession(agent: .antigravity, sessionID: secondID)

        state.beginAgentEvent(agent: .antigravity, sessionID: secondID)
        #expect(state.status == .idle)
        #expect(!adapter.isActive)

        // Late PostToolUse after cancellation must not reopen the finished turn.
        adapter.consumeHook(["event": "PostToolUse", "conversationId": secondID, "toolCall": ["name": "run_command", "toolSummary": "Late tool"]])
        state.beginAgentEvent(agent: .antigravity, sessionID: secondID)
        #expect(state.status == .idle)
    }

    @Test @MainActor func conversationStepsDatabaseSurfacesWaitingApprovalAndResumesWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID().uuidString
        let dbPath = root.appendingPathComponent("\(sessionID).db").path

        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        let createSQL = """
        CREATE TABLE steps (
            idx INTEGER PRIMARY KEY,
            step_type NUMERIC NOT NULL DEFAULT 0,
            status NUMERIC NOT NULL DEFAULT 0,
            permissions BLOB,
            metadata BLOB,
            step_payload BLOB
        );
        """
        #expect(sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK)

        // Step 10 waiting for user approval (CORTEX_STEP_STATUS_WAITING = 9) with binary suffix containing '}' after JSON
        let metaBytes = try metadata(tool: "run_command", args: ["CommandLine": "rm -rf build", "toolSummary": "Clean build folder"])
            + field(35, try JSONSerialization.data(withJSONObject: ["toolSummary": "Unrelated JSON must be ignored"]))
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, status, permissions, metadata, step_payload) VALUES (10, 132, 9, X'12160A07636F6D6D616E64120B726D202D7266206275696C64', ?, NULL);", -1, &stmt, nil) == SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = metaBytes.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 1, ptr.baseAddress, Int32(metaBytes.count), transient)
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
        sqlite3_finalize(stmt)

        let waitingState = try #require(AntigravityDatabase.readSteps(path: dbPath))
        #expect(waitingState.waitingApprovals[10] == "Permission: Clean build folder")

        let adapter = AntigravityAgentAdapter.shared
        let state = AgentStateManager.shared
        defer { state.removeSession(agent: .antigravity, sessionID: sessionID) }

        adapter.consumeHook(["event": "PreInvocation", "conversationId": sessionID, "modelName": "Gemini 3.8 Pro"])
        adapter.applyStepState(waitingState, sessionID: sessionID, surface: .dedicatedWindow)
        state.beginAgentEvent(agent: .antigravity, sessionID: sessionID)
        #expect(state.status == .waitingApproval)
        #expect(state.message == "Permission: Clean build folder")

        // User approves step 10 -> status becomes 2 (RUNNING)
        #expect(sqlite3_exec(db, "UPDATE steps SET status = 2 WHERE idx = 10;", nil, nil, nil) == SQLITE_OK)
        let runningState = try #require(AntigravityDatabase.readSteps(path: dbPath))
        #expect(runningState.waitingApprovals.isEmpty)
        #expect(runningState.activeActivity == "Command: Clean build folder")

        adapter.applyStepState(runningState, sessionID: sessionID, surface: .dedicatedWindow)
        state.beginAgentEvent(agent: .antigravity, sessionID: sessionID)
        #expect(state.status == .working)
        #expect(state.message == "Command: Clean build folder")

        // Step 11 is a PLANNER_RESPONSE (step_type = 15, status = 3) with field 20 -> subfield 3 (thinking)
        let thought = Data("Analyzing Claude workspace trust and hook execution".utf8)
        var inner = Data([0x1A, UInt8(thought.count)]) // subfield 3 (thinking)
        inner.append(thought)
        var outer = Data([0xA2, 0x01, UInt8(inner.count)]) // field 20 (PLANNER_RESPONSE)
        outer.append(inner)
        var plannerStmt: OpaquePointer?
        #expect(sqlite3_exec(db, "UPDATE steps SET status = 3 WHERE idx = 10;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_prepare_v2(db, "INSERT INTO steps (idx, step_type, status, step_payload) VALUES (11, 15, 3, ?);", -1, &plannerStmt, nil) == SQLITE_OK)
        _ = outer.withUnsafeBytes { ptr in
            sqlite3_bind_blob(plannerStmt, 1, ptr.baseAddress, Int32(outer.count), transient)
        }
        #expect(sqlite3_step(plannerStmt) == SQLITE_DONE)
        sqlite3_finalize(plannerStmt)
        sqlite3_close(db)

        let thoughtState = try #require(AntigravityDatabase.readSteps(path: dbPath, sinceStep: 11))
        #expect(thoughtState.activeActivity == "Thought: Analyzing Claude workspace trust and hook execution")
        #expect(AntigravityDatabase.readSteps(path: dbPath)?.activeActivity == nil)
        #expect(AntigravityDatabase.readSteps(path: dbPath, sinceStep: 12)?.activeActivity == nil)

        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "INSERT INTO steps(idx,status) VALUES (1,9),(12,3),(13,3),(14,3),(15,3),(16,3),(17,3),(18,3),(19,3),(20,3);", nil, nil, nil) == SQLITE_OK)
        let pending = try #require(AntigravityDatabase.readSteps(path: dbPath, sinceStep: 12))
        #expect(pending.waitingApprovals[1] == "Permission: Approval required")
        #expect(sqlite3_exec(db, "DROP TABLE steps", nil, nil, nil) == SQLITE_OK)
        #expect(AntigravityDatabase.readSteps(path: dbPath) == nil)

    }

    private func field(_ number: UInt64, _ data: Data) -> Data {
        func varint(_ value: UInt64) -> Data {
            var number = value, output = Data()
            repeat {
                let byte = UInt8(number & 127); number >>= 7
                output.append(byte | (number > 0 ? 128 : 0))
            } while number > 0
            return output
        }
        return varint(number << 3 | 2) + varint(UInt64(data.count)) + data
    }
    private func metadata(tool: String, args: [String: Any]) throws -> Data {
        field(4, field(2, Data(tool.utf8)) + field(3, try JSONSerialization.data(withJSONObject: args)))
    }

    @Test func wireDecodingIgnoresUnrelatedJSONAndRejectsMalformedFields() throws {
        let record = try metadata(tool: "read_file", args: ["Path": "/project/café.swift"])
        let unrelated = field(35, try JSONSerialization.data(withJSONObject: ["toolSummary": "Wrong detail"]))
        #expect(AntigravityStepDecoder.activity(metadata: record + unrelated, payload: Data(), stepType: 132) == "Read: café.swift")
        #expect(AntigravityStepDecoder.activity(metadata: unrelated, payload: Data(), stepType: 132) == nil)
        #expect(AntigravityStepDecoder.activity(metadata: Data(record.dropLast()), payload: Data(), stepType: 132) == nil)
        #expect(AntigravityStepDecoder.activity(metadata: Data([0x22, 0xff]), payload: Data(), stepType: 132) == nil)
    }

    @Test @MainActor func inactiveAndStaleSnapshotsCannotReviveOrOverwriteSessions() {
        let adapter = AntigravityAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString
        defer { state.removeSession(agent: .antigravity, sessionID: id) }
        let old = AntigravityDatabase.StepState(waitingApprovals: [1: "Permission: old"], activeActivity: "Old text")
        adapter.applyStepState(old, sessionID: id, surface: .dedicatedWindow)
        state.beginAgentEvent(agent: .antigravity, sessionID: id)
        #expect(state.status != .working && state.status != .waitingApproval)
        adapter.consumeHook(["event": "PreInvocation", "conversationId": id])
        adapter.consumeHook(["event": "PostToolUse", "conversationId": id,
            "toolCall": ["name": "read_file", "args": ["Path": "/project/Settings.swift"]]])
        adapter.consumeHook(["event": "PreInvocation", "conversationId": id])
        adapter.applyStepState(old, sessionID: id, surface: .dedicatedWindow, epoch: UUID())
        state.beginAgentEvent(agent: .antigravity, sessionID: id)
        #expect(state.status == .working)
        #expect(state.message == "Read: Settings.swift")
        state.endSession(agent: .antigravity, sessionID: id)
        adapter.applyStepState(old, sessionID: id, surface: .dedicatedWindow)
        state.beginAgentEvent(agent: .antigravity, sessionID: id)
        #expect(state.status == .idle)
    }

    @Test @MainActor func summaryReconciliationEndsStoppedSessionEvenWithSubsecondClockSkew() {
        let adapter = AntigravityAgentAdapter.shared, state = AgentStateManager.shared
        let id = UUID().uuidString
        defer { state.removeSession(agent: .antigravity, sessionID: id) }
        adapter.consumeHook(["event": "PreInvocation", "conversationId": id])
        state.beginAgentEvent(agent: .antigravity, sessionID: id)
        #expect(state.status == .working)
        adapter.reconcileSummaryIdleSessions([id])
        state.beginAgentEvent(agent: .antigravity, sessionID: id)
        #expect(state.status == .idle)
    }

}
