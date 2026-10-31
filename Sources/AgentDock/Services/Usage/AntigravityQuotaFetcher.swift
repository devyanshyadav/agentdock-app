import Foundation

/// Quotas from the installed CLI's read-only /usage command; no IDE process or port probing.
enum AntigravityQuotaFetcher {
    static func fetch() async throws -> [UsageWindow] {
        guard let executable = AgentCommandEnvironment.executable("agy") else {
            throw IntegrationError.message("Install the Antigravity CLI and sign in with agy to load usage.")
        }
        return try await AgentCommand.run(executable: executable,
            arguments: ["--print", "/usage", "--output-format", "json"], timeout: 30) { session in
            try parse(session.readAll())
        }
    }

    static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["status"] as? String == "SUCCESS",
              let command = json["command"] as? [String: Any], command["name"] as? String == "usage",
              let report = command["data"] as? [String: Any],
              let groups = report["groups"] as? [[String: Any]] else {
            throw IntegrationError.message("Antigravity did not return a quota report. Update the agy CLI and check its sign-in.")
        }
        var windows: [UsageWindow] = []
        for group in groups.prefix(16) {
            let groupName = (group["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Models"
            for bucket in (group["buckets"] as? [[String: Any]] ?? []).prefix(8) {
                guard let remaining = UsageWindow.number(bucket["remaining_fraction"]), (0...1).contains(remaining),
                      let id = bucket["id"] as? String, !id.isEmpty else { continue }
                let name = (bucket["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Allowance"
                let title = name.lowercased().hasPrefix(groupName.lowercased()) ? name : "\(groupName) · \(name)"
                if let window = UsageWindow(id: "agy:\(id)", title: title,
                    percentage: (1 - remaining) * 100, resetsAt: bucket["reset_time"]) {
                    windows.append(window)
                }
            }
        }
        guard !windows.isEmpty else { throw IntegrationError.message("Antigravity’s CLI returned no model quotas.") }
        return windows
    }
}
