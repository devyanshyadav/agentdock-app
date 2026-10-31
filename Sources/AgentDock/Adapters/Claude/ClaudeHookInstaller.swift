import Foundation

/// Installs neutral observers only. Claude still owns all tool decisions.
enum ClaudeHookInstaller {
    static var baseDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func install(base: URL = baseDirectory,
                        destination: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentDock/ClaudeHooks/observer.sh"),
                        source: URL? = Bundle.main.resourceURL?.appendingPathComponent("ClaudeHooks/observer.sh")) throws {
        guard let source else { throw IntegrationError.message("The Claude observer is missing.") }
        let fm = FileManager.default, config = base.appendingPathComponent("settings.json")
        var json: [String: Any] = [:]
        if fm.fileExists(atPath: config.path) {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] else { throw IntegrationError.message("Claude hooks have an unsupported format; they were preserved.") }
            json = value
        }
        guard json["hooks"] == nil || json["hooks"] is [String: Any] else { throw IntegrationError.message("Claude hooks have an unsupported format; they were preserved.") }
        var events = json["hooks"] as? [String: Any] ?? [:]
        let command = "'" + destination.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var changed = false
        // Chain an existing command verbatim; never replace the user's status-line output.
        let usageCommand = command + " StatusLine"
        if json["statusLine"] == nil || json["statusLine"] is [String: Any] {
            var line = json["statusLine"] as? [String: Any] ?? [:]
            let previous = line["command"] as? String ?? ""
            if (line["type"] == nil || line["type"] as? String == "command"),
               (line["command"] == nil || line["command"] is String),
               !previous.hasPrefix(usageCommand) {
                line["type"] = "command"
                line["command"] = usageCommand + (previous.isEmpty ? "" : " '" + previous.replacingOccurrences(of: "'", with: "'\\''") + "'")
                json["statusLine"] = line
                changed = true
            }
        }
        let legacyEvents = Set(ClaudeCodeAdapter.events).subtracting(ClaudeCodeAdapter.installedEvents)
        for legacy in legacyEvents {
            guard var groups = events[legacy] as? [[String: Any]] else { continue }
            var modified = false
            for index in groups.indices.reversed() {
                guard var hooks = groups[index]["hooks"] as? [[String: Any]] else { continue }
                let before = hooks.count
                hooks.removeAll { $0["command"] as? String == command }
                if hooks.count != before {
                    modified = true
                    if hooks.isEmpty { groups.remove(at: index) }
                    else { groups[index]["hooks"] = hooks }
                }
            }
            if modified {
                events[legacy] = groups.isEmpty ? nil : groups
                changed = true
            }
        }
        for event in ClaudeCodeAdapter.installedEvents {
            guard events[event] == nil || events[event] is [[String: Any]] else { throw IntegrationError.message("Claude \(event) hooks have an unsupported format; they were preserved.") }
            var groups = events[event] as? [[String: Any]] ?? []
            var installed = false
            for index in groups.indices {
                guard var hooks = groups[index]["hooks"] as? [[String: Any]] else { continue }
                for hook in hooks.indices where hooks[hook]["command"] as? String == command {
                    installed = true
                    guard hooks[hook]["timeout"] as? Int != 2 else { continue }
                    hooks[hook]["timeout"] = 2
                    changed = true
                }
                groups[index]["hooks"] = hooks
            }
            if !installed {
                groups.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 2]]])
                changed = true
            }
            events[event] = groups
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        guard changed else { return }
        json["hooks"] = events
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        if fm.fileExists(atPath: config.path) {
            let backup = config.appendingPathExtension("agentdock-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: config, to: backup)
            if let siblings = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
                for item in siblings where item.lastPathComponent.hasPrefix("settings.json.agentdock-backup-") {
                    try? fm.removeItem(at: item)
                }
            }
        }
        try data.write(to: config, options: .atomic)
    }
}
