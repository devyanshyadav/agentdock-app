import AppKit
import SwiftUI

/// A single reusable control window; closing it leaves the menu bar companion running.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()
    let model = ControlCenterModel()
    private var onboardingWindow: NSPanel?

    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { nil }

    func show(page: ControlCenterModel.Page? = nil) {
        guard UserDefaults.standard.bool(forKey: AppPreferences.onboardingCompletedKey) else {
            showOnboarding()
            return
        }
        // Opening an existing window preserves navigation; explicit destinations still switch tabs.
        if let page { model.page = page }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "AgentDock"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: 760, height: 540)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            let host = NSHostingController(rootView: ControlCenterView(model: model))
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: 880, height: 640))
            window.center()
            window.setFrameAutosaveName("AgentDock.ControlCenter")
            let restored = window.contentRect(forFrameRect: window.frame).size
            if restored.width < 760 || restored.height < 540 {
                window.setContentSize(NSSize(width: max(760, restored.width), height: max(540, restored.height)))
            }
            self.window = window
        }
        model.refresh()
        NSApp.setActivationPolicy(.regular)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startOnboarding() {
        UserDefaults.standard.set(false, forKey: AppPreferences.onboardingCompletedKey)
        window?.close()
        window = nil
        showOnboarding()
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.title = "Welcome to AgentDock"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.tabbingMode = .disallowed
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.fullScreenNone]
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            let host = NSHostingController(rootView: OnboardingView(model: model) { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: AppPreferences.onboardingCompletedKey)
                onboardingWindow?.close()
                onboardingWindow = nil
                show(page: .overview)
            })
            host.sizingOptions = []
            panel.contentViewController = host
            panel.setContentSize(NSSize(width: 800, height: 600))
            panel.center()
            onboardingWindow = panel
        }
        NSApp.setActivationPolicy(.regular)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
