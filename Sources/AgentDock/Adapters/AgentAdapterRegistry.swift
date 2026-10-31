import Foundation

/// Central registry managing lifecycle, discovery, and routing for all AI Coding Agent adapters.
@MainActor
public final class AgentAdapterRegistry {
    public static let shared = AgentAdapterRegistry()

    private var registeredAdapters: [AgentKind: AgentAdapter] = [:]

    public var allAdapters: [AgentAdapter] {
        Array(registeredAdapters.values)
    }

    private init() {
        register(CursorAgentAdapter.shared)
        register(AntigravityAgentAdapter.shared)
        register(ClaudeCodeAdapter.shared)
        register(CodexAgentAdapter.shared)
        register(OpenCodeAgentAdapter.shared)
    }

    /// Registers a new adapter into the system
    public func register(_ adapter: AgentAdapter) {
        registeredAdapters[adapter.kind] = adapter
    }

    /// Retrieves an adapter by its kind
    public func adapter(for kind: AgentKind) -> AgentAdapter? {
        registeredAdapters[kind]
    }

    /// Starts all registered agent adapters
    public func startAll() {
        for adapter in allAdapters {
            adapter.start()
        }
    }

    /// Stops all registered agent adapters
    public func stopAll() {
        for adapter in allAdapters {
            adapter.stop()
        }
    }
}
