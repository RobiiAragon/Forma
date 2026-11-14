import Foundation
import RealityKit
import ImageIO
import simd
import ModelIO

/// Native Apple outputs. This capture layer performs no camera inversion, axis
/// flip, scale alignment, image rotation, or conversion to a COLMAP convention.
enum DesktopPhotogrammetryCalibration {
    static func geometryCounts(_ url: URL) throws -> ModelGeometryCounts {
        try autoreleasepool {
            let asset = MDLAsset(url: url)
            var vertices = 0, faces = 0
            func visit(_ object: MDLObject) throws {
                try ProcessingControl.checkpoint()
                if let mesh = object as? MDLMesh {
                    vertices += mesh.vertexCount
                    for submesh in mesh.submeshes as? [MDLSubmesh] ?? [] {
                        guard submesh.geometryType == .triangles, submesh.indexCount % 3 == 0 else {
                            throw CaptureError.invalid("la malla no está triangulada")
                        }
                        faces += submesh.indexCount / 3
                    }
                }
                for child in object.children.objects { try visit(child) }
            }
            for index in 0..<asset.count { try visit(asset.object(at: index)) }
            guard vertices > 0, faces > 0 else { throw CaptureError.invalid("el modelo no tiene superficies") }
            return ModelGeometryCounts(vertexCount: vertices, faceCount: faces)
        }
    }
    struct LensDistortion: Codable, Sendable {
        var center: [Float]
        var radialLookupTable: [Float]
    }
    struct Camera: Codable, Sendable {
        var sampleID: Int
        var sampleURLFilename: String
        var inputFilename: String
        var sourceFile: String
        var frameID: String
        var timestamp: Double
        var nativeTransformColumnMajor: [Float]
        var nativeTranslation: [Float]
        var nativeRotationQuaternionXYZW: [Float]
        var nativeScale: [Float]
        var intrinsicsColumnMajor: [Float]?
        var lensDistortion: LensDistortion?
        var inputImageWidth: Int?
        var inputImageHeight: Int?
        var inputImageOrientation: Int?
    }
    struct CameraDocument: Codable, Sendable {
        var schemaVersion = 1
        var matrixLayout = "columnMajor"
        var coordinateSystem = "Unmodified Apple PhotogrammetrySession Pose.transform; no C2W/W2C interpretation, axis flip, CRS or scale conversion applied."
        var intrinsicsNote = "Native optional Pose.intrinsics. Input dimensions/orientation are image-container metadata, not a claim about Apple's internal downsampling raster."
        var inputCount: Int
        var poseCount: Int
        var cameras: [Camera]
        var inputsWithoutPose: [DesktopPhotogrammetryInput.Item]
    }
    struct BoundsDocument: Codable, Sendable {
        var schemaVersion = 1
        var coordinateSystem = "Unmodified Apple PhotogrammetrySession bounds; no CRS or scale conversion."
        var minimum: [Float]
        var maximum: [Float]
        var center: [Float]
        var extents: [Float]
    }
    enum CaptureError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return "No se guardó la calibración nativa: " + reason }
            return nil
        }
    }

    @available(macOS 14.0, *)
    static func writePoses(_ poses: PhotogrammetrySession.Poses, items: [DesktopPhotogrammetryInput.Item], to destination: URL) throws {
        guard !items.isEmpty, Set(items.map(\.filename)).count == items.count,
              Set(items.map(\.frameID)).count == items.count,
              items.allSatisfy({ !$0.filename.isEmpty && !$0.frameID.isEmpty && $0.timestamp.isFinite &&
                  ($0.filename as NSString).lastPathComponent == $0.filename }) else { throw CaptureError.invalid("el índice de fotografías es ambiguo o no válido") }
        let byFilename = Dictionary(uniqueKeysWithValues: items.map { ($0.filename, $0) })
        let urls = poses.urlsBySample
        var cameras: [Camera] = [], usedFrameIDs = Set<String>()
        for sampleID in poses.posesBySample.keys.sorted() {
            try ProcessingControl.checkpoint()
            guard let pose = poses.posesBySample[sampleID], let url = urls[sampleID], url.isFileURL,
                  let item = byFilename[url.lastPathComponent], usedFrameIDs.insert(item.frameID).inserted else {
                throw CaptureError.invalid("una pose no tiene una URL única asociada a input-order.json (sample \(sampleID))")
            }
            let transform = pose.transform, matrix = transform.matrix
            let nativeMatrix = (0..<4).flatMap { column in (0..<4).map { matrix[column][$0] } }
            let translation = vector(pose.translation), rotation = vector(pose.rotation.vector), scale = vector(transform.scale)
            try finite(nativeMatrix + translation + rotation + scale)
            var intrinsics: [Float]?, distortion: LensDistortion?
            if #available(macOS 26.0, *) {
                if let k = pose.intrinsics { intrinsics = (0..<3).flatMap { column in (0..<3).map { k[column][$0] } }; try finite(intrinsics!) }
                if let lens = pose.lensDistortionData {
                    let center = [lens.center.x, lens.center.y]
                    try finite(center + lens.radialLookupTable)
                    distortion = .init(center: center, radialLookupTable: lens.radialLookupTable)
                }
            }
            let properties = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
            cameras.append(Camera(sampleID: sampleID, sampleURLFilename: url.lastPathComponent, inputFilename: item.filename,
                sourceFile: item.sourceFile, frameID: item.frameID, timestamp: item.timestamp, nativeTransformColumnMajor: nativeMatrix,
                nativeTranslation: translation, nativeRotationQuaternionXYZW: rotation, nativeScale: scale,
                intrinsicsColumnMajor: intrinsics, lensDistortion: distortion,
                inputImageWidth: (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
                inputImageHeight: (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
                inputImageOrientation: (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue))
        }
        guard !cameras.isEmpty else { throw CaptureError.invalid("Apple no devolvió ninguna pose") }
        try writeJSON(CameraDocument(inputCount: items.count, poseCount: cameras.count, cameras: cameras,
            inputsWithoutPose: items.filter { !usedFrameIDs.contains($0.frameID) }), to: destination)
    }

    @available(macOS 13.0, *)
    static func writePointCloud(_ cloud: PhotogrammetrySession.PointCloud, to destination: URL) throws {
        try prepareParent(destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".native-points-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.write(contentsOf: Data(("ply\nformat ascii 1.0\ncomment Native Apple PhotogrammetrySession pointCloud; no CRS conversion\n" +
            "element vertex \(cloud.points.count)\nproperty float x\nproperty float y\nproperty float z\n" +
            "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\nend_header\n").utf8))
        var batch = String()
        for (index, point) in cloud.points.enumerated() {
            if index % 4096 == 0 {
                try ProcessingControl.checkpoint()
                if !batch.isEmpty { try output.write(contentsOf: Data(batch.utf8)); batch.removeAll(keepingCapacity: true) }
            }
            try finite(vector(point.position))
            let p = point.position, c = point.color
            batch += "\(p.x) \(p.y) \(p.z) \(c.x) \(c.y) \(c.z) \(c.w)\n"
        }
        if !batch.isEmpty { try output.write(contentsOf: Data(batch.utf8)) }
        try ProcessingControl.checkpoint(); try output.synchronize(); try output.close()
        try publish(temporary, to: destination)
    }

    static func writeBounds(_ bounds: BoundingBox, to destination: URL) throws {
        let minimum = vector(bounds.min), maximum = vector(bounds.max), center = vector(bounds.center), extents = vector(bounds.extents)
        try finite(minimum + maximum + center + extents)
        guard (0..<3).allSatisfy({ minimum[$0] <= maximum[$0] }) else { throw CaptureError.invalid("los límites están vacíos o invertidos") }
        try writeJSON(BoundsDocument(minimum: minimum, maximum: maximum, center: center, extents: extents), to: destination)
    }

    private static func vector(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }
    private static func vector(_ value: SIMD4<Float>) -> [Float] { [value.x, value.y, value.z, value.w] }
    private static func finite(_ values: [Float]) throws {
        guard values.allSatisfy(\.isFinite) else { throw CaptureError.invalid("Apple devolvió valores NaN o infinitos") }
    }
    static func writeJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        try prepareParent(destination); try ProcessingControl.checkpoint()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: destination, options: .atomic)
    }
    private static func prepareParent(_ destination: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path), attributes[.type] as? FileAttributeType != .typeRegular {
            throw CaptureError.invalid("el destino no es un archivo regular")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    private static func publish(_ temporary: URL, to destination: URL) throws {
        // rename on the same directory publishes one complete file atomically.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }
}
