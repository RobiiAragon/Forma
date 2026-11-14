import Foundation

/// Cooperative pacing between native inference/processing blocks. A 50% duty
/// cycle is elapsed work followed by comparable rest, not a Core ML utilization
/// setting. An in-flight GPU prediction cannot be preempted by this policy.
/// Own one policy per serial worker/job and call it only outside the main thread.
final class MobileProcessingPolicy: @unchecked Sendable {
    enum Mode: Sendable { case adaptive, continuous }
    enum Platform: Sendable {
        case mobile, desktop
        static var current: Self {
            #if os(iOS)
            return .mobile
            #else
            return .desktop
            #endif
        }
    }

    enum ThermalLevel: String, Sendable {
        case nominal, fair, serious, critical
        var activeFraction: Double {
            switch self {
            case .nominal: return 0.5
            case .fair: return 0.35
            case .serious: return 0.2
            case .critical: return 0
            }
        }
        static var current: Self {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return .nominal
            case .fair: return .fair
            case .serious: return .serious
            case .critical: return .critical
            @unknown default: return .serious
            }
        }
    }

    enum Phase: String, Sendable { case working, resting, cooling, disabled }

    struct Snapshot: Sendable, Equatable {
        var phase: Phase
        var thermalLevel: ThermalLevel
        var targetActiveFraction: Double
        /// Elapsed processing between checkpoints, not CPU/GPU hardware usage.
        var measuredWorkSeconds: Double = 0
        /// Includes user pause and thermal cooling: both already provide rest.
        var restSeconds: Double = 0
        var checkpointCount = 0
    }

    private let platform: Platform
    private let mode: Mode
    private let now: @Sendable () -> TimeInterval
    private let wait: @Sendable (TimeInterval) -> Void
    private let thermal: @Sendable () -> ThermalLevel
    private let isMainThread: @Sendable () -> Bool
    private let onStateChange: (@Sendable (Snapshot) -> Void)?
    private let stateLock = NSLock()
    private let executionLock = NSLock()
    private var state: Snapshot
    private var workStartedAt: TimeInterval
    private var observedPauseStartedAt: TimeInterval?
    private var observedPauseSeconds = 0.0
    private var observedControlRevision: UInt64?
    private var pauseWhenWorkStarted = 0.0
    private var pendingReset: (time: TimeInterval, pause: TimeInterval)?
    private let quantum: TimeInterval = 0.05

    convenience init(platform: Platform = .current, mode: Mode = .adaptive,
                     onStateChange: (@Sendable (Snapshot) -> Void)? = nil) {
        self.init(platform: platform, mode: mode,
                  now: { ProcessInfo.processInfo.systemUptime },
                  wait: { Thread.sleep(forTimeInterval: $0) },
                  thermal: { ThermalLevel.current },
                  isMainThread: { Thread.isMainThread },
                  onStateChange: onStateChange)
    }

    /// Injectable timing is for deterministic policy tests; production uses the
    /// monotonic uptime clock, Foundation thermal state, and relative waits.
    init(platform: Platform, mode: Mode = .adaptive,
         now: @escaping @Sendable () -> TimeInterval,
         wait: @escaping @Sendable (TimeInterval) -> Void,
         thermal: @escaping @Sendable () -> ThermalLevel,
         isMainThread: @escaping @Sendable () -> Bool,
         onStateChange: (@Sendable (Snapshot) -> Void)? = nil) {
        self.platform = platform; self.mode = mode; self.now = now; self.wait = wait
        self.thermal = thermal; self.isMainThread = isMainThread
        self.onStateChange = onStateChange
        workStartedAt = now()
        let level: ThermalLevel = platform == .desktop ? .nominal : thermal()
        let paced = platform == .mobile && mode == .adaptive
        state = Snapshot(phase: paced ? .working : .disabled,
                         thermalLevel: level,
                         targetActiveFraction: paced ? level.activeFraction : 1)
    }

    var snapshot: Snapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return state
    }

    /// Check cancellation/pause before every wait and at most 50ms apart while
    /// resting/cooling. The caller's gate also wakes cancellation while paused.
    /// Explicitly passing a control avoids changing global checkpoint behavior.
    func checkpoint(control: ProcessingControl? = nil,
                    additionalCheck: (@Sendable () throws -> Void)? = nil) throws {
        guard platform == .mobile else {
            try check(control)
            try additionalCheck?()
            return
        }
        guard !isMainThread() else { throw ProcessingControl.ControlError.mainThreadWait }
        executionLock.lock(); defer { executionLock.unlock() }
        let restStartedAt = now()
        stateLock.lock()
        if let reset = pendingReset {
            if reset.time > workStartedAt {
                workStartedAt = reset.time; pauseWhenWorkStarted = reset.pause
            }
            pendingReset = nil
        }
        let pausedDuringWork = max(0, observedPauseTotal(at: restStartedAt) - pauseWhenWorkStarted)
        stateLock.unlock()
        let work = max(0, finiteElapsed(from: workStartedAt, to: restStartedAt) - pausedDuringWork)
        update { $0.measuredWorkSeconds += work; $0.checkpointCount += 1 }
        defer {
            let finished = now()
            update { $0.restSeconds += pausedDuringWork + finiteElapsed(from: restStartedAt, to: finished) }
            stateLock.lock()
            pauseWhenWorkStarted = observedPauseTotal(at: finished)
            stateLock.unlock()
            workStartedAt = finished
        }

        while true {
            // Time spent paused belongs to rest. Capturing work before this gate
            // prevents a long user pause becoming a new work/rest debt.
            try check(control)
            try additionalCheck?()
            let level = thermal()
            let elapsedRest = pausedDuringWork + finiteElapsed(from: restStartedAt, to: now())
            // Continuous training observes the OS state but never adds a
            // thermal wait or reduces its requested activity fraction.
            let fraction = mode == .continuous ? 1 : level.activeFraction
            if fraction == 0 {
                update {
                    $0.phase = .cooling; $0.thermalLevel = level; $0.targetActiveFraction = 0
                }
                wait(quantum)
                continue
            }
            let requiredRest = work * (1 / fraction - 1)
            let remaining = requiredRest - elapsedRest
            guard remaining > 0.000_001 else {
                update {
                    $0.phase = .working; $0.thermalLevel = level; $0.targetActiveFraction = fraction
                }
                // Honor cancellation requested by a callback at the boundary too.
                try check(control)
                try additionalCheck?()
                return
            }
            update {
                $0.phase = .resting; $0.thermalLevel = level; $0.targetActiveFraction = fraction
            }
            wait(min(quantum, remaining))
        }
    }

    /// A controller resuming a suspended job may reset the elapsed-work origin.
    /// OS suspension is not measured processing; accumulated metrics stay intact.
    func resetWorkClock() {
        let time = now()
        stateLock.lock(); defer { stateLock.unlock() }
        pendingReset = (time, observedPauseTotal(at: time))
    }

    /// Connect directly to ProcessingControl.onStateChange before hopping to UI.
    /// This also excludes pauses inside other checkpoints between pacing calls.
    /// Pause-requested is still work; only acknowledged paused time is credited.
    func observeControlState(_ snapshot: ProcessingControl.Snapshot) {
        let time = now()
        stateLock.lock(); defer { stateLock.unlock() }
        if let previous = observedControlRevision, snapshot.revision <= previous { return }
        observedControlRevision = snapshot.revision
        if snapshot.phase == .paused {
            if observedPauseStartedAt == nil { observedPauseStartedAt = time }
        } else if let started = observedPauseStartedAt {
            observedPauseSeconds += finiteElapsed(from: started, to: time)
            observedPauseStartedAt = nil
        }
    }

    /// Call under stateLock.
    private func observedPauseTotal(at time: TimeInterval) -> TimeInterval {
        observedPauseSeconds + (observedPauseStartedAt.map { finiteElapsed(from: $0, to: time) } ?? 0)
    }

    private func check(_ control: ProcessingControl?) throws {
        if let control { try control.checkpoint() }
        else { try Task.checkCancellation() }
    }

    private func finiteElapsed(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        guard start.isFinite, end.isFinite else { return 0 }
        return max(0, end - start)
    }

    private func update(_ mutate: (inout Snapshot) -> Void) {
        stateLock.lock()
        let previous = state
        mutate(&state)
        let value = state
        let changed = previous.phase != value.phase || previous.thermalLevel != value.thermalLevel
        stateLock.unlock()
        // Never call UI/controller callbacks under the state lock.
        if changed { onStateChange?(value) }
    }
}
