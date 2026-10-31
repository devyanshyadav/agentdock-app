import Foundation

enum AntigravityHookInstaller {
    static func install(in base: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini"),
                        destination: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentDock/AntigravityHooks/observer.sh"),
                        source: URL? = Bundle.main.resourceURL?.appendingPathComponent("AntigravityHooks/observer.sh")) throws {
        guard let source else { throw IntegrationError.message("The Antigravity observer is missing.") }
        let fm = FileManager.default
        let hooksURL = base.appendingPathComponent("config/hooks.json")
        var hooks = try read(hooksURL)
        var group: [String: Any] = [:]
        for event in ["PreInvocation", "Stop"] {
            group[event] = [["type": "command", "command": quote(destination.path) + " " + event, "timeout": 2]]
        }
        group["PostToolUse"] = [["matcher": "*", "hooks": [["type": "command", "command": quote(destination.path) + " PostToolUse", "timeout": 2]]]]
        // Permit the question/permission-request tool itself to display its UI.
        // This matcher never applies to the action for which approval is requested.
        group["PreToolUse"] = [["matcher": "^(ask_question|ask_permission)$", "hooks": [["type": "command", "command": quote(destination.path) + " PreToolUse", "timeout": 2]]]]
        hooks["agentdock-observer"] = group
        let settingsURL = base.appendingPathComponent("antigravity-cli/settings.json")
        var settings = try read(settingsURL)
        guard settings["statusLine"] == nil || settings["statusLine"] is [String: Any] else {
            throw IntegrationError.message("Antigravity status-line settings have an unsupported format; they were preserved.")
        }
        var status = settings["statusLine"] as? [String: Any] ?? [:]
        let previous = status["command"] as? String ?? ""
        if !previous.hasPrefix(quote(destination.path) + " StatusLine") {
            status["type"] = "command"
            status["command"] = quote(destination.path) + " StatusLine" + (previous.isEmpty ? "" : " " + quote(previous))
            if previous.isEmpty { status["stack_with_default"] = true }
            settings["statusLine"] = status
        }
        // Validate both configuration files before changing the installed observer.
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        try write(hooks, to: hooksURL)
        try write(settings, to: settingsURL)
    }
    private static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw IntegrationError.message("Antigravity configuration has an unsupported format.")
        }
        return object
    }
    private static func write(_ json: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        if let old = try? Data(contentsOf: url), old == data { return }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("agentdock-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            let legacyPrefix = url.lastPathComponent + ".agentdock-backup-"
            if let siblings = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in siblings where item.lastPathComponent.hasPrefix(legacyPrefix) {
                    try? fm.removeItem(at: item)
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
