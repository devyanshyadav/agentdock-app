import Foundation

/// Native provider fields drive lifecycle and metadata; transcript text is a fallback.
struct AntigravityActivityEvent {
    let session: String
    let status: AgentStatus
    let text: String?
    let model: String?
    let transcript: String?
    let environment: AgentEnvironment
    let startsInvocation: Bool
    let authoritative: Bool
    let requestStep: Int?
    let resolvesRequest: Bool
    let confirmationPending: Bool?

    static func decode(_ json: [String: Any]) -> Self? {
        guard let event = json["event"] as? String,
              ["PreInvocation", "PostInvocation", "PreToolUse", "PostToolUse", "Stop", "StatusLine"].contains(event),
              let id = json["conversationId"] as? String ?? json["conversation_id"] as? String, UUID(uuidString: id) != nil else { return nil }
        let rawPath = json["transcriptPath"] as? String ?? json["transcript_path"] as? String
        let rawArtifact = json["artifactDirectoryPath"] as? String ?? json["artifact_directory_path"] as? String
        let artifactPath = rawArtifact.map { ($0 as NSString).expandingTildeInPath }
        let path = rawPath.map { ($0 as NSString).expandingTildeInPath }
            ?? artifactPath.map { URL(fileURLWithPath: $0).appendingPathComponent(".system_generated/logs/transcript.jsonl").path }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/brain/" + id + "/.system_generated/logs/transcript.jsonl").path
        guard event != "StatusLine" || json["tool_confirmation_pending"] as? Bool == true
            || ["idle", "thinking", "working", "tool_use", "initializing"].contains(json["agent_state"] as? String ?? "") else { return nil }
        let model = json["modelName"] as? String ?? (json["model"] as? [String: Any])?["display_name"] as? String
            ?? (json["model"] as? [String: Any])?["id"] as? String
        let surfacePath = rawPath ?? rawArtifact ?? path
        let surface: AgentEnvironment = event == "StatusLine" || surfacePath.contains("/antigravity-cli/") ? .cli
            : surfacePath.contains("/antigravity-ide/") ? .ide : .dedicatedWindow
        var status: AgentStatus = .working
        var text: String?
        let tool = json["toolCall"] as? [String: Any]
        let request = tool.flatMap(requestText)
        let step = json["stepIdx"] as? Int
        if event == "PreToolUse" {
            guard request != nil, let step, step >= 0 else { return nil }
        }
        var authoritative = event == "Stop" || event == "StatusLine"
        if event == "Stop" || event == "PostInvocation" {
            let reason = (json["terminationReason"] as? String ?? json["reason"] as? String ?? "").lowercased()
            let fullyIdle = json["fullyIdle"] as? Bool
            if let error = json["error"] as? String, !error.isEmpty {
                status = .error; text = preview(error); authoritative = true
            } else if reason == "error" || reason == "failed" {
                status = .error; authoritative = true
            } else if ["cancelled", "canceled", "aborted", "interrupted", "user_cancel", "user_canceled", "user_cancelled", "user_stop", "stop", "halted_step"].contains(reason) {
                status = .idle; authoritative = true
            } else if fullyIdle == false && event == "Stop" {
                // An intermediate sub-step stop while the outer turn is still active.
                status = .working; authoritative = false
            } else {
                status = ["model_stop", "completed", "no_tool_call", "terminal_step_type", "terminal_custom_hook", "injected_response", "max_invocations", "max_forced_invocations", "max_token_budget_exceeded"].contains(reason) ? .completed : .idle
                authoritative = true
            }
        } else if event == "StatusLine" {
            if json["tool_confirmation_pending"] as? Bool == true { status = .waitingApproval; text = "Approval required" }
            else if ["idle", "initializing"].contains(json["agent_state"] as? String ?? "") {
                // Queued tasks and CLI initialization do not mean an agent is running.
                status = .idle
            }
        } else if event == "PreToolUse" {
            status = .waitingApproval
            text = request
        } else if event == "PostToolUse", let tool {
            text = toolText(tool)
            if let error = json["error"] as? String, !error.isEmpty { text = preview("Error: " + error) }
        }
        return Self(session: id, status: status, text: text, model: model, transcript: path,
                    environment: surface, startsInvocation: event == "PreInvocation",
                    authoritative: authoritative,
                    requestStep: request != nil ? step : nil,
                    resolvesRequest: event == "PostToolUse",
                    confirmationPending: event == "StatusLine" ? json["tool_confirmation_pending"] as? Bool ?? false : nil)
    }

    static func requestText(_ tool: [String: Any]) -> String? {
        let args = tool["args"] as? [String: Any] ?? [:]
        switch tool["name"] as? String {
        case "ask_question":
            // Native transcripts may encode this array as a JSON string.
            var questions = args["questions"] as? [[String: Any]]
            if let encoded = cleanArg(args["questions"]), let data = encoded.data(using: .utf8) {
                questions = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            }
            let question = questions?.lazy.compactMap { cleanArg($0["question"]) }.first { !preview($0).isEmpty }
            return question.map { preview("Question: " + $0) } ?? "Question: Needs your answer"
        case "ask_permission":
            if let reason = cleanArg(args["Reason"]), !preview(reason).isEmpty { return preview("Permission: " + reason) }
            let action = cleanArg(args["Action"]) ?? "Permission"
            let target = cleanArg(args["Target"]) ?? ""
            return preview(action + (target.isEmpty ? "" : ": " + target))
        default: return nil
        }
    }

    /// Antigravity transcripts encode tool argument values as protojson string literals (e.g. `"\"git status\""`).
    static func cleanArg(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        var text = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            if let data = text.data(using: .utf8),
               let decoded = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String {
                text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.isEmpty ? nil : text
    }

    static func preview(_ text: String) -> String {
        String(text.prefix(240)).split(whereSeparator: { $0.isNewline }).first.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
        } ?? ""
    }

    private static let transcriptLabels = [
        "VIEW_FILE": "Reading a file", "GREP_SEARCH": "Searching files",
        "RUN_COMMAND": "Running a command", "CODE_ACTION": "Editing code",
        "LIST_DIRECTORY": "Listing a directory", "READ_URL_CONTENT": "Reading a web page",
        "SEARCH_WEB": "Searching the web", "GENERATE_IMAGE": "Generating an image"
    ]

    private static func semanticPrefix(for toolName: String) -> String? {
        switch toolName {
        case "run_command", "command_status", "send_command_input": return "Command"
        case "read_file", "view_file", "view_file_outline", "view_code_item", "read_url_content", "read_Deployment_Config": return "Read"
        case "edit_file", "write_file", "write_to_file", "replace_file_content", "multi_replace_file_content": return "Edit"
        case "grep_search", "find_by_name", "search_web": return "Search"
        case "list_dir", "list_resources": return "Workspace"
        case "invoke_subagent", "browser_subagent", "manage_subagents", "manage_task", "task_boundary": return "Task"
        case "ask_question": return "Question"
        case "ask_permission": return "Permission"
        default: return nil
        }
    }

    private static func applySemanticPrefix(_ text: String, toolName: String) -> String {
        guard !text.contains(":"), let label = semanticPrefix(for: toolName) else { return text }
        return preview(label + ": " + text)
    }

    static func toolText(_ tool: [String: Any]) -> String {
        let name = cleanArg(tool["name"]) ?? "Tool"
        let args = tool["args"] as? [String: Any] ?? tool["parameters"] as? [String: Any] ?? [:]
        if let summary = ["toolSummary", "toolAction"].lazy
            .compactMap({ cleanArg(tool[$0]) ?? cleanArg(args[$0]) }).map({ preview($0) }).first(where: { !$0.isEmpty }) {
            return applySemanticPrefix(summary, toolName: name)
        }
        let pathKeys: Set<String> = ["Path", "AbsolutePath", "TargetFile", "DirectoryPath", "SearchPath"]
        let detailKeys = ["Description", "Instruction", "CommandLine", "Query", "query", "Path", "AbsolutePath", "TargetFile", "DirectoryPath", "SearchPath", "Url", "Task", "Prompt", "TaskName", "TaskStatus", "Role"]
        for key in detailKeys {
            guard let raw = cleanArg(args[key]), !preview(raw).isEmpty else { continue }
            let detail: String
            if pathKeys.contains(key), raw.contains("/") {
                let last = URL(fileURLWithPath: raw).lastPathComponent
                detail = last.isEmpty ? raw : last
            } else {
                detail = raw
            }
            let prefix = semanticPrefix(for: name) ?? name
            return preview(prefix + ": " + detail)
        }
        if let prefix = semanticPrefix(for: name) {
            return preview(prefix + ": " + name.replacingOccurrences(of: "_", with: " "))
        }
        return preview(name)
    }

    /// Decode public activity metadata, never the file contents or command output
    /// included later in a transcript record.
    static func transcriptText(_ json: [String: Any]) -> String? {
        guard let type = json["type"] as? String else { return nil }
        if type == "PLANNER_RESPONSE" {
            if let tools = json["tool_calls"] as? [[String: Any]], let tool = tools.last { return toolText(tool) }
            if let thinking = cleanArg(json["thinking"]) {
                let thought = preview(thinking)
                if !thought.isEmpty { return preview("Thought: " + thought) }
            }
            if let content = json["content"] as? String {
                let text = preview(content)
                if !text.isEmpty { return preview("Response: " + text) }
            }
            return nil
        }
        guard let label = transcriptLabels[type] else { return nil }
        let content = String((json["content"] as? String ?? "").prefix(4096))
        if type == "SEARCH_WEB",
           let start = content.range(of: "The search for \""),
           let end = content[start.upperBound...].firstIndex(of: "\"") {
            let query = String(content[start.upperBound..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty { return preview(label + ": " + query) }
        }
        // Only recognized metadata headings qualify as details. Arbitrary body lines
        // can be source code, execution output, or user text.
        let headings = type == "VIEW_FILE" ? ["File Path"] : ["Command Line", "Command", "Query", "Summary", "Title", "Using prompt"]
        for line in content.split(whereSeparator: { $0.isNewline }) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let heading = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard headings.contains(heading) else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let detail = type == "VIEW_FILE" ? URL(fileURLWithPath: value).lastPathComponent : value
            return preview(label + ": " + detail)
        }
        return label
    }
    static func isTranscript(_ path: String, session: String) -> Bool {
        guard UUID(uuidString: session) != nil else { return false }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        return ["antigravity", "antigravity-ide", "antigravity-cli"].contains {
            file.path == base.appendingPathComponent($0 + "/brain/" + session + "/.system_generated/logs/transcript.jsonl").path
                && file.resolvingSymlinksInPath().path == file.path
        }
    }
}
