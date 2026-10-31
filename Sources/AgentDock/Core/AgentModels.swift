import Foundation
import SwiftUI

// MARK: - Supported Agents
public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cursor = "cursor"
    case claude = "claude"
    case antigravity = "antigravity"
    case codex = "codex"
    case opencode = "opencode"
    case grok = "grok"
    case generic = "generic"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cursor: return "Cursor"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .grok: return "Grok Build"
        case .generic: return "AI Agent"
        }
    }

    public var themeColor: Color {
        switch self {
        case .cursor: return Color(red: 0.12, green: 0.73, blue: 0.98) // Cyan / Blue
        case .claude: return Color(red: 0.85, green: 0.44, blue: 0.28) // Terracotta / Coral
        case .antigravity: return Color(red: 0.45, green: 0.42, blue: 0.98) // Indigo / Violet
        case .codex: return Color(red: 0.13, green: 0.77, blue: 0.55) // Emerald
        case .opencode: return Color(white: 0.85)
        case .grok: return Color(red: 0.95, green: 0.25, blue: 0.45) // Ruby
        case .generic: return Color(red: 0.60, green: 0.45, blue: 0.95) // Purple
        }
    }

    public var symbolIcon: String {
        switch self {
        case .cursor: return "cursorarrow.rays"
        case .claude: return "sparkles"
        case .antigravity: return "waveform.path.ecg"
        case .codex: return "terminal"
        case .opencode: return "terminal"
        case .grok: return "bolt.fill"
        case .generic: return "cpu"
        }
    }
}

// MARK: - Agent Status
public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case idle = "idle"
    case observed = "observed" // A point-in-time event, not evidence of a running or finished turn.
    case working = "working"
    case waitingApproval = "waiting_approval"
    case completed = "completed"
    case error = "error"

    public var isLive: Bool {
        self == .working || self == .waitingApproval
    }

}

// MARK: - Activity classification for local status input
public enum ToolActionKind: String, Codable, CaseIterable {
    case analyzing = "analyzing"
    case thinking = "thinking"
    case searching = "search"
    case reading = "read"
    case editing = "file_change"
    case command = "command"
    case general = "other"

}
