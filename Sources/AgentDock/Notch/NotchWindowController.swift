import AppKit
import SwiftUI
import Combine

@MainActor
public final class NotchWindowController: NSObject {
    public static let shared = NotchWindowController()

    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
    }

    public func setupAndShow() {
        if panel != nil { return }

        let preferences = AppPreferences.shared
        let geometry = NotchGeometry.current(displayID: preferences.displayID,
                                             showsBottomText: preferences.showsBottomText,
                                             compactness: preferences.notchCompactness, style: preferences.notchStyle)
        let initialFrame = geometry.notchWindowFrame()

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar + 1
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let hostingView = NSHostingView(rootView: NotchContainerView(geometry: geometry))
        panel.contentView = hostingView

        self.panel = panel
        panel.ignoresMouseEvents = !(AgentStateManager.shared.isIndicatorVisible && AppPreferences.shared.notchEnabled)
        panel.orderFrontRegardless()

        setupObservers()
    }

    public func stop() {
        cancellables.removeAll()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func setupObservers() {
        // Observe live status
        AgentStateManager.shared.$isIndicatorVisible
            .combineLatest(AppPreferences.shared.$notchEnabled)
            .map { $0.0 && $0.1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self, let panel = self.panel else { return }
                if visible { self.updateFrame() }
                // Pure black blend with hardware notch: no window shadow
                panel.hasShadow = false
                panel.ignoresMouseEvents = !visible
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(AppPreferences.shared.$displayID,
                                  AppPreferences.shared.$showsBottomText,
                                  AppPreferences.shared.$notchCompactness,
                                  AppPreferences.shared.$notchStyle)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateFrame(animated: false) }
            .store(in: &cancellables)

        // Refresh placement when interaction switches to an app on another display.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            // A hidden notch re-places itself when it next appears.
            .sink { [weak self] _ in if AgentStateManager.shared.isIndicatorVisible { self?.updateFrame() } }
            .store(in: &cancellables)

        // Screen configuration changes
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFrame()
            }
            .store(in: &cancellables)
    }

    public func updateFrame(animated: Bool = true) {
        guard let panel = self.panel else { return }

        let preferences = AppPreferences.shared
        let geometry = NotchGeometry.current(displayID: preferences.displayID,
                                             showsBottomText: preferences.showsBottomText,
                                             compactness: preferences.notchCompactness, style: preferences.notchStyle)
        let newFrame = geometry.notchWindowFrame()
        guard let host = panel.contentView as? NSHostingView<NotchContainerView>,
              host.rootView.geometry != geometry else { return }
        host.rootView = NotchContainerView(geometry: geometry)
        panel.invalidateShadow()
        guard animated else { panel.setFrame(newFrame, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }
}
