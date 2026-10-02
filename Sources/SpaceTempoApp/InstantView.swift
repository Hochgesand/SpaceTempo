import AppKit
import SwiftUI
import Combine

@MainActor final class InstantModel: ObservableObject {
    @Published var trusted = InstantSwitchEngine.isTrusted
    @Published var running = false
    @Published private(set) var desiredEnabled = UserDefaults.standard.bool(forKey: "instantEnabled")
    @Published var busy = false
    @Published var message = "Sofortwechsel ist ausgeschaltet."
    @Published var verification = "Noch kein Live-Test durchgeführt."
    @Published var spaceDescription = ""
    private let engine = InstantSwitchEngine()
    private let input = InstantInputController()
    private var terminationObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var shuttingDown = false
    private var lastAttempt = Date.distantPast

    init() {
        input.onFailure = { [weak self] message in
            self?.running = false
            self?.message = message
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        trusted = InstantSwitchEngine.isTrusted
        running = input.isRunning
        if let snapshot = engine.snapshot() {
            spaceDescription = "Unter dem Mauszeiger: Space \(snapshot.currentIndex + 1) von \(snapshot.ids.count)"
        } else { spaceDescription = "Spaces konnten nicht gelesen werden." }
        if desiredEnabled, !running, !shuttingDown, trusted, InstantSwitchEngine.supported,
           input.lastStopError == nil, Date().timeIntervalSince(lastAttempt) >= 5 {
            activate()
        }
    }

    func requestPermission() {
        _ = InstantSwitchEngine.requestTrust()
        message = "SpaceTempo unter Datenschutz & Sicherheit → Bedienungshilfen erlauben, danach erneut prüfen."
        refresh()
    }

    func start() {
        desiredEnabled = true
        UserDefaults.standard.set(true, forKey: "instantEnabled")
        activate()
    }

    private func activate() {
        lastAttempt = Date()
        do {
            try input.start { [weak self] right in
                guard let self else { return }
                do {
                    if try self.engine.switchImmediately(right: right) {
                        self.message = "Sofortwechsel ausgelöst."
                    }
                } catch {
                    self.message = error.localizedDescription
                }
            }
            running = input.isRunning
            message = "Sofortwechsel aktiv. Ctrl + ←/→ und horizontale Gesten werden übernommen."
        } catch {
            input.stop()
            running = false
            message = error.localizedDescription
        }
    }

    func stop() {
        desiredEnabled = false
        UserDefaults.standard.set(false, forKey: "instantEnabled")
        let restored = input.stop()
        running = false
        message = restored ? "Sofortwechsel aus. Die vorherigen Desktop-Kurzbefehle sind wiederhergestellt." : (input.lastStopError ?? "Die Wiederherstellung der Kurzbefehle konnte nicht bestätigt werden.")
    }

    func shutdown() {
        shuttingDown = true
        refreshTimer?.invalidate()
        _ = input.stop()
        running = false
        // Preserve the user's desired mode for the next launch.
    }

    func switchOnce(right: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; refresh() }
        do {
            let result = try await engine.switchOnce(right: right)
            verification = result.message
            message = result.verified ? "Spacewechsel bestätigt." : "Der Spacewechsel konnte nicht bestätigt werden."
        } catch { verification = error.localizedDescription }
    }
}

struct InstantView: View {
    @ObservedObject var model: InstantModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 36)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sofort wechseln").font(.largeTitle.bold())
                    Text("Ohne Animation. Ohne Neustart.").foregroundStyle(.secondary)
                }
            }
            Text("Dieser Modus überspringt die seitliche Animation. SIP bleibt aktiviert. SpaceTempo benötigt einmalig die Bedienungshilfen-Freigabe, um den Wechsel auszulösen.")
                .fixedSize(horizontal: false, vertical: true)

            if !InstantSwitchEngine.supported {
                Label("Unterstützt werden macOS 26.6+ und macOS 27.", systemImage: "exclamationmark.triangle")
            } else if !model.trusted {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Bedienungshilfen-Freigabe fehlt", systemImage: "lock.shield")
                        .font(.headline)
                    Text("Die Freigabe erlaubt der App, globale Kurzbefehle und Gesten zu verarbeiten und Eingaben zu erzeugen. Es werden keine Tastatureingaben gespeichert.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Freigabe anfragen") { model.requestPermission() }
                }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Einzelnen Wechsel testen").font(.headline)
                Text(model.spaceDescription).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("← Test nach links") { Task { await model.switchOnce(right: false) } }
                    Button("Test nach rechts →") { Task { await model.switchOnce(right: true) } }
                }.disabled(!model.trusted || model.busy || !InstantSwitchEngine.supported)
                Text(model.verification).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Label(model.message, systemImage: model.running ? "checkmark.circle.fill" : "info.circle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Prüfen") { model.refresh() }
                Spacer()
                if model.running {
                    Button("Sofortwechsel ausschalten") { model.stop() }
                } else {
                    Button("Sofortwechsel aktivieren") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.trusted || !InstantSwitchEngine.supported)
                }
            }
            Text("Fenster schließen lässt den Effekt aktiv. Die letzte Einstellung wird beim nächsten Start wiederhergestellt. Über das Menüleistensymbol kannst du SpaceTempo ausdrücklich beenden.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(width: 560)
        .onAppear { model.refresh() }
    }
}

struct ContentView: View {
    @ObservedObject var instant: InstantModel
    @ObservedObject var login: LoginLaunch
    @AppStorage("selectedMode") private var selectedMode = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TabView(selection: $selectedMode) {
                InstantView(model: instant).tabItem { Text("Sofortwechsel") }.tag(0)
                DurationView().tabItem { Text("Animationsdauer · SIP") }.tag(1)
            }
            Divider()
            Toggle("Beim Anmelden starten", isOn: Binding(
                get: { login.enabled }, set: { login.setEnabled($0) }
            ))
            if let message = login.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if login.requiresApproval {
                Button("Anmeldeobjekte öffnen") { login.openSettings() }
            }
            Text("Einstellungen werden automatisch gespeichert.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .fixedSize()
    }
}
