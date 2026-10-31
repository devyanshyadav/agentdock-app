/// Owns the activity services for the lifetime of the app.
@MainActor
final class AgentRuntime {
    private var running = false
    private let startServices: () -> Void
    private let stopServices: () -> Void

    init(start: @escaping () -> Void, stop: @escaping () -> Void) {
        startServices = start
        stopServices = stop
    }

    convenience init() {
        self.init(start: {
            ProviderIntegration.refreshEnabledObservers()
            LocalServerBridge.shared.start(port: 49152)
            AgentAdapterRegistry.shared.startAll()
            NotchWindowController.shared.setupAndShow()
        }, stop: {
            AgentAdapterRegistry.shared.stopAll()
            LocalServerBridge.shared.stop()
            AgentStateManager.shared.reset()
            NotchWindowController.shared.stop()
        })
    }

    func start() {
        guard !running else { return }
        running = true
        startServices()
    }

    func stop() {
        guard running else { return }
        running = false
        stopServices()
    }
}
