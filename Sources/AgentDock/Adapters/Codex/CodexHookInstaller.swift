import Foundation

/// Installs neutral observers only. Codex still owns hook trust and all tool decisions.
enum CodexHookInstaller {
    static var baseDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static func install(base: URL = CodexHookInstaller.baseDirectory,
                        destination: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentDock/CodexHooks/observer.sh"),
                        source: URL? = Bundle.main.resourceURL?.appendingPathComponent("CodexHooks/observer.sh")) throws {
        guard let source else { throw IntegrationError.message("The Codex observer is missing.") }
        let fm = FileManager.default, config = base.appendingPathComponent("hooks.json")
        var json: [String: Any] = [:]
        if fm.fileExists(atPath: config.path) {
            guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] else { throw IntegrationError.message("Codex hooks have an unsupported format; they were preserved.") }
            json = value
        }
        guard json["hooks"] == nil || json["hooks"] is [String: Any] else { throw IntegrationError.message("Codex hooks have an unsupported format; they were preserved.") }
        var events = json["hooks"] as? [String: Any] ?? [:]
        let command = "'" + destination.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        for event in CodexAgentAdapter.events {
            guard events[event] == nil || events[event] is [[String: Any]] else { throw IntegrationError.message("Codex \(event) hooks have an unsupported format; they were preserved.") }
            var groups = events[event] as? [[String: Any]] ?? []
            var installed = false
            for index in groups.indices {
                guard var hooks = groups[index]["hooks"] as? [[String: Any]] else { continue }
                for hook in hooks.indices where hooks[hook]["command"] as? String == command {
                    installed = true
                    guard hooks[hook]["timeout"] as? Int != 2 else { continue }
                    hooks[hook]["timeout"] = 2
                }
                groups[index]["hooks"] = hooks
            }
            if !installed { groups.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 2]]]) }
            events[event] = groups
        }
        json["hooks"] = events
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        if (try? Data(contentsOf: config)) == data { return }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        if fm.fileExists(atPath: config.path) { try fm.copyItem(at: config, to: config.appendingPathExtension("agentdock-backup-" + UUID().uuidString)) }
        try data.write(to: config, options: .atomic)
    }
}
