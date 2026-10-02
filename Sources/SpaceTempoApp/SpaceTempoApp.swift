import AppKit
import SwiftUI
import Combine

struct DockStatus: Decodable, Sendable {
    var compatible: Bool
    var patched: Bool
    var patchKnown: Bool
    var sipRestricted: Bool
    var message: String
    var duration: Double?
}

enum ToolError: LocalizedError {
    case unavailable
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Das mitgelieferte Kommandozeilenprogramm fehlt. Bitte die .app mit make app bauen."
        case .failed(let message): message
        }
    }
}

enum Tool {
    static var path: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/space-tempo-cli").path
    }

    static func status() throws -> DockStatus {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ToolError.unavailable }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["status"]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolError.failed(String(decoding: errorData, as: UTF8.self))
        }
        return try JSONDecoder().decode(DockStatus.self, from: data)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor static func administer(duration: Double?) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { throw ToolError.unavailable }
        let arguments = duration.map { "apply " + String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "revert"
        let command = shellQuote(path) + " " + arguments
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(literal)\" with administrator privileges"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ToolError.failed("Die Administratorabfrage konnte nicht erstellt werden.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -128 { throw ToolError.failed("Abgebrochen. Die Animation wurde nicht verändert.") }
            throw ToolError.failed(error[NSAppleScript.errorMessage] as? String ?? "Der Eingriff wurde abgelehnt.")
        }
        return result.stringValue ?? "Fertig."
    }
}

@MainActor final class Model: ObservableObject {
    @Published var duration = 0.5
    @Published var status: DockStatus?
    @Published var message = "Dock wird geprüft …"
    @Published var busy = false

    func refresh() async {
        do {
            let state = try await Task.detached { try Tool.status() }.value
            status = state
            message = !state.compatible ? "Dieser Dock-Build wird noch nicht unterstützt." : state.sipRestricted ? "SIP-Debugging-Beschränkungen verhindern den Zugriff auf Dock." : !state.patchKnown ? "Der aktive Zustand lässt sich erst mit Administratorrechten prüfen." : state.patched ? "SpaceTempo ist aktiv." : "Die Originalanimation ist aktiv."
            if state.patchKnown, state.patched, let value = state.duration { duration = value }
        } catch {
            status = nil
            message = error.localizedDescription
        }
    }

    func apply(reset: Bool = false) async {
        busy = true
        defer { busy = false }
        do {
            // The system owns the administrator password prompt; the app never reads it.
            let result = try Tool.administer(duration: reset ? nil : duration)
            await refresh()
            message = result.isEmpty ? "Fertig." : result
            if reset { duration = 0.5 }
        } catch { message = error.localizedDescription }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 34, weight: .medium)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SpaceTempo").font(.largeTitle.bold())
                    Text("Desktops wechseln. Mit deinem Tempo.").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Animationsdauer").font(.headline)
                    Spacer()
                    Text(String(format: "%.2f×", model.duration)).font(.title.monospacedDigit())
                }
                Slider(value: $model.duration, in: 0.25...1, step: 0.05)
                    .accessibilityLabel("Faktor der Animationsdauer")
                HStack {
                    Text("25 % der Dauer")
                    Spacer()
                    Text("Original")
                }.font(.caption).foregroundStyle(.secondary)
                Text(model.duration == 1 ? "Originalanimation" : String(format: "Etwa %.1f× schneller · seitliche Animation bleibt erhalten", 1 / model.duration))
                    .font(.callout)
            }
            .padding(18).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))

            Label(model.message, systemImage: model.status?.sipRestricted == true ? "lock.shield" : "info.circle")
                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)

            if model.status?.sipRestricted == true {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vor dem ersten Anwenden").font(.headline)
                    Text("Der Eingriff benötigt root und deaktivierte SIP-Debugging-Beschränkungen. Das erlaubt root-Prozessen den Zugriff auf geschützte Apple-Prozesse und senkt die Startsicherheit auf Apple Silicon. Die App ändert diese Schutzmaßnahmen nicht.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Einrichtung und Rückgängig machen", destination: URL(string: "https://github.com/Hochgesand/SpaceTempo#einrichtung")!)
                }
            }

            HStack {
                Button("Prüfen") { Task { await model.refresh() } }
                Spacer()
                Button("Original wiederherstellen") { Task { await model.apply(reset: true) } }
                    .disabled(model.busy || model.status?.compatible != true || model.status?.sipRestricted != false)
                Button("Anwenden") { Task { await model.apply() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.status?.compatible != true || model.status?.sipRestricted != false)
            }
            Text("Gilt bis Dock neu startet. Andere Systemanimationen werden nicht eingestellt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 560)
        .disabled(model.busy)
        .task { await model.refresh() }
    }
}

@main struct SpaceTempoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
