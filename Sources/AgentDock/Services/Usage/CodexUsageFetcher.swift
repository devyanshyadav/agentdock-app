import Foundation

/// Summary analytics from Codex's CLI (`account/usage/read`), matching `/usage -> View analytics`.
struct CodexAnalytics: Equatable, Sendable {
    let planType: String?
    let lifetimeTokens: Double?
    let peakDailyTokens: Double?
    let longestTurnSeconds: Double?
    let currentStreakDays: Int?
    let longestStreakDays: Int?

    var hasValues: Bool {
        lifetimeTokens != nil || peakDailyTokens != nil || longestTurnSeconds != nil
            || currentStreakDays != nil || longestStreakDays != nil
    }

    static func parse(_ json: [String: Any], planType: String? = nil) -> Self? {
        let result = json["result"] as? [String: Any] ?? json
        guard let summary = result["summary"] as? [String: Any] else { return nil }
        let analytics = Self(
            planType: planType?.trimmingCharacters(in: .whitespacesAndNewlines),
            lifetimeTokens: SessionUsage.nonnegative(summary["lifetimeTokens"]),
            peakDailyTokens: SessionUsage.nonnegative(summary["peakDailyTokens"]),
            longestTurnSeconds: SessionUsage.nonnegative(summary["longestRunningTurnSec"]),
            currentStreakDays: SessionUsage.nonnegative(summary["currentStreakDays"]).flatMap(Int.init(exactly:)),
            longestStreakDays: SessionUsage.nonnegative(summary["longestStreakDays"]).flatMap(Int.init(exactly:))
        )
        return analytics.hasValues ? analytics : nil
    }
}

/// Queries the installed Codex CLI (`codex app-server`) for live account rate limits (`account/rateLimits/read`) and analytics (`account/usage/read`).
enum CodexUsageFetcher {
    struct Response: Equatable, Sendable {
        let windows: [UsageWindow]
        let analytics: CodexAnalytics?
    }

    static func fetchFull() async throws -> Response {
        guard let executable = AgentCommandEnvironment.executable("codex") else {
            throw IntegrationError.message("Install the Codex CLI to load usage.")
        }
        return try await AgentCommand.run(executable: executable, arguments: ["app-server"]) { try query($0) }
    }

    static func query(_ session: AgentCommand.Session) throws -> Response {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let initialize: [String: Any] = ["id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "agentdock", "version": version]]]
        try session.writeLine(String(decoding: JSONSerialization.data(withJSONObject: initialize), as: UTF8.self))
        let initialized = try response(id: 1, from: session)
        guard initialized["result"] != nil, initialized["error"] == nil else {
            throw IntegrationError.message("Codex initialization failed. Update its CLI and try again.")
        }
        try session.writeLine(#"{"method":"initialized"}"#)
        try session.writeLine(#"{"id":2,"method":"account/rateLimits/read"}"#)
        let limits = try response(id: 2, from: session)
        let windows = try parse(limits)
        let result = limits["result"] as? [String: Any]
        let plan = (result?["rateLimits"] as? [String: Any])?["planType"] as? String
        try session.writeLine(#"{"id":3,"method":"account/usage/read"}"#)
        // Analytics are optional; a rejected/unsupported endpoint does not discard valid limits.
        let analytics = try? response(id: 3, from: session)
        return Response(windows: windows, analytics: analytics.flatMap { CodexAnalytics.parse($0, planType: plan) })
    }

    private static func response(id: Int, from session: AgentCommand.Session) throws -> [String: Any] {
        while let line = try session.readLine() {
            guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if UsageWindow.number(json["id"]) == Double(id) { return json }
        }
        throw IntegrationError.message("Codex closed before returning usage.")
    }

    static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError.message("Codex returned an unreadable rate-limit response.")
        }
        return try parse(json)
    }

    static func parse(_ json: [String: Any]) throws -> [UsageWindow] {
        let result = json["result"] as? [String: Any] ?? json
        if result["error"] != nil { throw IntegrationError.message("Codex rejected the usage request. Check its sign-in and CLI version.") }
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            let windows = byID.keys.sorted().prefix(32).flatMap { key -> [UsageWindow] in
                guard var limits = byID[key] as? [String: Any] else { return [] }
                limits["limitId"] = key
                return UsageParsers.codex(limits)
            }
            if !windows.isEmpty { return windows }
        }
        if let limits = result["rateLimits"] as? [String: Any] {
            let windows = UsageParsers.codex(limits)
            if !windows.isEmpty { return windows }
        }
        throw IntegrationError.message("Codex did not report any rate limits.")
    }

}
