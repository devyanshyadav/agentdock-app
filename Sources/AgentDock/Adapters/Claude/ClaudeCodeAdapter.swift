import AppKit
import Foundation
import CryptoKit

/// Native hook events own lifecycle. Session creation and saved text never imply active work.
@MainActor
public final class ClaudeCodeAdapter: AgentAdapter {
    public static let shared = ClaudeCodeAdapter()
    public let kind: AgentKind = .claude
    public let displayName = "Claude Code"
    public private(set) var environment: AgentEnvironment = .cli
    public private(set) var isActive = false
    public private(set) var lastActivityDate = Date.distantPast
    public private(set) var currentModel = ""
    /// Official hook event names validated by Claude Code's settings.json Zod schema (`CKA`).
    /// Writing unrecognized hook keys into settings.json causes Claude Code's Zod parser (`G0A`)
    /// to reject the entire settings.json and disable all hooks (`Found 0 hook matchers`).
    nonisolated static let installedEvents = ["PreToolUse", "PostToolUse", "Notification", "UserPromptSubmit", "SessionStart", "SessionEnd", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PermissionRequest"]
    nonisolated static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "MessageDisplay", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied", "Notification", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "PreCompact", "PostCompact", "PostModelSwitch", "Elicitation", "ElicitationResult", "TaskCreated", "TaskCompleted"]
    enum Receipt { case accepted, invalid, capacityExceeded }
    private struct Session {
        var prompt: String?
        var model = ""
        var text = ""
        var status: AgentStatus = .idle
        var finished = false
        var updated = Date()
        var messageID: String?
        var messageIndex = 0
        var response = ""
        var ownerPID: Int32?
        var surface: AgentEnvironment = .cli
        var transcript: String?
        var requests: [(key: Data, text: String)] = []
        var notificationText: String?
    }
    private var sessions: [String: Session] = [:]
    private var retired = Set<String>()
    private var retiredOrder: [String] = []
    /// Claude Code does not fire Stop on user interrupt and reports its model only at session
    /// start. Its documented transcript file carries both, so each live session tails it.
    private var transcriptTails: [String: LogStreamWatcher] = [:]
    private var transcriptOrder: [String] = []
    private static let maxTranscriptTails = 32
    private init() {}
    public func start() {}
    public func stop() {
        transcriptTails.values.forEach { $0.stop() }
        transcriptTails.removeAll()
        transcriptOrder.removeAll()
    }
    public func focus() {
        switch focusEnvironment {
        case .cli:
            AgentFocusCoordinator.shared.focusTerminal()
        case .ide:
            let ideBundles = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed"]
            if let running = ideBundles.first(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
                AgentFocusCoordinator.shared.activateApp(bundleId: running)
            } else {
                AgentFocusCoordinator.shared.focusTerminal()
            }
        default:
            AgentFocusCoordinator.shared.activateApp(bundleId: "com.anthropic.claudefordesktop", fallbackPath: "/Applications/Claude.app")
        }
    }
    @discardableResult func consumeHook(_ json: [String: Any]) -> Receipt {
        guard json["cursor_version"] == nil,
              let event = json["hook_event_name"] as? String, Self.events.contains(event),
              let id = json["session_id"] as? String, !id.isEmpty, id.utf8.count <= 256 else { return .invalid }
        let prompt = json["prompt_id"] as? String
        let agent = json["agent_id"] as? String
        guard prompt.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              agent.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { return .invalid }
        let key = agent.map { id + ":subagent:" + $0 } ?? id
        if let prompt, retired.contains(key + ":" + prompt), !["SessionEnd", "SessionStart", "PostModelSwitch"].contains(event) { return .accepted }
        if agent != nil, sessions[id]?.finished == true, sessions[key] == nil { return .accepted }
        guard retain(key) else { return .capacityExceeded }
        var session = sessions[key] ?? Session()
        let starts = event == "UserPromptSubmit" || event == "SubagentStart"
        let metadata = event == "SessionStart" || event == "PostModelSwitch"
        if session.finished && !starts && !metadata && !["SessionEnd", "SessionStart", "PostModelSwitch"].contains(event) { return .accepted }
        if starts {
            if let previous = session.prompt, previous != prompt { retire(key + ":" + previous) }
            session.finished = false; session.text = ""; session.response = ""; session.messageID = nil; session.messageIndex = 0
            session.requests.removeAll(); session.notificationText = nil
        }
        if let prompt { session.prompt = prompt }
        if event == "SessionStart", let model = json["model"] as? String, model.utf8.count <= 256 { session.model = model }
        if event == "PostModelSwitch", let model = json["to_model"] as? String, model.utf8.count <= 256 { session.model = model }
        switch event {
        case "SessionStart", "PostModelSwitch":
            sessions[key] = session
            if !session.status.isLive { return .accepted }
        case "UserPromptSubmit", "SubagentStart":
            session.status = .working
            if let agent { session.text = preview("Subagent: " + (json["agent_type"] as? String ?? agent)) }
        case "MessageDisplay":
            guard session.status.isLive, let message = json["message_id"] as? String, !message.isEmpty, message.utf8.count <= 256,
                  let index = json["index"] as? Int, index >= 0, let delta = json["delta"] as? String else { return .accepted }
            if session.messageID != message { session.messageID = message; session.messageIndex = 0; session.response = "" }
            guard index >= session.messageIndex else { return .accepted }
            session.messageIndex = index + 1
            session.response = String((session.response + String(delta.prefix(240))).prefix(240))
            session.text = preview("Response: " + session.response)
        case "PermissionRequest", "Elicitation":
            session.status = .waitingApproval
            session.text = event == "Elicitation"
                ? preview("Question: " + (json["message"] as? String ?? json["mcp_server_name"] as? String ?? "Input requested"))
                : (json["tool_name"] as? String == "AskUserQuestion" ? toolText(json) : preview("Approval: " + toolText(json)))
            if let key = requestKey(json, elicitation: event == "Elicitation") {
                if let index = session.requests.firstIndex(where: { $0.key == key }) { session.requests[index].text = session.text }
                else { session.requests.append((key, session.text)) }
            }
        case "PreToolUse", "PostToolUse", "PermissionDenied", "ElicitationResult":
            session.status = .working
            session.notificationText = nil
            if event != "PreToolUse", !session.requests.isEmpty,
               let key = requestKey(json, elicitation: event == "ElicitationResult"),
               let index = session.requests.firstIndex(where: { $0.key == key }) { session.requests.remove(at: index) }
            if event == "ElicitationResult" || event == "PostToolUse" && json["tool_name"] as? String == "AskUserQuestion" { session.text = "" }
            else if json["tool_name"] != nil { session.text = toolText(json) }
            // These tools ask for input themselves, even when no permission hook fires.
            if event == "PreToolUse", let name = json["tool_name"] as? String,
               name == "AskUserQuestion" || name == "ExitPlanMode", let key = requestKey(json) {
                session.status = .waitingApproval
                if let index = session.requests.firstIndex(where: { $0.key == key }) {
                    session.requests[index].text = session.text
                } else { session.requests.append((key, session.text)) }
            }
        case "PostToolUseFailure":
            session.notificationText = nil
            if !session.requests.isEmpty, let key = requestKey(json),
               let index = session.requests.firstIndex(where: { $0.key == key }) { session.requests.remove(at: index) }
            session.text = preview("Error: " + (json["error"] as? String ?? toolText(json)))
            if json["is_interrupt"] as? Bool == true { session.status = .idle; session.finished = true }
            else { session.status = .working }
        case "Notification":
            let type = json["notification_type"] as? String
            if ["permission_prompt", "worker_permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"].contains(type ?? "") {
                session.status = .waitingApproval
                let rawMessage = preview(json["message"] as? String ?? "")
                let prefix = (type?.contains("elicitation") == true || type == "agent_needs_input") ? "Question: " : "Approval: "
                if !session.text.isEmpty && !session.text.hasPrefix("Response: ") && !session.text.hasPrefix("Thought: ") && !session.text.hasPrefix("Approval: ") && !session.text.hasPrefix("Question: ") {
                    session.notificationText = preview(prefix + session.text)
                } else if !rawMessage.isEmpty {
                    session.notificationText = rawMessage.hasPrefix("Approval: ") || rawMessage.hasPrefix("Question: ")
                        ? rawMessage : preview(prefix + rawMessage)
                } else {
                    session.notificationText = preview(prefix + "Input requested")
                }
                session.text = session.notificationText ?? session.text
            } else if ["elicitation_complete", "elicitation_response"].contains(type ?? ""), session.notificationText != nil {
                session.notificationText = nil; session.status = .working; session.text = ""
            } else if type == "idle_prompt", session.status == .working { session.status = .idle; session.finished = true }
            else { return .accepted } // Notifications such as authentication success do not start a turn.
        case "Stop", "SubagentStop":
            session.status = .completed; session.finished = true
            if let text = json["last_assistant_message"] as? String { session.text = preview("Response: " + text) }
        case "StopFailure":
            session.status = .error; session.finished = true
            session.text = preview(json["error_details"] as? String ?? json["error"] as? String ?? "")
        case "SessionEnd": session.status = .idle; session.finished = true
        default:
            if !session.status.isLive { session.status = .observed }
            if let text = json["task_subject"] as? String { session.text = preview(event + ": " + text) }
            else if let trigger = json["trigger"] as? String { session.text = preview("Compact: " + trigger) }
        }
        if session.finished { session.requests.removeAll(); session.notificationText = nil }
        else if let text = session.requests.first?.text ?? session.notificationText {
            session.status = .waitingApproval; session.text = text
        }
        if session.finished, let prompt = session.prompt { retire(key + ":" + prompt) }
        if agent == nil, event == "SessionEnd" || event == "Stop" && (json["background_tasks"] as? [[String: Any]])?.isEmpty == true {
            for child in sessions.keys.filter({ $0.hasPrefix(id + ":subagent:") }) {
                sessions[child] = nil; AgentStateManager.shared.removeSession(agent: .claude, sessionID: child)
            }
        }
        let rawSurface = json["_agentdock_surface"] as? String
        let surface: AgentEnvironment = rawSurface == "cli" ? .cli : rawSurface == "ide" ? .ide : .dedicatedWindow
        session.surface = surface
        if let pid = (json["_agentdock_pid"] as? NSNumber).map({ Int32(truncating: $0) }) { session.ownerPID = pid }
        if agent == nil, let path = json["transcript_path"] as? String, !path.isEmpty { session.transcript = path }
        sessions[key] = session
        publish(key, session: session, surface: surface, startsTurn: starts)
        if agent == nil {
            if session.finished { stopTranscript(key) }
            else if let path = session.transcript { watchTranscript(path, key: key) }
        }
        return .accepted
    }
    private func retain(_ id: String) -> Bool {
        if sessions[id] != nil { return true }
        if sessions.count >= 256 {
            guard let old = sessions.filter({ !$0.value.status.isLive }).min(by: { $0.value.updated < $1.value.updated })?.key else { return false }
            stopTranscript(old)
            sessions[old] = nil; AgentStateManager.shared.removeSession(agent: .claude, sessionID: old)
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
        AgentStateManager.shared.update(agent: .claude, status: session.status, message: session.text, model: session.model, sessionID: id, environment: surface, startsTurn: startsTurn, ownerPID: session.ownerPID)
    }

    public func sessionDidEnd(_ sessionID: String, close: Bool) {
        guard var session = sessions[sessionID] else { return }
        session.status = .idle
        session.requests.removeAll()
        session.notificationText = nil
        if close {
            session.finished = true
            if let prompt = session.prompt { retire(sessionID + ":" + prompt) }
            stopTranscript(sessionID)
        }
        sessions[sessionID] = session
        isActive = sessions.values.contains { $0.status.isLive }
    }

    // MARK: Transcript

    private func watchTranscript(_ path: String, key: String) {
        guard transcriptTails[key] == nil else { return }
        let configRoot = ClaudeHookInstaller.baseDirectory.path
        guard TranscriptSupport.isAllowed(path, under: [configRoot]) else { return }
        if transcriptTails.count >= Self.maxTranscriptTails, let oldest = transcriptOrder.first(where: { sessions[$0]?.status.isLive != true }) {
            stopTranscript(oldest)
        }
        guard transcriptTails.count < Self.maxTranscriptTails else { return }
        // Tailing starts at the current end of file, so only new records are observed;
        // the model of earlier turns is recovered from the file's tail once.
        let watcher = LogStreamWatcher(observesDirectory: false, discoverActiveFile: { (path, Date(), nil) },
                                       onLine: { [weak self] line, _ in self?.consumeTranscript(line, key: key) })
        transcriptTails[key] = watcher; transcriptOrder.append(key)
        watcher.start()
        if sessions[key]?.model.isEmpty != false {
            Task { [weak self] in
                let model = await Task.detached(priority: .utility) {
                    TranscriptSupport.tailLines(of: path).reversed().lazy.compactMap { Self.assistantModel($0) }.first
                }.value
                if let model { self?.adoptTranscriptModel(model, key: key) }
            }
        }
    }

    private func stopTranscript(_ key: String) {
        transcriptTails.removeValue(forKey: key)?.stop()
        transcriptOrder.removeAll { $0 == key }
    }

    nonisolated private static func assistantModel(_ line: String) -> String? {
        guard line.contains("\"assistant\""), let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "assistant", json["isSidechain"] as? Bool != true,
              let model = (json["message"] as? [String: Any])?["model"] as? String,
              !model.isEmpty, !model.hasPrefix("<") else { return nil }
        return model
    }

    private func adoptTranscriptModel(_ model: String, key: String) {
        guard var session = sessions[key], session.model != model else { return }
        session.model = model; sessions[key] = session
        AgentStateManager.shared.noteModel(model, for: .claude)
        if session.status.isLive { publish(key, session: session, surface: session.surface) }
    }

    func consumeTranscript(_ line: String, key: String) {
        // Tool results make most transcript lines large; only these two record kinds matter,
        // so skip JSON decoding for everything else.
        guard line.utf8.count <= 256 * 1024, // Bound decoding work per record, including unusually large assistant messages.
              line.contains("\"assistant\"") || line.contains("[Request interrupted") || line.contains("doesn't want to") || line.contains("Tool call rejected") || line.contains("proposed a plan that was rejected"),
              var session = sessions[key],
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["isSidechain"] as? Bool != true,
              let type = json["type"] as? String else { return }
        let message = json["message"] as? [String: Any]
        if type == "assistant", let message { UsageStore.shared.recordClaudeMessage(message, sessionID: key) }
        if type == "assistant", let message {
            if json["isApiErrorMessage"] as? Bool == true {
                guard session.status.isLive else { return }
                let blocks = message["content"] as? [[String: Any]] ?? []
                let errText = blocks.lazy.compactMap { $0["text"] as? String }.first { !preview($0).isEmpty }
                    ?? (json["error"] as? String) ?? "API error"
                session.status = .error
                session.finished = true
                session.requests.removeAll()
                session.notificationText = nil
                session.text = preview("Error: " + errText)
                if let prompt = session.prompt { retire(key + ":" + prompt) }
                sessions[key] = session
                publish(key, session: session, surface: session.surface)
                return
            }
            var changed = false
            defer {
                if changed {
                    sessions[key] = session
                    if session.status.isLive { publish(key, session: session, surface: session.surface) }
                }
            }
            if let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<"), model != session.model {
                session.model = model; changed = true
                AgentStateManager.shared.noteModel(model, for: .claude)
            }
            guard session.status.isLive, !session.finished else { return }
            let blocks = message["content"] as? [[String: Any]] ?? []
            // Use the latest available content block. Older clients do not emit MessageDisplay,
            // so transcript text and tool calls also supply activity without extra polling.
            guard session.status != .waitingApproval else { return }
            for block in blocks.reversed() {
                let text: String
                switch block["type"] as? String {
                case "tool_use":
                    guard let name = block["name"] as? String, !name.isEmpty else { continue }
                    let toolPayload: [String: Any] = ["tool_name": name, "tool_input": block["input"] ?? [:]]
                    text = toolText(toolPayload)
                    if (name == "AskUserQuestion" || name == "ExitPlanMode"), let reqKey = requestKey(toolPayload) {
                        session.status = .waitingApproval
                        if let idx = session.requests.firstIndex(where: { $0.key == reqKey }) {
                            session.requests[idx].text = text
                        } else {
                            session.requests.append((reqKey, text))
                        }
                        changed = true
                    }
                case "text", "thinking":
                    let thinking = block["type"] as? String == "thinking"
                    guard let content = block[thinking ? "thinking" : "text"] as? String else { continue }
                    let detail = preview(String(content.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines))
                    guard !detail.isEmpty else { continue }
                    text = preview((thinking ? "Thought: " : "Response: ") + detail)
                default: continue
                }
                if session.text != text {
                    session.text = text; changed = true
                }
                break
            }
        } else if type == "user", Self.isInterruption(message?["content"]) || Self.isInterruption(json["toolUseResult"]) {
            // Interrupting Claude Code never fires Stop; the transcript is the only record.
            guard session.status.isLive else { return }
            session.status = .idle; session.finished = true
            session.requests.removeAll(); session.notificationText = nil
            if let prompt = session.prompt { retire(key + ":" + prompt) }
            sessions[key] = session
            publish(key, session: session, surface: session.surface)
            // An interrupted turn also abandons its subagents, which may never send SubagentStop.
            for child in sessions.keys.filter({ $0.hasPrefix(key + ":subagent:") }) {
                sessions[child] = nil; AgentStateManager.shared.removeSession(agent: .claude, sessionID: child)
            }
        }
    }

    nonisolated private static func isInterruption(_ content: Any?) -> Bool {
        let markers = [
            "[Request interrupted by user",
            "The user doesn't want to proceed with this tool use.",
            "The user doesn't want to take this action right now.",
            "Tool call rejected -- yielding control back to user",
            "The agent proposed a plan that was rejected by the user."
        ]
        if let text = content as? String {
            return markers.contains { text.hasPrefix($0) }
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.contains { block in
                if let text = block["text"] as? String, markers.contains(where: { text.hasPrefix($0) }) { return true }
                if isInterruption(block["content"]) { return true }
                return false
            }
        }
        return false
    }
    private func preview(_ text: String) -> String {
        String(text.prefix(240)).split(whereSeparator: { $0.isNewline }).first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(220)) } ?? ""
    }
    private func cleanPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let base = (trimmed as NSString).lastPathComponent
        return base.isEmpty || base == "/" ? trimmed : base
    }
    private func toolText(_ json: [String: Any]) -> String {
        let name = json["tool_name"] as? String ?? "Tool"
        let args = json["tool_input"] as? [String: Any] ?? [:]
        if name == "AskUserQuestion", let questions = args["questions"] as? [[String: Any]],
           let question = questions.lazy.compactMap({ $0["question"] as? String }).first(where: { !preview($0).isEmpty }) {
            return preview("Question: " + question.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if name == "TodoWrite", let todos = args["todos"] as? [[String: Any]] {
            let active = todos.first(where: { ($0["status"] as? String) == "in_progress" }) ?? todos.first
            if let text = (active?["activeForm"] as? String ?? active?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return preview("Task: " + text)
            }
            return "Task: Updating todo list"
        }
        if name == "EnterPlanMode" { return "Plan: Entering plan mode" }
        if name == "ExitPlanMode" {
            if let path = (args["planFilePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return preview("Plan: " + cleanPath(path))
            }
            if let plan = (args["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
                return preview("Plan: " + plan)
            }
            return "Plan: Review implementation plan"
        }
        if let pathKey = ["file_path", "notebook_path", "path"].first(where: {
            guard let val = args[$0] as? String else { return false }
            return !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), let rawPath = args[pathKey] as? String {
            let file = cleanPath(rawPath)
            if name == "Grep" || name == "Glob",
               let pattern = (args["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty {
                return preview("\(name): \(pattern) (\(file))")
            }
            return preview("\(name): \(file)")
        }
        let detail = ["description", "command", "query", "pattern", "skill", "subagent_type", "prompt", "url", "plan"].lazy
            .compactMap { (args[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return preview(name + (detail.map { ": " + $0 } ?? ""))
    }

    private func requestKey(_ json: [String: Any], elicitation: Bool = false) -> Data? {
        let identity: [String: Any]
        if elicitation {
            guard let server = json["mcp_server_name"] as? String else { return nil }
            let id = json["elicitation_id"] as? String ?? ""
            identity = ["server": server, "id": id, "mode": id.isEmpty ? json["mode"] as? String ?? "form" : ""]
        } else {
            guard let name = json["tool_name"] as? String else { return nil }
            var input: Any = json["tool_input"] ?? NSNull()
            let args = input as? [String: Any] ?? [:]
            // PermissionRequest omits tool_use_id. Ignore answers added after a question,
            // and execution-only options added after shell approval.
            if name == "AskUserQuestion", let questions = args["questions"] { input = questions }
            else if name == "Bash", let command = args["command"] { input = command }
            else if name == "ExitPlanMode" {
                let response = json["tool_response"] as? [String: Any] ?? [:]
                input = args["planFilePath"] ?? response["filePath"] ?? args["plan"] ?? response["plan"] ?? NSNull()
            }
            identity = ["tool": name, "input": input]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}
