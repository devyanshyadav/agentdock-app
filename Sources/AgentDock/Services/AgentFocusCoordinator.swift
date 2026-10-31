import AppKit
import Foundation

/// Unified coordinator for focusing active agent windows, IDEs, and terminal sessions on macOS.
/// Manages window layering without obscuring active panels, and supports all major terminal emulators.
@MainActor
public final class AgentFocusCoordinator {
    public static let shared = AgentFocusCoordinator()

    /// Known bundle IDs for popular terminal emulators on macOS
    public let terminalBundleIds = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm"
    ]

    private init() {}

    /// Activates whichever agent adapter is currently active
    public func focusActiveAgent() {
        // Fallback to active agent in AgentStateManager
        let kind = AgentStateManager.shared.activeAgent
        if let adapter = AgentAdapterRegistry.shared.adapter(for: kind) {
            adapter.focus()
            return
        }

        // Generic fallback to terminal
        focusTerminal()
    }

    /// Focuses the user's terminal window for CLI agent workflows
    public func focusTerminal() {
        for bundleId in terminalBundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                activateApp(app, bundleId: bundleId)
                return
            }
        }

        if let app = NSWorkspace.shared.runningApplications.first(where: {
            let name = $0.localizedName?.lowercased() ?? ""
            return name.contains("terminal") || name.contains("iterm") || name.contains("ghostty") ||
                   name.contains("warp") || name.contains("kitty") || name.contains("alacritty")
        }) {
            activateApp(app, bundleId: app.bundleIdentifier ?? "com.apple.Terminal")
            return
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
    }

    /// Activates an application by bundle identifier, preserving window order
    public func activateApp(bundleId: String, fallbackPath: String? = nil) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if let app = apps.first {
            activateApp(app, bundleId: bundleId)
            return
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        } else if let fallbackPath, FileManager.default.fileExists(atPath: fallbackPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: fallbackPath))
        }
    }

    private func activateApp(_ app: NSRunningApplication, bundleId: String) {
        if app.isTerminated { return }

        if app.isHidden {
            app.unhide()
        }

        // Activate without .activateAllWindows to preserve frontmost window ordering
        let success = app.activate(options: [.activateIgnoringOtherApps])
        if !success {
            let script = "tell application id \"\(bundleId)\" to activate"
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }
    }
}
