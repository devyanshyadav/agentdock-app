import Foundation

/// Historical totals from OpenCode's supported CLI, separate from account allowances.
struct OpenCodeStatistics: Equatable, Sendable {
    static let defaultDays = 7
    let sessions: Int?
    let period: DateInterval?
    let usage: SessionUsage

    static func parse(_ data: Data) throws -> Self {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else {
            throw IntegrationError.message("OpenCode returned unsupported statistics. Update its CLI and try again.")
        }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let usage = SessionUsage(id: "opencode-statistics",
            inputTokens: SessionUsage.nonnegative(tokens["input"]),
            outputTokens: SessionUsage.nonnegative(tokens["output"]),
            cacheReadTokens: SessionUsage.nonnegative(cache["read"]),
            cacheWriteTokens: SessionUsage.nonnegative(cache["write"]),
            reasoningTokens: SessionUsage.nonnegative(tokens["reasoning"]),
            costUSD: SessionUsage.nonnegative(json["cost"]))
        guard usage.hasValues else { throw IntegrationError.message("OpenCode did not report usage totals.") }
        let range = json["range"] as? [String: Any] ?? [:]
        // OpenCode stats reports range endpoints in Unix milliseconds.
        let start = UsageWindow.number(range["from"]).flatMap { UsageWindow.date($0 / 1000) }
        let end = UsageWindow.number(range["to"]).flatMap { UsageWindow.date($0 / 1000) }
        let period: DateInterval?
        if let start, let end, start <= end { period = DateInterval(start: start, end: end) }
        else { period = nil }
        return Self(sessions: SessionUsage.nonnegative(json["sessions"]).flatMap(Int.init(exactly:)), period: period, usage: usage)
    }
}

enum OpenCodeUsageFetcher {
    static func fetch(days: Int = OpenCodeStatistics.defaultDays) async throws -> OpenCodeStatistics {
        guard days >= 0 else { throw IntegrationError.message("Choose a nonnegative usage period.") }
        guard let executable = AgentCommandEnvironment.executable("opencode") else {
            throw IntegrationError.message("Install the latest OpenCode CLI to load usage.")
        }
        return try await AgentCommand.run(executable: executable,
            arguments: ["stats", "--json", "--cost", "--days", String(days)]) { session in
            try OpenCodeStatistics.parse(session.readAll())
        }
    }
}
