import Foundation

/// One resident native engine per process. Pending jobs keep their intent and
/// configuration; this is resource arbitration, rather than a user pause.
final class GaussianEngineGate: @unchecked Sendable {
    static let shared = GaussianEngineGate()

    final class Ticket: @unchecked Sendable {
        fileprivate let id = UUID()
        let jobID: UUID
        fileprivate let canRun: @Sendable () -> Bool
        fileprivate var continuation: CheckedContinuation<Lease?, Never>?
        fileprivate var consumed = false
        fileprivate var withdrawn = false
        fileprivate weak var gate: GaussianEngineGate?
        fileprivate init(jobID: UUID, canRun: @escaping @Sendable () -> Bool) {
            self.jobID = jobID; self.canRun = canRun
        }
    }
    final class Lease: @unchecked Sendable {
        let jobID: UUID
        private let id: UUID
        private weak var gate: GaussianEngineGate?
        private let lock = NSLock()
        private var released = false
        fileprivate init(ticket: Ticket, gate: GaussianEngineGate) {
            jobID = ticket.jobID; id = ticket.id; self.gate = gate
        }
        /// Call only after destroying the native handle. Safe from any thread.
        func release() {
            lock.lock()
            guard !released else { lock.unlock(); return }
            released = true; let gate = gate
            lock.unlock()
            gate?.release(id: id)
        }
        deinit { release() }
    }
    private let lock = NSLock()
    private var owner: UUID?
    private var queue: [Ticket] = []
    private typealias Delivery = (CheckedContinuation<Lease?, Never>, Lease?)

    /// Register synchronously when the user/recovery requests work, so scheduling
    /// of detached workers cannot change the requested FIFO order.
    func enqueue(jobID: UUID, canRun: @escaping @Sendable () -> Bool) -> Ticket {
        let ticket = Ticket(jobID: jobID, canRun: canRun)
        ticket.gate = self
        lock.lock(); queue.append(ticket); lock.unlock()
        return ticket
    }
    func acquire(_ ticket: Ticket) async -> Lease? {
        guard ticket.gate === self else { return nil }
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled { withdraw(ticket); return nil }
            let lease: Lease? = await withCheckedContinuation { continuation in
                lock.lock()
                guard !ticket.consumed, !ticket.withdrawn else {
                    lock.unlock(); continuation.resume(returning: nil); return
                }
                ticket.consumed = true; ticket.continuation = continuation
                let deliveries = drainLocked()
                lock.unlock(); deliver(deliveries)
            }
            if Task.isCancelled { lease?.release(); return nil }
            return lease
        }, onCancel: { self.withdraw(ticket) })
    }
    /// A manual pause/cancellation or loss of OS eligibility withdraws pending
    /// admission. An already resident engine keeps its lease until destruction.
    func interrupt(jobID: UUID) {
        lock.lock()
        var deliveries: [Delivery] = []
        queue.removeAll { ticket in
            guard ticket.jobID == jobID else { return false }
            ticket.withdrawn = true
            if let continuation = ticket.continuation { deliveries.append((continuation, nil)); ticket.continuation = nil }
            return true
        }
        deliveries.append(contentsOf: drainLocked())
        lock.unlock(); deliver(deliveries)
    }
    func withdraw(_ ticket: Ticket) {
        guard ticket.gate === self else { return }
        lock.lock()
        ticket.withdrawn = true
        queue.removeAll { $0.id == ticket.id }
        var deliveries: [Delivery] = []
        if let continuation = ticket.continuation { deliveries.append((continuation, nil)); ticket.continuation = nil }
        deliveries.append(contentsOf: drainLocked())
        lock.unlock(); deliver(deliveries)
    }
    private func release(id: UUID) {
        lock.lock()
        guard owner == id else { lock.unlock(); return }
        owner = nil
        let deliveries = drainLocked()
        lock.unlock(); deliver(deliveries)
    }
    private func drainLocked() -> [Delivery] {
        guard owner == nil else { return [] }
        var deliveries: [Delivery] = []
        while let ticket = queue.first {
            // A registered request owns its place before its worker reaches the
            // gate. Interruption removes unstarted requests too.
            guard let continuation = ticket.continuation else { break }
            queue.removeFirst(); ticket.continuation = nil
            if ticket.withdrawn || !ticket.canRun() {
                ticket.withdrawn = true; deliveries.append((continuation, nil)); continue
            }
            owner = ticket.id
            deliveries.append((continuation, Lease(ticket: ticket, gate: self)))
            break
        }
        return deliveries
    }
    private func deliver(_ deliveries: [Delivery]) {
        for (continuation, lease) in deliveries { continuation.resume(returning: lease) }
    }
}
