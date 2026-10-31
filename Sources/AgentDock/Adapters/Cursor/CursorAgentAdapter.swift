import Foundation

/// Native hooks own activity text; explicit runtime events supplement IDE lifecycle.
@MainActor
public final class CursorAgentAdapter: AgentAdapter {
    public static let shared = CursorAgentAdapter()
    public let kind: AgentKind = .cursor
    public let displayName = "Cursor"
    public private(set) var environment: AgentEnvironment = .ide
    public private(set) var isActive = false
    public private(set) var lastActivityDate = Date.distantPast
    public private(set) var currentModel = ""
    private var generations: [String: String] = [:]
    private var retiredGenerations = RecentCursorIDs(capacity: 1024)
    private var runtimeStates: [String: AgentStatus] = [:]
    private var runtimeDates: [String: Date] = [:]
    private var hookDates: [String: Date] = [:]
    private var turnStartDates: [String: Date] = [:]
    private var transcriptPaths: [String: String] = [:]
    private var recentEventIDs = Set<String>()
    private var eventOrder: [String] = []
    private static let conversationLimit = 256
    private var conversationOrder: [String] = []
    private var liveConversations = Set<String>()

    /// Counts expose retention behavior to regression tests without exposing event content.
    var retainedLifecycleCounts: [String: Int] {
        ["conversations": conversationOrder.count, "generations": generations.count,
         "runtimeStates": runtimeStates.count, "runtimeDates": runtimeDates.count, "hookDates": hookDates.count, "turnStartDates": turnStartDates.count,
         "retired": retiredGenerations.count,
         "subagents": subagents.count, "closedSubagents": closedSubagents.count]
    }

    @discardableResult private func trackConversation(_ id: String) -> Bool {
        if conversationOrder.last == id { return true }
        if let index = conversationOrder.firstIndex(of: id) {
            conversationOrder.remove(at: index)
        } else if conversationOrder.count >= Self.conversationLimit {
            // Completed history is expendable; running work and approvals are not.
            guard let index = conversationOrder.firstIndex(where: {
                !liveConversations.contains($0)
            }) else { return false }
            let evicted = conversationOrder.remove(at: index)
            if let generation = generations.removeValue(forKey: evicted) {
                retiredGenerations.insert(evicted + ":" + generation)
            }
            runtimeStates[evicted] = nil
            runtimeDates[evicted] = nil
            hookDates[evicted] = nil
            turnStartDates[evicted] = nil
            transcriptPaths[evicted] = nil
            AgentStateManager.shared.removeSession(agent: .cursor, sessionID: "cursor-hook:" + evicted)
        }
        conversationOrder.append(id)
        return true
    }

    private struct Subagent {
        let parent: String
        let session: String
        let model: String?
    }
    private var subagents: [String: Subagent] = [:]
    private var closedSubagents = RecentCursorIDs(capacity: 256)

    private init() {}
    public func start() { CursorLogWatcher.shared.start() }
    public func stop() { CursorLogWatcher.shared.stop() }
    public func focus() {
        if focusEnvironment == .cli { AgentFocusCoordinator.shared.focusTerminal(); return }
        AgentFocusCoordinator.shared.activateApp(bundleId: "com.todesktop.230313mzl4w4u92", fallbackPath: "/Applications/Cursor.app")
    }

    /// Native hook ingress: validation and interpretation belong to the adapter.
    @discardableResult func consumeHook(_ json: [String: Any]) -> Bool {
        guard let event = CursorActivityEvent.decode(json) else { return false }
        consumeHook(event, payload: json)
        return true
    }

    private func consumeHook(_ event: CursorActivityEvent, payload json: [String: Any]) {
        guard trackConversation(event.conversationID) else { return }
        // Cursor assigns a new generation_id to every user message, so the first live event of
        // an unseen generation is a native turn start even if beforeSubmitPrompt never reached us.
        var startsTurn = event.startsTurn
        if let generation = event.generationID {
            let key = event.conversationID + ":" + generation
            guard !retiredGenerations.contains(key) else { return }
            if event.startsTurn || generations[event.conversationID] == nil || event.status.isLive && generation != generations[event.conversationID] {
                if generations[event.conversationID] != generation, event.status.isLive, event.updatesLifecycle { startsTurn = true }
                if let previous = generations[event.conversationID], previous != generation {
                    retiredGenerations.insert(event.conversationID + ":" + previous)
                }
                generations[event.conversationID] = generation
            }
            guard generations[event.conversationID] == generation else { return }
        }
        // Completion stays closed until a native submission starts another turn.
        // A late response/tool hook without a generation ID is not a new turn.
        if (runtimeStates[event.conversationID] == .completed || runtimeStates[event.conversationID] == .idle),
           !startsTurn, event.status.isLive { return }
        if let key = event.duplicateKey {
            guard recentEventIDs.insert(key).inserted else { return }
            eventOrder.append(key)
            if eventOrder.count > 256 { recentEventIDs.remove(eventOrder.removeFirst()) }
        }
        if consumeSubagent(event) { return }
        if let path = event.transcriptPath, !path.isEmpty {
            transcriptPaths[event.conversationID] = (path as NSString).expandingTildeInPath
        }
        if event.updatesLifecycle {
            let received = Date()
            if event.hookName != "afterAgentThought" {
                hookDates[event.conversationID] = received
            }
            if startsTurn {
                // An inferred generation start may be a buffered activity hook. Only a native
                // submission/session start can fence completion logs from the previous turn.
                turnStartDates[event.conversationID] = event.startsTurn ? received : nil
            }
        }
        let state = AgentStateManager.shared
        state.beginAgentEvent(agent: .cursor, sessionID: "cursor-hook:" + event.conversationID)
        if startsTurn {
            runtimeStates[event.conversationID] = .working
            state.message = ""
        }
        let status: AgentStatus
        if !event.updatesLifecycle { status = state.status.isLive ? state.status : event.status }
        else if event.hookName == "preToolUse", event.text?.hasPrefix("Question: ") == true { status = .waitingApproval }
        else { status = event.status == .working && runtimeStates[event.conversationID] == .waitingApproval ? .waitingApproval : event.status }
        if event.updatesLifecycle && status.isLive { runtimeStates[event.conversationID] = status }
        if event.hookName == "stop" || event.hookName == "sessionEnd"
            || event.hookName == "postToolUseFailure" && json["is_interrupt"] as? Bool == true {
            finishGeneration(event.conversationID, status: status == .idle ? .idle : .completed)
        }
        let isApprovalDetail = (event.hookName == "preToolUse" && event.text?.hasPrefix("Question: ") == true)
            || event.text?.hasPrefix("Permission: ") == true
        let text = status == .waitingApproval && !isApprovalDetail ? state.message : event.text ?? state.message
        publish(status: status, text: text, model: event.model,
                sessionID: "cursor-hook:" + event.conversationID, surface: event.surface, startsTurn: startsTurn,
                ownerPID: event.ownerPID)
    }

    private func finishGeneration(_ conversation: String, status: AgentStatus = .completed) {
        runtimeStates[conversation] = status
        for (key, child) in Array(subagents) where child.parent == conversation {
            closedSubagents.insert(key); subagents[key] = nil
        }
        AgentStateManager.shared.removeSessions(prefix: "cursor-subagent:" + conversation + ":")
        if let generation = generations[conversation] { retiredGenerations.insert(conversation + ":" + generation) }
    }

    /// Children have their own model/session. A child's stop never ends its parent's turn.
    private func consumeSubagent(_ event: CursorActivityEvent) -> Bool {
        guard event.hookName == "subagentStart" || event.hookName == "subagentStop",
              let id = event.subagentID else { return false }
        let key = event.conversationID + ":" + id
        guard !closedSubagents.contains(key),
              runtimeStates[event.conversationID] != .completed,
              runtimeStates[event.conversationID] != .idle else { return true }
        guard subagents[key] != nil || subagents.count < 256 else { return true }
        let session = "cursor-subagent:" + key
        let child = subagents[key] ?? Subagent(parent: event.conversationID, session: session, model: event.subagentModel)
        let stopped = event.hookName == "subagentStop"
        let outcome: AgentStatus = event.subagentOutcome == "error" ? .error : event.subagentOutcome == "aborted" ? .observed : .completed
        if stopped { subagents[key] = nil; closedSubagents.insert(key) }
        else { subagents[key] = child }
        publish(status: stopped ? outcome : .working, text: event.text ?? "", model: child.model, sessionID: child.session, surface: event.surface, startsTurn: !stopped)
        return true
    }

    func consumeRuntime(_ event: CursorRuntimeEvent) {
        guard trackConversation(event.conversationID) else { return }
        if event.status == .completed || event.status == .idle {
            // A real end signal outranks buffered thought/tool hooks, but cannot close a newer turn.
            if let start = turnStartDates[event.conversationID], event.date <= start { return }
        } else if let hookDate = hookDates[event.conversationID], event.date <= hookDate {
            return // Delayed progress/approval logs must not override a newer native hook.
        }
        if let previous = runtimeDates[event.conversationID], event.date <= previous { return }
        runtimeDates[event.conversationID] = event.date
        runtimeStates[event.conversationID] = event.status
        if event.status == .completed || event.status == .idle {
            finishGeneration(event.conversationID, status: event.status)
        }
        let session = "cursor-hook:" + event.conversationID
        let state = AgentStateManager.shared
        state.beginAgentEvent(agent: .cursor, sessionID: session)
        let text: String
        if event.status == .waitingApproval {
            if let path = transcriptPaths[event.conversationID],
               let prompt = CursorActivityEvent.transcriptApprovalText(at: path, allowedRoots: Self.allowedTranscriptRoots) {
                text = prompt
            } else if state.message.hasPrefix("Question: ") || state.message.hasPrefix("Permission: ") {
                text = state.message
            } else if !state.message.isEmpty, !state.message.hasPrefix("Thought: "), !state.message.hasPrefix("Response: ") {
                let detail = state.message.firstIndex(of: ":").map {
                    String(state.message[state.message.index(after: $0)...]).trimmingCharacters(in: .whitespaces)
                } ?? state.message
                text = CursorActivityEvent.preview("Permission: " + (detail.isEmpty ? state.message : detail))
            } else {
                text = state.message
            }
        } else if event.status == .working && (state.message.hasPrefix("Question: ") || state.message.hasPrefix("Permission: ")) {
            text = ""
        } else {
            text = state.message
        }
        publish(status: event.status, text: text, model: nil, sessionID: session, surface: .ide, startsTurn: event.status == .working)
    }

    private static var allowedTranscriptRoots: [String] {
        [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/projects").path,
         FileManager.default.temporaryDirectory.path]
    }

    public func sessionDidEnd(_ sessionID: String, close: Bool) {
        if sessionID.hasPrefix("cursor-hook:") {
            let conversation = String(sessionID.dropFirst("cursor-hook:".count))
            liveConversations.remove(conversation)
            if close { finishGeneration(conversation, status: .idle) }
            else { runtimeStates[conversation] = .idle }
        } else if sessionID.hasPrefix("cursor-subagent:") {
            let key = String(sessionID.dropFirst("cursor-subagent:".count))
            subagents[key] = nil
            if close { closedSubagents.insert(key) }
        }
        isActive = !liveConversations.isEmpty || !subagents.isEmpty
    }

    private func publish(status: AgentStatus, text: String, model: String?, sessionID: String, surface: AgentEnvironment? = nil,
                         startsTurn: Bool = false, ownerPID: Int32? = nil) {
        if sessionID.hasPrefix("cursor-hook:") {
            let conversation = String(sessionID.dropFirst("cursor-hook:".count))
            if status.isLive { liveConversations.insert(conversation) }
            else { liveConversations.remove(conversation) }
        }
        isActive = !liveConversations.isEmpty || !subagents.isEmpty
        lastActivityDate = Date()
        if let surface { environment = surface }
        AgentStateManager.shared.beginAgentEvent(agent: .cursor, sessionID: sessionID)
        // Capture this session before visibility selection can restore another provider's approval.
        let sessionModel = model ?? AgentStateManager.shared.modelName
        AgentStateManager.shared.update(agent: .cursor, status: status,
                                        message: text, model: sessionModel, sessionID: sessionID, environment: surface, startsTurn: startsTurn,
                                        ownerPID: ownerPID)
        currentModel = sessionModel
    }

}

/// FIFO tombstones prevent late delivery from reviving recent completed work.
/// Retention stays bounded without clearing all protection at once.
private struct RecentCursorIDs {
    let capacity: Int
    private var values = Set<String>()
    private var order: [String] = []
    var count: Int { values.count }
    func contains(_ id: String) -> Bool { values.contains(id) }
    mutating func insert(_ id: String) {
        guard values.insert(id).inserted else { return }
        order.append(id)
        if order.count > capacity { values.remove(order.removeFirst()) }
    }
}
