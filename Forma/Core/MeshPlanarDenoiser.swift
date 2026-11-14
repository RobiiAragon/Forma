import Foundation
import simd

/// Opt-in geometric filtering for meter-based meshes. Works on a value copy and
/// preserves every index and vertex. A plane is a hypothesis, not evidence that
/// a surface was actually flat: structured residuals reject the entire region.
enum MeshPlanarDenoiser {
    struct Configuration: Codable, Sendable {
        var enabled = false
        /// Maximum source-to-plane distance AND maximum allowed displacement.
        var toleranceMeters: Double = 0.003
        var minimumRegionAreaSquareMeters: Double = 0.25
        var minimumRegionExtentMeters: Double = 0.4
        var minimumRegionVertices = 80
        var maximumNormalAngleDegrees: Double = 12
        /// Fraction of residual variance allowed in coherent spatial structure.
        var maximumStructuredResidualRatio: Double = 0.20
    }

    struct Metrics: Codable, Sendable {
        var toleranceMeters: Double
        var candidateRegions = 0
        var acceptedRegions = 0
        var planeSupportVertices = 0
        var movedVertices = 0
        var planeDeviationBeforeRMSMeters: Double = 0
        var planeDeviationAfterRMSMeters: Double = 0
        var maxDisplacementMeters: Double = 0
        var processingSeconds: Double = 0
        var statistics: [String: Double] {
            ["planarToleranceMeters": toleranceMeters,
             "planarCandidateRegions": Double(candidateRegions),
             "planarAcceptedRegions": Double(acceptedRegions),
             "planarSupportVertices": Double(planeSupportVertices),
             "planarMovedVertices": Double(movedVertices),
             "planarDeviationBeforeRMSMeters": planeDeviationBeforeRMSMeters,
             "planarDeviationAfterRMSMeters": planeDeviationAfterRMSMeters,
             "planarMaxDisplacementMeters": maxDisplacementMeters,
             "planarProcessingSeconds": processingSeconds]
        }
    }
    struct Result: Sendable { var mesh: MeshSnapshot; var metrics: Metrics }
    enum ProcessingError: Error { case invalidConfiguration, invalidMesh }
    private struct Edge: Hashable {
        let a: Int; let b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }
    private struct Face { var indices: [Int]; var normal: SIMD3<Double>; var area: Double }

    static func process(_ mesh: MeshSnapshot, configuration: Configuration = .init(),
                        control: ProcessingControl? = nil) throws -> Result {
        try ProcessingControl.withControl(control) {
            try run(mesh, configuration)
        }
    }

    private static func run(_ mesh: MeshSnapshot, _ config: Configuration) throws -> Result {
        let start = ProcessInfo.processInfo.systemUptime
        try ProcessingControl.checkpoint()
        guard config.toleranceMeters.isFinite, config.toleranceMeters > 0,
              config.minimumRegionAreaSquareMeters.isFinite, config.minimumRegionAreaSquareMeters > 0,
              config.minimumRegionExtentMeters.isFinite, config.minimumRegionExtentMeters > 0,
              config.minimumRegionVertices >= 16,
              config.maximumNormalAngleDegrees.isFinite, config.maximumNormalAngleDegrees > 0,
              config.maximumNormalAngleDegrees <= 20,
              config.maximumStructuredResidualRatio.isFinite,
              config.maximumStructuredResidualRatio >= 0, config.maximumStructuredResidualRatio <= 0.3
        else { throw ProcessingError.invalidConfiguration }
        guard mesh.triangles.count.isMultiple(of: 3),
              mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        else { throw ProcessingError.invalidMesh }
        var metrics = Metrics(toleranceMeters: config.toleranceMeters)
        // Disabled is the default: no Double point copy or mesh adjacency allocation.
        guard config.enabled else {
            metrics.processingSeconds = ProcessInfo.processInfo.systemUptime - start
            return Result(mesh: mesh, metrics: metrics)
        }
        var output = mesh
        var faces: [Face] = []
        var edges: [Edge: [Int]] = [:]
        var incident = Array(repeating: [Int](), count: mesh.vertices.count)
        let points = mesh.vertices.map { SIMD3<Double>($0) }
        for f in 0..<mesh.faceCount {
            if f.isMultiple(of: 1024) { try ProcessingControl.checkpoint() }
            let ids = (0..<3).map { Int(mesh.triangles[f * 3 + $0]) }
            guard ids.allSatisfy({ $0 < points.count }), Set(ids).count == 3 else {
                throw ProcessingError.invalidMesh
            }
            let cross = simd_cross(points[ids[1]] - points[ids[0]], points[ids[2]] - points[ids[0]])
            let length = simd_length(cross)
            guard length.isFinite, length > 1e-16 else { throw ProcessingError.invalidMesh }
            faces.append(Face(indices: ids, normal: cross / length, area: length / 2))
            for i in 0..<3 {
                incident[ids[i]].append(f)
                edges[Edge(ids[i], ids[(i + 1) % 3]), default: []].append(f)
            }
        }
        let cosine = cos(config.maximumNormalAngleDegrees * .pi / 180)
        var neighbors = Array(repeating: [Int](), count: faces.count)
        var protected = Set<Int>()
        for (edge, fs) in edges {
            if fs.count == 2 && simd_dot(faces[fs[0]].normal, faces[fs[1]].normal) >= cosine {
                neighbors[fs[0]].append(fs[1]); neighbors[fs[1]].append(fs[0])
            } else {
                // Mesh boundaries, nonmanifold edges, orientation seams and sharp edges.
                protected.insert(edge.a); protected.insert(edge.b)
            }
        }
        // A full additional ring holds the transition to retained geometry fixed.
        var locked = protected
        for v in protected {
            for f in incident[v] { locked.formUnion(faces[f].indices) }
        }
        var visited = Array(repeating: false, count: faces.count)
        var beforeSquared = 0.0, afterSquared = 0.0
        for seed in faces.indices where !visited[seed] {
            try ProcessingControl.checkpoint()
            var region = [seed]; visited[seed] = true
            var cursor = 0
            while cursor < region.count {
                if cursor.isMultiple(of: 1024) { try ProcessingControl.checkpoint() }
                for next in neighbors[region[cursor]] where !visited[next] {
                    visited[next] = true; region.append(next)
                }
                cursor += 1
            }
            metrics.candidateRegions += 1
            let ids = Set(region.flatMap { faces[$0].indices }).sorted()
            guard ids.count >= config.minimumRegionVertices,
                  region.reduce(0.0, { $0 + faces[$1].area }) >= config.minimumRegionAreaSquareMeters
            else { continue }
            let center = ids.reduce(SIMD3<Double>.zero) { $0 + points[$1] } / Double(ids.count)
            let basis = try principalAxes(ids.map { points[$0] - center })
            let normal = basis[0], u = basis[1], v = basis[2]
            guard region.allSatisfy({ abs(simd_dot(faces[$0].normal, normal)) >= cosine }) else { continue }
            let uv = ids.map { SIMD2(simd_dot(points[$0] - center, u), simd_dot(points[$0] - center, v)) }
            let lo = uv.reduce(SIMD2<Double>(repeating: .infinity), simd_min)
            let hi = uv.reduce(SIMD2<Double>(repeating: -.infinity), simd_max)
            guard hi.x - lo.x >= config.minimumRegionExtentMeters,
                  hi.y - lo.y >= config.minimumRegionExtentMeters else { continue }
            let distances = ids.map { simd_dot(points[$0] - center, normal) }
            guard distances.allSatisfy({ abs($0) <= config.toleranceMeters }) else { continue }
            let sumSquared = distances.reduce(0) { $0 + $1 * $1 }
            let rms = sqrt(sumSquared / Double(ids.count))
            // An already planar region requires no edit. Numerically tiny residuals
            // do not provide meaningful evidence to distinguish texture from detail.
            guard rms > 1e-7 else { continue }
            guard try !hasStructuredResidual(ids: ids, distances: distances,
                                         incident: incident, faces: faces, uv: uv, lo: lo, hi: hi,
                                         rms: rms, maximumRatio: config.maximumStructuredResidualRatio)
            else { continue }
            // Isolated residual peaks may be small real features. Retain the peak
            // and its immediate neighbors even when the rest looks stochastic.
            var detailLocked = Set<Int>()
            for (offset, id) in ids.enumerated() where abs(distances[offset]) > 2.5 * rms {
                detailLocked.insert(id)
                for f in incident[id] { detailLocked.formUnion(faces[f].indices) }
            }
            var proposals: [Int: SIMD3<Float>] = [:]
            for (offset, id) in ids.enumerated() where !locked.contains(id) && !detailLocked.contains(id) {
                // Shared vertices belonging to another region are always retained.
                guard incident[id].allSatisfy({ abs(simd_dot(faces[$0].normal, normal)) >= cosine }) else { continue }
                let candidate = SIMD3<Float>(points[id] - distances[offset] * normal)
                let displacement = simd_length(SIMD3<Double>(candidate) - points[id])
                if displacement <= config.toleranceMeters { proposals[id] = candidate }
            }
            guard !proposals.isEmpty else { continue }
            // Validate simultaneous movement, including neighboring retained faces.
            // Rejection is atomic for this region; never accept partially invalid geometry.
            let affected = Set(proposals.keys.flatMap { incident[$0] })
            let valid = affected.allSatisfy { f in
                let p = faces[f].indices.map { SIMD3<Double>(proposals[$0] ?? output.vertices[$0]) }
                let cross = simd_cross(p[1] - p[0], p[2] - p[0])
                let areaRatio = simd_length(cross) / (2 * faces[f].area)
                return areaRatio >= 0.5 && areaRatio <= 2 &&
                    simd_dot(cross, faces[f].normal) > 0 &&
                    simd_dot(simd_normalize(cross), faces[f].normal) >= cosine
            }
            guard valid else { continue }
            metrics.acceptedRegions += 1
            metrics.planeSupportVertices += ids.count
            beforeSquared += sumSquared
            for (id, candidate) in proposals {
                metrics.maxDisplacementMeters = max(metrics.maxDisplacementMeters,
                                                    simd_length(SIMD3<Double>(candidate) - points[id]))
                output.vertices[id] = candidate
                metrics.movedVertices += 1
            }
            for id in ids {
                let d = simd_dot(SIMD3<Double>(output.vertices[id]) - center, normal)
                afterSquared += d * d
            }
        }
        if metrics.planeSupportVertices > 0 {
            metrics.planeDeviationBeforeRMSMeters = sqrt(beforeSquared / Double(metrics.planeSupportVertices))
            metrics.planeDeviationAfterRMSMeters = sqrt(afterSquared / Double(metrics.planeSupportVertices))
        }
        try ProcessingControl.checkpoint()
        metrics.processingSeconds = ProcessInfo.processInfo.systemUptime - start
        return Result(mesh: output, metrics: metrics)
    }

    /// Both local smoothness and coarse spatial structure count against flattening.
    /// This intentionally rejects many ambiguous surfaces, including shallow relief.
    private static func hasStructuredResidual(ids: [Int], distances: [Double],
                                              incident: [[Int]], faces: [Face], uv: [SIMD2<Double>],
                                              lo: SIMD2<Double>, hi: SIMD2<Double>, rms: Double,
                                              maximumRatio: Double) throws -> Bool {
        let residual = Dictionary(uniqueKeysWithValues: zip(ids, distances))
        var numerator = 0.0, denominator = 0.0
        for (i, id) in ids.enumerated() {
            if i.isMultiple(of: 1024) { try ProcessingControl.checkpoint() }
            let adjacent = Set(incident[id].flatMap { faces[$0].indices }).subtracting([id])
            let values = adjacent.compactMap { residual[$0] }
            guard !values.isEmpty else { continue }
            let mean = values.reduce(0, +) / Double(values.count)
            numerator += distances[i] * mean
            denominator += distances[i] * distances[i]
        }
        if denominator > 0 && numerator / denominator > maximumRatio { return true }
        // Multi-scale bins catch bends, steps, separated depth layers and smooth
        // relief even if high-frequency reconstruction noise masks local correlation.
        for dimension in [2, 4] {
            var sums = Array(repeating: 0.0, count: dimension * dimension)
            var counts = Array(repeating: 0, count: sums.count)
            for i in ids.indices {
                let t = (uv[i] - lo) / (hi - lo)
                let x = min(dimension - 1, max(0, Int(t.x * Double(dimension))))
                let y = min(dimension - 1, max(0, Int(t.y * Double(dimension))))
                sums[y * dimension + x] += distances[i]; counts[y * dimension + x] += 1
            }
            for j in sums.indices where counts[j] >= 8 {
                if abs(sums[j] / Double(counts[j])) > rms * sqrt(maximumRatio) { return true }
            }
        }
        // A two-layer residual distribution has a large central gap. Keep both.
        let sorted = distances.sorted()
        let middle = sorted.count / 2
        if sorted[middle] - sorted[middle - 1] > rms * 0.5 { return true }
        return false
    }

    /// Symmetric 3x3 Jacobi eigensolver, ordered from least to greatest variance.
    /// Coordinates are centered in Double before accumulating the covariance.
    private static func principalAxes(_ centered: [SIMD3<Double>]) throws -> [SIMD3<Double>] {
        var a = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for (offset, p) in centered.enumerated() {
            if offset.isMultiple(of: 1024) { try ProcessingControl.checkpoint() }
            for i in 0..<3 { for j in 0..<3 { a[i][j] += p[i] * p[j] } }
        }
        var vectors = [[1.0, 0, 0], [0.0, 1, 0], [0.0, 0, 1]]
        for _ in 0..<32 {
            var p = 0, q = 1
            for i in 0..<3 { for j in (i + 1)..<3 where abs(a[i][j]) > abs(a[p][q]) { p = i; q = j } }
            if abs(a[p][q]) <= 1e-18 { break }
            let angle = 0.5 * atan2(2 * a[p][q], a[q][q] - a[p][p])
            let c = cos(angle), s = sin(angle)
            let pp = a[p][p], qq = a[q][q], pq = a[p][q]
            a[p][p] = c*c*pp - 2*s*c*pq + s*s*qq
            a[q][q] = s*s*pp + 2*s*c*pq + c*c*qq
            a[p][q] = 0; a[q][p] = 0
            for k in 0..<3 where k != p && k != q {
                let kp = a[k][p], kq = a[k][q]
                a[k][p] = c*kp - s*kq; a[p][k] = a[k][p]
                a[k][q] = s*kp + c*kq; a[q][k] = a[k][q]
            }
            for k in 0..<3 {
                let kp = vectors[k][p], kq = vectors[k][q]
                vectors[k][p] = c*kp - s*kq; vectors[k][q] = s*kp + c*kq
            }
        }
        return (0..<3).sorted { a[$0][$0] < a[$1][$1] }.map {
            simd_normalize(SIMD3(vectors[0][$0], vectors[1][$0], vectors[2][$0]))
        }
    }
}
