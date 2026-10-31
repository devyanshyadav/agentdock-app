import Foundation

/// Native CLI report. Its fresh-session counters are never imported as saved-session usage.
enum ClaudeUsageFetcher {
    static func fetch() async throws -> String {
        guard let executable = AgentCommandEnvironment.executable("claude") else {
            throw IntegrationError.message("Install the Claude Code CLI to load its usage report.")
        }
        return try await AgentCommand.run(executable: executable, arguments: [
            "--print", "/usage", "--output-format", "json", "--no-session-persistence",
            "--settings", #"{"disableAllHooks":true}"#,
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#, "--tools", ""
        ], timeout: 30) { try parse($0.readAll()) }
    }

    static func parse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["is_error"] as? Bool == false, json["local_command"] as? String == "usage",
              let text = json["result"] as? String else {
            throw IntegrationError.message("Claude Code did not return a native usage report. Check its CLI version and account configuration.")
        }
        let report = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !report.isEmpty, report.utf8.count <= 65_536 else {
            throw IntegrationError.message("Claude Code returned an empty or oversized usage report.")
        }
        return report
    }
}
