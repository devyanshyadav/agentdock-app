import Foundation
import Testing
@testable import AgentDock

struct UsageParserTests {
    @Test func cursorDiscoversNewPercentageCategoriesWithoutInventingMissingLimits() {
        let windows = CursorUsageFetcher.parse(["current": ["planUsage": [
            "newModelPercentUsed": 12.5, "bonusPercentUsed": 0, "notUsage": 99, "invalidPercentUsed": true
        ]]])
        #expect(Set(windows.map(\.id)) == ["cursor:newModelPercentUsed", "cursor:bonusPercentUsed"])
        #expect(windows.first { $0.id == "cursor:newModelPercentUsed" }?.title == "New Model")
    }

    @Test func openCodeUsesReportedPeriodAndRejectsFractionalSessionCounts() throws {
        let report = Data(#"{"range":{"from":1792693800000,"to":1793257678730},"sessions":1.5,"tokens":{"input":0},"cost":0}"#.utf8)
        let statistics = try OpenCodeStatistics.parse(report)
        #expect(statistics.sessions == nil)
        #expect(statistics.period?.start.timeIntervalSince1970 == 1_792_693_800)
        #expect(statistics.period?.end.timeIntervalSince1970 == 1_793_257_678.73)
    }

    @Test func desktopCodexKeepsItsReportedSessionTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("rollout.jsonl")
        let rows = #"""
        {"type":"session_meta","payload":{"id":"desktop-usage","source":"vscode","cwd":"/tmp"}}
        {"type":"event_msg","timestamp":"2026-10-29T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":30}}}}
        """# + "\n"
        try Data(rows.utf8).write(to: path)
        let snapshot = try #require(CodexTranscriptSnapshot.load(path: path.path, root: root.path, startedAt: Date()))
        #expect(snapshot.usage?.inputTokens == 120)
        #expect(snapshot.usage?.outputTokens == 30)
    }

    @Test func malformedStreaksCannotOverflowIntegers() {
        for value in [Double.greatestFiniteMagnitude, Double(Int.max), 1.5, -1.0] {
            #expect(CodexAnalytics.parse(["summary": ["currentStreakDays": value]]) == nil)
        }
        #expect(CodexAnalytics.parse(["summary": ["currentStreakDays": 0]])?.currentStreakDays == 0)
    }

    @Test func cursorMissingSpendNeverBecomesZeroUsage() {
        let windows = CursorUsageFetcher.parse(["current": ["planUsage": ["totalPercentUsed": 10]],
            "hardLimit": ["hardLimit": 20]])
        #expect(windows.count == 1)
        #expect(!windows.contains { $0.id == "cursor:spendLimitUsage" })
    }

    @Test func codexRetainsEveryReportedLimitPool() throws {
        let windows = try CodexUsageFetcher.parse(["result": ["rateLimitsByLimitId": [
            "codex": ["primary": ["usedPercent": 25]],
            "review": ["primary": ["usedPercent": 50]]
        ]]])
        #expect(windows.count == 2)
        #expect(Set(windows.map(\.usedPercent)) == [25, 50])
    }

    @Test func openCodeStatisticsPreserveZeroAndRejectUnknownSchemas() throws {
        let json = Data(#"{"sessions":2,"tokens":{"input":100,"output":20,"cache":{"read":0,"write":5},"reasoning":7},"cost":0}"#.utf8)
        let statistics = try OpenCodeStatistics.parse(json)
        #expect(statistics.sessions == 2)
        #expect(statistics.usage.inputTokens == 100)
        #expect(statistics.usage.cacheReadTokens == 0)
        #expect(statistics.usage.costUSD == 0)
        #expect(throws: (any Error).self) { try OpenCodeStatistics.parse(Data(#"{"tokens":{},"cost":true}"#.utf8)) }
        #expect(throws: (any Error).self) { try OpenCodeStatistics.parse(Data(#"{"unexpected":42}"#.utf8)) }
    }

    @Test func invalidNumbersStayUnavailableAndOverageIsPreserved() {
        for value: Any in [true, -1.0, Double.nan, Double.infinity, "25"] {
            #expect(UsageWindow(id: "test", title: "Test", percentage: value) == nil)
        }
        #expect(UsageWindow(id: "test", title: "Test", percentage: 125)?.usedPercent == 125)
        #expect(UsageWindow(id: "test", title: "Test", percentage: 0)?.usedPercent == 0)
        #expect(UsageWindow.date(true) == nil)
    }

    @Test func claudeNativeUsageRequiresNoSubscriptionQuotaFields() throws {
        let data = Data(#"{"is_error":false,"local_command":"usage","num_turns":0,"result":"Total cost: $0.0000\nUsage: 0 input, 0 output"}"#.utf8)
        #expect(try ClaudeUsageFetcher.parse(data).contains("0 input"))
        for data in [Data(#"{"is_error":true,"result":"Not signed in"}"#.utf8),
                     Data(#"{"is_error":false,"result":"I think usage is 50%"}"#.utf8)] {
            #expect(throws: (any Error).self) { try ClaudeUsageFetcher.parse(data) }
        }
    }

    @Test func codexSupportsNativeWindowKeysWithoutInventingCost() throws {
        let camel: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 30, "windowDurationMins": 300, "resetsAt": 1_900_000_000]]
        #expect(UsageParsers.codex(camel).first?.usedPercent == 30)
        let json: [String: Any] = ["type": "event_msg", "timestamp": "2026-10-28T10:00:00Z", "payload": [
            "type": "token_count", "rate_limits": camel,
            "info": ["total_token_usage": ["input_tokens": 1200, "output_tokens": 200, "cached_input_tokens": 400]]
        ]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        let report = try #require(UsageParsers.codexLine(line, sessionID: "test"))
        #expect(report.inputTokens == 1200)
        #expect(report.costUSD == nil)
    }

    @Test func antigravityReadsNativeCliQuotaReport() throws {
        let report: [String: Any] = ["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": [
            ["name": "Gemini Models", "buckets": [
                ["id": "weekly", "name": "Weekly", "remaining_fraction": 0.759, "reset_time": "2026-10-31T07:57:22Z"],
                ["id": "5h", "name": "5-hour", "remaining_fraction": 0.962],
                ["id": "invalid", "remaining_fraction": true],
                ["id": "overflow", "remaining_fraction": 2]
            ]],
            ["name": "New Model", "buckets": [
                ["id": "monthly", "name": "Monthly", "remaining_fraction": 0]
            ]]
        ]]]]
        let windows = try AntigravityQuotaFetcher.parse(JSONSerialization.data(withJSONObject: report))
        #expect(windows.count == 3)
        #expect(windows[0].title == "Gemini Models · Weekly")
        #expect(abs(windows[0].usedPercent - 24.1) < 0.01)
        #expect(windows[0].resetsAt != nil)
        #expect(abs(windows[1].usedPercent - 3.8) < 0.01)
        #expect(windows[2].usedPercent == 100)
    }

    @Test func antigravityRejectsFailedEmptyAndModelGeneratedReports() throws {
        for report: [String: Any] in [
            ["status": "ERROR", "error": "Not signed in"],
            ["status": "SUCCESS", "response": "You have 100% remaining"],
            ["status": "SUCCESS", "command": ["name": "usage", "data": ["groups": []]]]
        ] {
            let data = try JSONSerialization.data(withJSONObject: report)
            #expect(throws: (any Error).self) { try AntigravityQuotaFetcher.parse(data) }
        }
    }

    @Test func codexAppServerRateLimitsParseCleanly() throws {
        let payload = Data(#"""
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":24,"windowDurationMins":300,"resetsAt":1793218508},"secondary":{"usedPercent":19,"windowDurationMins":10080,"resetsAt":1793784953}}}}
        """#.utf8)
        let windows = try CodexUsageFetcher.parse(payload)
        #expect(windows.count == 2)
        #expect(windows[0].title.hasPrefix("codex · "))
        #expect(!windows[0].title.contains("Primary"))
        #expect(windows[0].usedPercent == 24)
        #expect(windows[0].title != windows[1].title)
        #expect(windows[1].usedPercent == 19)

        let analyticsJson: [String: Any] = [
            "id": 3,
            "result": [
                "summary": [
                    "lifetimeTokens": 1_234_567,
                    "peakDailyTokens": 98_765,
                    "longestRunningTurnSec": 900,
                    "currentStreakDays": 3,
                    "longestStreakDays": 5
                ]
            ]
        ]
        let analytics = try #require(CodexAnalytics.parse(analyticsJson, planType: "plus"))
        #expect(analytics.planType == "plus")
        #expect(analytics.lifetimeTokens == 1_234_567)
        #expect(analytics.peakDailyTokens == 98_765)
        #expect(analytics.longestTurnSeconds == 900)
        #expect(analytics.currentStreakDays == 3)
        #expect(analytics.longestStreakDays == 5)
    }

    @Test func cursorParsesIncludedAutoApiAndOnDemandWindows() {
        let json: [String: Any] = [
            "current": [
                "billingCycleEnd": "1794814221000",
                "planUsage": [
                    "totalPercentUsed": 16.5,
                    "autoPercentUsed": 15.4,
                    "apiPercentUsed": 61.6
                ],
                "spendLimitUsage": [
                    "individualUsed": 500,
                    "individualLimit": 2000
                ]
            ],
            "plan": ["planInfo": ["planName": "Pro"]]
        ]
        let windows = CursorUsageFetcher.parse(json)
        #expect(windows.count == 4)
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        #expect(byID["cursor:totalPercentUsed"]?.usedPercent == 16.5)
        #expect(byID["cursor:totalPercentUsed"]?.resetsAt == Date(timeIntervalSince1970: 1_794_814_221))
        #expect(byID["cursor:autoPercentUsed"]?.usedPercent == 15.4)
        #expect(byID["cursor:apiPercentUsed"]?.usedPercent == 61.6)
        #expect(byID["cursor:spendLimitUsage"]?.usedPercent == 25)
    }


}

@MainActor
struct UsageStoreTests {
    @Test func cancelledRefreshCanRetryImmediately() async {
        let store = UsageStore(fetchers: [.claude: {
            try await Task.sleep(nanoseconds: 10_000_000)
            return UsageStore.Refresh(report: "Native report")
        }])
        let task = Task { await store.refresh([.claude], now: 100) }
        task.cancel()
        await task.value
        #expect(store.refreshing.isEmpty)
        await store.refresh([.claude], now: 100)
        #expect(store.snapshots[.claude]?.report == "Native report")
        #expect(store.sessions[.claude] == nil)
    }

    @Test func unchangedSessionMeasurementsDoNotRepublish() {
        let store = UsageStore(fetchers: [:])
        let sample = SessionUsage(id: "fixture", inputTokens: 10, costUSD: 0)
        store.recordSession(sample, for: .claude)
        let before = store.sessions[.claude]
        store.recordSession(SessionUsage(id: "fixture", updatedAt: sample.updatedAt.addingTimeInterval(1), inputTokens: 10), for: .claude)
        #expect(store.sessions[.claude] == before)
        store.recordClaudeMessage(["id": "message", "usage": ["input_tokens": 20]], sessionID: "observed")
        let observed = store.sessions[.claude]
        store.recordClaudeMessage(["id": "message", "usage": ["input_tokens": 20]], sessionID: "observed")
        #expect(store.sessions[.claude] == observed)
    }

    @Test func antigravityStatusLineCannotOverwriteTheQuotaDisplay() {
        let before = UsageStore.shared.snapshots[.antigravity]
        for remaining in [0.9, 0.8] {
            _ = AntigravityAgentAdapter.shared.consumeHook([
                "event": "StatusLine",
                "quota": ["gemini-weekly": ["remaining_fraction": remaining, "reset_time": "2026-11-01T12:00:00Z"]]
            ])
            #expect(UsageStore.shared.snapshots[.antigravity] == before)
        }
    }

    @Test func analyticsBelongToTheStoreThatRequestedThem() async throws {
        let analytics = try #require(CodexAnalytics.parse(["summary": ["lifetimeTokens": 123]]))
        let store = UsageStore(fetchers: [.codex: { UsageStore.Refresh(analytics: analytics) }])
        let unrelated = UsageStore(fetchers: [:])
        await store.refresh([.codex])
        #expect(store.snapshots[.codex]?.analytics?.lifetimeTokens == 123)
        #expect(unrelated.snapshots[.codex]?.analytics == nil)
        #expect(store.refreshing.isEmpty)
    }

    @Test func refreshIsThrottledAndFailureKeepsLastReportedValues() async {
        actor Fetcher {
            var calls = 0
            func fetch() throws -> UsageStore.Refresh {
                calls += 1
                if calls > 1 { throw IntegrationError.message("Fixture failure") }
                return UsageStore.Refresh(windows: [UsageWindow(id: "monthly", title: "Monthly", percentage: 42)!])
            }
        }
        let fetcher = Fetcher()
        let store = UsageStore(fetchers: [.antigravity: { try await fetcher.fetch() }])
        await store.refresh([.antigravity])
        await store.refresh([.antigravity])
        #expect(await fetcher.calls == 1)
        await store.refresh([.antigravity], force: true)
        #expect(await fetcher.calls == 2)
        #expect(store.snapshots[.antigravity]?.windows.first?.usedPercent == 42)
        #expect(store.snapshots[.antigravity]?.message != nil)
        #expect(store.refreshing.isEmpty)
    }

    @Test func defaultRefreshCoversCursorCodexAndAntigravity() async {
        let store = UsageStore()
        #expect(store.canRefresh(.cursor))
        #expect(store.canRefresh(.codex))
        #expect(store.canRefresh(.antigravity))
        #expect(store.canRefresh(.claude))
    }

    @Test func openCodeStatisticsAreSeparateFromSessionEventsAndSurviveRefreshFailure() async throws {
        actor Fetcher {
            var calls = 0
            func fetch() throws -> OpenCodeStatistics {
                calls += 1
                if calls > 1 { throw IntegrationError.message("Unavailable") }
                return try OpenCodeStatistics.parse(Data(#"{"sessions":3,"tokens":{"input":120},"cost":0.5}"#.utf8))
            }
        }
        let fetcher = Fetcher()
        let store = UsageStore(fetchers: [.opencode: { UsageStore.Refresh(statistics: try await fetcher.fetch()) }])
        #expect(store.canRefresh(.opencode))
        await store.refresh([.opencode])
        await store.refresh([.opencode])
        #expect(await fetcher.calls == 1)
        #expect(store.snapshots[.opencode]?.statistics?.usage.inputTokens == 120)
        #expect(store.sessions[.opencode] == nil)
        #expect(store.snapshots[.opencode]?.windows.isEmpty == true)
        await store.refresh([.opencode], force: true)
        #expect(store.snapshots[.opencode]?.statistics?.usage.costUSD == 0.5)
        #expect(store.snapshots[.opencode]?.message != nil)
        #expect(store.refreshing.isEmpty)
    }

    @Test func refreshingReplacesRemovedWindowsAndPreservesProviderOrder() async throws {
        actor Fetcher {
            var calls = 0
            func fetch() -> UsageStore.Refresh {
                calls += 1
                let ids = calls == 1 ? ["z", "a", "z"] : ["new"]
                return UsageStore.Refresh(windows: ids.compactMap { UsageWindow(id: $0, title: $0, percentage: 0) })
            }
        }
        let fetcher = Fetcher()
        let store = UsageStore(fetchers: [.codex: { await fetcher.fetch() }])
        await store.refresh([.codex])
        #expect(store.snapshots[.codex]?.windows.map(\.id) == ["z", "a"])
        await store.refresh([.codex], force: true)
        #expect(store.snapshots[.codex]?.windows.map(\.id) == ["new"])
    }

    @Test func nativeClaudeCostsCannotOverwriteTheCLIAccountReport() async {
        let store = UsageStore(fetchers: [.claude: { UsageStore.Refresh(report: "Native CLI report") }])
        await store.refresh([.claude])
        _ = store.consumeClaude(["session_id": "fixture", "rate_limits": ["five_hour": ["used_percentage": 99]],
            "cost": ["total_cost_usd": 0]])
        #expect(store.snapshots[.claude]?.report == "Native CLI report")
        #expect(store.snapshots[.claude]?.windows.isEmpty == true)
        #expect(store.sessions[.claude]?.first?.costUSD == 0)
    }

    @Test func cumulativeSessionReportsReplaceRatherThanAddAndRetainPartialMetrics() {
        let store = UsageStore(fetchers: [:])
        store.recordSession(SessionUsage(id: "session", inputTokens: 100, outputTokens: 20, costUSD: 0.12), for: .opencode)
        store.recordSession(SessionUsage(id: "session", inputTokens: 150, outputTokens: 30), for: .opencode)
        #expect(store.sessions[.opencode]?.count == 1)
        #expect(store.sessions[.opencode]?.first?.inputTokens == 150)
        #expect(store.sessions[.opencode]?.first?.costUSD == 0.12)
    }

    @Test func claudeStreamingUsageIsDeduplicatedByMessageID() {
        let store = UsageStore(fetchers: [:])
        store.recordClaudeMessage(["id": "a", "usage": ["input_tokens": 100, "output_tokens": 10]], sessionID: "session")
        store.recordClaudeMessage(["id": "a", "usage": ["output_tokens": 20]], sessionID: "session")
        store.recordClaudeMessage(["id": "b", "usage": ["input_tokens": 50, "output_tokens": 5]], sessionID: "session")
        #expect(store.sessions[.claude]?.first?.inputTokens == 150)
        #expect(store.sessions[.claude]?.first?.outputTokens == 25)
        #expect(store.sessions[.claude]?.first?.observed == true)
        #expect(store.sessions[.claude]?.first?.costUSD == nil)
    }

    @Test func usageDoesNotStartAnAgentOrChangeItsActivity() {
        let store = UsageStore(fetchers: [:])
        let state = AgentStateManager.shared
        let original = (state.status, state.message, state.isIndicatorVisible)
        #expect(store.consumeClaude(["session_id": "fixture", "rate_limits": ["five_hour": ["used_percentage": 12]], "cost": ["total_cost_usd": 0.03]]))
        #expect(state.status == original.0)
        #expect(state.message == original.1)
        #expect(state.isIndicatorVisible == original.2)
        #expect(store.sessions[.claude]?.first?.costUSD == 0.03)
    }

    @Test func sessionRetentionStaysBounded() {
        let store = UsageStore(fetchers: [:])
        for index in 0..<100 { store.recordSession(SessionUsage(id: "session-\(index)", inputTokens: 1), for: .codex) }
        #expect(store.sessions[.codex]?.count == 64)
        #expect(store.sessions[.codex]?.first?.id == "session-99")
    }
}

struct ClaudeUsageInstallationTests {
    @Test func unsupportedStatusLineConfigurationIsPreserved() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: source)
        let config = root.appendingPathComponent("settings.json")
        let custom: [String: Any] = ["type": "future-type", "command": "another-status", "padding": 3]
        try JSONSerialization.data(withJSONObject: ["statusLine": custom]).write(to: config)
        try ClaudeHookInstaller.install(base: root, destination: root.appendingPathComponent("observer.sh"), source: source)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let actual = try #require(json["statusLine"] as? [String: Any])
        #expect(NSDictionary(dictionary: actual).isEqual(to: custom))
        #expect(json["hooks"] != nil)
    }

    @Test func existingStatusLineOutputAndSettingsSurviveInstallation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("Observer's hooks/observer.sh")
        let config = root.appendingPathComponent("settings.json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ClaudeHooks/observer.sh")
        let previous = "printf 'original: '; cat"
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": previous, "padding": 2]])
            .write(to: config)
        try ClaudeHookInstaller.install(base: root, destination: destination, source: source)
        let installed = try Data(contentsOf: config)
        try ClaudeHookInstaller.install(base: root, destination: destination, source: source)
        #expect(try Data(contentsOf: config) == installed)
        let json = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        let status = try #require(json["statusLine"] as? [String: Any])
        #expect(status["padding"] as? Int == 2)
        let command = try #require(status["command"] as? String)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("{\"session_id\":\"fixture\"}".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: data, as: UTF8.self) == "original: {\"session_id\":\"fixture\"}")
    }
}
