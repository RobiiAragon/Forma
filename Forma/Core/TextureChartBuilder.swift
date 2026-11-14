import Foundation
import simd
import Darwin

/// Finds photographic regions without changing a triangle or its source sampling.
/// Each face belongs to exactly one chart. Splits only move whole faces between
/// storage rectangles; their UVs continue to sample the same native source pixels.
enum TextureChartBuilder {
    static func isUnitUV(_ uv: SIMD2<Float>) -> Bool {
        guard uv.x.isFinite, uv.y.isFinite else { return false }
        let insideX: Bool = uv.x >= 0 && uv.x <= 1
        let insideY: Bool = uv.y >= 0 && uv.y <= 1
        return insideX && insideY
    }
    struct Face: Sendable {
        var id: Int
        var sourceID: Int
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var c: SIMD2<Float>
    }

    struct PixelRect: Sendable, Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        func union(_ other: PixelRect) -> PixelRect {
            let left = min(x, other.x), top = min(y, other.y)
            let right = max(x + width, other.x + other.width)
            let bottom = max(y + height, other.y + other.height)
            return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    struct Chart: Sendable {
        var id: Int
        var sourceID: Int
        /// Indices into the caller's unchanged face array, not geometry indices.
        var faceIndices: [Int]
        var crop: PixelRect
    }

    struct Result: Sendable {
        var charts: [Chart]
        /// Parallel to the input array. Arbitrary public face IDs remain intact.
        var faceChartIDs: [Int]
        var connectedIslandCount: Int
    }

    enum ChartError: LocalizedError {
        case invalidFace(Int)
        case invalidDimensions(Int)
        case sizeOverflow
        case insufficientMemory
        var errorDescription: String? {
            switch self {
            case .invalidFace(let id): "La cara \(id) no tiene coordenadas fotográficas válidas."
            case .invalidDimensions(let id): "Las dimensiones de la fotografía \(id) no son válidas."
            case .sizeOverflow: "Las regiones fotográficas exceden el rango de direcciones disponible."
            case .insufficientMemory: "No hay memoria disponible para agrupar estas regiones; las fuentes se conservan."
            }
        }
    }

    /// Exact UV-edge connectivity is deliberately conservative. Close, overlapping
    /// or point-touching UVs are not evidence that a shared storage region is needed.
    /// Median region splits are accepted only when their padded pixel cost decreases.
    /// There is no quota on photos, charts, pages or faces.
    static func build(
        faces: [Face], dimensions: [Int: SIMD2<Int>], padding: Int = 2,
        checkCancellation: () throws -> Void = { try ProcessingControl.checkpoint() }
    ) throws -> Result {
        try checkCancellation()
        guard padding >= 1, padding < Int.max / 16 else { throw ChartError.sizeOverflow }
        for (id, size) in dimensions {
            guard size.x > 0, size.y > 0, size.x < Int.max / 16, size.y < Int.max / 16 else {
                throw ChartError.invalidDimensions(id)
            }
        }
        let estimated = faces.count.multipliedReportingOverflow(by: 512)
        guard !estimated.overflow else { throw ChartError.sizeOverflow }
        try checkAvailableMemory(estimated.partialValue)
        var faceIDs: Set<Int> = []
        var rects: [PixelRect] = []
        rects.reserveCapacity(faces.count)
        for (index, face) in faces.enumerated() {
            if index & 1023 == 0 { try checkCancellation() }
            guard faceIDs.insert(face.id).inserted, let size = dimensions[face.sourceID],
                  Self.isUnitUV(face.a), Self.isUnitUV(face.b), Self.isUnitUV(face.c) else {
                throw ChartError.invalidFace(face.id)
            }
            rects.append(crop(lower: simd_min(face.a, simd_min(face.b, face.c)),
                              upper: simd_max(face.a, simd_max(face.b, face.c)), size: size))
        }
        var connectivity = Connectivity(faces.count)
        var firstEdge: [Edge: Int] = [:]
        for (index, face) in faces.enumerated() {
            if index & 1023 == 0 { try checkCancellation() }
            let points = [pointKey(face.a), pointKey(face.b), pointKey(face.c)]
            for corner in 0..<3 {
                let a = points[corner], b = points[(corner + 1) % 3]
                // A zero-length UV edge supplies no adjacency evidence.
                if a == b { continue }
                let edge = Edge(sourceID: face.sourceID, lower: min(a, b), upper: max(a, b))
                if let previous = firstEdge[edge] { connectivity.join(index, previous) }
                else { firstEdge[edge] = index }
            }
        }
        // Release the largest hash table before region sorting and packing.
        firstEdge = [:]
        var islands: [Int: [Int]] = [:]
        for index in faces.indices {
            if index & 1023 == 0 { try checkCancellation() }
            islands[connectivity.root(index), default: []].append(index)
        }
        var charts: [Chart] = []
        var faceChartIDs = [Int](repeating: -1, count: faces.count)
        for island in islands.values.sorted(by: { $0[0] < $1[0] }) {
            try partition(island, faces: faces, rects: rects, padding: padding,
                          charts: &charts, faceChartIDs: &faceChartIDs, checkCancellation: checkCancellation)
        }
        try checkCancellation()
        return Result(charts: charts, faceChartIDs: faceChartIDs, connectedIslandCount: islands.count)
    }

    private static func partition(
        _ indices: [Int], faces: [Face], rects: [PixelRect], padding: Int,
        charts: inout [Chart], faceChartIDs: inout [Int], checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        let bounds = union(indices, rects: rects)
        var bestCost = try paddedPixels(bounds, padding: padding)
        var bestOrder: [Int]?
        if indices.count > 1 {
            for axis in 0..<2 {
                let ordered = indices.sorted {
                    let a = rects[$0], b = rects[$1]
                    let left = axis == 0 ? Double(a.x) + Double(a.width) / 2 : Double(a.y) + Double(a.height) / 2
                    let right = axis == 0 ? Double(b.x) + Double(b.width) / 2 : Double(b.y) + Double(b.height) / 2
                    return left == right ? $0 < $1 : left < right
                }
                let middle = ordered.count / 2
                let left = union(ordered[..<middle], rects: rects)
                let right = union(ordered[middle...], rects: rects)
                let cost = try paddedPixels(left, padding: padding).addingReportingOverflow(paddedPixels(right, padding: padding))
                guard !cost.overflow else { throw ChartError.sizeOverflow }
                if cost.partialValue < bestCost { bestCost = cost.partialValue; bestOrder = ordered }
            }
        }
        if let order = bestOrder {
            let middle = order.count / 2
            try partition(Array(order[..<middle]), faces: faces, rects: rects, padding: padding,
                          charts: &charts, faceChartIDs: &faceChartIDs, checkCancellation: checkCancellation)
            try partition(Array(order[middle...]), faces: faces, rects: rects, padding: padding,
                          charts: &charts, faceChartIDs: &faceChartIDs, checkCancellation: checkCancellation)
        } else {
            let id = charts.count
            charts.append(Chart(id: id, sourceID: faces[indices[0]].sourceID, faceIndices: indices, crop: bounds))
            for index in indices { faceChartIDs[index] = id }
        }
    }

    private static func union<C: Collection>(_ indices: C, rects: [PixelRect]) -> PixelRect where C.Element == Int {
        var result = rects[indices.first!]
        for index in indices.dropFirst() { result = result.union(rects[index]) }
        return result
    }

    private static func paddedPixels(_ rect: PixelRect, padding: Int) throws -> Int64 {
        let result = Int64(rect.width + padding + padding).multipliedReportingOverflow(by: Int64(rect.height + padding + padding))
        guard !result.overflow else { throw ChartError.sizeOverflow }
        return result.partialValue
    }

    private static func crop(lower: SIMD2<Float>, upper: SIMD2<Float>, size: SIMD2<Int>) -> PixelRect {
        // Preserve the two neighbours of each bilinear sample at native density.
        let x0 = max(0, min(size.x - 1, Int(floor(Double(lower.x) * Double(size.x) - 0.5))))
        let x1 = max(x0, min(size.x - 1, Int(ceil(Double(upper.x) * Double(size.x) - 0.5))))
        let y0 = max(0, min(size.y - 1, Int(floor((1 - Double(upper.y)) * Double(size.y) - 0.5))))
        let y1 = max(y0, min(size.y - 1, Int(ceil((1 - Double(lower.y)) * Double(size.y) - 0.5))))
        return PixelRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    private static func pointKey(_ uv: SIMD2<Float>) -> UInt64 {
        // Treat negative and positive zero identically, without quantizing a texel.
        let u = uv.x == 0 ? Float(0).bitPattern : uv.x.bitPattern
        let v = uv.y == 0 ? Float(0).bitPattern : uv.y.bitPattern
        return UInt64(u) << 32 | UInt64(v)
    }
    private struct Edge: Hashable { var sourceID: Int; var lower: UInt64; var upper: UInt64 }
    private struct Connectivity {
        var parents: [Int], ranks: [UInt8]
        init(_ count: Int) { parents = Array(0..<count); ranks = [UInt8](repeating: 0, count: count) }
        mutating func root(_ index: Int) -> Int {
            var index = index
            while parents[index] != index { parents[index] = parents[parents[index]]; index = parents[index] }
            return index
        }
        mutating func join(_ a: Int, _ b: Int) {
            var a = root(a), b = root(b)
            guard a != b else { return }
            if ranks[a] < ranks[b] { swap(&a, &b) }
            parents[b] = a
            if ranks[a] == ranks[b] { ranks[a] += 1 }
        }
    }

    static func checkAvailableMemory(_ bytes: Int) throws {
        let available: UInt64
        #if os(iOS) && !targetEnvironment(simulator)
        available = UInt64(os_proc_available_memory())
        #else
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var page: vm_size_t = 0, statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let pageStatus = host_page_size(host, &page)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard pageStatus == KERN_SUCCESS, status == KERN_SUCCESS else { throw ChartError.insufficientMemory }
        available = (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * UInt64(page)
        #endif
        guard UInt64(bytes) <= available - available / 10 else { throw ChartError.insufficientMemory }
    }
}
