import CoreGraphics

// Standalone checks: no application startup, event posting, or trust prompts.
@main @MainActor
struct InstantEngineTests {
    static func main() throws {
        let tests = Self()
        tests.testBoundsAndShortLivedPrediction()
        try tests.testPayloadLayoutAndDirection()
        try tests.testCompleteSequencesWithoutPosting()
        print("PASS: instant-engine boundaries, prediction, IOHID payloads, and complete event sequences")
    }
    func testBoundsAndShortLivedPrediction() {
        var prediction = SpacePrediction()
        let first = SpaceSnapshot(ids: [10, 20, 30], currentIndex: 0, display: "A")
        expectNil(prediction.destination(first, right: false, now: 10))
        expectEqual(prediction.destination(first, right: true, now: 10), 1)
        prediction.record(first, destination: 1, now: 10)
        expectEqual(prediction.destination(first, right: true, now: 10.1), 2)
        expectEqual(prediction.destination(first, right: true, now: 10.5), 1)
        let otherDisplay = SpaceSnapshot(ids: first.ids, currentIndex: 0, display: "B")
        expectEqual(prediction.destination(otherDisplay, right: true, now: 10.1), 1)
        let reordered = SpaceSnapshot(ids: [10, 30, 20], currentIndex: 0, display: "A")
        expectEqual(prediction.destination(reordered, right: true, now: 10.1), 1)
        prediction.record(first, destination: 2, now: 11)
        expectNil(prediction.destination(first, right: true, now: 11.1))
        expectEqual(prediction.destination(first, right: false, now: 11.1), 1)
    }

    func testPayloadLayoutAndDirection() throws {
        do {
            for natural in [true, false] {
                for right in [true, false] {
                    let factory = GestureFactory(augmented: true, naturalScrolling: natural)
                    for phase in [GestureFactory.GesturePhase.began, .changed, .ended] {
                        let event = try requireValue(factory.makeAugmentedDockEvent(phase, right: right))
                        let bytes = factory.generateIOHIDPayload(event)
                        expectEqual(bytes.count, phase == .ended ? 96 : 68)
                        // Queue header count and fluid record size/type/phase options.
                        expectEqual(bytes[24], phase == .ended ? 2 : 1)
                        expectEqual(bytes[28], 40)
                        expectEqual(bytes[32], 23)
                        expectEqual(bytes[39], UInt8(phase.rawValue))
                        expectEqual(bytes[62], 3) // Dock primary gesture flavor
                        let progressBits = bytes[64..<68].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
                        let expectedSign: Int32 = (right ? -1 : 1) * (natural ? 1 : -1)
                        expectEqual(Int32(bitPattern: progressBits), 6 * expectedSign)
                        if phase == .ended {
                            expectEqual(bytes[68], 28)
                            expectEqual(bytes[72], 9)
                            expectEqual(bytes[80], 1) // velocity child depth
                        }
                    }
                }
            }
        }
    }

    func testCompleteSequencesWithoutPosting() throws {
        do {
            for augmented in [false, true] {
                let factory = GestureFactory(augmented: augmented, naturalScrolling: true)
                let events = try factory.events(right: true)
                expectEqual(events.count, augmented ? 6 : 3)
                for event in events {
                    expectEqual(event.getIntegerValueField(.eventSourceUserData), 0x5354494E)
                }
                let dockEvents = events.enumerated().filter { !augmented || $0.offset.isMultiple(of: 2) }.map(\.element)
                expectEqual(dockEvents.map { $0.getIntegerValueField(factory.fieldGesturePhase) }, [1, 2, 4])
                expectTrue(dockEvents.allSatisfy { $0.getIntegerValueField(factory.fieldCGSEventType) == 30 })
                if augmented {
                    for offset in [1, 3, 5] {
                        expectEqual(events[offset].getIntegerValueField(factory.fieldCGSEventType), 29)
                    }
                }
            }
        }
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
private func expectNil<T>(_ actual: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == nil, "Expected nil", file: file, line: line)
}
private func expectTrue(_ actual: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(actual, "Expected true", file: file, line: line)
}
private func requireValue<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { preconditionFailure("Unexpected nil", file: file, line: line) }
    return value
}
