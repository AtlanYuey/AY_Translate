import XCTest
@testable import ScreenTranslationCore

final class SerialWorkGateTests: XCTestCase {
    private actor Hold {
        var continuation: CheckedContinuation<Void, Never>?
        var started = false
        var events: [Int] = []
        func block() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(); continuation = nil }
        func record(_ value: Int) { events.append(value) }
    }

    func testCancelledActiveFrameworkWorkKeepsPermitUntilItActuallyReturns() async throws {
        let gate = SerialWorkGate(), hold = Hold()
        let first = Task { try await gate.run { await hold.record(1); await hold.block(); await hold.record(2) } }
        while !(await hold.started) { await Task.yield() }
        let second = Task { try await gate.run { await hold.record(3) } }
        first.cancel()
        try await Task.sleep(for: .milliseconds(30))
        let during = await hold.events
        XCTAssertEqual(during, [1], "A cancelled but still running Vision request must not overlap its successor")
        await hold.finish()
        _ = try? await first.value
        try await second.value
        let after = await hold.events
        XCTAssertEqual(after, [1, 2, 3])
    }

    func testCancelledQueuedRequestCannotStartOrBlockLaterWork() async throws {
        let gate = SerialWorkGate(), hold = Hold()
        let first = Task { try await gate.run { await hold.block() } }
        while !(await hold.started) { await Task.yield() }
        let cancelled = Task { try await gate.run { await hold.record(99) } }
        try await Task.sleep(for: .milliseconds(20))
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled work should throw") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let third = Task { try await gate.run { await hold.record(3) } }
        await hold.finish()
        try await first.value; try await third.value
        let values = await hold.events
        XCTAssertEqual(values, [3])
    }
}
