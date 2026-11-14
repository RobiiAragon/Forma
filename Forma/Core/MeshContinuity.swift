import Foundation
import simd
import Darwin
import os

/// Conservative, independently implemented boundary stitching. This produces a
/// derived mesh; it neither repairs missing surfaces nor establishes accuracy.
enum MeshContinuity {
    struct Options: Codable, Sendable {
        /// Exact Euclidean radius, in the mesh's declared meters.
        var toleranceMeters: Float = 0.0005
        /// Every incident face pair must agree; sharp corners stay separate.
        var minimumNormalCosine: Double = cos(15 * .pi / 180)
        /// Reject distinct parallel sheets, including similarly oriented sheets.
        /// Only predominantly tangential boundary discrepancies may be stitched.
        var maximumNormalSeparationMeters: Double = 0.00001
        /// Preserve small features rather than flattening a triangle near a seam.
        var maximumRelativeTriangleAreaChange: Double = 0.05
    }

    struct Metrics: Codable, Sendable {
        var toleranceMeters: Double
        var minimumNormalCosine: Double
        var maximumNormalSeparationMeters: Double
        var maximumRelativeTriangleAreaChange: Double
        var verticesBefore: Int
        var verticesAfter: Int
        var verticesMerged: Int
        var facesBefore: Int
        var facesAfter: Int
        /// Index connectivity, including isolated source vertices. Not hole counts.
        var componentsBefore: Int
        var componentsAfter: Int
        var isolatedVerticesBefore: Int
        var isolatedVerticesAfter: Int
        var surfaceComponentsBefore: Int
        var surfaceComponentsAfter: Int
        var boundaryEdgesBefore: Int
        var boundaryEdgesAfter: Int
        var maxDisplacementMeters: Double
        var candidatePairsRejectedForOrientation: Int
        var candidatePairsRejectedForSeparation: Int
        var candidatePairsRejectedForTopology: Int
        var estimatedAdditionalMemoryBytes: Int
        var processingSeconds: Double

        var statistics: [String: Double] {
            ["continuityToleranceMeters": toleranceMeters,
             "continuityNormalSeparationMeters": maximumNormalSeparationMeters,
             "continuityVerticesBefore": Double(verticesBefore), "continuityVerticesAfter": Double(verticesAfter),
             "continuityVerticesMerged": Double(verticesMerged),
             "continuityFacesBefore": Double(facesBefore), "continuityFacesAfter": Double(facesAfter),
             "continuityComponentsBefore": Double(componentsBefore), "continuityComponentsAfter": Double(componentsAfter),
             "continuitySurfaceComponentsBefore": Double(surfaceComponentsBefore),
             "continuitySurfaceComponentsAfter": Double(surfaceComponentsAfter),
             "continuityIsolatedVerticesBefore": Double(isolatedVerticesBefore),
             "continuityIsolatedVerticesAfter": Double(isolatedVerticesAfter),
             "continuityBoundaryEdgesBefore": Double(boundaryEdgesBefore),
             "continuityBoundaryEdgesAfter": Double(boundaryEdgesAfter),
             "continuityMaxDisplacementMeters": maxDisplacementMeters,
             "continuityProcessingSeconds": processingSeconds]
        }
    }

    struct Result: Sendable {
        var mesh: MeshSnapshot
        var metrics: Metrics
        /// All source vertices, including unused vertices, retain a corresponding output vertex.
        var sourceVertexToOutput: [UInt32]
    }

    enum ProcessingError: LocalizedError {
        case invalidOptions, empty, invalidCoordinate, invalidIndex, degenerateFace(Int), coordinateRange
        case sizeOverflow
        case insufficientMemory(estimated: Int, available: UInt64)
        case unavailableMemory
        var errorDescription: String? {
            switch self {
            case .invalidOptions: "Los umbrales físicos de continuidad no son válidos."
            case .empty: "La malla no contiene superficies para analizar."
            case .invalidCoordinate: "La malla contiene coordenadas no finitas; se conserva el original."
            case .invalidIndex: "La malla contiene índices inválidos; se conserva el original."
            case .degenerateFace(let face): "La cara \(face) es degenerada; no se ha descartado ni reparado el original."
            case .coordinateRange: "Las coordenadas no permiten construir la búsqueda espacial con esta tolerancia."
            case .sizeOverflow: "La malla excede el espacio de direcciones disponible."
            case .insufficientMemory(let estimate, let available):
                "La continuidad requiere aproximadamente \(estimate) bytes adicionales y el sistema informa \(available) disponibles. El modelo original no se ha reducido."
            case .unavailableMemory: "El sistema no pudo consultar la memoria disponible; se conserva el original."
            }
        }
    }

    static func process(_ mesh: MeshSnapshot, options: Options = Options(),
                        control: ProcessingControl? = nil,
                        progress: @Sendable (Double) -> Void = { _ in }) throws -> Result {
        try ProcessingControl.withControl(control) { try processControlled(mesh, options: options, progress: progress) }
    }

    private static func processControlled(_ mesh: MeshSnapshot, options: Options,
                                          progress: @Sendable (Double) -> Void) throws -> Result {
        try ProcessingControl.checkpoint()
        let started = ProcessInfo.processInfo.systemUptime
        guard options.toleranceMeters.isFinite, options.toleranceMeters > 0,
              options.minimumNormalCosine.isFinite, options.minimumNormalCosine > 0, options.minimumNormalCosine <= 1,
              options.maximumNormalSeparationMeters.isFinite, options.maximumNormalSeparationMeters >= 0,
              options.maximumNormalSeparationMeters <= Double(options.toleranceMeters),
              options.maximumRelativeTriangleAreaChange.isFinite, options.maximumRelativeTriangleAreaChange >= 0,
              options.maximumRelativeTriangleAreaChange < 1 else { throw ProcessingError.invalidOptions }
        guard !mesh.vertices.isEmpty, !mesh.triangles.isEmpty else { throw ProcessingError.empty }
        guard mesh.triangles.count.isMultiple(of: 3), mesh.vertices.count <= Int(UInt32.max) else {
            throw ProcessingError.invalidIndex
        }
        // Conservative estimates include Swift hash-table/adjacency overhead,
        // remap/output copies and candidate transaction storage. This checks a
        // fresh OS memory snapshot, not a commercial or vertex-count quota.
        let memoryEstimate = try checkedSum(checkedProduct(mesh.vertices.count, 512), checkedProduct(mesh.faceCount, 512))
        try requireMemory(memoryEstimate)
        let count = mesh.vertices.count, faceCount = mesh.faceCount
        let tolerance = Double(options.toleranceMeters), radiusSquared = tolerance * tolerance
        var incident = [[Int]](repeating: [], count: count)
        var normals = [SIMD3<Double>](repeating: .zero, count: faceCount)
        var twiceAreas = [Double](repeating: 0, count: faceCount)
        var edges: [UInt64: Edge] = [:]
        var faceKeys: [FaceKey: Int] = [:]
        var originalConnectivity = Connectivity(count)
        for (index, point) in mesh.vertices.enumerated() {
            if index & 1023 == 0 { try ProcessingControl.checkpoint() }
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { throw ProcessingError.invalidCoordinate }
        }
        for face in 0..<faceCount {
            if face & 1023 == 0 { try ProcessingControl.checkpoint() }
            let indices = (0..<3).map { Int(mesh.triangles[face * 3 + $0]) }
            guard indices.allSatisfy({ $0 < count }), Set(indices).count == 3 else { throw ProcessingError.invalidIndex }
            let p = indices.map { point(mesh.vertices[$0]) }
            let cross = simd_cross(p[1] - p[0], p[2] - p[0]), area = simd_length(cross)
            guard area.isFinite, area > 0 else { throw ProcessingError.degenerateFace(face) }
            normals[face] = cross / area
            twiceAreas[face] = area
            faceKeys[FaceKey(indices), default: 0] += 1
            for vertex in indices { incident[vertex].append(face) }
            for edge in 0..<3 {
                let a = indices[edge], b = indices[(edge + 1) % 3], key = edgeKey(a, b)
                var value = edges[key] ?? Edge(start: a, end: b)
                value.count += 1; value.balance += a < b ? 1 : -1
                edges[key] = value
                originalConnectivity.join(a, b)
            }
        }
        var originalRoots = [Int](repeating: 0, count: count), originalRootSet = Set<Int>()
        for vertex in 0..<count {
            if vertex & 1023 == 0 { try ProcessingControl.checkpoint() }
            originalRoots[vertex] = originalConnectivity.root(vertex)
            originalRootSet.insert(originalRoots[vertex])
        }
        let beforeComponents = originalRootSet.count
        let beforeIsolated = incident.reduce(0) { $0 + ($1.isEmpty ? 1 : 0) }
        let beforeBoundary = edges.values.reduce(0) { $0 + ($1.count == 1 ? 1 : 0) }
        var boundary = [[Boundary]](repeating: [], count: count)
        for (index, edge) in edges.values.enumerated() where edge.count == 1 {
            if index & 1023 == 0 { try ProcessingControl.checkpoint() }
            boundary[edge.start].append(Boundary(other: edge.end, outgoing: true))
            boundary[edge.end].append(Boundary(other: edge.start, outgoing: false))
        }
        // Deterministic order, independent of Swift Dictionary iteration order.
        for vertex in boundary.indices where !boundary[vertex].isEmpty {
            boundary[vertex].sort { $0.other < $1.other }
        }
        let baselineNormals = normals, baselineAreas = twiceAreas
        var representative = Array(0..<count)
        var members: [Int: [Int]] = [:]
        var grid: [Cell: [Int]] = [:]
        var merged = 0, rejectedOrientation = 0, rejectedSeparation = 0, rejectedTopology = 0
        var maximumDisplacement: Double = 0
        let origin = point(mesh.vertices[0])
        progress(0.15)

        func group(_ vertex: Int) -> [Int] { members[vertex] ?? [vertex] }
        func vertexFaces(_ vertex: Int) -> [Int] { group(vertex).flatMap { incident[$0] } }
        func compatibleNormals(_ source: Int, _ destination: Int) throws -> Bool {
            let a = incident[source], b = vertexFaces(destination)
            let all = a + b
            // Also reject vertices lying on a sharp corner within either input group.
            for i in all.indices {
                if i & 31 == 0 { try ProcessingControl.checkpoint() }
                for j in all.indices where j > i {
                    if simd_dot(normals[all[i]], normals[all[j]]) < options.minimumNormalCosine { return false }
                }
            }
            return true
        }
        func compatibleSeparation(_ source: Int, _ destination: Int) -> Bool {
            let p = point(mesh.vertices[source]), q = point(mesh.vertices[destination]), delta = p - q
            for other in group(destination) {
                if originalRoots[source] == originalRoots[other] { return false }
                if simd_length_squared(p - point(mesh.vertices[other])) > radiusSquared { return false }
            }
            for face in incident[source] + vertexFaces(destination) {
                if abs(simd_dot(delta, normals[face])) > options.maximumNormalSeparationMeters { return false }
            }
            return true
        }
        func hasBoundarySupport(_ source: Int, _ destination: Int) -> Bool {
            // A real seam must also have a nearby opposite-winding boundary edge.
            // Merely touching at one point, or overlapping the same-facing sheet,
            // is insufficient evidence to join two components.
            for first in boundary[source] {
                for member in group(destination) {
                    for second in boundary[member] where first.outgoing != second.outgoing {
                        if simd_length_squared(point(mesh.vertices[first.other]) - point(mesh.vertices[second.other])) <= radiusSquared {
                            return true
                        }
                    }
                }
            }
            return false
        }

        for vertex in 0..<count {
            if vertex & 255 == 0 {
                try ProcessingControl.checkpoint()
                progress(0.15 + 0.75 * Double(vertex) / Double(count))
            }
            guard !boundary[vertex].isEmpty else { continue }
            let p = point(mesh.vertices[vertex]), cell = try Cell(p - origin, tolerance: tolerance)
            var candidates: [(index: Int, distance: Double)] = []
            var visitedCandidates = 0
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                for candidate in grid[cell.offset(dx, dy, dz)] ?? [] {
                    if visitedCandidates & 255 == 0 { try ProcessingControl.checkpoint() }
                    visitedCandidates += 1
                    let distance = simd_length_squared(p - point(mesh.vertices[candidate]))
                    if distance <= radiusSquared, originalRoots[vertex] != originalRoots[candidate] {
                        candidates.append((candidate, distance))
                    }
                }
            } } }
            candidates.sort { $0.distance == $1.distance ? $0.index < $1.index : $0.distance < $1.distance }
            var selected: Int?
            for candidate in candidates {
                try ProcessingControl.checkpoint()
                let destination = candidate.index
                guard try compatibleNormals(vertex, destination) else { rejectedOrientation += 1; continue }
                guard compatibleSeparation(vertex, destination), hasBoundarySupport(vertex, destination) else {
                    rejectedSeparation += 1; continue
                }
                // Only source-incident triangles change: earlier representatives
                // never move or get replaced by a later vertex.
                var edgeDelta: [UInt64: Delta] = [:]
                var faceDelta: [FaceKey: Int] = [:]
                var changed: [(face: Int, normal: SIMD3<Double>, area: Double)] = []
                var valid = true
                for face in incident[vertex] {
                    let old = (0..<3).map { representative[Int(mesh.triangles[face * 3 + $0])] }
                    let next = old.map { $0 == vertex ? destination : $0 }
                    guard Set(next).count == 3 else { valid = false; break }
                    let positions = next.map { point(mesh.vertices[$0]) }
                    let cross = simd_cross(positions[1] - positions[0], positions[2] - positions[0]), area = simd_length(cross)
                    guard area.isFinite, area > 0, simd_dot(cross / area, baselineNormals[face]) >= options.minimumNormalCosine,
                          abs(area / baselineAreas[face] - 1) <= options.maximumRelativeTriangleAreaChange else {
                        valid = false; break
                    }
                    changed.append((face, cross / area, area))
                    faceDelta[FaceKey(old), default: 0] -= 1
                    faceDelta[FaceKey(next), default: 0] += 1
                    for edge in 0..<3 {
                        let a = old[edge], b = old[(edge + 1) % 3], c = next[edge], d = next[(edge + 1) % 3]
                        edgeDelta[edgeKey(a, b), default: Delta()].count -= 1
                        edgeDelta[edgeKey(a, b), default: Delta()].balance -= a < b ? 1 : -1
                        edgeDelta[edgeKey(c, d), default: Delta()].count += 1
                        edgeDelta[edgeKey(c, d), default: Delta()].balance += c < d ? 1 : -1
                    }
                }
                if valid {
                    for (key, delta) in faceDelta where delta > 0 {
                        if (faceKeys[key] ?? 0) + delta > max(1, faceKeys[key] ?? 0) { valid = false; break }
                    }
                }
                if valid {
                    for (key, delta) in edgeDelta {
                        let old = edges[key] ?? Edge(start: Int(key >> 32), end: Int(key & 0xffffffff))
                        let count = old.count + delta.count, balance = old.balance + delta.balance
                        if count < 0 || count > max(2, old.count) || (count == 2 && abs(balance) > 0 && (old.count != 2 || delta.count != 0 || delta.balance != 0)) {
                            valid = false; break
                        }
                    }
                }
                guard valid else { rejectedTopology += 1; continue }
                for (key, delta) in edgeDelta {
                    var value = edges[key] ?? Edge(start: Int(key >> 32), end: Int(key & 0xffffffff))
                    value.count += delta.count; value.balance += delta.balance
                    if value.count == 0 { edges.removeValue(forKey: key) } else { edges[key] = value }
                }
                for (key, delta) in faceDelta {
                    let value = (faceKeys[key] ?? 0) + delta
                    if value == 0 { faceKeys.removeValue(forKey: key) } else { faceKeys[key] = value }
                }
                for change in changed { normals[change.face] = change.normal; twiceAreas[change.face] = change.area }
                selected = destination
                break
            }
            if let selected {
                representative[vertex] = selected
                if members[selected] == nil { members[selected] = [selected] }
                members[selected]!.append(vertex)
                merged += 1
                maximumDisplacement = max(maximumDisplacement, simd_length(p - point(mesh.vertices[selected])))
            } else { grid[cell, default: []].append(vertex) }
        }
        try ProcessingControl.checkpoint()
        var output = [SIMD3<Float>](), outputIndices = [UInt32]()
        output.reserveCapacity(count - merged); outputIndices.reserveCapacity(mesh.triangles.count)
        var outputIndex = [UInt32](repeating: .max, count: count)
        for vertex in 0..<count where representative[vertex] == vertex {
            if vertex & 1023 == 0 { try ProcessingControl.checkpoint() }
            outputIndex[vertex] = UInt32(output.count)
            output.append(mesh.vertices[vertex])
        }
        for vertex in 0..<count {
            if vertex & 1023 == 0 { try ProcessingControl.checkpoint() }
            outputIndex[vertex] = outputIndex[representative[vertex]]
        }
        var afterConnectivity = Connectivity(output.count)
        var referenced = [Bool](repeating: false, count: output.count)
        for face in 0..<faceCount {
            if face & 1023 == 0 { try ProcessingControl.checkpoint() }
            let a = outputIndex[Int(mesh.triangles[3 * face])], b = outputIndex[Int(mesh.triangles[3 * face + 1])], c = outputIndex[Int(mesh.triangles[3 * face + 2])]
            outputIndices.append(contentsOf: [a, b, c])
            afterConnectivity.join(Int(a), Int(b)); afterConnectivity.join(Int(a), Int(c))
            referenced[Int(a)] = true; referenced[Int(b)] = true; referenced[Int(c)] = true
        }
        var afterRoots = Set<Int>()
        for vertex in 0..<output.count {
            if vertex & 1023 == 0 { try ProcessingControl.checkpoint() }
            afterRoots.insert(afterConnectivity.root(vertex))
        }
        let afterComponents = afterRoots.count
        let afterIsolated = referenced.reduce(0) { $0 + ($1 ? 0 : 1) }
        try ProcessingControl.checkpoint()
        let result = Result(mesh: MeshSnapshot(vertices: output, triangles: outputIndices),
            metrics: Metrics(toleranceMeters: tolerance, minimumNormalCosine: options.minimumNormalCosine,
                maximumNormalSeparationMeters: options.maximumNormalSeparationMeters,
                maximumRelativeTriangleAreaChange: options.maximumRelativeTriangleAreaChange,
                verticesBefore: count, verticesAfter: output.count, verticesMerged: merged,
                facesBefore: faceCount, facesAfter: outputIndices.count / 3,
                componentsBefore: beforeComponents, componentsAfter: afterComponents,
                isolatedVerticesBefore: beforeIsolated, isolatedVerticesAfter: afterIsolated,
                surfaceComponentsBefore: beforeComponents - beforeIsolated,
                surfaceComponentsAfter: afterComponents - afterIsolated,
                boundaryEdgesBefore: beforeBoundary, boundaryEdgesAfter: edges.values.reduce(0) { $0 + ($1.count == 1 ? 1 : 0) },
                maxDisplacementMeters: maximumDisplacement,
                candidatePairsRejectedForOrientation: rejectedOrientation,
                candidatePairsRejectedForSeparation: rejectedSeparation,
                candidatePairsRejectedForTopology: rejectedTopology,
                estimatedAdditionalMemoryBytes: memoryEstimate,
                processingSeconds: ProcessInfo.processInfo.systemUptime - started), sourceVertexToOutput: outputIndex)
        progress(1)
        return result
    }

    private struct Cell: Hashable {
        var x: Int64, y: Int64, z: Int64
        init(_ p: SIMD3<Double>, tolerance: Double) throws {
            let values = (0..<3).map { floor(p[$0] / tolerance) }
            guard values.allSatisfy({ $0.isFinite && $0 > Double(Int64.min) + 2048 && $0 < Double(Int64.max) - 2048 }) else {
                throw ProcessingError.coordinateRange
            }
            x = Int64(values[0]); y = Int64(values[1]); z = Int64(values[2])
        }
        private init(x: Int64, y: Int64, z: Int64) { self.x = x; self.y = y; self.z = z }
        func offset(_ x: Int, _ y: Int, _ z: Int) -> Cell { Cell(x: self.x + Int64(x), y: self.y + Int64(y), z: self.z + Int64(z)) }
    }
    private struct FaceKey: Hashable {
        var a: Int, b: Int, c: Int
        init(_ indices: [Int]) { let sorted = indices.sorted(); a = sorted[0]; b = sorted[1]; c = sorted[2] }
    }
    private struct Boundary { var other: Int; var outgoing: Bool }
    private struct Edge { var count = 0; var balance = 0; var start: Int; var end: Int }
    private struct Delta { var count = 0; var balance = 0 }
    private static func point(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), Double(p.z)) }
    private static func edgeKey(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
    private struct Connectivity {
        var parents: [Int], ranks: [UInt8]
        init(_ count: Int) { parents = Array(0..<count); ranks = [UInt8](repeating: 0, count: count) }
        mutating func root(_ value: Int) -> Int {
            var v = value
            while parents[v] != v { parents[v] = parents[parents[v]]; v = parents[v] }
            return v
        }
        mutating func join(_ a: Int, _ b: Int) {
            var x = root(a), y = root(b)
            if x == y { return }
            if ranks[x] < ranks[y] { swap(&x, &y) }
            parents[y] = x
            if ranks[x] == ranks[y] { ranks[x] += 1 }
        }
    }
    private static func checkedProduct(_ a: Int, _ b: Int) throws -> Int {
        let value = a.multipliedReportingOverflow(by: b)
        guard !value.overflow, value.partialValue >= 0 else { throw ProcessingError.sizeOverflow }
        return value.partialValue
    }
    private static func checkedSum(_ a: Int, _ b: Int) throws -> Int {
        let value = a.addingReportingOverflow(b)
        guard !value.overflow, value.partialValue >= 0 else { throw ProcessingError.sizeOverflow }
        return value.partialValue
    }
    private static func requireMemory(_ estimated: Int) throws {
        let available: UInt64
        #if os(iOS) && !targetEnvironment(simulator)
        available = UInt64(os_proc_available_memory())
        #else
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var page: vm_size_t = 0, statistics = vm_statistics64_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let pageStatus = host_page_size(host, &page)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(host, HOST_VM_INFO64, $0, &size) }
        }
        guard status == KERN_SUCCESS, pageStatus == KERN_SUCCESS else { throw ProcessingError.unavailableMemory }
        available = UInt64(statistics.free_count) * UInt64(page) + UInt64(statistics.inactive_count) * UInt64(page)
        #endif
        guard UInt64(estimated) <= available - available / 10 else {
            throw ProcessingError.insufficientMemory(estimated: estimated, available: available)
        }
    }
}
