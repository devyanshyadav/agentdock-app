import AppKit

/// Plays deduplicated session lifecycle cues independently of notch presentation.
@MainActor
public final class AgentSoundService {
    public static let shared = AgentSoundService()

    public enum SoundEvent: Sendable {
        case start, question, stop

        fileprivate var resource: String {
            switch self {
            case .start: return "AgentStart"
            case .question: return "AgentQuestion"
            case .stop: return "AgentStop"
            }
        }

        fileprivate var fallback: String {
            switch self {
            case .start: return "Tink"
            case .question: return "Ping"
            case .stop: return "Sosumi"
            }
        }

        fileprivate var minimumInterval: TimeInterval {
            switch self {
            case .start: return 1.2
            case .question: return 2
            case .stop: return 1
            }
        }
    }

    private var sounds: [SoundEvent: NSSound] = [:]
    private var lastPlayed: [SoundEvent: TimeInterval] = [:]
    private init() {}

    /// Classify a visible status transition for lifecycle cues.
    nonisolated static func event(from previous: AgentStatus?, to current: AgentStatus) -> SoundEvent? {
        switch current {
        case .waitingApproval:
            return previous != .waitingApproval ? .question : nil
        case .working:
            switch previous {
            case nil, .idle, .completed, .error:
                return .start
            case .working, .waitingApproval, .observed:
                return nil
            }
        case .idle, .completed, .error:
            return previous?.isLive == true ? .stop : nil
        case .observed:
            return nil
        }
    }

    public func play(_ event: SoundEvent) {
        let preferences = AppPreferences.shared
        guard preferences.soundEffectsEnabled else { return }
        switch event {
        case .start: guard preferences.soundOnStart else { return }
        case .question: guard preferences.soundOnQuestion else { return }
        case .stop: guard preferences.soundOnStop else { return }
        }

        // Coalesce bursts across sessions, using a clock unaffected by wall-clock changes.
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastPlayed[event], now - last < event.minimumInterval { return }
        if playSound(event) { lastPlayed[event] = now }
    }

    /// Settings previews ignore event throttling.
    public func previewSound(_ event: SoundEvent) {
        _ = playSound(event)
    }

    private func playSound(_ event: SoundEvent) -> Bool {
        if sounds[event] == nil {
            let custom = Bundle.main.url(forResource: event.resource, withExtension: "wav", subdirectory: "Sounds")
                .flatMap { NSSound(contentsOf: $0, byReference: true) }
            sounds[event] = custom ?? NSSound(named: NSSound.Name(event.fallback))
        }
        guard let sound = sounds[event] else { return false }
        if sound.isPlaying { return true }
        return sound.play()
    }
}
