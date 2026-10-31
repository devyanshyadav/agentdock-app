import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = AgentRuntime()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory app (seamless status bar & floating notch HUD, no dock clutter)
        NSApplication.shared.setActivationPolicy(.accessory)

        AppPreferences.shared.applyAppearance()
        runtime.start()

        // Setup MenuBar icon
        MenuBarController.shared.setup()

        if let iconURL = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }

        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if CommandLine.arguments.contains("--show-window") || !launchedAtLogin {
            MainWindowController.shared.show()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Initial presentation is handled once above, including background login launches.
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
