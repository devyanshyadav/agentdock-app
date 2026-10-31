import AppKit

/// Setup belongs to the provider boundary, not to the window's view hierarchy.
struct ProviderIntegration: Identifiable, Equatable, Sendable {
    let kind: AgentKind
    var id: AgentKind { kind }

    @MainActor
    func isDetected(environment: [String: String] = ProcessInfo.processInfo.environment,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        if commandNames.contains(where: { AgentCommandEnvironment.executable($0, environment: environment, home: home) != nil }) { return true }
        let bundles: [String]
        switch kind {
        case .cursor: bundles = ["com.todesktop.230313mzl4w4u92"]
        case .antigravity: bundles = ["com.google.antigravity-ide", "com.google.antigravity"]
        case .codex: bundles = ["com.openai.codex", "com.openai.chat"]
        case .opencode: bundles = ["ai.opencode.desktop"]
        default: bundles = [] // Claude Desktop is not the Claude Code CLI.
        }
        return bundles.contains {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) else { return false }
            if $0 == "com.openai.chat" {
                // ChatGPT counts only when it contains the coding agent, not for ordinary chats.
                return ["Contents/Resources/codex", "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
                    .contains { FileManager.default.isExecutableFile(atPath: url.appendingPathComponent($0).path) }
            }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private var commandNames: [String] {
        switch kind {
        case .claude: return ["claude"]
        case .cursor: return ["cursor-agent", "agent"]
        case .codex: return ["codex"]
        case .antigravity: return ["antigravity", "agy"]
        case .opencode: return ["opencode"]
        default: return []
        }
    }

    enum Installation: String, Sendable {
        case missing = "Not installed", repair = "Needs repair", updateAvailable = "Update available", configured = "Configured"
    }

    enum HelpTopic {
        case installation, activity
    }

    func documentationURL(for topic: HelpTopic) -> URL? {
        let path: String
        switch (kind, topic) {
        case (.cursor, .installation): path = "https://cursor.com/docs/cli/installation"
        case (.cursor, .activity): path = "https://cursor.com/docs/hooks"
        case (.claude, .installation): path = "https://code.claude.com/docs/en/setup"
        case (.claude, .activity): path = "https://code.claude.com/docs/en/hooks"
        case (.codex, .installation): path = "https://learn.chatgpt.com/docs/cli"
        case (.codex, .activity): path = "https://learn.chatgpt.com/docs/hooks"
        case (.antigravity, .installation): path = "https://antigravity.google/docs/getting-started"
        case (.antigravity, .activity): path = "https://antigravity.google/docs/hooks"
        case (.opencode, .installation): path = "https://opencode.ai/v2/docs/"
        case (.opencode, .activity): path = "https://opencode.ai/v2/docs/plugins/"
        default: return nil
        }
        return URL(string: path)
    }

    private var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AgentDock")
    }
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var config: URL {
        switch kind {
        case .opencode: return OpenCodeIntegration.plugin
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        case .antigravity: return home.appendingPathComponent(".gemini/config/hooks.json")
        case .claude: return ClaudeHookInstaller.baseDirectory.appendingPathComponent("settings.json")
        default: return CodexHookInstaller.baseDirectory.appendingPathComponent("hooks.json")
        }
    }
    private var script: URL {
        switch kind {
        case .opencode: return OpenCodeIntegration.plugin
        case .cursor: return home.appendingPathComponent(".cursor/hooks/agentdock.sh")
        case .antigravity: return support.appendingPathComponent("AntigravityHooks/observer.sh")
        case .claude: return support.appendingPathComponent("ClaudeHooks/observer.sh")
        default: return support.appendingPathComponent("CodexHooks/observer.sh")
        }
    }
    private var bundledScript: URL? {
        let path: String
        switch kind {
        case .opencode: return OpenCodeIntegration.source
        case .cursor: path = "CursorHooks/agentdock.sh"
        case .antigravity: path = "AntigravityHooks/observer.sh"
        case .claude: path = "ClaudeHooks/observer.sh"
        default: path = "CodexHooks/observer.sh"
        }
        return Bundle.main.resourceURL?.appendingPathComponent(path)
    }
    var instructions: String {
        switch kind {
        case .opencode: return "Start a new chat in OpenCode. If activity is missing, restart OpenCode."
        case .codex: return "In Codex, open /hooks and approve AgentDock, then start a new chat."
        default: return "Start a new chat in \(kind.displayName) to apply changes."
        }
    }

    func installation() -> Installation {
        if kind == .opencode { return OpenCodeIntegration.installation() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: script.path) else { return .missing }
        guard fm.isExecutableFile(atPath: script.path),
              let actual = try? Data(contentsOf: script),
              let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .repair }
        let quoted = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        let hooksConfigured: Bool
        switch kind {
        case .cursor:
            hooksConfigured = CursorHookInstaller.observationEvents.allSatisfy {
                Self.contains(command: quoted + " " + $0, in: hooks[$0])
            }
        case .antigravity:
            guard let group = json["agentdock-observer"] as? [String: Any],
                  ["PreInvocation", "Stop", "PostToolUse", "PreToolUse"].allSatisfy({
                      Self.contains(command: quoted + " " + $0, in: group[$0])
                  }), let settings = try? Data(contentsOf: home.appendingPathComponent(".gemini/antigravity-cli/settings.json")),
                  let status = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
                  let line = status["statusLine"] as? [String: Any],
                  (line["command"] as? String)?.hasPrefix(quoted + " StatusLine") == true else { return .repair }
            hooksConfigured = true
        case .claude:
            let legacyPresent = Set(ClaudeCodeAdapter.events).subtracting(ClaudeCodeAdapter.installedEvents).contains {
                Self.contains(command: quoted, in: hooks[$0])
            }
            hooksConfigured = !legacyPresent && ClaudeCodeAdapter.installedEvents.allSatisfy { Self.contains(command: quoted, in: hooks[$0]) }
        default:
            hooksConfigured = CodexAgentAdapter.events.allSatisfy { Self.contains(command: quoted, in: hooks[$0]) }
        }
        guard hooksConfigured else { return .repair }
        // A different observer version is an update, not evidence that events are broken.
        guard let source = bundledScript, let expected = try? Data(contentsOf: source) else { return .repair }
        guard expected == actual else { return .updateAvailable }
        return .configured
    }

    private static func contains(command: String, in value: Any?) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary["command"] as? String == command || dictionary.values.contains { contains(command: command, in: $0) }
        }
        if let array = value as? [Any] { return array.contains { contains(command: command, in: $0) } }
        return false
    }

    /// Refresh scripts only when the user's current hook registrations are complete.
    /// Missing registrations are left for an explicit reconnect.
    @MainActor
    static func refreshEnabledObservers() {
        for kind in [AgentKind.cursor, .claude, .codex, .antigravity, .opencode] {
            let integration = ProviderIntegration(kind: kind)
            guard integration.installation() == .updateAvailable else { continue }
            try? integration.install()
        }
    }

    func install() throws {
        switch kind {
        case .cursor: try CursorHookInstaller.install()
        case .antigravity: try AntigravityHookInstaller.install()
        case .claude: try ClaudeHookInstaller.install()
        case .codex: try CodexHookInstaller.install()
        case .opencode: try OpenCodeIntegration.install()
        default: throw IntegrationError.message("This provider has no event installer.")
        }
    }
}
