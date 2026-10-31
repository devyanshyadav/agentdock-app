import Foundation

/// Provider-reported subscription consumption, independent of context-window occupancy.
struct UsageWindow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?

    init?(id: String, title: String, percentage: Any?, resetsAt: Any? = nil) {
        guard let value = Self.number(percentage), value >= 0, !id.isEmpty else { return nil }
        self.id = String(id.prefix(256))
        self.title = String(title.prefix(128))
        usedPercent = value
        self.resetsAt = Self.date(resetsAt)
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0, seconds <= Date.distantFuture.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

struct UsageSnapshot: Equatable, Sendable {
    var windows: [UsageWindow] = []
    var updatedAt: Date?
    var message: String?
    var report: String?
    var statistics: OpenCodeStatistics?
    var analytics: CodexAnalytics?
}

struct SessionUsage: Identifiable, Equatable, Sendable {
    let id: String
    var updatedAt = Date()
    var inputTokens: Double?
    var outputTokens: Double?
    var cacheReadTokens: Double?
    var cacheWriteTokens: Double?
    var reasoningTokens: Double?
    var costUSD: Double?
    var observed = false

    var hasValues: Bool {
        [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens, costUSD].contains { $0 != nil }
    }

    static func nonnegative(_ value: Any?) -> Double? {
        UsageWindow.number(value).flatMap { $0 >= 0 ? $0 : nil }
    }
}

