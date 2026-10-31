import Foundation

/// Turns whatever model identifier a running agent reports into a compact label.
/// Nothing here knows specific model families: it only normalizes separators, version
/// numbers, snapshot dates, and provider path prefixes, so new models display correctly
/// without code changes.
@MainActor
enum ModelName {
    private static var cache: [String: String] = [:]

    /// - Parameter agent: When the identifier starts with the agent's own name
    ///   ("claude-…" for Claude Code) that redundant word is dropped.
    static func display(_ raw: String, agent: AgentKind? = nil) -> String {
        let key = (agent?.rawValue ?? "") + "|" + raw
        if let cached = cache[key] { return cached }
        let value = format(raw, agent: agent)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = value
        return value
    }

    private static func format(_ raw: String, agent: AgentKind?) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        // Providers that already report a display name ("Gemini 3 Pro (High)") are used as-is.
        if text.contains(" ") { return text }
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        // Context-window style suffix, e.g. "name[1m]".
        var suffix = ""
        if let open = text.firstIndex(of: "["), text.hasSuffix("]") {
            suffix = " (" + text[text.index(after: open)..<text.index(before: text.endIndex)].uppercased() + ")"
            text = String(text[..<open])
        }
        var tokens = text.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        if let agent, tokens.count > 1, tokens.first?.lowercased() == agent.rawValue { tokens.removeFirst() }
        var words: [String] = []
        var version: [String] = []
        func flushVersion() {
            if !version.isEmpty { words.append(version.joined(separator: ".")); version = [] }
        }
        for (index, token) in tokens.enumerated() {
            if token.count >= 6, token.allSatisfy(\.isNumber) { continue } // Snapshot date such as 20250929.
            if token.allSatisfy(\.isNumber) { version.append(token); continue }
            flushVersion()
            // Mixed alphanumerics ("o3", "4o", "v2.5") keep their own casing.
            let keepsCase = token.contains(where: \.isNumber)
            // A short name directly before a version number is an acronym-style family ("gpt-5").
            let acronym = token.count <= 3 && index + 1 < tokens.count && tokens[index + 1].first?.isNumber == true
            words.append(keepsCase ? token : acronym ? token.uppercased() : token.prefix(1).uppercased() + token.dropFirst())
        }
        flushVersion()
        let label = words.joined(separator: " ")
        return label.isEmpty ? raw : label + suffix
    }

    /// Shortens a label to fit a fixed notch slot.
    static func clipped(_ label: String, limit: Int = 22) -> String {
        guard label.count > limit else { return label }
        return String(label.prefix(limit - 1)) + "…"
    }
}

/// Last-resort model hints read from each CLI's own documented configuration (Claude's
/// `model` setting, Codex's top-level `model` key). Used only until a hook or transcript
/// reports the real model; never overrides anything an agent has reported.
@MainActor
enum AgentModelDefaults {
    private static var cache: [AgentKind: (value: String?, date: Date)] = [:]

    static func current(for kind: AgentKind) -> String? {
        if let cached = cache[kind], Date().timeIntervalSince(cached.date) < 30 { return cached.value }
        let value = read(kind)
        cache[kind] = (value, Date())
        return value
    }

    private static func read(_ kind: AgentKind) -> String? {
        switch kind {
        case .claude:
            let base = ClaudeHookInstaller.baseDirectory
            guard let data = try? Data(contentsOf: base.appendingPathComponent("settings.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let model = json["model"] as? String, !model.isEmpty { return model }
            return (json["env"] as? [String: Any])?["ANTHROPIC_MODEL"] as? String
        case .codex:
            let base = CodexHookInstaller.baseDirectory
            guard let text = try? String(contentsOf: base.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n") {
                // Only top-level keys: stop at the first table header.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { break }
                guard trimmed.hasPrefix("model"), let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                guard key == "model" else { continue }
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !value.isEmpty { return value }
            }
            return nil
        default:
            return nil
        }
    }
}
