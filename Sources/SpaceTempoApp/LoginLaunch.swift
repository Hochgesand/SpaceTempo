import AppKit
import Combine
import CoreServices
import ServiceManagement

/// Controls macOS's user-level login item for the installed main application.
/// Initialization and refresh are read-only; changes require setEnabled(_:).
@MainActor final class LoginLaunch: ObservableObject {
    @Published private(set) var enabled = false
    @Published var message: String?
    @Published private(set) var requiresApproval = false

    private var activationObserver: AnyCancellable?
    private let service = SMAppService.mainApp

    init() {
        refresh()
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
    }

    /// Read during applicationDidFinishLaunching; the current Apple event is transient.
    /// Apple documents this launch marker in its Launch Apple Event Constants.
    static var isLoginLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func refresh() {
        let status = service.status
        enabled = status == .enabled
        requiresApproval = status == .requiresApproval
        switch status {
        case .enabled, .notRegistered:
            message = nil
        case .requiresApproval:
            message = "Bitte SpaceTempo unter Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen erlauben."
        case .notFound:
            message = "Bitte SpaceTempo aus /Applications/SpaceTempo.app öffnen und den Autostart erneut aktivieren."
        @unknown default:
            message = "Der Autostart-Status ist unbekannt. Bitte die Anmeldeobjekte in den Systemeinstellungen prüfen."
        }
    }

    func setEnabled(_ requested: Bool) {
        if requested {
            let installed = URL(fileURLWithPath: "/Applications/SpaceTempo.app", isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            guard Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL == installed else {
                refresh()
                message = "Bitte SpaceTempo zuerst in Programme installieren und /Applications/SpaceTempo.app öffnen. Danach lässt sich der Autostart aktivieren."
                return
            }
        }
        do {
            switch (requested, service.status) {
            case (true, .enabled), (false, .notRegistered):
                break
            case (true, .requiresApproval):
                // Registration already exists. Re-registering would obscure its
                // actual state with an AlreadyRegistered/LaunchDenied error.
                break
            case (true, _):
                try service.register()
            case (false, _):
                try service.unregister()
            }
            refresh()
        } catch {
            refresh()
            // A successful registration may still require approval; preserve that
            // specific next step instead of presenting a generic framework error.
            if !requiresApproval {
                message = "Autostart konnte nicht \(requested ? "aktiviert" : "deaktiviert") werden: \(error.localizedDescription) Bitte die Anmeldeobjekte in den Systemeinstellungen prüfen."
            }
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
