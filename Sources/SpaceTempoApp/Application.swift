import AppKit
import SwiftUI

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var instant: InstantModel!
    private var login: LoginLaunch!
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var effectItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let backgroundLaunch = LoginLaunch.isLoginLaunch || CommandLine.arguments.contains("--background")
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != getpid() }) {
            if !backgroundLaunch { existing.activate(options: []) }
            NSApplication.shared.terminate(nil)
            return
        }
        login = LoginLaunch()
        instant = InstantModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "SpaceTempo")
        statusItem.button?.toolTip = "SpaceTempo"
        let menu = NSMenu()
        menu.delegate = self
        let settings = NSMenuItem(title: "Einstellungen öffnen …", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        effectItem = NSMenuItem(title: "Sofortwechsel aktiv", action: #selector(toggleEffect), keyEquivalent: "")
        effectItem.target = self
        menu.addItem(effectItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "SpaceTempo beenden", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        // Standard shortcuts work while the settings window is in front.
        let main = NSMenu()
        let application = NSMenuItem()
        let commands = NSMenu(title: "SpaceTempo")
        let close = NSMenuItem(title: "Fenster schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        commands.addItem(close)
        let menuQuit = NSMenuItem(title: "SpaceTempo beenden", action: #selector(quitApplication), keyEquivalent: "q")
        menuQuit.target = self
        commands.addItem(menuQuit)
        application.submenu = commands
        main.addItem(application)
        NSApplication.shared.mainMenu = main
        if !backgroundLaunch { showSettings() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { instant?.shutdown() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        effectItem.state = instant.running ? .on : .off
        effectItem.title = instant.desiredEnabled && !instant.running ? "Sofortwechsel: wartet auf Freigabe" : "Sofortwechsel aktiv"
    }

    @objc func showSettings() {
        if window == nil {
            let host = NSHostingController(rootView: ContentView(instant: instant, login: login))
            host.sizingOptions = [.preferredContentSize]
            let created = NSWindow(contentViewController: host)
            created.title = "SpaceTempo"
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func toggleEffect() {
        if instant.desiredEnabled { instant.stop() } else { instant.start() }
    }

    @objc private func quitApplication() { NSApplication.shared.terminate(nil) }
}

@main enum SpaceTempoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
