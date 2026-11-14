import Foundation
import simd

enum DemoGeometry {
    // Mathematical study, never presented as a captured or benchmarked object.
    static func sculpture() -> MeshSnapshot {
        let rings = 96, sides = 48
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0..<rings {
            let t = Float(i) / Float(rings) * .pi * 2
            let center = SIMD3<Float>(sin(t) + 2*sin(2*t), cos(t) - 2*cos(2*t), -sin(3*t)) * 0.13
            let nextT = t + 0.001
            let next = SIMD3<Float>(sin(nextT) + 2*sin(2*nextT), cos(nextT)-2*cos(2*nextT), -sin(3*nextT)) * 0.13
            let tangent = simd_normalize(next-center)
            let normal = simd_normalize(simd_cross(tangent, SIMD3<Float>(0, 1, 0)))
            let binormal = simd_cross(tangent, normal)
            for j in 0..<sides {
                let a = Float(j) / Float(sides) * .pi * 2
                vertices.append(center + 0.073 * (cos(a)*normal + sin(a)*binormal))
                let a0 = UInt32(i*sides+j), a1 = UInt32(i*sides+(j+1)%sides)
                let b0 = UInt32(((i+1)%rings)*sides+j), b1 = UInt32(((i+1)%rings)*sides+(j+1)%sides)
                indices += [a0, b0, a1, a1, b0, b1]
            }
        }
        return MeshSnapshot(vertices: vertices, triangles: indices)
    }
}
