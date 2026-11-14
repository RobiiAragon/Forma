import Foundation
import simd

/// Polygon vertices use the model's metric coordinates and implicit closure; do not repeat the first vertex.
/// The result is the area of a simple, approximately planar polygon, never an enclosed volume.
enum SurfaceMeasurement {
    enum Failure: LocalizedError, Equatable {
        case insufficientPoints
        case nonFinite
        case nonPlanar(maxDeviationMeters: Float, toleranceMeters: Float)
        case selfIntersection
        case degenerate
        case unrepresentableArea

        var errorDescription: String? {
            switch self {
            case .insufficientPoints: return "Marca al menos tres puntos para medir un área."
            case .nonFinite: return "La selección contiene coordenadas no válidas. Vuelve a marcar los puntos."
            case .nonPlanar(let deviation, let tolerance):
                return String(format: "Los puntos no forman un plano: desviación %.3f m; tolerancia %.3f m. Selecciona una sola superficie plana.", deviation, tolerance)
            case .selfIntersection: return "El contorno se cruza, se toca a sí mismo o vuelve sobre un tramo. Marca los puntos siguiendo el borde en orden."
            case .degenerate: return "La selección tiene puntos repetidos, lados demasiado cortos o no encierra un área."
            case .unrepresentableArea: return "El área excede el rango numérico de la medición. Selecciona una región más pequeña."
            }
        }
    }

    /// Coplanarity allows 5 mm or 0.1% of the selection's bounding-box diagonal, whichever is larger.
    /// Accepted sensor deviations are projected onto the Newell plane; this remains an estimated mesh measurement.
    static func polygonArea(_ points: [SIMD3<Float>]) throws -> Float {
        guard points.count >= 3 else { throw Failure.insufficientPoints }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw Failure.nonFinite }
        let vertices = points.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        var low = vertices[0], high = vertices[0], sum = SIMD3<Double>.zero
        for point in vertices { low = simd_min(low, point); high = simd_max(high, point); sum += point }
        let diagonal = simd_length(high - low)
        guard diagonal > 0, diagonal.isFinite else { throw Failure.degenerate }
        // Geometric comparison tolerances handle floating-point noise; they are not an area or vertex quota.
        let lengthTolerance = max(0.000001, diagonal * 0.0000001)
        let areaTolerance = max(0.000000000001, diagonal * diagonal * 0.0000000001)
        let centroid = sum / Double(vertices.count)
        let centered = vertices.map { $0 - centroid }
        var newell = SIMD3<Double>.zero
        for index in centered.indices {
            let current = centered[index], next = centered[(index + 1) % centered.count]
            guard simd_distance(current, next) > lengthTolerance else { throw Failure.degenerate }
            newell.x += (current.y - next.y) * (current.z + next.z)
            newell.y += (current.z - next.z) * (current.x + next.x)
            newell.z += (current.x - next.x) * (current.y + next.y)
        }
        let newellLength = simd_length(newell)
        var normal = newell
        if newellLength <= 2 * areaTolerance {
            // A crossed contour (for example a bow tie) can cancel its Newell vector.
            // Find a diagnostic plane so it is rejected as an intersection instead of silently reporting zero.
            let baseline = vertices[1] - vertices[0]
            var largestCross: Double = 0
            for point in vertices.dropFirst(2) {
                let candidate = simd_cross(baseline, point - vertices[0])
                let magnitude = simd_length(candidate)
                if magnitude > largestCross { largestCross = magnitude; normal = candidate }
            }
            guard largestCross > areaTolerance else { throw Failure.degenerate }
        }
        normal = simd_normalize(normal)
        let planeTolerance = max(0.005, diagonal * 0.001)
        let deviation = centered.reduce(0.0) { max($0, abs(simd_dot($1, normal))) }
        guard deviation <= planeTolerance else {
            throw Failure.nonPlanar(maxDeviationMeters: Float(deviation), toleranceMeters: Float(planeTolerance))
        }
        let reference = abs(normal.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u = simd_normalize(simd_cross(reference, normal)), v = simd_cross(normal, u)
        let projected = centered.map { SIMD2<Double>(simd_dot($0, u), simd_dot($0, v)) }
        for index in projected.indices {
            let previous = projected[(index + projected.count - 1) % projected.count]
            let current = projected[index], next = projected[(index + 1) % projected.count]
            let incoming = current - previous, outgoing = next - current
            guard simd_length(incoming) > lengthTolerance, simd_length(outgoing) > lengthTolerance else { throw Failure.degenerate }
            let turnTolerance = lengthTolerance * max(simd_length(incoming), simd_length(outgoing))
            if abs(cross(incoming, outgoing)) <= turnTolerance, simd_dot(incoming, outgoing) < 0 {
                throw Failure.selfIntersection
            }
        }
        // Non-adjacent edges may neither cross, overlap, nor touch: all three violate a simple polygon.
        for first in projected.indices {
            let firstEnd = (first + 1) % projected.count
            for second in (first + 1)..<projected.count {
                let secondEnd = (second + 1) % projected.count
                if firstEnd == second || secondEnd == first { continue }
                if intersects(projected[first], projected[firstEnd], projected[second], projected[secondEnd], tolerance: lengthTolerance) {
                    throw Failure.selfIntersection
                }
            }
        }
        var twiceArea = 0.0
        for index in projected.indices { twiceArea += cross(projected[index], projected[(index + 1) % projected.count]) }
        let area = abs(twiceArea) * 0.5
        guard area > areaTolerance else { throw Failure.degenerate }
        guard area.isFinite, area <= Double(Float.greatestFiniteMagnitude) else { throw Failure.unrepresentableArea }
        return Float(area)
    }

    private static func cross(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>) -> Double { lhs.x * rhs.y - lhs.y * rhs.x }

    private static func intersects(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>, tolerance: Double) -> Bool {
        guard max(a.x, b.x) + tolerance >= min(c.x, d.x), max(c.x, d.x) + tolerance >= min(a.x, b.x),
              max(a.y, b.y) + tolerance >= min(c.y, d.y), max(c.y, d.y) + tolerance >= min(a.y, b.y) else { return false }
        func side(_ start: SIMD2<Double>, _ end: SIMD2<Double>, _ point: SIMD2<Double>) -> Int {
            let value = cross(end - start, point - start)
            let threshold = tolerance * simd_length(end - start)
            return value > threshold ? 1 : value < -threshold ? -1 : 0
        }
        func contains(_ point: SIMD2<Double>, between start: SIMD2<Double>, and end: SIMD2<Double>) -> Bool {
            point.x >= min(start.x, end.x) - tolerance && point.x <= max(start.x, end.x) + tolerance &&
            point.y >= min(start.y, end.y) - tolerance && point.y <= max(start.y, end.y) + tolerance
        }
        let ac = side(a, b, c), ad = side(a, b, d), ca = side(c, d, a), cb = side(c, d, b)
        if ac * ad < 0, ca * cb < 0 { return true }
        return (ac == 0 && contains(c, between: a, and: b)) || (ad == 0 && contains(d, between: a, and: b)) ||
               (ca == 0 && contains(a, between: c, and: d)) || (cb == 0 && contains(b, between: c, and: d))
    }
}
