import Foundation
import simd

/// Exposure calibration from matching, visible world points. It never estimates a
/// scene-wide neutral color or white balance: one scalar preserves each RGB hue.
enum PhotometricHarmonizer {
    struct ColorPair {
        var first: SIMD3<Float>
        var second: SIMD3<Float>
        var isValidation: Bool
    }

    struct Link {
        var first: Int
        var second: Int
        var logRatio: Double
        var weight: Double
        var sampleCount: Int
        var validationCount: Int
        // Sufficient statistics evaluate held-out RGB error without keeping all pixels.
        var firstSquared: SIMD3<Double>
        var secondSquared: SIMD3<Double>
        var cross: SIMD3<Double>
        var validationLogSum: Double
        var validationLogSquaredSum: Double

        func squaredError(firstGain: Double, secondGain: Double) -> Double {
            let v = firstSquared * (firstGain * firstGain)
                + secondSquared * (secondGain * secondGain) - cross * (2 * firstGain * secondGain)
            return max(0, v.x + v.y + v.z)
        }

        func logSquaredError(firstGain: Double, secondGain: Double) -> Double {
            let shift = log(firstGain) - log(secondGain)
            return max(0, validationLogSquaredSum + 2 * shift * validationLogSum + Double(validationCount) * shift * shift)
        }
    }

    struct Result {
        var gains: [Int: Double]
        var linkCount: Int
        var sampleCount: Int
        var validationSampleCount: Int
        var adjustedPhotoCount: Int
        /// RMS difference in linear sRGB at held-out, co-visible seam samples.
        var seamRMSEBefore: Double
        var seamRMSEAfter: Double
        var acceptedComponentCount: Int
        var seamLogRMSEBefore: Double
        var seamLogRMSEAfter: Double
        var referenceFrames: [Int]
        var imageDecodeCount: Int = 0
    }

    static func linearSRGB(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func encodedSRGB(_ value: Float) -> Float {
        let v = max(0, value)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private static func luminance(_ value: SIMD3<Float>) -> Double {
        Double(value.x) * 0.2126 + Double(value.y) * 0.7152 + Double(value.z) * 0.0722
    }

    private static func usable(_ color: SIMD3<Float>) -> Bool {
        color.x.isFinite && color.y.isFinite && color.z.isFinite
            && min(color.x, min(color.y, color.z)) > 0.003
            && max(color.x, max(color.y, color.z)) < 0.94
            && luminance(color) > 0.015
    }

    private static func median(_ input: [Double]) -> Double {
        let sorted = input.sorted()
        let n = sorted.count
        return n.isMultiple(of: 2) ? (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5 : sorted[n / 2]
    }

    /// Samples are already visibility-checked by the mesh/depth observer. Dark,
    /// clipped and inconsistent pairs cannot establish a graph constraint.
    static func makeLink(first: Int, second: Int, pairs: [ColorPair]) -> Link? {
        guard first != second else { return nil }
        let valid = pairs.filter { usable($0.first) && usable($0.second) }
        let training = valid.filter { !$0.isValidation }
        guard training.count >= 8 else { return nil }
        let ratios = training.map { log(luminance($0.first) / luminance($0.second)) }
        let center = median(ratios)
        let mad = median(ratios.map { abs($0 - center) })
        // A broad, inconsistent overlap is not reliable exposure evidence.
        guard center.isFinite, mad < 0.15 else { return nil }
        let tolerance = max(0.04, 3 * 1.4826 * mad)
        let inliers = training.filter { abs(log(luminance($0.first) / luminance($0.second)) - center) <= tolerance }
        // Reserved measurements never use the fitted ratio as an acceptance
        // filter. Otherwise a wrong fit could hide its own contradictory pixels.
        let validation = valid.filter { $0.isValidation }
        guard inliers.count >= 8, validation.count >= 3 else { return nil }
        let target = median(inliers.map { log(luminance($0.first) / luminance($0.second)) })
        var aa = SIMD3<Double>.zero, bb = aa, ab = aa
        var logSum = 0.0, logSquared = 0.0
        for pair in validation {
            let a = SIMD3<Double>(Double(pair.first.x), Double(pair.first.y), Double(pair.first.z))
            let b = SIMD3<Double>(Double(pair.second.x), Double(pair.second.y), Double(pair.second.z))
            aa += a * a; bb += b * b; ab += a * b
            let ratio = log(luminance(pair.first) / luminance(pair.second))
            logSum += ratio; logSquared += ratio * ratio
        }
        return Link(first: first, second: second, logRatio: target,
                    weight: Double(inliers.count) / (1 + 100 * mad),
                    sampleCount: inliers.count + validation.count, validationCount: validation.count,
                    firstSquared: aa, secondSquared: bb, cross: ab,
                    validationLogSum: logSum, validationLogSquaredSum: logSquared)
    }

    static func harmonize(frameIndices: [Int], links: [Link], control: ProcessingControl? = nil) throws -> Result {
        try ProcessingControl.withControl(control) { try harmonizeControlled(frameIndices: frameIndices, links: links) }
    }

    private static func harmonizeControlled(frameIndices: [Int], links: [Link]) throws -> Result {
        let ids = frameIndices.sorted()
        var gains = Dictionary(uniqueKeysWithValues: ids.map { ($0, 1.0) })
        let admitted = links.filter { gains[$0.first] != nil && gains[$0.second] != nil }
        var adjacency: [Int: [Int]] = [:]
        for (index, link) in admitted.enumerated() {
            adjacency[link.first, default: []].append(index)
            adjacency[link.second, default: []].append(index)
        }
        var visited = Set<Int>()
        var accepted = 0
        var references: [Int] = []
        for seed in ids where !visited.contains(seed) {
            try ProcessingControl.checkpoint()
            var component = [seed], cursor = 0, edgeIndices = Set<Int>()
            visited.insert(seed)
            while cursor < component.count {
                let node = component[cursor]; cursor += 1
                for index in adjacency[node] ?? [] {
                    edgeIndices.insert(index)
                    let link = admitted[index]
                    let next = link.first == node ? link.second : link.first
                    if visited.insert(next).inserted { component.append(next) }
                }
            }
            guard component.count > 1 else { continue }
            component.sort()
            let edges = edgeIndices.sorted().map { admitted[$0] }
            var logs = try solve(component: component, edges: edges, anchor: component[0])
            // Re-anchor to an actual observed photograph, so every applied gain is
            // <=1. Bright highlight detail cannot be clipped by exposure recovery.
            // There is no global gray/white target or cross-component propagation.
            let anchor = component.max { (logs[$0] ?? 0) < (logs[$1] ?? 0) } ?? component[0]
            if anchor != component[0] { logs = try solve(component: component, edges: edges, anchor: anchor) }
            // Keep this reference exactly unchanged. If inconsistent evidence
            // still requires amplification, reject the component rather than
            // applying an arbitrary darkening shift to all its photographs.
            guard component.allSatisfy({ (logs[$0] ?? 0) <= 0.000001 }) else { continue }
            let candidate = Dictionary(uniqueKeysWithValues: component.map { ($0, exp(min(0, logs[$0] ?? 0))) })
            guard candidate.values.contains(where: { $0 < 1 / 1.015 }) else { continue }
            let before = edges.reduce(0) { $0 + $1.squaredError(firstGain: 1, secondGain: 1) }
            let after = edges.reduce(0) { $0 + $1.squaredError(firstGain: candidate[$1.first] ?? 1,
                                                            secondGain: candidate[$1.second] ?? 1) }
            let channels = Double(edges.reduce(0) { $0 + $1.validationCount } * 3)
            let beforeRMS = sqrt(before / max(1, channels)), afterRMS = sqrt(after / max(1, channels))
            let validationCount = Double(edges.reduce(0) { $0 + $1.validationCount })
            let logBefore = sqrt(edges.reduce(0) { $0 + $1.logSquaredError(firstGain: 1, secondGain: 1) } / max(1, validationCount))
            let logAfter = sqrt(edges.reduce(0) { $0 + $1.logSquaredError(firstGain: candidate[$1.first] ?? 1,
                                                                      secondGain: candidate[$1.second] ?? 1) } / max(1, validationCount))
            // Held-out samples, not the optimization residual, must improve.
            guard afterRMS + max(0.0005, beforeRMS * 0.03) < beforeRMS,
                  logAfter + max(0.001, logBefore * 0.03) < logBefore else { continue }
            for (frame, gain) in candidate { gains[frame] = abs(gain - 1) < 0.000001 ? 1 : gain }
            accepted += 1
            references.append(anchor)
        }
        let channels = Double(admitted.reduce(0) { $0 + $1.validationCount } * 3)
        let before = admitted.reduce(0) { $0 + $1.squaredError(firstGain: 1, secondGain: 1) }
        let after = admitted.reduce(0) { $0 + $1.squaredError(firstGain: gains[$1.first] ?? 1, secondGain: gains[$1.second] ?? 1) }
        let validationCount = Double(admitted.reduce(0) { $0 + $1.validationCount })
        let logBefore = admitted.reduce(0) { $0 + $1.logSquaredError(firstGain: 1, secondGain: 1) }
        let logAfter = admitted.reduce(0) { $0 + $1.logSquaredError(firstGain: gains[$1.first] ?? 1, secondGain: gains[$1.second] ?? 1) }
        return Result(gains: gains, linkCount: admitted.count,
                      sampleCount: admitted.reduce(0) { $0 + $1.sampleCount },
                      validationSampleCount: admitted.reduce(0) { $0 + $1.validationCount },
                      adjustedPhotoCount: gains.values.filter { $0 < 1 - 0.000001 }.count,
                      seamRMSEBefore: sqrt(before / max(1, channels)), seamRMSEAfter: sqrt(after / max(1, channels)),
                      acceptedComponentCount: accepted,
                      seamLogRMSEBefore: sqrt(logBefore / max(1, validationCount)),
                      seamLogRMSEAfter: sqrt(logAfter / max(1, validationCount)), referenceFrames: references)
    }

    /// Sparse, diagonally preconditioned conjugate gradients for the anchored
    /// log-exposure Laplacian, with weak identity regularization on each node.
    private static func solve(component: [Int], edges: [Link], anchor: Int) throws -> [Int: Double] {
        let free = component.filter { $0 != anchor }
        let index = Dictionary(uniqueKeysWithValues: free.enumerated().map { ($0.element, $0.offset) })
        var diagonal = [Double](repeating: 0, count: free.count), rhs = diagonal
        for edge in edges {
            if let i = index[edge.first] { diagonal[i] += edge.weight; rhs[i] -= edge.weight * edge.logRatio }
            if let j = index[edge.second] { diagonal[j] += edge.weight; rhs[j] += edge.weight * edge.logRatio }
        }
        let regularization = diagonal.map { max(0.000001, $0 * 0.002) }
        diagonal = zip(diagonal, regularization).map(+)
        func multiply(_ x: [Double]) -> [Double] {
            var y = zip(x, regularization).map(*)
            for edge in edges {
                let a = index[edge.first].map { x[$0] } ?? 0
                let b = index[edge.second].map { x[$0] } ?? 0
                if let i = index[edge.first] { y[i] += edge.weight * (a - b) }
                if let j = index[edge.second] { y[j] += edge.weight * (b - a) }
            }
            return y
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        var x = [Double](repeating: 0, count: free.count), residual = rhs
        var z = zip(residual, diagonal).map(/), direction = z
        var rz = dot(residual, z)
        let tolerance = max(1e-20, dot(rhs, rhs) * 1e-16)
        for iteration in 0..<max(32, free.count * 4) {
            if iteration & 15 == 0 { try ProcessingControl.checkpoint() }
            if dot(residual, residual) <= tolerance { break }
            let product = multiply(direction), denominator = dot(direction, product)
            guard denominator.isFinite, denominator > 1e-30 else { break }
            let alpha = rz / denominator
            for i in x.indices { x[i] += alpha * direction[i]; residual[i] -= alpha * product[i] }
            z = zip(residual, diagonal).map(/)
            let nextRZ = dot(residual, z), beta = nextRZ / max(1e-30, rz)
            for i in direction.indices { direction[i] = z[i] + beta * direction[i] }
            rz = nextRZ
        }
        var result = Dictionary(uniqueKeysWithValues: zip(free, x))
        result[anchor] = 0
        return result
    }
}
