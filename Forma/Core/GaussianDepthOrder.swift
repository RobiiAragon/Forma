import Foundation
import simd

/// Exact, stable ordering of finite Float32 depths. All IEEE mantissa bits are
/// retained; radix passes change CPU complexity, never the Gaussian population.
enum GaussianDepthOrder {
    static func workingBytes(pointCount: Int, includeGPUOrder: Bool = false) throws -> Int {
        let arrays = try GaussianMemoryGuard.bytes(pointCount, stride: includeGPUOrder ? 16 : 12)
        return try GaussianMemoryGuard.sum(arrays,256 * MemoryLayout<Int>.stride)
    }

    static func sortedIndices(points: [GaussianPoint], direction: SIMD3<Float>,
                              checkCancellation: () throws -> Void = {}) throws -> [UInt32] {
        try checkCancellation()
        guard points.count <= Int(UInt32.max), direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else {
            throw RGBDDatasetError.invalid("El orden de profundidad excede la precisión numérica del visor.")
        }
        if points.isEmpty { return [] }
        try GaussianMemoryGuard.require(try workingBytes(pointCount: points.count), phase: "ordenar todas las Gaussianas sin reducir el modelo")
        let count = points.count
        var keys: [UInt32] = [], source: [UInt32] = []
        keys.reserveCapacity(count); source.reserveCapacity(count)
        for index in 0..<count {
            if index.isMultiple(of: 4096) { try checkCancellation() }
            let p = points[index].positionOpacity
            // Translation adds the same constant to every depth. Excluding that
            // constant makes zoom reuse exact and avoids unnecessary rounding ties.
            let depth = simd_dot(direction,SIMD3(p.x,p.y,p.z))
            guard depth.isFinite else {
                throw RGBDDatasetError.invalid("La cámara excede la precisión numérica del visor. Los archivos siguen disponibles para exportar.")
            }
            let bits = depth.bitPattern
            let key = depth == 0 ? UInt32(0x80000000) : bits ^ (bits & 0x80000000 == 0 ? 0x80000000 : 0xffffffff)
            keys.append(key); source.append(UInt32(index))
        }
        var destination = [UInt32](repeating: 0,count: count)
        var offsets = [Int](repeating: 0,count: 256)
        try keys.withUnsafeBufferPointer { keyBuffer in
            for shift in stride(from: 0,to: 32,by: 8) {
                try checkCancellation()
                for bucket in 0..<256 { offsets[bucket] = 0 }
                try source.withUnsafeBufferPointer { input in
                    for index in 0..<count {
                        if index.isMultiple(of: 4096) { try checkCancellation() }
                        let bucket = Int((keyBuffer[Int(input[index])] >> shift) & 255)
                        offsets[bucket] += 1
                    }
                    var next = 0
                    for bucket in 0..<256 {
                        let amount = offsets[bucket]
                        offsets[bucket] = next
                        next += amount
                    }
                    try destination.withUnsafeMutableBufferPointer { output in
                        for index in 0..<count {
                            if index.isMultiple(of: 4096) { try checkCancellation() }
                            let point = input[index]
                            let bucket = Int((keyBuffer[Int(point)] >> shift) & 255)
                            output[offsets[bucket]] = point
                            offsets[bucket] += 1
                        }
                    }
                }
                swap(&source,&destination)
            }
        }
        try checkCancellation()
        return source
    }
}
