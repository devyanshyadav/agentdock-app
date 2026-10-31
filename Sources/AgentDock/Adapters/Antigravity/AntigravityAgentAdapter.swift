import Foundation

@MainActor
public final class AntigravityAgentAdapter: AgentAdapter {
    public static let shared = AntigravityAgentAdapter()
    public let kind: AgentKind = .antigravity
    public let displayName = "Antigravity"
    public private(set) var environment: AgentEnvironment = .dedicatedWindow
    public private(set) var isActive = false
    public private(set) var lastActivityDate = Date.distantPast
    public private(set) var currentModel = ""

    private struct Session {
        var status: AgentStatus = .idle
        var text = ""
        var model = ""
        var surface: AgentEnvironment = .dedicatedWindow
        var nativeLifecycle = false
        var epoch = UUID()
        var firstStep: Int?
        var finished = false
        var startedAt = Date()
        var updated = Date()
        var ownerPID: Int32?
        var requests: [Int: String] = [:]
        var stepRequests: [Int: String] = [:]
        var confirmationPending = false
        var waitingText: String? {
            if let first = requests.keys.min() { return requests[first] }
            if let first = stepRequests.keys.min() { return stepRequests[first] }
            return confirmationPending ? "Approval required" : nil
        }
    }
    /// The IDE emits no event when a turn is cancelled (the Stop hook is killed with the request and
    /// the transcript records nothing). A working turn that stays silent this long is hidden; the next
    /// hook or transcript line brings it back, so a slow tool call only causes a brief gap.
    private static let quietLimit: TimeInterval = 120
    private var sessions: [String: Session] = [:]
    private var watchers: [String: LogStreamWatcher] = [:]
    private var lastCapacityWarning = Date.distantPast
    enum HookReceipt { case accepted, invalid, capacityExceeded }
    private var summaryObservers: [FileChangeObserver] = []
    private var databaseReads: [String: Task<Void, Never>] = [:]
    private var readTickets: [String: UUID] = [:]
    private var pendingReads = Set<String>()
    private init() {}

    public func start() {
        guard summaryObservers.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let gemini = home.appendingPathComponent(".gemini")
        for (dirName, surface) in [("antigravity", AgentEnvironment.dedicatedWindow), ("antigravity-ide", .ide), ("antigravity-cli", .cli)] {
            let root = gemini.appendingPathComponent(dirName)
            let observer = FileChangeObserver(paths: [root.path], onFileChange: { [weak self] path in
                if path.contains("conversation_summaries.db") || path == root.path {
                    self?.scheduleSummaryReconciliation(dbPath: root.appendingPathComponent("conversation_summaries.db").path, surface: surface)
                }
                if path.contains("/conversations/") || path == root.path || path.hasSuffix("/conversations") {
                    let filename = URL(fileURLWithPath: path).lastPathComponent
                    if filename.hasSuffix(".db") || filename.hasSuffix(".db-wal"),
                       let dot = filename.firstIndex(of: ".") {
                        let sessionID = String(filename[..<dot])
                        if UUID(uuidString: sessionID) != nil {
                            let dbPath = root.appendingPathComponent("conversations/" + sessionID + ".db").path
                            self?.scheduleStepReconciliation(dbPath: dbPath, sessionID: sessionID, surface: surface)
                        }
                    } else if path == root.path || path.hasSuffix("/conversations") {
                        for (liveID, liveSession) in self?.sessions ?? [:] where liveSession.status.isLive && liveSession.surface == surface {
                            let dbPath = root.appendingPathComponent("conversations/" + liveID + ".db").path
                            self?.scheduleStepReconciliation(dbPath: dbPath, sessionID: liveID, surface: surface)
                        }
                    }
                }
            }, onChange: { [weak self] in
                self?.scheduleSummaryReconciliation(dbPath: root.appendingPathComponent("conversation_summaries.db").path, surface: surface)
            })
            summaryObservers.append(observer)
            observer.start()
        }
    }
    public func stop() {
        databaseReads.values.forEach { $0.cancel() }; databaseReads.removeAll()
        readTickets.removeAll(); pendingReads.removeAll()
        summaryObservers.forEach { $0.stop() }; summaryObservers.removeAll()
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }
    public func focus() {
        let surface = focusEnvironment
        switch surface {
        case .cli: AgentFocusCoordinator.shared.focusTerminal()
        case .ide: AgentFocusCoordinator.shared.activateApp(bundleId: "com.google.antigravity-ide", fallbackPath: "/Applications/Antigravity IDE.app")
        case .dedicatedWindow: AgentFocusCoordinator.shared.activateApp(bundleId: "com.google.antigravity", fallbackPath: "/Applications/Antigravity.app")
        }
    }

    @discardableResult func consumeHook(_ json: [String: Any]) -> HookReceipt {
        guard let event = AntigravityActivityEvent.decode(json) else {
            return json["event"] as? String == "StatusLine" ? .accepted : .invalid
        }
        guard retain(event.session) else { return .capacityExceeded }
        // A completed invocation stays closed until the next native start. Status-line
        // redraws (including old approvals) and delayed post hooks are not new turns.
        if sessions[event.session]?.finished == true && !event.startsInvocation { return .accepted }
        var session = sessions[event.session] ?? Session()
        session.nativeLifecycle = true
        if let pid = (json["_agentdock_pid"] as? NSNumber).map({ Int32(truncating: $0) }) { session.ownerPID = pid }
        if event.startsInvocation || event.authoritative && event.confirmationPending == nil && !event.status.isLive {
            session.requests.removeAll()
            session.stepRequests.removeAll()
            session.confirmationPending = false
        }
        if event.startsInvocation {
            session.epoch = UUID()
            session.firstStep = (json["initialNumSteps"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
            if session.finished || session.status != .working { session.text = "" }
            session.finished = false
            if session.text.isEmpty { session.text = "Thinking…" }
        }
        if let pending = event.confirmationPending { session.confirmationPending = pending }
        if let step = event.requestStep {
            if event.resolvesRequest { session.requests[step] = nil }
            else if let text = event.text { session.requests[step] = text }
        }
        sessions[event.session] = session
        let waitingText = session.waitingText
        let status: AgentStatus = waitingText != nil ? .waitingApproval : event.status
        publish(event.session, status: status, text: waitingText ?? event.text, model: event.model, surface: event.environment, startsTurn: event.startsInvocation)
        if let path = event.transcript, !event.authoritative || status.isLive { watch(path, session: event.session) }
        if event.startsInvocation {
            let root = Self.dataDirectory(event.environment)
            scheduleStepReconciliation(dbPath: root.appendingPathComponent("conversations/" + event.session + ".db").path,
                                       sessionID: event.session, surface: event.environment)
            scheduleSummaryReconciliation(dbPath: root.appendingPathComponent("conversation_summaries.db").path, surface: event.environment)
        }
        if !status.isLive && event.authoritative {
            sessions[event.session]?.finished = true
            cancelRead("step:" + event.session)
            watchers.removeValue(forKey: event.session)?.stop()
        }
        return .accepted
    }

    private func retain(_ id: String) -> Bool {
        if sessions[id] != nil { return true }
        if sessions.count >= 256 {
            guard let oldest = sessions.filter({ !$0.value.status.isLive }).min(by: { $0.value.updated < $1.value.updated })?.key else {
                if Date().timeIntervalSince(lastCapacityWarning) >= 30 {
                    NSLog("[AgentDock] Antigravity event dropped: all 256 retained sessions are live.")
                    lastCapacityWarning = Date()
                }
                return false
            }
            sessions[oldest] = nil; watchers.removeValue(forKey: oldest)?.stop()
            AgentStateManager.shared.removeSession(agent: .antigravity, sessionID: oldest)
        }
        sessions[id] = Session()
        return true
    }
    private func publish(_ id: String, status: AgentStatus, text: String?, model: String?, surface: AgentEnvironment, startsTurn: Bool = false) {
        guard retain(id) else { return }
        var session = sessions[id] ?? Session()
        let now = Date()
        if startsTurn || status.isLive && !session.status.isLive { session.startedAt = now }
        session.status = status; session.updated = now; session.surface = surface
        if let text { session.text = AntigravityActivityEvent.preview(text) }
        if let model, !model.isEmpty { session.model = model }
        sessions[id] = session
        environment = surface; isActive = sessions.values.contains { $0.status.isLive }; lastActivityDate = Date()
        AgentStateManager.shared.update(agent: .antigravity, status: status, message: session.text,
                                        model: session.model, sessionID: id, environment: surface, startsTurn: startsTurn,
                                        ownerPID: session.ownerPID, quietLimit: session.ownerPID == nil ? Self.quietLimit : nil)
        currentModel = session.model
    }
    private static func dataDirectory(_ surface: AgentEnvironment) -> URL {
        let product: String
        switch surface {
        case .cli: product = "antigravity-cli"
        case .ide: product = "antigravity-ide"
        case .dedicatedWindow: product = "antigravity"
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/" + product)
    }

    /// One pending read per database scope. Writes during an in-flight read request one follow-up;
    /// there are no recurring scans and a busy stream cannot postpone updates indefinitely.
    private func enqueueRead(_ key: String, read: @escaping @MainActor () async -> Void) {
        pendingReads.insert(key)
        guard databaseReads[key] == nil else { return }
        let ticket = UUID()
        readTickets[key] = ticket
        databaseReads[key] = Task { [weak self] in
            defer {
                if let self, self.readTickets[key] == ticket {
                    self.readTickets[key] = nil; self.databaseReads[key] = nil; self.pendingReads.remove(key)
                }
            }
            repeat {
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
                guard let self, self.readTickets[key] == ticket else { return }
                self.pendingReads.remove(key)
                await read()
                guard !Task.isCancelled, self.pendingReads.contains(key) else { return }
            } while true
        }
    }
    private func cancelRead(_ key: String) {
        readTickets[key] = nil; pendingReads.remove(key)
        databaseReads.removeValue(forKey: key)?.cancel()
    }

    private func scheduleSummaryReconciliation(dbPath: String, surface: AgentEnvironment) {
        guard sessions.values.contains(where: { $0.status.isLive && $0.surface == surface }) else { return }
        enqueueRead("summary:" + surface.rawValue) { [weak self] in
            guard let self else { return }
            let epochs = self.sessions.filter { $0.value.status.isLive && $0.value.surface == surface }
                .mapValues { $0.epoch }
            guard !epochs.isEmpty else { return }
            let snapshot = await Task.detached(priority: .utility) {
                AntigravityDatabase.readRuns(path: dbPath, sessionIDs: Array(epochs.keys))
            }.value
            guard !Task.isCancelled, let snapshot else { return }
            let ended = snapshot.compactMap { id, record -> String? in
                guard let session = self.sessions[id], session.epoch == epochs[id], session.status.isLive,
                      record.isIdleOrCancelled else { return nil }
                let modified = record.modifiedAt ?? session.startedAt
                guard modified >= session.startedAt.addingTimeInterval(-5.0) else { return nil }
                return id
            }
            self.reconcileSummaryIdleSessions(ended)
        }
    }

    func reconcileSummaryIdleSessions(_ ids: [String]) {
        for id in ids {
            guard sessions[id]?.status.isLive == true else { continue }
            sessionDidEnd(id, close: true)
            AgentStateManager.shared.endSession(agent: .antigravity, sessionID: id)
        }
    }

    private func scheduleStepReconciliation(dbPath: String, sessionID: String, surface: AgentEnvironment) {
        guard let session = sessions[sessionID], session.status.isLive, !session.finished,
              session.surface == surface else { return }
        enqueueRead("step:" + sessionID) { [weak self] in
            guard let self, let current = self.sessions[sessionID], current.status.isLive, !current.finished else { return }
            let epoch = current.epoch, firstStep = current.firstStep
            let snapshot = await Task.detached(priority: .utility) {
                AntigravityDatabase.readSteps(path: dbPath, sinceStep: firstStep)
            }.value
            guard !Task.isCancelled, let snapshot else { return }
            self.applyStepState(snapshot, sessionID: sessionID, surface: surface, epoch: epoch)
        }
    }

    func applyStepState(_ snapshot: AntigravityDatabase.StepState, sessionID: String, surface: AgentEnvironment, epoch: UUID? = nil) {
        guard var session = sessions[sessionID], session.status.isLive, !session.finished,
              session.surface == surface,
              epoch == nil || session.epoch == epoch else { return }
        let previousWaiting = session.waitingText
        session.stepRequests = snapshot.waitingApprovals
        sessions[sessionID] = session
        if let waitingText = session.waitingText {
            if session.status != .waitingApproval || session.text != waitingText {
                publish(sessionID, status: .waitingApproval, text: waitingText, model: nil, surface: surface)
            }
        } else if previousWaiting != nil {
            publish(sessionID, status: session.nativeLifecycle ? .working : .observed,
                    text: snapshot.activeActivity ?? "Thinking…", model: nil, surface: surface)
        } else if let activity = snapshot.activeActivity, session.text != activity {
            publish(sessionID, status: session.status, text: activity, model: nil, surface: surface)
        } else if snapshot.activeActivity == nil && snapshot.waitingApprovals.isEmpty {
            scheduleSummaryReconciliation(dbPath: Self.dataDirectory(surface).appendingPathComponent("conversation_summaries.db").path, surface: surface)
        }
    }

    public func sessionDidEnd(_ sessionID: String, close: Bool) {
        guard var session = sessions[sessionID] else { return }
        session.status = .idle
        session.requests.removeAll()
        session.stepRequests.removeAll()
        session.confirmationPending = false
        cancelRead("step:" + sessionID)
        if close {
            session.finished = true
            watchers.removeValue(forKey: sessionID)?.stop()
        }
        sessions[sessionID] = session
        isActive = sessions.values.contains { $0.status.isLive }
    }

    private func watch(_ path: String, session id: String) {
        guard watchers[id] == nil, watchers.count < 64, AntigravityActivityEvent.isTranscript(path, session: id) else { return }
        let watcher = LogStreamWatcher(observesDirectory: false, discoverActiveFile: { (path, Date(), id) },
            onLine: { [weak self] line, _ in self?.consumeTranscript(line, path: path) })
        watchers[id] = watcher; watcher.start()
    }
    func consumeTranscript(_ line: String, path: String) {
        let id = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        guard AntigravityActivityEvent.isTranscript(path, session: id),
              let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, retain(id) else { return }
        var session = sessions[id] ?? Session()
        guard !session.nativeLifecycle || !session.finished else { return }
        let surface: AgentEnvironment = path.contains("/antigravity-cli/") ? .cli : path.contains("/antigravity-ide/") ? .ide : .dedicatedWindow
        if type == "USER_INPUT" {
            session.finished = false
            if !session.nativeLifecycle { session.model = "" }
            sessions[id] = session
            publish(id, status: session.nativeLifecycle ? session.status : .observed,
                    text: session.nativeLifecycle && session.status == .working ? "Thinking…" : "",
                    model: json["modelName"] as? String, surface: surface)
        } else if !session.finished {
            let status: AgentStatus = session.status == .waitingApproval ? .waitingApproval : session.nativeLifecycle ? .working : .observed
            if type == "ERROR_MESSAGE" {
                publish(id, status: .error, text: json["content"] as? String, model: nil, surface: surface)
            } else if session.waitingText == nil, let activity = AntigravityActivityEvent.transcriptText(json) {
                publish(id, status: status, text: activity, model: nil, surface: surface)
            }
        }
    }
}
