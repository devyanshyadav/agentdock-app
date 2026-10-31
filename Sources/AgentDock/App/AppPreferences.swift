import AppKit
import Combine

/// Shared preferences are the single source of truth for the menu, window and overlays.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    nonisolated static let onboardingCompletedKey = "AgentDock_OnboardingCompleted"
    nonisolated static let displayKey = "AgentDock_NotchDisplay"
    nonisolated static let bottomTextKey = "AgentDock_NotchBottomText"
    nonisolated static let compactnessKey = "AgentDock_NotchCompactness"
    nonisolated static let notchStyleKey = "AgentDock_NotchStyle"
    nonisolated static let marqueeSpeedKey = "AgentDock_MarqueeSpeed"
    nonisolated static let soundEffectsKey = "AgentDock_SoundEffectsEnabled"
    nonisolated static let soundOnStartKey = "AgentDock_SoundOnStart"
    nonisolated static let soundOnStopKey = "AgentDock_SoundOnStop"
    nonisolated static let soundOnQuestionKey = "AgentDock_SoundOnQuestion"

    @Published var notchEnabled: Bool {
        didSet { defaults.set(notchEnabled, forKey: "AgentDock_NotchEnabled") }
    }
    @Published var displayID: String {
        didSet { defaults.set(displayID, forKey: Self.displayKey) }
    }
    @Published var showsBottomText: Bool {
        didSet { defaults.set(showsBottomText, forKey: Self.bottomTextKey) }
    }
    @Published var notchCompactness: Double {
        didSet { defaults.set(notchCompactness, forKey: Self.compactnessKey) }
    }
    @Published var notchStyle: NotchStyle {
        didSet { defaults.set(notchStyle.rawValue, forKey: Self.notchStyleKey) }
    }
    @Published var marqueeSpeed: Double {
        didSet { defaults.set(marqueeSpeed, forKey: Self.marqueeSpeedKey) }
    }
    @Published var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: Self.soundEffectsKey) }
    }
    @Published var soundOnStart: Bool {
        didSet { defaults.set(soundOnStart, forKey: Self.soundOnStartKey) }
    }
    @Published var soundOnStop: Bool {
        didSet { defaults.set(soundOnStop, forKey: Self.soundOnStopKey) }
    }
    @Published var soundOnQuestion: Bool {
        didSet { defaults.set(soundOnQuestion, forKey: Self.soundOnQuestionKey) }
    }
    @Published var completionDuration: Double {
        didSet { defaults.set(completionDuration, forKey: "AgentDock_CompletionDuration") }
    }
    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "AgentDock_Appearance"); applyAppearance() }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: String { rawValue }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notchEnabled = defaults.object(forKey: "AgentDock_NotchEnabled") as? Bool ?? true
        displayID = defaults.string(forKey: Self.displayKey) ?? ""
        showsBottomText = defaults.object(forKey: Self.bottomTextKey) as? Bool ?? true
        notchStyle = NotchStyle(rawValue: defaults.string(forKey: Self.notchStyleKey) ?? "") ?? .stepped
        let speed = defaults.object(forKey: Self.marqueeSpeedKey) as? Double ?? 1
        marqueeSpeed = speed.isFinite ? min(2, max(0.5, speed)) : 1
        soundEffectsEnabled = defaults.object(forKey: Self.soundEffectsKey) as? Bool ?? true
        soundOnStart = defaults.object(forKey: Self.soundOnStartKey) as? Bool ?? true
        soundOnStop = defaults.object(forKey: Self.soundOnStopKey) as? Bool ?? true
        soundOnQuestion = defaults.object(forKey: Self.soundOnQuestionKey) as? Bool ?? true
        let compactness = defaults.object(forKey: Self.compactnessKey) as? Double ?? 0
        notchCompactness = compactness.isFinite ? min(1, max(0, compactness)) : 0
        let duration = defaults.object(forKey: "AgentDock_CompletionDuration") as? Double ?? 3
        completionDuration = duration.isFinite ? min(10, max(0, duration)) : 3
        appearance = Appearance(rawValue: defaults.string(forKey: "AgentDock_Appearance") ?? "") ?? .system
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
