import Foundation

private enum DwellTestFailure: Error { case failed(String) }

@MainActor
private final class ManualDwellSleep {
    private(set) var requestedDelays: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(for delay: Duration) async {
        await withCheckedContinuation { continuation in
            pending[requestedDelays.count] = continuation
            requestedDelays.append(delay)
        }
    }

    // Deliberately resume canceled waits to exercise late completions.
    func finish(_ request: Int) { pending.removeValue(forKey: request)?.resume() }

    func finishAll() {
        for request in Array(pending.keys) { finish(request) }
    }
}

@main
struct DwellActivationTests {
    @MainActor
    static func main() async throws {
        let clock = ManualDwellSleep()
        defer { clock.finishAll() }
        let dwell = DwellActivation(sleep: { await clock.sleep(for: $0) })
        var actions: [String] = []

        dwell.pointerEntered { actions.append("first") }
        try await waitUntil("First dwell starts") { clock.requestedDelays.count == 1 }
        try require(clock.requestedDelays == [.seconds(2)], "Dwell waits two seconds")
        try require(actions.isEmpty, "Entering does not immediately activate")
        dwell.pointerEntered { actions.append("duplicate") }
        await settle()
        try require(clock.requestedDelays.count == 1, "Duplicate enter keeps the pending dwell")
        clock.finish(0)
        try await waitUntil("First dwell finishes") { !actions.isEmpty }
        try require(actions == ["first"], "Completed dwell fires the original action once")
        dwell.pointerEntered { actions.append("repeated") }
        await settle()
        try require(clock.requestedDelays.count == 1, "A stationary pointer cannot trigger another dwell")

        dwell.pointerExited()
        dwell.pointerEntered { actions.append("left too soon") }
        try await waitUntil("Second dwell starts") { clock.requestedDelays.count == 2 }
        dwell.pointerExited()
        dwell.pointerEntered { actions.append("re-entered") }
        try await waitUntil("Re-entered dwell starts") { clock.requestedDelays.count == 3 }
        clock.finish(1)
        await settle()
        try require(actions == ["first"], "A late completion after exiting cannot fire")
        clock.finish(2)
        try await waitUntil("Re-entered dwell finishes") { actions.count >= 2 }
        try require(actions == ["first", "re-entered"], "Re-entering starts a fresh dwell")

        dwell.pointerExited()
        dwell.pointerEntered { actions.append("followed a click") }
        try await waitUntil("Dwell before click starts") { clock.requestedDelays.count == 4 }
        dwell.cancel()
        dwell.pointerEntered { actions.append("rearmed after click") }
        clock.finish(3)
        await settle()
        try require(clock.requestedDelays.count == 4, "A click cancels without rearming while the pointer remains")
        try require(actions == ["first", "re-entered"], "The canceled dwell cannot repeat a click")

        dwell.pointerExited()
        dwell.pointerEntered { actions.append("after click and exit") }
        try await waitUntil("Dwell after leaving starts") { clock.requestedDelays.count == 5 }
        clock.finish(4)
        try await waitUntil("Dwell after leaving finishes") { actions.count >= 3 }
        try require(actions == ["first", "re-entered", "after click and exit"], "Leaving after a click permits the next dwell")
        print("PASS: two-second dwell, single activation, exit and click cancellation, and stale async completions")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DwellTestFailure.failed(message) }
    }

    @MainActor
    private static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { throw DwellTestFailure.failed(message) }
            await Task.yield()
        }
    }

    @MainActor
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
