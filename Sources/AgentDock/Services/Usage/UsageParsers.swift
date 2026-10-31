import Foundation

enum UsageParsers {
    static func codex(_ json: [String: Any]) -> [UsageWindow] {
        let name = json["limitName"] as? String ?? json["limitId"] as? String ?? AgentKind.codex.displayName
        let id = json["limitId"] as? String ?? name
        return ["primary", "secondary"].compactMap { key in
            guard let bucket = json[key] as? [String: Any] else { return nil }
            let minutes = UsageWindow.number(bucket["windowDurationMins"])
            let duration = minutes.flatMap { value -> String? in
                guard value > 0, Int(exactly: (value * 60).rounded(.down)) != nil else { return nil }
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute]
                formatter.unitsStyle = .short
                formatter.maximumUnitCount = 2
                return formatter.string(from: value * 60)
            }
            return UsageWindow(id: id + ":" + key, title: name + " · " + (duration ?? key.capitalized),
                percentage: bucket["usedPercent"], resetsAt: bucket["resetsAt"])
        }
    }

    static func codexLine(_ line: String, sessionID: String) -> SessionUsage? {
        guard line.utf8.count <= 1_048_576, line.contains("token_count"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "event_msg", let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let date = UsageWindow.date(json["timestamp"]) else { return nil }
        let info = payload["info"] as? [String: Any] ?? [:]
        let tokens = info["total_token_usage"] as? [String: Any] ?? [:]
        let session = SessionUsage(id: sessionID, updatedAt: date,
            inputTokens: SessionUsage.nonnegative(tokens["input_tokens"]),
            outputTokens: SessionUsage.nonnegative(tokens["output_tokens"]),
            cacheReadTokens: SessionUsage.nonnegative(tokens["cached_input_tokens"]),
            reasoningTokens: SessionUsage.nonnegative(tokens["reasoning_output_tokens"]))
        return session.hasValues ? session : nil
    }

}
