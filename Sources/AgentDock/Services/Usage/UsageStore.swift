import Foundation
import Combine

/// Account metadata never changes agent lifecycle, focus, or notch visibility.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()
    struct Refresh: Sendable {
        var windows: [UsageWindow] = []
        var statistics: OpenCodeStatistics?
        var analytics: CodexAnalytics?
        var report: String?
    }
    typealias Fetch = @Sendable () async throws -> Refresh

    @Published private(set) var snapshots: [AgentKind: UsageSnapshot] = [:]
    @Published private(set) var refreshing: Set<AgentKind> = []
    @Published private(set) var sessions: [AgentKind: [SessionUsage]] = [:]
    private var claudeMessages: [String: [String: SessionUsage]] = [:]
    private var lastAttempt: [AgentKind: TimeInterval] = [:]
    private let fetchers: [AgentKind: Fetch]
    // Bound automatic tab-open requests and in-memory session retention. Manual refresh bypasses the interval.
    private static let refreshInterval: TimeInterval = 60
    private static let sessionLimit = 64
    private static let messageLimit = 512

    init(fetchers: [AgentKind: Fetch] = [
        .antigravity: { Refresh(windows: try await AntigravityQuotaFetcher.fetch()) },
        .claude: { Refresh(report: try await ClaudeUsageFetcher.fetch()) },
        .codex: {
            let response = try await CodexUsageFetcher.fetchFull()
            return Refresh(windows: response.windows, analytics: response.analytics)
        },
        .cursor: { Refresh(windows: try await CursorUsageFetcher.fetch()) },
        .opencode: { Refresh(statistics: try await OpenCodeUsageFetcher.fetch()) }
    ]) { self.fetchers = fetchers }

    func canRefresh(_ kind: AgentKind) -> Bool { fetchers[kind] != nil }

    func recordSession(_ sample: SessionUsage, for kind: AgentKind) {
        guard sample.hasValues, !sample.id.isEmpty, sample.id.utf8.count <= 512 else { return }
        var next = sessions[kind] ?? []
        var value = sample
        if let index = next.firstIndex(where: { $0.id == sample.id }) {
            let previous = next.remove(at: index)
            guard sample.updatedAt >= previous.updatedAt else { return }
            value.inputTokens = value.inputTokens ?? previous.inputTokens
            value.outputTokens = value.outputTokens ?? previous.outputTokens
            value.cacheReadTokens = value.cacheReadTokens ?? previous.cacheReadTokens
            value.cacheWriteTokens = value.cacheWriteTokens ?? previous.cacheWriteTokens
            value.reasoningTokens = value.reasoningTokens ?? previous.reasoningTokens
            value.costUSD = value.costUSD ?? previous.costUSD
            value.observed = value.observed || previous.observed
            var comparable = value
            comparable.updatedAt = previous.updatedAt
            guard comparable != previous else { return }
        }
        next.insert(value, at: 0)
        if next.count > Self.sessionLimit {
            for old in next.dropFirst(Self.sessionLimit) where kind == .claude { claudeMessages[old.id] = nil }
            next = Array(next.prefix(Self.sessionLimit))
        }
        sessions[kind] = next
    }

    @discardableResult func consumeClaude(_ json: [String: Any]) -> Bool {
        guard let id = json["session_id"] as? String, !id.isEmpty, id.utf8.count <= 256 else { return false }
        let cost = json["cost"] as? [String: Any] ?? [:]
        recordSession(SessionUsage(id: id, costUSD: SessionUsage.nonnegative(cost["total_cost_usd"])), for: .claude)
        return true
    }

    /// Message IDs make repeated/streamed usage snapshots replacements, never added twice.
    func recordClaudeMessage(_ message: [String: Any], sessionID: String) {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 512,
              let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 256,
              let usage = message["usage"] as? [String: Any] else { return }
        var sample = SessionUsage(id: id,
            inputTokens: SessionUsage.nonnegative(usage["input_tokens"]),
            outputTokens: SessionUsage.nonnegative(usage["output_tokens"]),
            cacheReadTokens: SessionUsage.nonnegative(usage["cache_read_input_tokens"]),
            cacheWriteTokens: SessionUsage.nonnegative(usage["cache_creation_input_tokens"]), observed: true)
        guard sample.hasValues else { return }
        var messages = claudeMessages[sessionID] ?? [:]
        if let previous = messages[id] {
            sample.inputTokens = sample.inputTokens ?? previous.inputTokens
            sample.outputTokens = sample.outputTokens ?? previous.outputTokens
            sample.cacheReadTokens = sample.cacheReadTokens ?? previous.cacheReadTokens
            sample.cacheWriteTokens = sample.cacheWriteTokens ?? previous.cacheWriteTokens
            sample.updatedAt = previous.updatedAt
            guard sample != previous else { return }
            sample.updatedAt = Date()
        }
        messages[id] = sample
        if messages.count > Self.messageLimit, let oldest = messages.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key { messages[oldest] = nil }
        claudeMessages[sessionID] = messages
        func sum(_ key: KeyPath<SessionUsage, Double?>) -> Double? {
            let values = messages.values.compactMap { $0[keyPath: key] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        recordSession(SessionUsage(id: sessionID, inputTokens: sum(\.inputTokens), outputTokens: sum(\.outputTokens),
            cacheReadTokens: sum(\.cacheReadTokens), cacheWriteTokens: sum(\.cacheWriteTokens), observed: true), for: .claude)
    }

    func refresh(_ kinds: [AgentKind], force: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        await withTaskGroup(of: Void.self) { group in
            for kind in Set(kinds) {
                guard let fetch = fetchers[kind], !refreshing.contains(kind),
                      force || now - (lastAttempt[kind] ?? -.infinity) >= Self.refreshInterval else { continue }
                refreshing.insert(kind)
                lastAttempt[kind] = now
                group.addTask { [weak self] in
                    do {
                        let value = try await fetch()
                        guard !Task.isCancelled else { await self?.fail(kind, cancelled: true); return }
                        await self?.complete(kind, value: value)
                    } catch {
                        await self?.fail(kind, cancelled: Task.isCancelled,
                            reason: (error as? IntegrationError)?.errorDescription)
                    }
                }
            }
        }
    }

    private func complete(_ kind: AgentKind, value: Refresh) {
        guard !value.windows.isEmpty || value.statistics != nil || value.analytics != nil || value.report != nil else {
            fail(kind, cancelled: false)
            return
        }
        defer { finish(kind) }
        var seen = Set<String>()
        let windows = value.windows.prefix(64).filter { seen.insert($0.id).inserted }
        snapshots[kind] = UsageSnapshot(windows: windows, updatedAt: Date(),
            report: value.report, statistics: value.statistics, analytics: value.analytics)
    }

    private func fail(_ kind: AgentKind, cancelled: Bool, reason: String? = nil) {
        finish(kind)
        guard !cancelled else { lastAttempt[kind] = nil; return }
        var snapshot = snapshots[kind] ?? UsageSnapshot()
        switch kind {
        case .opencode: snapshot.message = "Couldn’t load statistics. Update the OpenCode CLI, then refresh."
        case .antigravity: snapshot.message = "Couldn’t load usage. Install the latest agy CLI, sign in there, then refresh."
        case .cursor: snapshot.message = "Couldn’t load usage. Check Cursor Agent’s version and sign-in, or open its usage dashboard."
        default: snapshot.message = "Couldn’t refresh usage. Check the agent’s sign-in and try again."
        }
        // Only our own controlled errors are displayed; never CLI stderr or account responses.
        if let reason { snapshot.message = reason }
        snapshots[kind] = snapshot
    }

    private func finish(_ kind: AgentKind) { refreshing.remove(kind) }
}
