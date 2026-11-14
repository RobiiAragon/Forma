import Foundation
import simd

/// A calibrated observation in the original ARKit world coordinates. With a
/// keepCrs Gaussian export its pose can be used directly, without another Y/Z flip.
struct GaussianViewpoint: Sendable {
    enum ViewpointError: LocalizedError {
        case invalidFrame(String, String)
        case invalidDataset(String)
        case invalidProjection
        var errorDescription: String? {
            switch self {
            case .invalidFrame(let id, let reason): return "Vista calibrada \(id) no válida: \(reason). Las fuentes se conservan."
            case .invalidDataset(let reason): return "No se pueden leer las vistas calibradas: \(reason). Las fuentes se conservan."
            case .invalidProjection: return "El tamaño de vista, zoom o planos de cámara no permiten una proyección finita."
            }
        }
    }

    struct CalibratedProjection: Sendable {
        /// Metal right-handed camera, -Z forward, NDC depth 0...1.
        var matrix: simd_float4x4
        /// Drawable coordinates start at the top-left EDGE, not pixel center.
        var viewportOrigin: SIMD2<Float>
        var viewportSize: SIMD2<Float>
        var focalPixels: SIMD2<Float>
    }
    struct ProjectedPoint: Sendable {
        /// Native raster: center of the upper-left pixel is (0,0).
        var pixel: SIMD2<Float>
        var cameraDepth: Float
    }

    let frameID: String
    let sourceFrameIndex: Int
    let timestamp: Double
    let rgbFile: String
    let imageWidth: Int
    let imageHeight: Int
    let cameraToWorld: simd_float4x4
    let intrinsics: simd_float3x3
    private(set) var presentationQuarterTurns = 0
    var viewMatrix: simd_float4x4 { simd_inverse(cameraToWorld) }
    var position: SIMD3<Float> { SIMD3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z) }
    var backward: SIMD3<Float> { SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z) }
    var forward: SIMD3<Float> { -backward }
    var up: SIMD3<Float> { SIMD3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z) }

    /// Rotates the presented raster clockwise in exact quarter turns, preserving
    /// the world-space rays. Photos, Gaussian parameters and source identity stay
    /// unchanged. Dimensions/K describe this virtual presentation, not a new file.
    func rotatedForPresentation(quarterTurns: Int) throws -> Self {
        let turns = (quarterTurns % 4 + 4) % 4
        var result = self
        for _ in 0..<turns {
            let c = result.cameraToWorld, k = result.intrinsics
            let rotatedPose = simd_float4x4(columns: (c.columns.1, -c.columns.0, c.columns.2, c.columns.3))
            let rotatedK = simd_float3x3(columns: (
                SIMD3(k[1][1], -k[1][0], 0), SIMD3(-k[0][1], k[0][0], 0),
                SIMD3(Float(result.imageHeight - 1) - k[2][1], k[2][0], 1)))
            let frame = RGBDFrameRecord(id: frameID, timestamp: timestamp, rgbFile: rgbFile,
                imageWidth: result.imageHeight, imageHeight: result.imageWidth,
                cameraToWorld: (0..<4).flatMap { column in (0..<4).map { rotatedPose[column][$0] } },
                intrinsics: (0..<3).flatMap { column in (0..<3).map { rotatedK[column][$0] } },
                source: "presentation-only derived calibration; original image is unchanged",
                exposureDuration: nil, exposureOffset: nil)
            let totalTurns = (result.presentationQuarterTurns + 1) % 4
            result = try Self(frame: frame, sourceFrameIndex: sourceFrameIndex)
            result.presentationQuarterTurns = totalTurns
        }
        return result
    }

    /// Chooses among equivalent raster presentations using ARKit world +Y. Ties
    /// preserve the current presentation, including cameras aimed along gravity.
    var uprightPresentation: Self {
        get throws {
            var best = self
            for turns in 1..<4 {
                let candidate = try rotatedForPresentation(quarterTurns: turns)
                if candidate.up.y > best.up.y { best = candidate }
            }
            return best
        }
    }

    init(frame: RGBDFrameRecord, sourceFrameIndex: Int = 0) throws {
        func invalid(_ reason: String) -> ViewpointError { .invalidFrame(frame.id, reason) }
        guard frame.timestamp.isFinite, frame.imageWidth > 1, frame.imageHeight > 1,
              frame.intrinsics.count == 9, frame.intrinsics.allSatisfy(\.isFinite),
              frame.intrinsics[0] > 0, frame.intrinsics[4] > 0,
              abs(frame.intrinsics[2]) < 0.000001, abs(frame.intrinsics[5]) < 0.000001,
              abs(frame.intrinsics[8] - 1) < 0.000001 else { throw invalid("raster o matriz intrínseca incorrectos") }
        guard let transform = frame.transformMatrix,
              abs(transform.columns.0.w) < 0.000001, abs(transform.columns.1.w) < 0.000001,
              abs(transform.columns.2.w) < 0.000001, abs(transform.columns.3.w - 1) < 0.000001 else {
            throw invalid("pose incompleta o no afín")
        }
        let rotation = simd_float3x3(columns: (
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
        // Numerical validation of a rigid, right-handed sensor pose. No pose is
        // silently normalized, replaced, skipped, or inferred from another frame.
        guard abs(simd_determinant(rotation) - 1) < 0.001,
              (0..<3).allSatisfy({ column in (0..<3).allSatisfy { other in
                  abs(simd_dot(rotation[column], rotation[other]) - (column == other ? 1 : 0)) < 0.001
              } }) else { throw invalid("la rotación no es rígida y dextrógira") }
        frameID = frame.id; self.sourceFrameIndex = sourceFrameIndex; timestamp = frame.timestamp
        rgbFile = frame.rgbFile; imageWidth = frame.imageWidth; imageHeight = frame.imageHeight
        cameraToWorld = transform
        intrinsics = simd_float3x3(columns: (
            SIMD3(frame.intrinsics[0], frame.intrinsics[1], frame.intrinsics[2]),
            SIMD3(frame.intrinsics[3], frame.intrinsics[4], frame.intrinsics[5]),
            SIMD3(frame.intrinsics[6], frame.intrinsics[7], frame.intrinsics[8])))
    }

    /// Off-center projection and covariance focal lengths for an aspect-fit Metal
    /// viewport. Use the returned rectangle for both viewport and scissor; do not
    /// stretch the native raster to the whole drawable or replace its principal point.
    func projection(viewport: SIMD2<Float>, near: Float, far: Float, zoom: Float = 1) throws -> CalibratedProjection {
        guard viewport.x.isFinite, viewport.y.isFinite, viewport.x > 0, viewport.y > 0,
              near.isFinite, far.isFinite, near > 0, far > near, zoom.isFinite, zoom > 0 else {
            throw ViewpointError.invalidProjection
        }
        let width = Double(imageWidth), height = Double(imageHeight), magnification = Double(zoom)
        let scale = min(Double(viewport.x) / width, Double(viewport.y) / height)
        let size = SIMD2<Float>(Float(width * scale), Float(height * scale))
        let origin = (viewport - size) * 0.5
        let fx = Double(intrinsics[0][0]) * magnification, fy = Double(intrinsics[1][1]) * magnification
        let skewX = Double(intrinsics[1][0]) * magnification, skewY = Double(intrinsics[0][1]) * magnification
        let cx = Double(intrinsics[2][0]), cy = Double(intrinsics[2][1])
        let depthScale = Double(far) / (Double(near) - Double(far))
        let depthTranslation = Double(far) * Double(near) / (Double(near) - Double(far))
        let matrix = simd_float4x4(columns: (
            SIMD4(Float(2 * fx / width), Float(-2 * skewY / height), 0, 0),
            SIMD4(Float(-2 * skewX / width), Float(2 * fy / height), 0, 0),
            SIMD4(Float(1 - 2 * (cx + 0.5) / width), Float(2 * (cy + 0.5) / height - 1), Float(depthScale), -1),
            SIMD4(0, 0, Float(depthTranslation), 0)))
        let focal = SIMD2<Float>(Float(fx * scale), Float(fy * scale))
        guard (0..<4).allSatisfy({ matrix[$0].x.isFinite && matrix[$0].y.isFinite && matrix[$0].z.isFinite && matrix[$0].w.isFinite }),
              size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0,
              focal.x.isFinite, focal.y.isFinite, focal.x > 0, focal.y > 0 else { throw ViewpointError.invalidProjection }
        return CalibratedProjection(matrix: matrix, viewportOrigin: origin, viewportSize: size, focalPixels: focal)
    }

    func project(worldPoint: SIMD3<Float>) -> ProjectedPoint? {
        guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else { return nil }
        let q = viewMatrix * SIMD4(worldPoint, 1)
        let depth = -q.z
        guard depth.isFinite, depth > 0 else { return nil }
        let homogeneous = intrinsics * SIMD3(q.x, -q.y, depth)
        let pixel = SIMD2(homogeneous.x / homogeneous.z, homogeneous.y / homogeneous.z)
        guard pixel.x.isFinite, pixel.y.isFinite else { return nil }
        return ProjectedPoint(pixel: pixel, cameraDepth: depth)
    }

    /// Preserves every observation, ordered by acquisition time, with stable
    /// original-index ties. An invalid observation raises its identity explicitly.
    static func views(in manifest: RGBDDatasetManifest) throws -> [Self] {
        try manifest.frames.enumerated().map { index, frame in
            try Task.checkCancellation()
            return try Self(frame: frame, sourceFrameIndex: index)
        }.sorted {
            $0.timestamp == $1.timestamp ? $0.sourceFrameIndex < $1.sourceFrameIndex : $0.timestamp < $1.timestamp
        }
    }

    /// Metadata-only file I/O and validation stay off the caller's UI executor.
    static func load(fromDataset directory: URL) async throws -> [Self] {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let manifest = try RGBDDatasetManifest.load(from: directory)
            guard manifest.units == "meters", manifest.matrixLayout == "columnMajor" else {
                throw ViewpointError.invalidDataset("unidades o disposición de matrices desconocidas")
            }
            return try views(in: manifest)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func previousIndex(before index: Int, count: Int) -> Int? {
        guard count > 0, index > 0, index < count else { return nil }; return index - 1
    }
    static func nextIndex(after index: Int, count: Int) -> Int? {
        guard count > 0, index >= 0, index < count - 1 else { return nil }; return index + 1
    }
}
