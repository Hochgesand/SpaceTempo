import Cocoa
@preconcurrency import ApplicationServices
import Darwin

// Synthetic gesture / IOHID serialization adapted from noswoosh (MIT),
// Copyright (c) 2026 Max Mathys. See THIRD_PARTY_NOTICES.md.
// Upstream credits jurplel/InstantSpaceSwitcher (MIT) and joshuarli/iss (ISC).
// All private SkyLight functions below are read-only and dynamically resolved.

struct SpaceSnapshot: Sendable {
    let ids: [UInt64]
    let currentIndex: Int
    let display: String?
}

struct SwitchResult: Sendable {
    let before: SpaceSnapshot
    let after: SpaceSnapshot
    let elapsedMilliseconds: Double
    let verified: Bool
    let message: String
}

@MainActor
final class InstantSwitchEngine {
    static var supported: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion == 27 || (v.majorVersion == 26 && v.minorVersion >= 6)
    }
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private let spaces = SpaceReader()
    private var switching = false
    private var prediction = SpacePrediction()
    func snapshot() -> SpaceSnapshot? { spaces.snapshot() }

    /// Global input path: no polling or sleeps, and no changes to hotkey settings.
    @discardableResult
    func switchImmediately(right: Bool) throws -> Bool {
        guard Self.supported else { throw Failure.unsupported }
        guard Self.isTrusted else { throw Failure.permission }
        guard !switching else { throw Failure.busy }
        guard let before = snapshot() else { throw Failure.unreadable }
        let now = ProcessInfo.processInfo.systemUptime
        guard let destination = prediction.destination(before, right: right, now: now) else { return false }
        let events = try GestureFactory().events(right: right)
        events.forEach { $0.post(tap: .cgSessionEventTap) }
        prediction.record(before, destination: destination, now: now)
        return true
    }

    func switchOnce(right: Bool) async throws -> SwitchResult {
        guard Self.supported else { throw Failure.unsupported }
        guard Self.isTrusted else { throw Failure.permission }
        guard !switching else { throw Failure.busy }
        guard let before = snapshot() else { throw Failure.unreadable }
        prediction = SpacePrediction()
        guard let destination = prediction.destination(before, right: right, now: ProcessInfo.processInfo.systemUptime) else {
            return SwitchResult(before: before, after: before, elapsedMilliseconds: 0,
                                verified: false, message: "Am Rand: kein weiterer Desktop in dieser Richtung.")
        }
        switching = true
        defer { switching = false }
        let events = try GestureFactory().events(right: right)
        try Task.checkCancellation()
        let start = ContinuousClock.now
        // No await inside the complete gesture sequence: cancellation cannot leave
        // Dock in a partial began/changed state. No hotkeys or defaults are changed.
        events.forEach { $0.post(tap: .cgSessionEventTap) }
        let expectedID = before.ids[destination]
        var latest = before
        var arrivalMilliseconds: Double?
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            if let read = spaces.snapshot(display: before.display) {
                latest = read
                if read.ids[read.currentIndex] == expectedID {
                    let elapsed = start.duration(to: .now)
                    arrivalMilliseconds = Double(elapsed.components.seconds) * 1000
                        + Double(elapsed.components.attoseconds) / 1e15
                    break
                }
            }
        }
        if let elapsed = arrivalMilliseconds {
            // Check repeatedly through the ~400 ms empty-space focus bounce window.
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                guard let read = spaces.snapshot(display: before.display) else {
                    return SwitchResult(before: before, after: latest, elapsedMilliseconds: elapsed,
                                        verified: false, message: "Ziel erreicht, aber Stabilitätsprüfung nicht lesbar.")
                }
                latest = read
                if read.ids[read.currentIndex] != expectedID {
                    return SwitchResult(before: before, after: read, elapsedMilliseconds: elapsed,
                                        verified: false, message: "Ziel kurz erreicht; macOS wechselte anschließend wieder weg. Test fehlgeschlagen.")
                }
            }
            return SwitchResult(before: before, after: latest, elapsedMilliseconds: elapsed,
                                verified: true, message: "Desktopwechsel bestätigt und 500 ms stabil. Die Messzeit ist keine Animationsdauer.")
        }
        let elapsed = start.duration(to: .now)
        return SwitchResult(before: before, after: latest,
                            elapsedMilliseconds: Double(elapsed.components.seconds) * 1000
                                + Double(elapsed.components.attoseconds) / 1e15,
                            verified: false, message: "Ziel innerhalb einer Sekunde nicht bestätigt. Bedienungshilfen-Freigabe und gegebenenfalls App-Neustart prüfen.")
    }

    enum Failure: LocalizedError {
        case unsupported, permission, busy, unreadable, eventBuild
        var errorDescription: String? {
            switch self {
            case .unsupported: "Der Sofort-Test unterstützt macOS 26.6+ und 27."
            case .permission: "SpaceTempo benötigt die Bedienungshilfen-Freigabe."
            case .busy: "Ein Desktopwechsel wird noch geprüft."
            case .unreadable: "Die Desktops des Zielbildschirms konnten nicht gelesen werden."
            case .eventBuild: "Die vollständige Gestensequenz konnte nicht erzeugt werden; es wurde nichts gesendet."
            }
        }
    }
}

@MainActor
private final class SpaceReader {
    typealias Connection = @convention(c) () -> UInt32
    typealias DisplaySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    typealias ActiveSpace = @convention(c) (UInt32) -> UInt64
    private let handle: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let displaySpaces: DisplaySpaces?
    private let activeSpace: ActiveSpace?

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        handle = h
        func resolve<T>(_ name: String, _ type: T.Type) -> T? {
            guard let h, let address = dlsym(h, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        connection = resolve("SLSMainConnectionID", Connection.self)
        displaySpaces = resolve("SLSCopyManagedDisplaySpaces", DisplaySpaces.self)
        activeSpace = resolve("SLSGetActiveSpace", ActiveSpace.self)
        // Keep the library loaded for process lifetime; function pointers remain valid.
    }

    func snapshot(display requested: String? = nil) -> SpaceSnapshot? {
        guard let connection, let displaySpaces, let activeSpace,
              let raw = displaySpaces(connection())?.takeRetainedValue(),
              let displays = raw as? [[String: Any]] else { return nil }
        func parse(_ display: [String: Any], current: UInt64? = nil) -> SpaceSnapshot? {
            guard let rawSpaces = display["Spaces"] as? [[String: Any]] else { return nil }
            let ids = rawSpaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            let currentID = current ?? ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value
            guard let currentID, let index = ids.firstIndex(of: currentID) else { return nil }
            return SpaceSnapshot(ids: ids, currentIndex: index, display: display["Display Identifier"] as? String)
        }
        if let requested {
            guard let display = displays.first(where: { ($0["Display Identifier"] as? String) == requested }) else { return nil }
            return parse(display)
        }
        if displays.count == 1, let display = displays.first { return parse(display) ?? parse(display, current: activeSpace(connection())) }
        if let point = CGEvent(source: nil)?.location {
            var id = CGDirectDisplayID()
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 {
                let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
                let name = uuid.map { CFUUIDCreateString(nil, $0) as String }
                if let display = displays.first(where: {
                    let identifier = $0["Display Identifier"] as? String
                    return identifier == name || (identifier == "Main" && id == CGMainDisplayID())
                }) { return parse(display) }
            }
        }
        let current = activeSpace(connection())
        return displays.compactMap { parse($0, current: current) }.first
    }
}

@MainActor
final class GestureFactory {
    let needsAugmentation: Bool
    let postedSwipeSign: Double
    init(augmented: Bool = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
         naturalScrolling: Bool? = nil) {
        needsAugmentation = augmented
        let natural = naturalScrolling ?? (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                                kCFPreferencesAnyApplication) as? Bool ?? true)
        postedSwipeSign = augmented && !natural ? -1 : 1
    }

let fieldCGSEventType   = field(55)
let fieldGestureHIDType = field(110)
let fieldSwipeMask      = field(115)   // 27 payload
let fieldSwipeMotion    = field(123)
let fieldSwipeProgress  = field(124)
let fieldSwipePositionX = field(125)   // 27 payload
let fieldSwipePositionY = field(126)   // 27 payload
let fieldSwipeVelocityX = field(129)
let fieldSwipeVelocityY = field(130)
let fieldGesturePhase   = field(132)

let kCGSEventGesture: Int64 = 29
let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGGestureMotionHorizontal: Int64 = 1
let kRawIOHIDPayloadTag: Int = 4205    // 0x106D — CGEvent field carrying the blob
let gestureVelocity = 2000.0

enum GesturePhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

// Synthetic events we post re-enter our own event tap; both paths tag them so
// the tap lets them straight back out. A tag travels with the event, so it also
// works across processes — which a counter could not, and that was #8: a running
// daemon intercepted the CLI's events and moved the wrong way.

// MARK: pre-27 path (macOS 26) — bare Dock-swipe, near-zero progress

// This path is correct on macOS 26.6+; on 26.0–26.5 WindowServer drops the
// destination's surfaces at commit (see the header note and issue #1, which
// also records the workarounds that were tried and rejected).

// Synthetic events identify themselves to our own event tap via this tag in
// the user-data field, so the tap passes them through instead of intercepting
// them. Real trackpad gestures carry 0 there.
let noswooshEventTag: Int64 = 0x5354_494E // 'STIN'

// MARK: macOS 27+ path — IOHID payload + companion pairs

func fixed1616(_ v: Double) -> Int32 {
    let f = Int32(truncatingIfNeeded: Int64(v * 65536.0))
    if f == 0 && v != 0 { return v > 0 ? 1 : -1 }
    return f
}

// Little-endian byte buffer helpers for the packed IOHID structs.
// Serialized IOHID queue payload macOS 27 validates the synthetic swipe against:
// a queue header, a fluid-touch gesture record, and (on motion/end) a velocity
// record. Layout reverse-engineered from joshuarli/iss.
func generateIOHIDPayload(_ ev: CGEvent) -> [UInt8] {
    let phase   = ev.getIntegerValueField(fieldGesturePhase)
    let motion  = ev.getIntegerValueField(fieldSwipeMotion)
    let progress = ev.getDoubleValueField(fieldSwipeProgress)
    let posX    = ev.getDoubleValueField(fieldSwipePositionX)
    let posY    = ev.getDoubleValueField(fieldSwipePositionY)
    let velX    = ev.getDoubleValueField(fieldSwipeVelocityX)
    let velY    = ev.getDoubleValueField(fieldSwipeVelocityY)
    let mask    = ev.getIntegerValueField(fieldSwipeMask)
    // The velocity record is required on macOS 27 (dropping it entirely stops the
    // switch), even when the velocities are zero on the non-ended phases.
    let includeVelocity = velX != 0 || velY != 0 || phase == GesturePhase.ended.rawValue

    var p = [UInt8]()
    // IOHIDSystemQueueElementHeader (28 bytes)
    let ts = ev.timestamp
    p.le(ts != 0 ? ts : mach_absolute_time())   // timestamp
    p.le(UInt64(0))                             // sender_id
    p.le(UInt32(0))                             // options
    p.le(UInt32(0))                             // attribute_length
    p.le(UInt32(includeVelocity ? 2 : 1))       // event_count
    // IOHIDFluidTouchGestureData (40 bytes): 16-byte base + fields
    p.le(UInt32(40))                            // base.size
    p.le(UInt32(23))                            // base.type = fluid-touch gesture
    p.le(UInt32((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24)) // base.options
    p.append(0); p.append(0); p.append(0); p.append(0)            // base.depth + reserved[3]
    p.le(fixed1616(posX))                       // position_x
    p.le(fixed1616(posY))                       // position_y
    p.le(Int32(0))                              // position_z
    p.le(UInt32(truncatingIfNeeded: mask))      // swipe_mask
    p.le(UInt16(truncatingIfNeeded: motion))    // gesture_motion
    p.le(UInt16(3))                             // gesture_flavor = Dock primary
    p.le(fixed1616(progress))                   // swipe_progress
    if includeVelocity {
        // IOHIDVelocityEventData (28 bytes): 16-byte base + 3 fixed velocities
        p.le(UInt32(28))                        // base.size
        p.le(UInt32(9))                         // base.type = velocity
        p.le(UInt32(0))                         // base.options
        p.append(1); p.append(0); p.append(0); p.append(0)       // base.depth = 1 + reserved
        p.le(fixed1616(velX))                   // velocity_x
        p.le(fixed1616(velY))                   // velocity_y
        p.le(Int32(0))                          // velocity_z
    }
    return p
}

// Round-trip the event through its serialized form to append the raw IOHID
// payload under field 4205, which the plain setters cannot write.
func augment(_ ev: CGEvent) -> CGEvent? {
    guard let cf = ev.data else { return nil }
    var bytes = [UInt8](cf as Data)
    // Serialized-event format must be version 2 (header 00 00 00 02).
    guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2 else { return nil }
    let payload = generateIOHIDPayload(ev)
    let len = payload.count
    bytes.append(UInt8((len >> 8) & 0xFF))
    bytes.append(UInt8(len & 0xFF))
    bytes.append(UInt8((kRawIOHIDPayloadTag >> 8) & 0xFF))
    bytes.append(UInt8(kRawIOHIDPayloadTag & 0xFF))
    bytes.append(contentsOf: payload)
    return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
}

func makeAugmentedDockEvent(_ phase: GesturePhase, right: Bool) -> CGEvent? {
    guard let ev = CGEvent(source: nil) else { return nil }
    ev.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
    ev.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    ev.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    // Near-zero progress, same as the pre-27 path and for the same reason: it
    // commits the switch with nothing left to animate. This path used full travel
    // (±1.0) through 1.7.0, which visibly slid on 27 — the switch was correct but
    // not instant, defeating the point. The ±9999 fling on .ended is what commits
    // it, so the magnitude here can be ~0 without losing the switch; only the sign
    // matters. Not FLT_TRUE_MIN (flushes to zero on Apple Silicon, losing the sign)
    // and not 0 either — `fixed1616` would serialize it as 0 in the IOHID payload.
    // On the 27 path direction is inverted: rightward = negative progress.
    ev.setDoubleValueField(fieldSwipeProgress, value: (right ? -1e-4 : 1e-4) * postedSwipeSign)
    ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
    ev.setDoubleValueField(fieldSwipePositionX, value: 0.1)
    // A strong "fling" velocity on the terminal phase is what commits the switch.
    if phase == .ended {
        ev.setDoubleValueField(fieldSwipeVelocityX, value: (right ? -9999.0 : 9999.0) * postedSwipeSign)
    }
    return ev
}


    func events(right: Bool) throws -> [CGEvent] {
        var built: [CGEvent] = []
        for phase in [GesturePhase.began, .changed, .ended] {
            if needsAugmentation {
                guard let dock = makeAugmentedDockEvent(phase, right: right),
                      let augmented = augment(dock), let companion = CGEvent(source: nil) else {
                    throw InstantSwitchEngine.Failure.eventBuild
                }
                augmented.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
                companion.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
                companion.setIntegerValueField(fieldCGSEventType, value: kCGSEventGesture)
                built.append(contentsOf: [augmented, companion])
            } else {
                guard let event = CGEvent(source: nil) else { throw InstantSwitchEngine.Failure.eventBuild }
                let sign = right ? 1.0 : -1.0
                event.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
                event.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
                event.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
                event.setDoubleValueField(fieldSwipeProgress, value: 1e-4 * sign)
                event.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
                event.setDoubleValueField(fieldSwipeVelocityX, value: gestureVelocity * sign)
                event.setDoubleValueField(fieldSwipeVelocityY, value: gestureVelocity * sign)
                event.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
                built.append(event)
            }
        }
        return built
    }
}

private func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
extension Array where Element == UInt8 {
    mutating func le(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: Int32)  { le(UInt32(bitPattern: v)) }
}


/// A brief prediction bridges asynchronous Dock bookkeeping on rapid input.
/// It can never cross displays or survive a changed desktop ordering.
struct SpacePrediction {
    private var ids: [UInt64] = []
    private var display: String?
    private var index: Int?
    private var timestamp: TimeInterval = -.infinity

    func destination(_ snapshot: SpaceSnapshot, right: Bool, now: TimeInterval) -> Int? {
        let age = now - timestamp
        let usePrediction = age >= 0 && age < 0.4 && ids == snapshot.ids && display == snapshot.display
        let current = usePrediction ? (index ?? snapshot.currentIndex) : snapshot.currentIndex
        let next = current + (right ? 1 : -1)
        return snapshot.ids.indices.contains(next) ? next : nil
    }

    mutating func record(_ snapshot: SpaceSnapshot, destination: Int, now: TimeInterval) {
        ids = snapshot.ids
        display = snapshot.display
        index = destination
        timestamp = now
    }
}
