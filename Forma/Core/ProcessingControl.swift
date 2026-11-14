import Foundation

/// A cooperative gate for synchronous processing on a worker thread. Requesting
/// pause is immediate; `paused` is acknowledged only at an actual checkpoint.
final class ProcessingControl: @unchecked Sendable {
    enum Phase: String, Sendable { case running, pauseRequested, paused, cancelled }
    struct Snapshot: Sendable, Equatable {
        var phase: Phase
        var revision: UInt64
        var isPauseActive: Bool { phase == .pauseRequested || phase == .paused }
    }
    enum ControlError: LocalizedError {
        case mainThreadWait
        var errorDescription: String? { "El procesamiento debe pausarse fuera del hilo de la interfaz." }
    }

    private let condition = NSCondition()
    private var state = Snapshot(phase: .running, revision: 0)
    private let onStateChange: (@Sendable (Snapshot) -> Void)?
    @TaskLocal static var current: ProcessingControl?
    /// Optional pacing for CPU-heavy save/export workers; the default remains unrestricted.
    @TaskLocal static var workPacing: (@Sendable () throws -> Void)?

    init(onStateChange: (@Sendable (Snapshot) -> Void)? = nil) { self.onStateChange = onStateChange }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        return state
    }

    @discardableResult func requestPause() -> Snapshot { change { $0 == .running ? .pauseRequested : $0 } }
    @discardableResult func resume() -> Snapshot { change { $0 == .cancelled ? .cancelled : .running } }
    @discardableResult func cancel() -> Snapshot { change { _ in .cancelled } }

    private func change(_ transform: (Phase) -> Phase) -> Snapshot {
        condition.lock()
        let next = transform(state.phase), changed = next != state.phase
        if changed { state.phase = next; state.revision &+= 1 }
        let value = state
        condition.broadcast()
        condition.unlock()
        if changed { onStateChange?(value) }
        return value
    }

    func checkpoint() throws {
        try Task.checkCancellation()
        condition.lock()
        if state.isPauseActive && Thread.isMainThread {
            condition.unlock(); throw ControlError.mainThreadWait
        }
        if state.phase == .pauseRequested {
            state.phase = .paused; state.revision &+= 1
            let acknowledged = state
            condition.unlock()
            onStateChange?(acknowledged)
            condition.lock()
        }
        while state.isPauseActive { condition.wait() }
        let cancelled = state.phase == .cancelled
        condition.unlock()
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    static func checkpoint() throws {
        try workPacing?()
        if let current { try current.checkpoint() }
        else { try Task.checkCancellation() }
    }

    /// nil inherits an enclosing pipeline gate; standalone callers remain unchanged.
    static func withControl<T>(_ control: ProcessingControl?, operation: () throws -> T) rethrows -> T {
        try $current.withValue(control ?? current, operation: operation)
    }
}
