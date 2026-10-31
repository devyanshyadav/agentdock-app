import AppKit
import CryptoKit

/// Hooks supply approvals and tool details; transcripts recover missed lifecycle events.
@MainActor
public final class CodexAgentAdapter: AgentAdapter {
    public static let shared = CodexAgentAdapter()
    public let kind: AgentKind = .codex
    public let displayName = "Codex"
    public private(set) var environment: AgentEnvironment = .dedicatedWindow
    public private(set) var isActive = false
    public private(set) var lastActivityDate = Date.distantPast
    public private(set) var currentModel = ""
    nonisolated static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt"]
    enum Receipt { case accepted, invalid, capacityExceeded }
    private struct Session {
        var turn: String?
        var model = ""
        var text = ""
        var status: AgentStatus = .idle
        var finished = false
        var updated = Date()
        var ownerPID: Int32?
        var surface: AgentEnvironment = .dedicatedWindow
        var lastTranscriptDate = Date.distantPast
        var lastHookDate: Date?
        var hookHasDetail = false
        var turnStartedAt = Date.distantPast
        var requests: [(key: Data, text: String, survivesTurnEnd: Bool)] = []
    }
    private var sessions: [String: Session] = [:]
    private var retired = Set<String>()
    private var retiredOrder: [String] = []
    private var transcriptMonitor: CodexTranscriptMonitor?
    // Allow the native hook's bounded delivery to arrive before using a transcript update.
    private static let hookGrace: TimeInterval = 1
    private struct PendingTranscript {
        let start: CodexTranscriptEvent?
        let latest: CodexTranscriptEvent
        let task: Task<Void, Never>
    }
    private var pendingTranscripts: [String: PendingTranscript] = [:]
    private init() {}
    public func start() {
        guard transcriptMonitor == nil else { return }
        let monitor = CodexTranscriptMonitor(
            root: CodexHookInstaller.baseDirectory.appendingPathComponent("sessions").path,
            onEvent: { [weak self] event in self?.consumeTranscript(event) },
            onUsage: { UsageStore.shared.recordSession($0, for: .codex) })
        transcriptMonitor = monitor; monitor.start()
    }
    public func stop() {
        transcriptMonitor?.stop(); transcriptMonitor = nil
        pendingTranscripts.values.forEach { $0.task.cancel() }; pendingTranscripts.removeAll()
    }
    public func focus() {
        if focusEnvironment == .cli { AgentFocusCoordinator.shared.focusTerminal(); return }
        let workspace = NSWorkspace.shared
        let bundle = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") != nil
            ? "com.openai.codex" : "com.openai.chat"
        AgentFocusCoordinator.shared.activateApp(bundleId: bundle)
    }
    @discardableResult func consumeHook(_ json: [String: Any]) -> Receipt {
        guard let event = json["hook_event_name"] as? String, Self.events.contains(event),
              let id = json["session_id"] as? String, !id.isEmpty, id.utf8.count <= 256 else { return .invalid }
        let turn = json["turn_id"] as? String
        let child = event.hasPrefix("Subagent") ? json["agent_id"] as? String : nil
        if event.hasPrefix("Subagent"), child?.isEmpty != false { return .invalid }
        guard turn.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              child.map({ $0.utf8.count <= 256 }) ?? true else { return .invalid }
        let key = child.map { id + ":subagent:" + $0 } ?? id
        if let turn, retired.contains(key + ":" + turn), !["SessionStart", "SessionEnd"].contains(event) { return .accepted }
        if child != nil, sessions[id]?.finished == true, sessions[key] == nil { return .accepted }
        guard retain(key) else { return .capacityExceeded }
        var session = sessions[key] ?? Session()
        let startEvent = event == "UserPromptSubmit" || event == "SubagentStart"
        let starts = startEvent && (session.finished || session.status == .idle || turn == nil || session.turn != turn)
        if session.finished && !starts && !["SessionStart", "SessionEnd"].contains(event) { return .accepted }
        if starts {
            if let previous = session.turn, previous != turn { retire(key + ":" + previous) }
            session.finished = false; session.text = ""; session.requests.removeAll()
            session.turnStartedAt = Date()
            session.turn = turn
        }
        if startEvent { session.text = "" }
        if let turn { session.turn = turn }
        if let model = json["model"] as? String, !model.isEmpty, model.utf8.count <= 256 { session.model = model }
        switch event {
        case "SessionStart":
            sessions[key] = session
            return .accepted // A session can be open while no turn is running.
        case "SessionEnd", "Interrupt": session.status = .idle; session.finished = true
        case "Stop", "SubagentStop":
            // The shared pending-request handling below keeps the question visible.
            if session.requests.contains(where: { $0.survivesTurnEnd }) { break }
            session.status = .completed; session.finished = true
            if let text = json["last_assistant_message"] as? String { session.text = preview("Response: " + text) }
        case "PermissionRequest", "PreToolUse", "PostToolUse":
            let question = event == "PreToolUse" ? questionText(json) : nil
            if event == "PermissionRequest" || question != nil {
                session.status = .waitingApproval
                session.text = question ?? approvalText(json)
                if let key = requestKey(json) {
                    if let index = session.requests.firstIndex(where: { $0.key == key }) {
                        session.requests[index].text = session.text
                    } else {
                        session.requests.append((key, session.text, json["tool_name"] as? String == "request_user_input_async"))
                    }
                }
            } else {
                // Async question tools return when the prompt is shown, before an answer.
                // Keep that question until the next prompt, session end, or interruption.
                if event == "PostToolUse", json["tool_name"] as? String != "request_user_input_async",
                   !session.requests.isEmpty, let key = requestKey(json),
                   let index = session.requests.firstIndex(where: { $0.key == key }) {
                    session.requests.remove(at: index)
                }
                session.status = .working; session.text = toolText(json)
            }
        case "PreCompact", "PostCompact":
            if !session.status.isLive { session.status = .observed }
            if let trigger = json["trigger"] as? String { session.text = preview("Compact: " + trigger) }
        default:
            session.status = .working
            if let child { session.text = preview("Subagent: " + (json["agent_type"] as? String ?? child)) }
        }
        if session.finished { session.requests.removeAll() }
        else if let request = session.requests.first {
            session.status = .waitingApproval; session.text = request.text
        }
        if session.finished, let turn = session.turn { retire(key + ":" + turn) }
        if child == nil, session.finished {
            let children = sessions.keys.filter { $0.hasPrefix(id + ":subagent:") }
            for child in children { sessions[child] = nil; AgentStateManager.shared.removeSession(agent: .codex, sessionID: child) }
        }
        if let pid = (json["_agentdock_pid"] as? NSNumber).map({ Int32(truncating: $0) }) { session.ownerPID = pid }
        let surface: AgentEnvironment = (json["_agentdock_surface"] as? String) == "cli" ? .cli : .dedicatedWindow
        session.surface = surface
        session.lastHookDate = Date()
        session.hookHasDetail = !session.text.isEmpty && session.text != (json["tool_name"] as? String)
        sessions[key] = session
        if session.finished { cancelPendingTranscript(key) }
        else if let pending = pendingTranscripts[key] { deferTranscript(pending.latest, start: pending.start) }
        publish(key, session: session, surface: surface, startsTurn: starts)
        return .accepted
    }
    /// Merge by the same session/turn IDs as hooks. A repeated start/stop never
    /// reopens a finished turn or extends its completion banner.
    func consumeTranscript(_ event: CodexTranscriptEvent) {
        consumeTranscript(event, afterHookGrace: false)
    }
    private func consumeTranscript(_ event: CodexTranscriptEvent, afterHookGrace: Bool) {
        let id = event.sessionID
        guard retain(id) else { return }
        var session = sessions[id] ?? Session()
        guard event.date >= session.lastTranscriptDate else { return }
        if let turn = event.turnID, retired.contains(id + ":" + turn) { return }
        // Async questions outlive the assistant turn. Only a new prompt, interrupt,
        // or session end resolves them; a transcript completion is not an answer.
        if event.status == .completed, session.requests.contains(where: { $0.survivesTurnEnd }),
           event.turnID == nil || session.turn == nil || event.turnID == session.turn {
            session.lastTranscriptDate = event.date
            sessions[id] = session
            return
        }
        let hookOwnsCurrentTurn = session.lastHookDate != nil && session.status.isLive
            && (session.turn == nil || event.turnID == nil || session.turn == event.turnID)
        if hookOwnsCurrentTurn && event.status.isLive {
            // Silence during a model request/tool is normal. Keep native progress for
            // this turn; only learn its missing ID so lifecycle fallback can correlate it.
            if session.turn == nil { session.turn = event.turnID }
            session.lastTranscriptDate = event.date
            let fillsDetail = session.status == .working && !session.hookHasDetail && event.hasDetail
            if fillsDetail { session.text = event.text }
            sessions[id] = session
            if fillsDetail { publish(id, session: session, surface: session.surface) }
            return
        }
        if !afterHookGrace, let hookDate = session.lastHookDate,
           hookOwnsCurrentTurn || Date() < hookDate.addingTimeInterval(Self.hookGrace) {
            deferTranscript(event)
            return
        }
        if let current = session.turn, let turn = event.turnID, current != turn {
            guard event.startsTurn, event.date > session.turnStartedAt else { return }
        }
        let sameTurn = event.turnID != nil && event.turnID == session.turn
        if session.finished && (sameTurn || !event.startsTurn) { return }
        let starts = event.startsTurn && (!sameTurn || session.turnStartedAt == .distantPast)
            || session.turn == nil && session.status == .idle && event.status.isLive
        if starts {
            if let previous = session.turn, previous != event.turnID { retire(id + ":" + previous) }
            session.turnStartedAt = event.date
            session.finished = false; session.requests.removeAll(); session.text = ""
        }
        session.lastTranscriptDate = event.date
        if let turn = event.turnID { session.turn = turn }
        if !event.model.isEmpty { session.model = event.model }
        if session.ownerPID == nil { session.surface = event.surface }
        // Hook-provided question/permission state wins over generic transcript progress.
        session.status = event.status
        session.text = event.text
        if event.status.isLive, let request = session.requests.first {
            session.status = .waitingApproval; session.text = request.text
        }
        if !event.status.isLive {
            session.finished = true; session.requests.removeAll()
            if let turn = session.turn { retire(id + ":" + turn) }
            let children = sessions.keys.filter { $0.hasPrefix(id + ":subagent:") }
            for child in children { sessions[child] = nil; AgentStateManager.shared.removeSession(agent: .codex, sessionID: child) }
        }
        sessions[id] = session
        publish(id, session: session, surface: session.surface, startsTurn: starts)
    }
    private func cancelPendingTranscript(_ id: String) {
        pendingTranscripts.removeValue(forKey: id)?.task.cancel()
    }

    /// Keep at most a start and the latest update per session. This preserves a
    /// missed turn boundary without queuing every transcript line during hook delivery.
    private func deferTranscript(_ event: CodexTranscriptEvent, start suppliedStart: CodexTranscriptEvent? = nil) {
        let id = event.sessionID
        let previous = pendingTranscripts[id]
        if let previous {
            guard event.date >= previous.latest.date else { return }
            if previous.latest.turnID != event.turnID && !event.startsTurn { return }
        }
        let start = suppliedStart ?? (event.startsTurn ? event : previous?.start)
        cancelPendingTranscript(id)
        let deadline = Date().addingTimeInterval(Self.hookGrace)
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled, let self, let pending = self.pendingTranscripts.removeValue(forKey: id) else { return }
            if let start = pending.start { self.consumeTranscript(start, afterHookGrace: true) }
            if pending.latest.startsTurn == false { self.consumeTranscript(pending.latest, afterHookGrace: true) }
        }
        pendingTranscripts[id] = PendingTranscript(start: start, latest: event, task: task)
    }
    private func retain(_ id: String) -> Bool {
        if sessions[id] != nil { return true }
        if sessions.count >= 256 {
            guard let old = sessions.filter({ !$0.value.status.isLive }).min(by: { $0.value.updated < $1.value.updated })?.key else { return false }
            cancelPendingTranscript(old)
            sessions[old] = nil; AgentStateManager.shared.removeSession(agent: .codex, sessionID: old)
        }
        sessions[id] = Session(); return true
    }
    private func retire(_ key: String) {
        if retired.insert(key).inserted { retiredOrder.append(key) }
        if retiredOrder.count > 1024 { retired.remove(retiredOrder.removeFirst()) }
    }
    private func publish(_ id: String, session: Session, surface: AgentEnvironment, startsTurn: Bool = false) {
        sessions[id]?.updated = Date()
        environment = surface; currentModel = session.model
        isActive = sessions.values.contains { $0.status.isLive }; lastActivityDate = Date()
        AgentStateManager.shared.update(agent: .codex, status: session.status, message: session.text, model: session.model, sessionID: id, environment: surface, startsTurn: startsTurn, ownerPID: session.ownerPID)
    }

    public func sessionDidEnd(_ sessionID: String, close: Bool) {
        guard var session = sessions[sessionID] else { return }
        session.status = .idle
        session.requests.removeAll()
        if close {
            session.finished = true
            if let turn = session.turn { retire(sessionID + ":" + turn) }
            cancelPendingTranscript(sessionID)
        }
        sessions[sessionID] = session
        isActive = sessions.values.contains { $0.status.isLive }
    }
    private func preview(_ text: String) -> String {
        String(text.prefix(240)).split(whereSeparator: { $0.isNewline }).first.map { String($0.prefix(220)) } ?? ""
    }
    private func toolText(_ json: [String: Any]) -> String {
        CodexTranscriptDecoder.activityDescription(name: json["tool_name"] as? String ?? "Tool",
            input: json["tool_input"] as? [String: Any] ?? [:])
    }

    private func approvalText(_ json: [String: Any]) -> String {
        let args = json["tool_input"] as? [String: Any] ?? [:]
        let reason = (args["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = reason.flatMap { $0.isEmpty ? nil : $0.split(whereSeparator: { $0.isNewline }).joined(separator: " ") }
        return preview("Approval: " + (detail ?? toolText(json)))
    }

    private func questionText(_ json: [String: Any]) -> String? {
        guard let name = json["tool_name"] as? String,
              ["request_user_input", "request_user_input_async"].contains(name),
              let args = json["tool_input"] as? [String: Any],
              let questions = args["questions"] as? [[String: Any]],
              let question = questions.lazy.compactMap({ ($0["question"] as? String ?? $0["title"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) else { return nil }
        return preview("Question: " + question.split(whereSeparator: { $0.isNewline }).joined(separator: " "))
    }

    private func requestKey(_ json: [String: Any]) -> Data? {
        guard let name = json["tool_name"] as? String else { return nil }
        var input: Any = json["tool_input"] ?? NSNull()
        // PermissionRequest has no documented tool_use_id. Bash/edit approval inputs
        // add a description and omit execution options, so correlate by command.
        if ["Bash", "apply_patch"].contains(name), let command = (input as? [String: Any])?["command"] {
            input = command
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["tool": name, "input": input], options: [.sortedKeys]) else { return nil }
        // Retain a fixed-size identity rather than entire commands, patches or MCP inputs.
        return Data(SHA256.hash(data: data))
    }
}
