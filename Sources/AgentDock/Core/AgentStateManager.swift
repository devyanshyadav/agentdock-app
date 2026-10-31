import Foundation
import Combine
import AppKit

/// Native lifecycle controls visibility; retained text alone never opens the notch.
@MainActor
public final class AgentStateManager: ObservableObject {
    public static let shared = AgentStateManager()
    @Published public private(set) var status: AgentStatus = .idle
    @Published public private(set) var activeAgent: AgentKind = .cursor
    public private(set) var environment: AgentEnvironment?
    @Published public var modelName = ""
    @Published public var message = ""
    @Published public var localBridgePort = 49152
    @Published public var isLocalBridgeListening = false
    public var currentAction: ToolActionKind { .general }
    public var detail: String? { nil }

    private struct Observation {
        var agent: AgentKind
        var status: AgentStatus = .idle
        var environment: AgentEnvironment?
        var model = ""
        var text = ""
        var updatedAt = Date()
        var visibleUntil: Date?
        var closed = false
        var startedAt = Date()
        /// Last time the provider told us anything about this session.
        var lastEventAt = Date()
        /// Agent process (CLI sessions only). Lets us notice a killed or crashed agent
        /// that could not send a final event.
        var ownerPID: Int32?
        /// For providers that emit nothing on cancel: how long a working session may stay
        /// silent before it is hidden. Any later event revives it.
        var quietLimit: TimeInterval?
    }
    /// Desktop apps that host agent sessions, and the surface each one represents.
    private static let ownerApps: [String: (agent: AgentKind, environment: AgentEnvironment)] = [
        "com.todesktop.230313mzl4w4u92": (.cursor, .ide),
        "com.google.antigravity-ide": (.antigravity, .ide),
        "com.google.antigravity": (.antigravity, .dedicatedWindow),
        "com.anthropic.claudefordesktop": (.claude, .dedicatedWindow),
        "com.openai.codex": (.codex, .dedicatedWindow),
        "com.openai.chat": (.codex, .dedicatedWindow),
        "ai.opencode.desktop": (.opencode, .dedicatedWindow)
    ]
    private static let learnedAssertionKey = "AgentDock_AssertionApps"
    /// How long an app must be seen without its assertion before its working sessions end. Covers the
    /// moment between a submit hook and the app taking its assertion, and brief hand-offs.
    private static let assertionGrace: TimeInterval = 6
    private static let assertionInterval: UInt64 = 3_000_000_000
    private static let maxSilenceUnowned: TimeInterval = 15 * 60
    private static let maxSilenceOwned: TimeInterval = 2 * 60 * 60
    private var lastModelByAgent: [AgentKind: String] = [:]
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var assertionTask: Task<Void, Never>?
    private var assertionAbsentSince: [String: Date] = [:]
    /// Apps seen holding an assertion while one of their sessions was working. Absence only counts as
    /// evidence for these, so an app that never holds one can never have a live turn ended wrongly.
    private var assertionApps = Set(UserDefaults.standard.stringArray(forKey: AgentStateManager.learnedAssertionKey) ?? [])
    private var silenceTask: Task<Void, Never>?
    private var silenceDeadline: Date?
    private var sessions: [String: Observation] = [:]
    @Published public private(set) var isIndicatorVisible = false
    private var dismissTask: Task<Void, Never>?
    private var dismissDeadline: Date?
    private var selectedID = AgentKind.cursor.rawValue
    private var terminationObserver: AnyCancellable?
    private init() {
        for kind in AgentKind.allCases {
            let model = UserDefaults.standard.string(forKey: "AgentDock_LastModel_" + kind.rawValue)
            if let model, !model.isEmpty {
                lastModelByAgent[kind] = model
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                guard let owner = Self.ownerApps[app.bundleIdentifier ?? ""] else { return }
                self?.endSessions(agent: owner.agent, environment: owner.environment)
            }
    }

    public func beginAgentEvent(agent: AgentKind, sessionID: String? = nil) {
        let key = sessionID.map { agent.rawValue + ":" + $0 } ?? (activeAgent == agent ? selectedID : agent.rawValue)
        guard key != selectedID else { return }
        save()
        selectedID = key
        apply(sessions[key] ?? Observation(agent: agent))
    }

    public func update(agent: AgentKind, status: AgentStatus, message: String, model: String? = nil,
                       sessionID: String? = nil, environment: AgentEnvironment? = nil, startsTurn: Bool = false,
                       ownerPID: Int32? = nil, quietLimit: TimeInterval? = nil) {
        let key = sessionID.map { agent.rawValue + ":" + $0 } ?? (activeAgent == agent ? selectedID : agent.rawValue)
        // Progress is not a new turn. Cancellation, idle, and completion remain closed
        // until the adapter reports a native start, even if delayed tool events arrive.
        if status.isLive && sessions[key]?.closed == true && !startsTurn {
            selectVisible(); refreshVisibility()
            return
        }
        let visibleBefore = self.status
        let sessionBefore = sessions[key]?.status
        beginAgentEvent(agent: agent, sessionID: sessionID)
        let previous = sessions[selectedID]
        if activeAgent != agent { activeAgent = agent }
        if self.status != status { self.status = status }
        if self.message != message { self.message = message }
        if let model, !model.isEmpty { noteModel(model, for: agent) }
        let resolvedModel = Self.firstNonEmpty([{ model }, { self.modelName }, { self.lastModelByAgent[agent] }, { AgentModelDefaults.current(for: agent) }])
        if modelName != resolvedModel { modelName = resolvedModel }
        if let environment { self.environment = environment }
        save()
        sessions[selectedID]?.updatedAt = Date()
        sessions[selectedID]?.lastEventAt = Date()
        if let ownerPID { sessions[selectedID]?.ownerPID = ownerPID }
        if let quietLimit { sessions[selectedID]?.quietLimit = quietLimit }
        if startsTurn || status.isLive && previous?.status.isLive != true { sessions[selectedID]?.startedAt = Date() }
        if status.isLive { sessions[selectedID]?.closed = false }
        else if status == .idle || status == .completed || status == .error { sessions[selectedID]?.closed = true }
        if status.isLive {
            sessions[selectedID]?.visibleUntil = nil
        } else if status == .completed || status == .error {
            // Only a real live-to-terminal transition earns a brief result display.
            // Duplicate stops and late metadata cannot extend or recreate it.
            if previous?.status.isLive == true {
                sessions[selectedID]?.visibleUntil = Date().addingTimeInterval(AppPreferences.shared.completionDuration)
            } else if previous?.status != status {
                sessions[selectedID]?.visibleUntil = nil
            }
        } else {
            sessions[selectedID]?.visibleUntil = nil
        }
        selectVisible()
        refreshVisibility()
        ensureLiveness()
        playLifecycleSound(visibleBefore: visibleBefore, sessionBefore: sessionBefore, incoming: status, updatedKey: key)
        if sessions.count > 100, let oldest = sessions.filter({ $0.key != selectedID && !$0.value.status.isLive })
            .min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key { sessions[oldest] = nil }
    }

    private func refreshVisibility() {
        let deadline = sessions[selectedID]?.visibleUntil
        let showsResult = (deadline ?? .distantPast) > Date()
            && (status == .error || status == .completed && !message.isEmpty)
        let visible = status.isLive || showsResult
        if isIndicatorVisible != visible { isIndicatorVisible = visible }

        let nextDeadline = showsResult && !status.isLive ? deadline : nil
        guard dismissDeadline != nextDeadline else { return }
        dismissTask?.cancel()
        dismissTask = nil
        dismissDeadline = nextDeadline
        guard let deadline = nextDeadline else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.dismissTask = nil
            self.dismissDeadline = nil
            self.selectVisible()
            self.refreshVisibility()
        }
    }

    private func save() {
        let previous = sessions[selectedID]
        sessions[selectedID] = Observation(agent: activeAgent, status: status, environment: environment,
            model: modelName, text: message, updatedAt: previous?.updatedAt ?? Date(),
            visibleUntil: previous?.visibleUntil, closed: previous?.closed ?? false,
            startedAt: previous?.startedAt ?? Date(), lastEventAt: previous?.lastEventAt ?? Date(),
            ownerPID: previous?.ownerPID, quietLimit: previous?.quietLimit)
    }

    /// Candidates are evaluated lazily, so configuration files are read only when nothing else is known.
    private static func firstNonEmpty(_ values: [() -> String?]) -> String {
        for value in values { if let text = value(), !text.isEmpty { return text } }
        return ""
    }

    /// Remember the latest model an agent reported so new sessions never show a blank badge.
    public func noteModel(_ model: String, for agent: AgentKind) {
        guard !model.isEmpty, lastModelByAgent[agent] != model else { return }
        lastModelByAgent[agent] = model
        UserDefaults.standard.set(model, forKey: "AgentDock_LastModel_" + agent.rawValue)
        if activeAgent == agent, modelName.isEmpty || sessions[selectedID]?.model.isEmpty == true { modelName = model }
    }
    private func apply(_ observation: Observation) {
        if activeAgent != observation.agent { activeAgent = observation.agent }
        if status != observation.status { status = observation.status }
        environment = observation.environment
        let model = observation.model.isEmpty ? (lastModelByAgent[observation.agent] ?? "") : observation.model
        if modelName != model { modelName = model }
        if message != observation.text { message = observation.text }
    }
    private func selectVisible() {
        // Approval cannot be hidden by background updates from another session.
        let now = Date()
        var selected: (key: String, value: Observation)?
        var selectedPriority = 0
        for (key, observation) in sessions {
            let priority = observation.status == .waitingApproval ? 3
                : observation.status.isLive ? 2
                : (observation.visibleUntil ?? .distantPast) > now ? 1 : 0
            guard priority > 0 else { continue }
            if priority > selectedPriority || priority == selectedPriority
                && observation.updatedAt > (selected?.value.updatedAt ?? .distantPast) {
                selected = (key, observation)
                selectedPriority = priority
            }
        }
        if let selected {
            selectedID = selected.key; apply(selected.value)
        }
    }
    /// Ends one session when its provider reports a cancellation that carries no stop event.
    public func endSession(agent: AgentKind, sessionID: String) {
        let key = agent.rawValue + ":" + sessionID
        guard sessions[key]?.status.isLive == true else { return }
        end(keys: [key])
    }

    /// Clear stuck indicators while keeping closed sessions protected from late progress.
    public func resetActivity() {
        end(keys: Array(sessions.keys))
    }

    private func endSessions(agent: AgentKind, environment: AgentEnvironment) {
        end(keys: sessions.keys.filter { sessions[$0]?.agent == agent && sessions[$0]?.environment == environment })
    }

    private func end(keys: [String], close: Bool = true) {
        let visibleBefore = status
        for key in keys {
            let agent = sessions[key]?.agent
            // A silent-but-possibly-alive session stays revivable by its next event.
            sessions[key]?.status = .idle; sessions[key]?.closed = close
            sessions[key]?.text = ""; sessions[key]?.visibleUntil = nil
            if let agent, let colon = key.firstIndex(of: ":") {
                let sessionID = String(key[key.index(after: colon)...])
                AgentAdapterRegistry.shared.adapter(for: agent)?.sessionDidEnd(sessionID, close: close)
            }
        }
        if let current = sessions[selectedID] { apply(current) }
        selectVisible(); refreshVisibility()
        ensureLiveness()
        if close { playVisibleSoundTransition(from: visibleBefore) }
    }

    private func playVisibleSoundTransition(from before: AgentStatus) {
        guard let event = AgentSoundService.event(from: before, to: status) else { return }
        AgentSoundService.shared.play(event)
    }

    /// Prefer visible notch transitions; fall back to the updated session when the HUD stays on another row.
    private func playLifecycleSound(visibleBefore: AgentStatus, sessionBefore: AgentStatus?, incoming: AgentStatus, updatedKey: String) {
        if visibleBefore != status {
            if let event = AgentSoundService.event(from: visibleBefore, to: status) {
                AgentSoundService.shared.play(event)
            }
            return
        }
        guard updatedKey == selectedID else { return }
        guard let event = AgentSoundService.event(from: sessionBefore, to: incoming) else { return }
        AgentSoundService.shared.play(event)
    }

    // MARK: Liveness

    /// Event-driven, with no polling. Native stop events remain authoritative, but some providers
    /// omit them (Claude Code does not fire Stop on interrupt) and a killed CLI cannot report
    /// anything. Owner processes are observed through kernel exit notifications, and silence
    /// expiry uses a single timer aimed at the earliest possible deadline.
    private func ensureLiveness() {
        let pids = Set(sessions.values.compactMap { $0.status.isLive ? $0.ownerPID : nil })
        for pid in Array(exitSources.keys) where !pids.contains(pid) { exitSources.removeValue(forKey: pid)?.cancel() }
        for pid in pids where exitSources[pid] == nil { watchExit(of: pid) }
        scheduleSilenceCheck()
        scheduleAssertionCheck()
    }

    // MARK: Power-assertion reconciliation

    private func ownerBundles(of observation: Observation) -> [String] {
        Self.ownerApps.filter { $0.value.agent == observation.agent && $0.value.environment == observation.environment }.map(\.key)
    }

    /// Runs only while a desktop-app session is working, so an idle notch costs nothing.
    private func scheduleAssertionCheck() {
        guard sessions.values.contains(where: { $0.status == .working && !ownerBundles(of: $0).isEmpty }) else {
            assertionTask?.cancel(); assertionTask = nil; assertionAbsentSince.removeAll()
            return
        }
        guard assertionTask == nil else { return }
        assertionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.assertionInterval)
                let holders = await Task.detached(priority: .utility) { PowerAssertionProbe.holdingBundleIdentifiers() }.value
                guard !Task.isCancelled, let self else { return }
                self.reconcileAssertions(holders)
            }
        }
    }

    private func reconcileAssertions(_ holders: Set<String>) {
        let now = Date()
        var apps = Set<String>()
        for observation in sessions.values where observation.status == .working { apps.formUnion(ownerBundles(of: observation)) }
        assertionAbsentSince = assertionAbsentSince.filter { apps.contains($0.key) }
        var finished: [String] = []
        for app in apps {
            if holders.contains(app) {
                assertionAbsentSince[app] = nil
                if assertionApps.insert(app).inserted {
                    UserDefaults.standard.set(Array(assertionApps), forKey: Self.learnedAssertionKey)
                }
            } else if assertionApps.contains(app) {
                let since = assertionAbsentSince[app] ?? now
                assertionAbsentSince[app] = since
                if now.timeIntervalSince(since) >= Self.assertionGrace { finished.append(app) }
            }
        }
        guard !finished.isEmpty else { return }
        for app in finished { assertionAbsentSince[app] = nil }
        // The turn is over as far as the app is concerned; a later event can still revive the session.
        end(keys: sessions.filter { entry in
            entry.value.status == .working && finished.contains { ownerBundles(of: entry.value).contains($0) }
        }.map(\.key), close: false)
    }

    private func watchExit(of pid: Int32) {
        guard Self.isAlive(pid) else {
            DispatchQueue.main.async { [weak self] in self?.ownerExited(pid) }
            return
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.ownerExited(pid) } }
        source.resume()
        exitSources[pid] = source
    }

    private func ownerExited(_ pid: Int32) {
        exitSources.removeValue(forKey: pid)?.cancel()
        let dead = sessions.filter { $0.value.ownerPID == pid && $0.value.status.isLive }.map(\.key)
        if !dead.isEmpty { end(keys: dead, close: true) }
    }

    /// Only working sessions expire by silence: a pending approval produces no events while the
    /// user decides, so only a dead owner process can end it.
    private func silenceLimit(_ observation: Observation) -> TimeInterval {
        observation.quietLimit ?? (observation.ownerPID == nil ? Self.maxSilenceUnowned : Self.maxSilenceOwned)
    }

    private func scheduleSilenceCheck() {
        let next = sessions.values.filter { $0.status == .working }
            .map { $0.lastEventAt.addingTimeInterval(silenceLimit($0)) }.min()
        guard let next else {
            silenceTask?.cancel(); silenceTask = nil; silenceDeadline = nil
            return
        }
        // Events only push deadlines later, so an earlier pending timer just re-checks when it fires.
        if silenceTask != nil, let current = silenceDeadline, current <= next { return }
        silenceTask?.cancel()
        silenceDeadline = next
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, next.timeIntervalSinceNow) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.silenceTask = nil; self.silenceDeadline = nil
            self.expireSilentSessions()
        }
    }

    private func expireSilentSessions() {
        let now = Date()
        let stale = sessions.filter {
            $0.value.status == .working && now.timeIntervalSince($0.value.lastEventAt) >= silenceLimit($0.value)
        }.map(\.key)
        // Silent but possibly alive: a later event revives the session.
        if stale.isEmpty { scheduleSilenceCheck() } else { end(keys: stale, close: false) }
    }

    nonisolated private static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func removeSession(agent: AgentKind, sessionID: String) {
        let key = agent.rawValue + ":" + sessionID
        sessions[key] = nil
        if selectedID == key {
            selectedID = agent.rawValue; apply(Observation(agent: agent)); selectVisible(); refreshVisibility()
        }
    }
    public func removeSessions(prefix: String) {
        let removed = sessions.keys.filter { key in
            let parts = key.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[1].hasPrefix(prefix)
        }
        for key in removed { sessions[key] = nil }
        if removed.contains(selectedID) {
            selectedID = AgentKind.cursor.rawValue; apply(Observation(agent: .cursor)); selectVisible(); refreshVisibility()
        }
    }
    public func reset() {
        dismissTask?.cancel(); dismissTask = nil; dismissDeadline = nil
        silenceTask?.cancel(); silenceTask = nil; silenceDeadline = nil
        assertionTask?.cancel(); assertionTask = nil; assertionAbsentSince.removeAll()
        exitSources.values.forEach { $0.cancel() }; exitSources.removeAll()
        if isIndicatorVisible { isIndicatorVisible = false }
        sessions.removeAll(); selectedID = AgentKind.cursor.rawValue; apply(Observation(agent: .cursor))
    }
}
