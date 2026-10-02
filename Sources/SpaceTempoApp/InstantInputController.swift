import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Horizontal Dock-swipe recognition adapted from noswoosh by mmathys (MIT).
// See THIRD_PARTY_NOTICES.md. Private event fields may change between OS versions.
// No input is logged, persisted, or sent anywhere; unrelated events pass through.
@MainActor final class InstantInputController {
    enum InputError: LocalizedError {
        case accessibilityRequired
        case tapUnavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired:
                "SpaceTempo benötigt die Bedienungshilfen-Freigabe. Danach die App erneut öffnen."
            case .failed(let message):
                message
            case .tapUnavailable:
                "Die Eingabeüberwachung konnte nicht gestartet werden. Bitte die Bedienungshilfen-Freigabe prüfen und SpaceTempo erneut öffnen."
            }
        }
    }

    private(set) var isRunning = false
    var onFailure: (@MainActor (String) -> Void)?
    private(set) var lastStopError: String?
    let keyboardShortcutDescription = "Ctrl + ←/→"

    private var resources: TapResources?
    private var onSwitch: (@MainActor (Bool) -> Void)?
    private var swipeTracking = false
    private var swipeFired = false
    private let augmentedGestures = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    func start(onSwitch: @escaping @MainActor (Bool) -> Void) throws {
        guard !isRunning else { return }
        if let lastStopError { throw InputError.failed(lastStopError + " Bitte SpaceTempo erneut öffnen.") }
        guard AXIsProcessTrusted() else { throw InputError.accessibilityRequired }
        guard !IsSecureEventInputEnabled() else {
            throw InputError.failed("Sichere Eingabe ist aktiv. Bitte den Mac sperren und entsperren oder das Passwortfeld verlassen, dann erneut starten.")
        }
        let context = CallbackContext(self)
        let mask = (CGEventMask(1) << 29) | (CGEventMask(1) << 30)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                // This source is installed only on the main run loop.
                let consumed = MainActor.assumeIsolated {
                    guard let controller = context.controller else { return false }
                    return controller.handle(type: type, event: event) == nil
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { throw InputError.tapUnavailable }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw InputError.tapUnavailable
        }
        self.onSwitch = onSwitch
        let owned = TapResources(tap: tap, source: source, context: context)
        resources = owned
        do {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == 0x5354494E, id.id == 1 || id.id == 2 else {
                    return OSStatus(eventNotHandledErr)
                }
                let context = Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue()
                let right = id.id == 2
                MainActor.assumeIsolated {
                    guard let controller = context.controller, controller.isRunning else { return }
                    controller.onSwitch?(right)
                }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(context).toOpaque(), &owned.hotkeyHandler)
            guard handlerStatus == noErr else {
                throw InputError.failed("Tastenkürzel-Handler nicht verfügbar (\(handlerStatus)).")
            }
            let lease = try NativeHotKeyLease()
            owned.nativeLease = lease
            lease.process.terminationHandler = { [weak self] terminated in
                Task { @MainActor [weak self] in
                    guard let self, self.resources?.nativeLease?.process === terminated else { return }
                    self.fail("Der Wiederherstellungsprozess wurde beendet. Die normalen Tastenkürzel wurden wiederhergestellt.")
                }
            }
            try lease.disable()
            for (id, code) in [(UInt32(1), UInt32(kVK_LeftArrow)), (UInt32(2), UInt32(kVK_RightArrow))] {
                var reference: EventHotKeyRef?
                let result = RegisterEventHotKey(code, UInt32(controlKey),
                    EventHotKeyID(signature: 0x5354494E, id: id), GetApplicationEventTarget(), 0, &reference)
                guard result == noErr, let reference else {
                    throw InputError.failed("Ctrl + Pfeiltaste konnte nicht übernommen werden (\(result)).")
                }
                owned.hotkeys.append(reference)
            }
            guard lease.process.isRunning else {
                throw InputError.failed("Der Wiederherstellungsprozess wurde unerwartet beendet.")
            }
        } catch {
            stop()
            throw error
        }
        resources?.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stop() }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        isRunning = true
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            throw InputError.tapUnavailable
        }
        owned.healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }

    @discardableResult func stop() -> Bool {
        let restored = resources?.shutdown() ?? true
        resources = nil
        isRunning = false
        onSwitch = nil
        resetSwipe()
        if !restored {
            let message = "Die Wiederherstellung der Tastenkürzel konnte nicht bestätigt werden. Der Schutzprozess versucht sie erneut; bitte SpaceTempo schließen und Ctrl + Pfeiltaste prüfen."
            lastStopError = message
            onFailure?(message)
        }
        return restored
    }

    private func fail(_ message: String) {
        if stop() { onFailure?(message) }
    }

    private func checkHealth() {
        guard isRunning else { return }
        guard AXIsProcessTrusted() else {
            fail("Die Bedienungshilfen-Freigabe fehlt. Instant-Modus wurde beendet und normale Tastenkürzel wiederhergestellt.")
            return
        }
        guard !IsSecureEventInputEnabled() else {
            fail("Sichere Eingabe ist aktiv. Instant-Modus wurde beendet; bitte sperren/entsperren und erneut starten.")
            return
        }
        guard let tap = resources?.tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                fail("Die Eingabeüberwachung wurde beendet. Normale Tastenkürzel wurden wiederhergestellt.")
            }
        }
    }

    private func resetSwipe() {
        swipeTracking = false
        swipeFired = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard isRunning else { return pass }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetSwipe()
                checkHealth()
            return pass
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        // STIN is SpaceTempo; NSWS also avoids interfering with upstream's CLI.
        if tag == 0x5354_494E || tag == 0x4E53_5753 { return pass }

        let eventType = event.getIntegerValueField(Self.field(55))
        if eventType == 30,
           event.getIntegerValueField(Self.field(110)) == 23,
           event.getIntegerValueField(Self.field(123)) == 1 {
            let phase = event.getIntegerValueField(Self.field(132))
            switch phase {
            case 1: // began
                swipeTracking = true
                swipeFired = false
                return nil
            case 2: // changed
                if swipeTracking && !swipeFired {
                    let progress = event.getDoubleValueField(Self.field(124))
                    if progress.isFinite && progress != 0 {
                        swipeFired = true
                        onSwitch?(progress > 0)
                    }
                }
                return swipeTracking ? nil : pass
            case 4: // ended
                let wasTracking = swipeTracking
                if wasTracking && !swipeFired {
                    let velocity = event.getDoubleValueField(Self.field(129))
                    if velocity.isFinite && velocity != 0 { onSwitch?(velocity > 0) }
                }
                resetSwipe()
                // macOS 27 needs its native terminal event to close gesture state.
                if augmentedGestures && wasTracking {
                    event.setDoubleValueField(Self.field(129), value: 0)
                    event.setDoubleValueField(Self.field(130), value: 0)
                    event.setDoubleValueField(Self.field(124), value: 0)
                    return pass
                }
                return wasTracking ? nil : pass
            case 8: // cancelled
                let wasTracking = swipeTracking
                resetSwipe()
                return wasTracking ? nil : pass
            default:
                return swipeTracking ? nil : pass
            }
        }
        // Only suppress companion events within a captured horizontal gesture.
        if eventType == 29 && swipeTracking { return nil }
        return pass
    }

    private static func field(_ number: UInt32) -> CGEventField {
        unsafeBitCast(number, to: CGEventField.self)
    }
}

// The callback owns no controller lifetime. TapResources holds the context until
// after invalidation, so destruction cannot leave the callback a dangling pointer.
private final class CallbackContext {
    weak var controller: InstantInputController?
    init(_ controller: InstantInputController) { self.controller = controller }
}

// Only accessed on main while alive; Core Foundation cleanup is thread-safe.
// Sendable lets Swift 6 perform resource destruction from a nonisolated deinit.
private final class TapResources: @unchecked Sendable {
    let tap: CFMachPort
    let source: CFRunLoopSource
    let context: CallbackContext
    var terminationObserver: NSObjectProtocol?
    var healthTimer: Timer?
    var nativeLease: NativeHotKeyLease?
    var hotkeyHandler: EventHandlerRef?
    var hotkeys: [EventHotKeyRef] = []
    private var stopped = false
    private var restoreSucceeded = true

    init(tap: CFMachPort, source: CFRunLoopSource, context: CallbackContext) {
        self.tap = tap
        self.source = source
        self.context = context
    }

    @discardableResult func shutdown() -> Bool {
        guard !stopped else { return restoreSucceeded }
        stopped = true
        healthTimer?.invalidate()
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
        restoreSucceeded = nativeLease?.restore() ?? true
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        return restoreSucceeded
    }

    deinit { shutdown() }
}

// A process-local lease, backed by a separate parent-death monitor. Original
// states are sampled, never assumed. No defaults, login items, or root access.
private final class NativeHotKeyLease: @unchecked Sendable {
    typealias GetEnabled = @convention(c) (Int32) -> Bool
    typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    let process: Process
    private let pipe: Pipe
    private let library: UnsafeMutableRawPointer
    private let setEnabled: SetEnabled
    private let getEnabled: GetEnabled
    private let originalLeft: Bool
    private let originalRight: Bool
    private var restored = false
    private var restoreVerified = false

    init() throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/space-tempo-input-guard")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InstantInputController.InputError.failed("Das Wiederherstellungsprogramm fehlt. Bitte die vollständige App verwenden.")
        }
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) else {
            throw InstantInputController.InputError.failed("Die macOS-Tastenkürzelverwaltung ist nicht verfügbar.")
        }
        guard let getter = dlsym(library, "SLSIsSymbolicHotKeyEnabled"),
              let setter = dlsym(library, "SLSSetSymbolicHotKeyEnabled") else {
            dlclose(library)
            throw InstantInputController.InputError.failed("Dieser macOS-Build unterstützt die sichere Tastenkürzelübernahme nicht.")
        }
        self.library = library
        getEnabled = unsafeBitCast(getter, to: GetEnabled.self)
        setEnabled = unsafeBitCast(setter, to: SetEnabled.self)
        originalLeft = getEnabled(79)
        originalRight = getEnabled(81)
        pipe = Pipe()
        // A crashed helper must not let writing its pipe terminate the app.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [String(getpid()), originalLeft ? "1" : "0", originalRight ? "1" : "0"]
        process.standardInput = pipe
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Close our copies of the child's pipe ends; EOF is the rollback signal.
            try? pipe.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 3000) > 0,
                  try output.fileHandleForReading.read(upToCount: 6) == Data("READY\n".utf8),
                  process.isRunning else {
                throw InstantInputController.InputError.failed("Die Tastenkürzel-Wiederherstellung konnte nicht abgesichert werden.")
            }
            try? output.fileHandleForReading.close()
        } catch {
            restore()
            throw error
        }
    }

    func disable() throws {
        guard process.isRunning else {
            throw InstantInputController.InputError.failed("Der Wiederherstellungsprozess ist nicht aktiv.")
        }
        let leftResult = setEnabled(79, false)
        let rightResult = setEnabled(81, false)
        guard leftResult == 0, rightResult == 0, !getEnabled(79), !getEnabled(81), process.isRunning else {
            restore()
            throw InstantInputController.InputError.failed("Die macOS-Tastenkürzel konnten nicht vorübergehend übernommen werden.")
        }
    }

    @discardableResult func restore() -> Bool {
        guard !restored else { return restoreVerified }
        restored = true
        process.terminationHandler = nil
        let leftResult = setEnabled(79, originalLeft)
        let rightResult = setEnabled(81, originalRight)
        // D disarms an old guardian only after this process has restored both.
        // Prevents it restoring again after a fast stop/start with a new lease.
        restoreVerified = leftResult == 0 && rightResult == 0
            && getEnabled(79) == originalLeft && getEnabled(81) == originalRight
        if restoreVerified {
            try? pipe.fileHandleForWriting.write(contentsOf: Data([0x44]))
        }
        try? pipe.fileHandleForWriting.close()
        return restoreVerified
    }

    deinit {
        restore()
        dlclose(library)
    }
}
