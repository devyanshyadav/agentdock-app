import AppKit

@MainActor
public final class MenuBarController: NSObject {
    public static let shared = MenuBarController()
    private var statusItem: NSStatusItem?

    public func setup() {
        guard statusItem == nil else { return }
        setupApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = Self.makeMenuBarIcon()
        let menu = NSMenu()
        menu.autoenablesItems = false
        add("Open AgentDock…", action: #selector(openWindow), key: "0", to: menu)
        add("Settings…", action: #selector(openSettings), key: ",", to: menu)
        menu.addItem(.separator())
        add("Open Current Agent", action: #selector(focusAgent), key: "f", to: menu)
        menu.addItem(.separator())
        add("Quit AgentDock", action: #selector(quitApp), key: "q", to: menu)
        statusItem?.menu = menu
    }
    /// AppKit owns the app lifecycle, so install the standard responder-chain menus here.
    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "AgentDock")
        add("About AgentDock", action: #selector(openAbout), to: appMenu)
        appMenu.addItem(.separator())
        add("Open AgentDock…", action: #selector(openWindow), key: "0", to: appMenu)
        add("Settings…", action: #selector(openSettings), key: ",", to: appMenu)
        appMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AgentDock", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add("Quit AgentDock", action: #selector(quitApp), key: "q", to: appMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        for menu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func add(_ title: String, action: Selector, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; menu.addItem(item)
    }
    @objc private func openWindow() { MainWindowController.shared.show() }
    @objc private func openAbout() { MainWindowController.shared.show(page: .about) }
    @objc private func openSettings() { MainWindowController.shared.show(page: .settings) }
    @objc private func focusAgent() {
        AgentFocusCoordinator.shared.focusActiveAgent()
    }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    private static func makeMenuBarIcon() -> NSImage {
        let bundle = Bundle.main
        // Try color mascot icon first
        if let url = bundle.url(forResource: "MenuBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        // Try template mascot silhouette
        if let url = bundle.url(forResource: "MenuBarTemplate", withExtension: "png") ?? bundle.url(forResource: "MenuBarTemplate@2x", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }
        if let url = bundle.url(forResource: "AppLogo@1x", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            return img
        }
        return NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "AgentDock") ?? NSImage()
    }
}
