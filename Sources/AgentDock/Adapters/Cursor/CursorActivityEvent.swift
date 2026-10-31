import Foundation

/// Cursor's event text is presentation data. Lifecycle is used only for visibility and approvals.
struct CursorActivityEvent {
    let surface: AgentEnvironment
    let conversationID: String
    let generationID: String?
    let model: String?
    let status: AgentStatus
    let text: String?
    let transcriptPath: String?
    let startsTurn: Bool
    let updatesLifecycle: Bool
    let hookName: String
    let toolUseID: String?
    let subagentID: String?
    let subagentModel: String?
    let subagentOutcome: String?
    let ownerPID: Int32?

    var duplicateKey: String? {
        guard let identity = toolUseID ?? subagentID else { return nil }
        // Different calls with the same text and start/end phases are distinct events.
        return [conversationID, generationID ?? "", hookName, identity, status.rawValue, text ?? "", model ?? ""].joined(separator: "|")
    }

    static func decode(_ json: [String: Any]) -> Self? {
        guard let name = json["hook_event_name"] as? String, CursorHookInstaller.events.contains(name) else { return nil }
        let roots = (json["workspace_roots"] as? [String] ?? []).sorted()
        let suppliedID = json["conversation_id"] as? String ?? json["session_id"] as? String
        let generation = normalizedGeneration(json["generation_id"] as? String)
        let startsTurn = name == "beforeSubmitPrompt" || name == "sessionStart" && generation?.isEmpty == false
        let isTab = name == "beforeTabFileRead" || name == "afterTabFileEdit"
        let conversation: String
        if name == "workspaceOpen" {
            guard !roots.isEmpty else { return nil }
            conversation = "workspace:" + roots.joined(separator: "|")
        } else if isTab {
            // Tab operations are separate from Agent Chat, even if a composer ID is supplied.
            guard let scope = roots.first ?? json["file_path"] as? String else { return nil }
            conversation = "tab:" + scope
        } else {
            guard let id = (name.hasPrefix("subagent") ? json["parent_conversation_id"] as? String : nil) ?? suppliedID,
                  !id.isEmpty else { return nil }
            conversation = id
        }
        let status: AgentStatus
        switch name {
        case "stop", "sessionEnd":
            let outcome = json["final_status"] as? String ?? json["status"] as? String ?? json["reason"] as? String
            status = outcome == "error" || outcome == "failed" ? .error : outcome == "completed" || outcome == "success" ? .completed : .idle
        case "postToolUseFailure": status = json["is_interrupt"] as? Bool == true ? .idle : .working
        case "sessionStart": status = startsTurn ? .working : .idle
        case "subagentStop", "preCompact", "workspaceOpen", "beforeTabFileRead", "afterTabFileEdit": status = .observed
        default: status = .working
        }
        var text: String?
        switch name {
        case "beforeSubmitPrompt", "sessionStart": text = nil // Never display user prompts.
        case "afterAgentThought": text = activity("Thought", json["text"] as? String)
        case "afterAgentResponse": text = activity("Response", json["text"] as? String)
        case "stop", "sessionEnd": text = json["error_message"] as? String
        case "beforeShellExecution", "afterShellExecution": text = activity("Shell", json["command"] as? String)
        case "beforeReadFile": text = activity("Read", cleanPath(json["file_path"] as? String))
        case "afterFileEdit": text = activity("Edit", cleanPath(json["file_path"] as? String))
        case "beforeTabFileRead": text = activity("Tab read", cleanPath(json["file_path"] as? String))
        case "afterTabFileEdit": text = activity("Tab edit", cleanPath(json["file_path"] as? String))
        case "workspaceOpen": text = activity("Workspace", roots.joined(separator: ", "))
        case "subagentStart", "subagentStop":
            let outcome = name == "subagentStop" ? " " + (json["status"] as? String ?? "stopped") : ""
            text = activity("Subagent" + outcome, json["description"] as? String ?? json["task"] as? String ?? json["subagent_type"] as? String)
        case "postToolUseFailure":
            let label: String
            if json["is_interrupt"] as? Bool == true { label = "Interrupted" }
            else {
                switch json["failure_type"] as? String {
                case "timeout": label = "Timeout"
                case "permission_denied": label = "Permission denied"
                default: label = "Error"
                }
            }
            text = activity(label, json["error_message"] as? String ?? json["tool_name"] as? String)
        case "preCompact":
            let trigger = json["trigger"] as? String ?? ""
            let usage = (json["context_usage_percent"] as? NSNumber).map { " (" + $0.stringValue + "% context)" } ?? ""
            text = activity("Compact", trigger + usage)
        case "beforeMCPExecution", "afterMCPExecution":
            let server = json["mcp_server_name"] as? String
            let tool = json["tool_name"] as? String
            let label = [server, tool].compactMap { $0 }.joined(separator: "/")
            text = toolActivity(name: label.isEmpty ? "MCP" : label, input: json["tool_input"], description: json["agent_message"] as? String)
        default:
            text = toolActivity(name: json["tool_name"] as? String, input: json["tool_input"],
                                description: json["agent_message"] as? String ?? json["error_message"] as? String)
        }
        if name == "postToolUse", text?.hasPrefix("Question: ") == true { text = nil }
        return Self(surface: json["_agentdock_surface"] as? String == "cli" ? .cli : .ide, conversationID: conversation, generationID: isTab || name == "workspaceOpen" || name.hasPrefix("subagent") ? nil : generation,
                    model: preferredModel(json),
                    status: status, text: text.map(preview), transcriptPath: isTab ? nil : json["transcript_path"] as? String,
                    startsTurn: startsTurn,
                    updatesLifecycle: startsTurn || !["sessionStart", "subagentStop", "preCompact"].contains(name),
                    hookName: name, toolUseID: json["tool_use_id"] as? String ?? json["tool_call_id"] as? String,
                    subagentID: json["subagent_id"] as? String, subagentModel: json["subagent_model"] as? String,
                    subagentOutcome: name == "subagentStop" ? json["status"] as? String : nil,
                    ownerPID: (json["_agentdock_pid"] as? NSNumber).map { Int32(truncating: $0) })
    }

    /// Cursor 3.27+ appends step suffixes (`<uuid>-<step>-<hash>`) to `generation_id` on `afterAgentThought`
    /// while using the base UUID on `beforeSubmitPrompt`, `preToolUse`, and `stop`.
    static func normalizedGeneration(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.count > 36 {
            let prefix = String(raw.prefix(36))
            let index36 = raw.index(raw.startIndex, offsetBy: 36)
            if raw[index36] == "-", UUID(uuidString: prefix) != nil {
                return prefix
            }
        }
        return raw
    }

    /// `model` is the composer's slug including variant ("claude-opus-4-7-thinking-max");
    /// `model_id` is the bare structured id. Prefer the more descriptive slug unless it is a placeholder.
    private static func preferredModel(_ json: [String: Any]) -> String? {
        let slug = (json["model"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let id = (json["model_id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !slug.isEmpty, slug != "default" { return slug }
        return !id.isEmpty ? id : (slug.isEmpty ? nil : slug)
    }

    static func preview(_ text: String) -> String {
        String(text.prefix(240)).split(whereSeparator: { $0.isNewline }).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }).map { String($0.prefix(220)) } ?? ""
    }

    private static func activity(_ label: String, _ detail: String?) -> String? {
        guard let detail else { return nil }
        let text = preview(detail)
        guard !text.isEmpty, text != "[REDACTED]" else { return nil }
        return preview(label + ": " + text)
    }

    /// Labels describe the event source; details always come from Cursor, never a generated summary.
    private static let explorationTools: Set<String> = ["grep", "glob", "read", "readfile", "readlints", "listdir", "ls",
        "websearch", "webfetch", "search", "searchcodebase", "codebasesearch", "semanticsearch"]
    private static let editTools: Set<String> = ["write", "strreplace", "edit", "editfile", "delete", "todowrite"]
    private static let pathKeys: Set<String> = ["path", "file_path", "target_file", "target_directory", "project_path"]

    static func cleanPath(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.contains("/") else { return raw }
        let last = URL(fileURLWithPath: raw).lastPathComponent
        return last.isEmpty ? raw : last
    }

    static func toolActivity(name: String?, input: Any?, description: String? = nil) -> String? {
        var arguments = input as? [String: Any] ?? [:]
        if let encoded = input as? String, let data = encoded.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { arguments = decoded }
        var tool = name == "CallDynamicTool" ? arguments["toolName"] as? String ?? name : name
        if let rawTool = tool, rawTool.hasPrefix("MCP:") {
            tool = String(rawTool.dropFirst(4))
        }
        let normalized = tool?.lowercased().replacingOccurrences(of: "_", with: "") ?? ""
        if normalized == "askquestion" {
            let questions = arguments["questions"] as? [[String: Any]] ?? []
            let prompt = questions.lazy.compactMap { $0["prompt"] as? String }.first { !preview($0).isEmpty }
            return activity("Question", prompt ?? arguments["title"] as? String)
        }
        // Only known tool identities receive semantic categories; unknown tools retain their own name.
        let label: String
        if explorationTools.contains(normalized) { label = "Explore" }
        else if editTools.contains(normalized) { label = "Edit" }
        else if normalized == "shell" { label = "Shell" }
        else if normalized == "task" || normalized == "createplan" || normalized == "await" { label = "Task" }
        else { label = tool ?? "Tool" }

        var detail = description.flatMap { preview($0).isEmpty ? nil : $0 }
        if detail == nil {
            let keys = ["description", "explanation", "command", "query", "search_term", "pattern", "glob_pattern",
                        "url", "path", "file_path", "target_file", "target_directory", "project_path",
                        "name", "overview", "filename", "target_mode_id", "task_id"]
            for key in keys {
                guard let value = arguments[key] as? String, !preview(value).isEmpty else { continue }
                detail = pathKeys.contains(key) ? cleanPath(value) : value
                break
            }
        }
        if detail == nil, let paths = arguments["paths"] as? [String], let first = paths.first {
            detail = cleanPath(first)
        }
        return activity(label, detail ?? tool)
    }

    /// Reads the tail of a Cursor `.jsonl` transcript when `ComposerWakelockManager` reports
    /// `reason="user-approval-requested"` so the yellow notch displays the exact `AskQuestion`
    /// prompt or pending tool call.
    static func transcriptApprovalText(at path: String, allowedRoots: [String]) -> String? {
        guard TranscriptSupport.isAllowed(path, under: allowedRoots) else { return nil }
        for line in TranscriptSupport.tailLines(of: path, maxBytes: 64 * 1024).reversed() {
            guard line.contains("\"tool_use\""),
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["role"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks.reversed() where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String,
                      let toolText = toolActivity(name: name, input: block["input"]) else { continue }
                if toolText.hasPrefix("Question: ") { return toolText }
                let detail = toolText.firstIndex(of: ":").map {
                    String(toolText[toolText.index(after: $0)...]).trimmingCharacters(in: .whitespaces)
                } ?? toolText
                return activity("Permission", detail.isEmpty ? toolText : detail)
            }
        }
        return nil
    }

}
