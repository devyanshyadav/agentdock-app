import Foundation

/// Native OpenCode events own lifecycle; progress can never reopen a finished run.
@MainActor
public final class OpenCodeAgentAdapter: AgentAdapter {
    public static let shared = OpenCodeAgentAdapter()
    public let kind: AgentKind = .opencode
    public let displayName = "OpenCode"
    public private(set) var environment: AgentEnvironment = .cli
    public var isActive: Bool { sessions.values.contains { $0.status.isLive } }
    public private(set) var lastActivityDate = Date.distantPast
    public private(set) var currentModel = ""
    private struct Session {
        var run: String
        var status: AgentStatus = .working
        var text = ""
        var model = ""
        var updated = Date()
        var surface: AgentEnvironment = .cli
        var sourceID = ""
        var sourceStartedAt: Double = 0
        var turn = 0
        var sequence = 0
    }
    private static let sessionLimit = 256
    private var sessions: [String: Session] = [:]
    private var disconnectedSources: [String] = []
    private init() {}
    public func start() {} // The native plugin pushes events to the loopback bridge.
    public func stop() {}
    public func focus() {
        if focusEnvironment == .dedicatedWindow {
            AgentFocusCoordinator.shared.activateApp(bundleId: "ai.opencode.desktop", fallbackPath: "/Applications/OpenCode.app")
        } else { AgentFocusCoordinator.shared.focusTerminal() }
    }

    @discardableResult func consume(_ json: [String: Any], ownerPID: Int32?) -> Bool {
        guard let source = json["sourceID"] as? String, Self.validID(source) else { return false }
        if json["event"] as? String == "disconnect" {
            if !disconnectedSources.contains(source) {
                disconnectedSources.append(source)
                if disconnectedSources.count > Self.sessionLimit { disconnectedSources.removeFirst() }
            }
            for id in sessions.keys.filter({ sessions[$0]?.sourceID == source && sessions[$0]?.status.isLive == true }) {
                sessions[id]?.status = .idle
                AgentStateManager.shared.endSession(agent: kind, sessionID: id)
            }
            return true
        }
        guard !disconnectedSources.contains(source) else { return true }
        guard let id = json["sessionID"] as? String, id.hasPrefix("ses_"), Self.validID(id),
              let started = json["sourceStartedAt"] as? Double, started.isFinite, started > 0,
              let turn = json["turn"] as? Int, turn > 0,
              let sequence = json["sequence"] as? Int, sequence > 0,
              let rawStatus = json["status"] as? String, let status = AgentStatus(rawValue: rawStatus),
              [.working, .waitingApproval, .completed, .idle, .error].contains(status) else { return false }
        let run = source + ":" + String(turn)
        let previous = sessions[id]
        if let previous {
            if previous.sourceID == source {
                guard turn >= previous.turn, sequence > previous.sequence else { return true }
                if previous.run == run, !previous.status.isLive, status.isLive { return true }
            } else {
                guard started >= previous.sourceStartedAt else { return true }
                // A retiring observer cannot close a replacement observer's live run.
                if !status.isLive && previous.status.isLive { return true }
            }
        }
        guard retain(id) else { return false }
        if let usage = json["usage"] as? [String: Any] {
            let tokens = usage["tokens"] as? [String: Any] ?? [:]
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            UsageStore.shared.recordSession(SessionUsage(id: id,
                inputTokens: SessionUsage.nonnegative(tokens["input"]),
                outputTokens: SessionUsage.nonnegative(tokens["output"]),
                cacheReadTokens: SessionUsage.nonnegative(cache["read"]),
                cacheWriteTokens: SessionUsage.nonnegative(cache["write"]),
                reasoningTokens: SessionUsage.nonnegative(tokens["reasoning"]),
                costUSD: SessionUsage.nonnegative(usage["cost"])), for: .opencode)
        }
        var session = Session(run: run, status: status,
            text: Self.preview(json["message"] as? String ?? ""),
            model: String((json["model"] as? String ?? "").prefix(256)),
            surface: json["environment"] as? String == "dedicatedWindow" ? .dedicatedWindow : .cli,
            sourceID: source, sourceStartedAt: started, turn: turn, sequence: sequence)
        session.updated = Date(); sessions[id] = session
        lastActivityDate = session.updated; currentModel = session.model; environment = session.surface
        AgentStateManager.shared.update(agent: kind, status: status, message: session.text, model: session.model,
            sessionID: id, environment: session.surface, startsTurn: previous?.run != run && status.isLive, ownerPID: ownerPID)
        return true
    }
    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-:".contains($0)) }
    }
    private static func preview(_ text: String) -> String {
        String(text.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(240)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
    private func retain(_ id: String) -> Bool {
        if sessions[id] != nil { return true }
        if sessions.count >= Self.sessionLimit {
            guard let oldest = sessions.filter({ !$0.value.status.isLive }).min(by: { $0.value.updated < $1.value.updated })?.key else { return false }
            sessions[oldest] = nil
            AgentStateManager.shared.removeSession(agent: .opencode, sessionID: oldest)
        }
        return true
    }

    public func sessionDidEnd(_ sessionID: String, close: Bool) {
        sessions[sessionID]?.status = .idle
    }
}
