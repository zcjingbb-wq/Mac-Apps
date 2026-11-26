@MainActor
final class DwellActivation {
    static let delay: Duration = .seconds(2)

    private let sleep: @Sendable (Duration) async throws -> Void
    private var pointerInside = false
    private var pending: Task<Void, Never>?

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    @discardableResult
    func pointerEntered(action: @escaping @MainActor () -> Void) -> Bool {
        guard !pointerInside else { return false }
        pointerInside = true
        pending = Task { [weak self, sleep] in
            do { try await sleep(Self.delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            action()
        }
        return true
    }

    func pointerExited() {
        pointerInside = false
        cancel()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
