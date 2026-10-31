import AppKit
import Combine
import ServiceManagement

@MainActor
final class ControlCenterModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case overview = "Home", providers = "Your agents", usage = "Usage", settings = "Settings", license = "License", about = "About"
        var id: Self { self }
        var icon: AppIcon.Source {
            switch self {
            case .overview: return .custom(.home)
            case .providers: return .custom(.processor)
            case .usage: return .custom(.activity)
            case .settings: return .system("gearshape")
            case .license: return .custom(.openSource)
            case .about: return .system("info.circle")
            }
        }
    }
    struct ProviderReport: Identifiable, Equatable {
        let integration: ProviderIntegration
        let detected: Bool
        let installation: ProviderIntegration.Installation
        var id: AgentKind { integration.kind }
    }

    struct Display: Identifiable, Equatable {
        let id: String
        let name: String
    }
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var offersReconnect = false
    }

    struct Activity: Equatable {
        let activeAgent: AgentKind
        let status: AgentStatus
        let isLocalBridgeListening: Bool
    }
    @Published private(set) var activity = Activity(activeAgent: .cursor, status: .idle, isLocalBridgeListening: false)
    private var activitySubscription: AnyCancellable?

    init() {
        let state = AgentStateManager.shared
        activitySubscription = Publishers.CombineLatest3(state.$activeAgent, state.$status, state.$isLocalBridgeListening)
            .map { Activity(activeAgent: $0.0, status: $0.1, isLocalBridgeListening: $0.2) }
            .removeDuplicates()
            .sink { [weak self] in self?.activity = $0 }
    }

    @Published var targetedProviderId: String? = nil
    @Published private(set) var activeSetupProvider: AgentKind?
    @Published var page: Page? = .overview
    @Published private(set) var providers: [ProviderReport] = []
    @Published private(set) var displays: [Display] = []
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var installing: AgentKind?
    @Published private(set) var isInstallingClaudeCLI = false
    @Published private(set) var setupProgress: String?
    @Published private(set) var setupMessage: String?
    @Published private(set) var setupErrors: [AgentKind: String] = [:]
    @Published private(set) var completedSetupProviders: Set<AgentKind> = []
    @Published private(set) var updatingLogin = false
    @Published private(set) var diagnosticsCopied = false
    @Published var notice: Notice?

    var launchAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }
    var isSettingUp: Bool { setupProgress != nil }
    var providerActionInProgress: Bool { isSettingUp || installing != nil || isInstallingClaudeCLI }

    var connectionSummary: String {
        Self.connectionSummary(for: providers, errors: setupErrors)
    }

    static func connectionSummary(for reports: [ProviderReport], errors: [AgentKind: String] = [:]) -> String {
        var detected = 0, connected = 0, failed = 0, notConnected = 0, notInstalled = 0
        for report in reports {
            guard report.detected else { notInstalled += 1; continue }
            detected += 1
            if errors[report.id] != nil { failed += 1 }
            else if report.installation == .configured { connected += 1 }
            else { notConnected += 1 }
        }
        var parts = [detected == 1 ? "1 agent detected" : "\(detected) agents detected"]
        if connected > 0 { parts.append("\(connected) connected") }
        if failed > 0 { parts.append("\(failed) failed") }
        if notConnected > 0 { parts.append("\(notConnected) not connected") }
        if notInstalled > 0 { parts.append("\(notInstalled) not installed") }
        return parts.joined(separator: " · ")
    }

    /// User/window activation driven snapshot; never launches an agent or polls authentication.
    func refresh() {
        refreshProviders()
        let screens = NSScreen.screens.compactMap { screen -> Display? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: id.stringValue, name: screen.localizedName)
        }
        if displays != screens { displays = screens }
        let status = SMAppService.mainApp.status
        if loginStatus != status { loginStatus = status }
    }

    private func refreshProviders() {
        let reports = AgentAdapterRegistry.shared.allAdapters.sorted { $0.displayName < $1.displayName }.map { adapter in
            let integration = ProviderIntegration(kind: adapter.kind)
            return ProviderReport(integration: integration, detected: integration.isDetected(),
                                  installation: integration.installation())
        }
        if providers != reports { providers = reports }
    }

    func install(_ integration: ProviderIntegration) async {
        guard !providerActionInProgress else { return }
        installing = integration.kind
        defer { installing = nil; refreshProviders() }
        do {
            try await Task.detached(priority: .userInitiated) { try integration.install() }.value
            setupErrors[integration.kind] = nil
            notice = Notice(title: "Activity tracking set up", message: integration.instructions)
        } catch {
            setupErrors[integration.kind] = error.localizedDescription
        }
    }

    func installClaudeCLI(using install: @Sendable () async throws -> String = { try await ClaudeCLIInstaller.install() }) async {
        guard !providerActionInProgress else { return }
        isInstallingClaudeCLI = true
        defer { isInstallingClaudeCLI = false; refreshProviders() }
        do {
            let version = try await install()
            notice = Notice(title: "Claude Code installed", message: "\(version)\n\nRun claude in Terminal to sign in, then connect it in Your agents.")
        } catch {
            notice = Notice(title: "Couldn’t install Claude Code",
                message: "Check your internet connection and try again, or use Anthropic’s installation guide.")
        }
    }

    /// Finish each provider, including hook installation, before starting the next. Never sign in silently.
    func setUpDetectedProviders(presentResult: Bool = false, reconnect: Bool = false) async {
        guard !providerActionInProgress else { return }
        var offersReconnect = false
        defer {
            if presentResult, let setupMessage {
                notice = Notice(title: "Agent setup", message: setupMessage, offersReconnect: offersReconnect)
            }
        }
        refreshProviders()
        let detected = providers.filter(\.detected)
        setupMessage = nil
        setupErrors = [:]
        completedSetupProviders = []
        guard !detected.isEmpty else {
            setupMessage = "No supported agents found. Install an agent, then connect it here."
            return
        }
        setupProgress = "Preparing your agents…"
        var hasFailures = false
        var installedAny = false
        defer {
            setupProgress = nil
            activeSetupProvider = nil
            refreshProviders()
        }
        for report in detected {
            guard !Task.isCancelled else { setupMessage = "Setup stopped. You can run it again at any time."; return }
            activeSetupProvider = report.id
            setupProgress = "Connecting \(report.id.displayName)…"
            
            if reconnect || report.installation != .configured {
                do {
                    try await Task.detached(priority: .userInitiated) { try report.integration.install() }.value
                    installedAny = true
                    refreshProviders()
                } catch {
                    setupErrors[report.id] = error.localizedDescription
                    hasFailures = true
                }
            }
            
            completedSetupProviders.insert(report.id)
        }
        guard !Task.isCancelled else { setupMessage = "Setup stopped. You can run it again at any time."; return }
        if hasFailures {
            setupMessage = "Some agents need attention. Open Your agents for the next steps."
        } else if installedAny {
            setupMessage = "Agents connected. Start a new chat to apply changes."
        } else {
            setupMessage = "Agents already connected."
            offersReconnect = true
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !updatingLogin else { return }
        updatingLogin = true
        defer { updatingLogin = false; refresh() }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch {
            notice = Notice(title: "Could not change login item", message: error.localizedDescription)
        }
    }

    func diagnosticReport() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let state = AgentStateManager.shared
        var lines = ["AgentDock \(version)", ProcessInfo.processInfo.operatingSystemVersionString,
                     "Bridge: \(state.isLocalBridgeListening ? "listening" : "unavailable")",
                     "Notch: \(AppPreferences.shared.notchEnabled ? "enabled" : "disabled")"]
        lines += providers.map { "\($0.id.displayName): events \($0.installation.rawValue.lowercased())" }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        refresh()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticReport(), forType: .string)
        diagnosticsCopied = true
    }
}
