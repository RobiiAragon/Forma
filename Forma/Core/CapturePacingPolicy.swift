import Foundation

enum CapturePacingPolicy {
    static let phonePreviewFPS = 5
    static let meshPreviewFPS = 5
    static let automaticKeyframeEvaluationFPS = 5
    static let maximumSavedStreamFPS = 5

    static var meshPreviewInterval: TimeInterval { 1 / Double(meshPreviewFPS) }
    static var automaticKeyframeEvaluationInterval: TimeInterval { 1 / Double(automaticKeyframeEvaluationFPS) }

    /// Backpressure can slow acquisition further; startup and a fast writer must
    /// still obey the requested cadence without reducing a saved image's raster.
    static func savedStreamInterval(meanCommitSeconds: TimeInterval) -> TimeInterval {
        let minimum = 1 / Double(maximumSavedStreamFPS)
        guard meanCommitSeconds.isFinite, meanCommitSeconds > 0 else { return minimum }
        return max(minimum, min(0.45, meanCommitSeconds * 1.2))
    }

    /// ARFrame timestamps and uptime are monotonic. Invalid or regressing samples
    /// do not consume a slot. The tolerance only absorbs floating-point rounding
    /// at an exact interval boundary, not a fraction of a camera frame.
    static func hasElapsed(_ interval: TimeInterval, since previous: TimeInterval?, at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, interval.isFinite, interval > 0 else { return false }
        guard let previous else { return true }
        guard previous.isFinite, timestamp > previous else { return false }
        let tolerance = max(timestamp.ulp, previous.ulp) * 4
        return timestamp - previous + tolerance >= interval
    }

    struct Format: Sendable {
        var framesPerSecond: Int
        var width: Int
        var height: Int
        var supportsHighResolution: Bool = false
    }

    /// ARKit formats are immutable. Use its actual lowest supported sensor rate;
    /// the application's 5 FPS processing target does not relabel a 24/30 FPS sensor.
    static func preferredFormatIndex(_ formats: [Format], maximumQuality: Bool) -> Int? {
        let valid = formats.indices.filter {
            formats[$0].framesPerSecond > 0 && formats[$0].width > 0 && formats[$0].height > 0
        }
        guard let minimum = valid.map({ formats[$0].framesPerSecond }).min() else { return nil }
        let eligible = valid.filter { formats[$0].framesPerSecond == minimum }
        return eligible.max {
            let a = formats[$0], b = formats[$1]
            let aa = Int64(a.width) * Int64(a.height), ba = Int64(b.width) * Int64(b.height)
            if aa != ba { return maximumQuality ? aa < ba : aa > ba }
            if a.supportsHighResolution != b.supportsHighResolution { return !a.supportsHighResolution }
            return a.framesPerSecond > b.framesPerSecond
        }
    }
}
