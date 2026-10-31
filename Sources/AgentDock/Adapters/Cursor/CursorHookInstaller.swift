import Foundation

/// Own only our entries in Cursor's configuration; preserve all other hooks.
enum CursorHookInstaller {
    static let events = ["sessionStart", "sessionEnd", "preToolUse", "postToolUse", "postToolUseFailure",
                         "subagentStart", "subagentStop", "beforeShellExecution", "afterShellExecution",
                         "beforeMCPExecution", "afterMCPExecution", "beforeReadFile", "afterFileEdit",
                         "beforeSubmitPrompt", "preCompact", "stop", "afterAgentResponse", "afterAgentThought",
                         "beforeTabFileRead", "afterTabFileEdit", "workspaceOpen"]
    // These hooks can also return permission/prompt decisions. Agent Dock registers them as
    // observers whose script prints nothing (documented as "no decision"), which gives real-time
    // prompt-submitted and tool-started events without ever allowing, denying, or modifying work.
    // The remaining gate-style hooks are not needed: preToolUse already covers every tool kind.
    static let observationEvents = ["sessionStart", "sessionEnd", "preToolUse", "postToolUse", "postToolUseFailure",
                                    "subagentStart", "subagentStop", "afterShellExecution", "afterMCPExecution",
                                    "afterFileEdit", "beforeSubmitPrompt", "preCompact", "stop", "afterAgentResponse",
                                    "afterAgentThought", "afterTabFileEdit", "workspaceOpen"]
    static func install(in directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor"),
                        source: URL? = Bundle.main.resourceURL?.appendingPathComponent("CursorHooks/agentdock.sh")) throws {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            throw IntegrationError.message("The bundled Cursor hook is missing.")
        }
        let fm = FileManager.default
        let script = directory.appendingPathComponent("hooks/agentdock.sh")
        let config = directory.appendingPathComponent("hooks.json")
        var json: [String: Any] = [:]
        let original = fm.fileExists(atPath: config.path) ? try Data(contentsOf: config) : nil
        if let original {
            guard let existing = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  existing["version"] as? Int == 1,
                  existing["hooks"] == nil || existing["hooks"] is [String: Any] else {
                throw IntegrationError.message("Cursor hooks.json has an unsupported format. It was left unchanged.")
            }
            json = existing
        }
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else {
                throw IntegrationError.message("Cursor's \(event) hooks have an unsupported format.")
            }
            var entries = hooks[event] as? [[String: Any]] ?? []
            let command = shellQuote(script.path) + " " + event
            entries.removeAll {
                guard let cmd = $0["command"] as? String else { return false }
                return cmd.hasPrefix(shellQuote(script.path) + " ")
            }
            if observationEvents.contains(event) { entries.append(["command": command, "timeout": 2]) }
            if entries.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = entries }
        }
        json["version"] = 1; json["hooks"] = hooks
        let scriptData = try Data(contentsOf: source)
        let configData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: script)) != scriptData {
            try scriptData.write(to: script, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        if original != configData {
            if original != nil {
                let backup = directory.appendingPathComponent("hooks.json.agentdock-backup")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: config, to: backup)
                if let siblings = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    for item in siblings where item.lastPathComponent.hasPrefix("hooks.json.agentdock-backup-") {
                        try? fm.removeItem(at: item)
                    }
                }
            }
            try configData.write(to: config, options: .atomic)
        }
    }
    private static func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
