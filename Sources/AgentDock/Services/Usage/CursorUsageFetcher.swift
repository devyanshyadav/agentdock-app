import Foundation

/// Reads Cursor plan and allowance usage via the installed Cursor Agent CLI.
enum CursorUsageFetcher {
    private static let preloadScript = #"""
    let installed = false;
    process.once("beforeExit", () => { if (!installed) process.exitCode = 1; });
    const Module = require("node:module");
    const orig = Module._load;
    Module._load = function(request, parent, isMain) {
      const exp = orig.apply(this, arguments);
      if (exp && exp.modules && typeof exp.modules["./src/commands/status.ts"] === "function") {
        installed = true;
        exp.modules["./src/commands/status.ts"] = (e, t, a) => {
          a.d(t, { handleStatus: () => async (cred, client) => {
            try {
              const [current, plan] = await Promise.all([
                client.getCurrentPeriodUsage({}),
                client.getPlanInfo({}).catch(() => null)
              ]);
              process.stdout.write(JSON.stringify(
                { current, plan },
                (k, v) => typeof v === "bigint" ? Number(v) : v
              ) + "\n");
              process.exit(0);
            } catch (err) {
              process.stderr.write((err && err.message ? err.message : String(err)) + "\n");
              process.exit(1);
            }
          }});
        };
      }
      return exp;
    };
    """#

    /// Cursor has no documented usage export. This isolated adapter depends on its private
    /// Node CLI layout; unsupported versions must fail rather than invent account figures.
    static func fetch() async throws -> [UsageWindow] {
        guard let executable = AgentCommandEnvironment.executable("cursor-agent") else {
            throw IntegrationError.message("Install the Cursor Agent CLI to load usage.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentdock-cursor-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preloadURL = directory.appendingPathComponent("usage.cjs")
        try Data(preloadScript.utf8).write(to: preloadURL, options: .atomic)
        return try await AgentCommand.run(executable: executable, arguments: ["status", "--format", "json"],
            environment: ["NODE_OPTIONS": "--require \"\(preloadURL.path)\"", "NO_COLOR": "1"]) { session in
            let json = try session.readAll()
            return try parse(json)
        }
    }

    static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IntegrationError.message("Cursor returned an unsupported usage format.")
        }
        let windows = parse(json)
        guard !windows.isEmpty else {
            throw IntegrationError.message("This Cursor CLI version did not expose usage. Open Cursor’s usage dashboard.")
        }
        return windows
    }

    static func parse(_ json: [String: Any]) -> [UsageWindow] {
        let current = json["current"] as? [String: Any] ?? json
        guard let planUsage = current["planUsage"] as? [String: Any] else { return [] }

        let plan = json["plan"] as? [String: Any] ?? [:]
        let planInfo = plan["planInfo"] as? [String: Any] ?? [:]
        let planName = (planInfo["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = planName.flatMap { $0.isEmpty ? nil : $0 + " · " } ?? ""

        let resetSeconds = epochSeconds(current["billingCycleEnd"]) ?? epochSeconds(planInfo["billingCycleEnd"])

        var windows: [UsageWindow] = []

        // Discover every percentage bucket exposed by this CLI instead of maintaining a category list.
        let suffix = "PercentUsed"
        for key in planUsage.keys.sorted() where key.hasSuffix(suffix) {
            let category = String(key.dropLast(suffix.count))
            let title = category.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ").localizedCapitalized
            if let window = UsageWindow(id: "cursor:" + key, title: prefix + title,
                percentage: planUsage[key], resetsAt: resetSeconds) { windows.append(window) }
        }
        let spend = current["spendLimitUsage"] as? [String: Any] ?? [:]
        if let used = SessionUsage.nonnegative(spend["individualUsed"]),
           let limit = SessionUsage.nonnegative(spend["individualLimit"]), limit > 0,
           let window = UsageWindow(id: "cursor:spendLimitUsage", title: "Spend limit",
               percentage: used / limit * 100, resetsAt: resetSeconds) { windows.append(window) }

        return windows
    }

    private static func epochSeconds(_ value: Any?) -> Double? {
        // Cursor billing-cycle endpoints are Unix milliseconds; protobuf JSON can encode int64 as a string.
        let milliseconds = UsageWindow.number(value) ?? (value as? String).flatMap(Double.init)
        return milliseconds.flatMap { UsageWindow.date($0 / 1000)?.timeIntervalSince1970 }
    }
}
