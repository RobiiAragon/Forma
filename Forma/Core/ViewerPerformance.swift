import Foundation
import QuartzCore

enum ViewerFrameSource: String, Sendable {
    case sceneKitRender, metalPresentation
    var title: String { self == .sceneKitRender ? "Cadencia de render" : "Cadencia de presentación" }
}

struct ViewerPerformanceSnapshot: Equatable, Sendable {
    var source: ViewerFrameSource
    var loadSeconds: TimeInterval?
    var preparationSeconds: TimeInterval?
    var readySeconds: TimeInterval?
    var frameCount = 0
    var framesPerSecond: Double?
    var lastFrameTime: TimeInterval?

    /// An idle viewport has no current FPS measurement. UI timers may refresh
    /// this state but never add to frameCount or manufacture frame timestamps.
    func activeFramesPerSecond(at time: TimeInterval) -> Double? {
        guard let lastFrameTime,time-lastFrameTime <= 0.75 else { return nil }
        return framesPerSecond
    }
}

/// Counts actual renderer/presentation callbacks, independent of display-link
/// ticks. Callback delivery is throttled; every observed frame is still counted.
final class ViewerPerformanceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt: TimeInterval
    private var state: ViewerPerformanceSnapshot
    private var timestamps: [TimeInterval] = []
    private var lastPublished: TimeInterval = -.greatestFiniteMagnitude

    init(source: ViewerFrameSource,startedAt: TimeInterval = CACurrentMediaTime()) {
        self.startedAt = startedAt
        state = ViewerPerformanceSnapshot(source: source)
    }

    func loaded(loadSeconds: TimeInterval,preparationSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        state.loadSeconds = max(0,loadSeconds)
        state.preparationSeconds = max(0,preparationSeconds)
    }

    func snapshot() -> ViewerPerformanceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func frame(at time: TimeInterval) -> ViewerPerformanceSnapshot? {
        guard time.isFinite,time > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let previous = state.lastFrameTime {
            guard time > previous else { return nil }
            if time-previous > 0.35 { timestamps.removeAll(keepingCapacity: true) }
        }
        state.frameCount += 1
        state.lastFrameTime = time
        if state.readySeconds == nil { state.readySeconds = max(0,time-startedAt) }
        timestamps.append(time)
        let expired = timestamps.prefix(while: { time-$0 > 1 }).count
        if expired > 0 { timestamps.removeFirst(expired) }
        if timestamps.count >= 3,let first = timestamps.first,time-first >= 0.15 {
            state.framesPerSecond = Double(timestamps.count-1)/(time-first)
        } else { state.framesPerSecond = nil }
        guard state.frameCount == 1 || time-lastPublished >= 0.25 else { return nil }
        lastPublished = time
        return state
    }
}
