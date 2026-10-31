import Foundation
import SwiftUI

/// Represents the execution environment of an agent
public enum AgentEnvironment: String, Codable, Sendable {
    case dedicatedWindow   // Standalone dedicated agent app / window
    case ide               // Embedded inside full IDE editor
    case cli               // Terminal-based command-line agent
}

/// Unified protocol each supported coding agent implements.
@MainActor
public protocol AgentAdapter: AnyObject {
    /// The unique kind of the agent (cursor, antigravity, claude, etc.)
    var kind: AgentKind { get }

    /// Human-friendly display name of the agent
    var displayName: String { get }

    /// Current environment (dedicated window, IDE, or CLI)
    var environment: AgentEnvironment { get }

    /// Whether this agent is currently running a turn or awaiting input
    var isActive: Bool { get }

    /// Timestamp of the most recent activity or event observed
    var lastActivityDate: Date { get }

    /// Current active model name dynamically discovered for this agent
    var currentModel: String { get }

    /// Starts all watchers/listeners for this agent
    func start()

    /// Stops all watchers/listeners and cleans up resources
    func stop()

    /// Brings the agent's active surface (dedicated window, IDE, or Terminal) to the foreground
    func focus()

    /// Synchronizes adapter-owned session state when AgentStateManager ends a session
    /// (for example on power assertion drop, silence expiry, owner process exit, or manual reset).
    func sessionDidEnd(_ sessionID: String, close: Bool)
}

public extension AgentAdapter {
    func sessionDidEnd(_ sessionID: String, close: Bool) {}

    /// Route focus using the observation actually selected by the notch.
    var focusEnvironment: AgentEnvironment {
        let state = AgentStateManager.shared
        return state.activeAgent == kind ? state.environment ?? environment : environment
    }

}
