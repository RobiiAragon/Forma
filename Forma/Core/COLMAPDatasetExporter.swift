import Foundation
import simd

enum RGBDDatasetError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum COLMAPDatasetExporter {
    /// COLMAP expects world -> camera, with camera +Y down / +Z forward.
    /// ARKit stores camera -> world, with camera +Y up / -Z forward.
    static func worldToCOLMAPCamera(_ cameraToWorld: simd_float4x4) -> simd_float4x4 {
        let flip = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))
        return flip * cameraToWorld.inverse
    }

    static func prepare(datasetDirectory: URL, mesh: MeshSnapshot) throws {
        let manifest = try RGBDDatasetManifest.load(from: datasetDirectory)
        guard !manifest.frames.isEmpty else { throw RGBDDatasetError.invalid("No se guardaron fotografías calibradas para reconstruir esta escena.") }
        let cameras = datasetDirectory.appendingPathComponent("cameras.txt")
        let images = datasetDirectory.appendingPathComponent("images.txt")
        let points = datasetDirectory.appendingPathComponent("points3D.txt")
        try stream(to: cameras) { write in
            try write("# Forma: calibrated PINHOLE cameras; native full-resolution image pixels\n")
            for (index, frame) in manifest.frames.enumerated() {
                try ProcessingControl.checkpoint()
                try validate(frame, at: datasetDirectory)
                let k = frame.intrinsics
                try write("\(index+1) PINHOLE \(frame.imageWidth) \(frame.imageHeight) \(k[0]) \(k[4]) \(k[6]) \(k[7])\n")
            }
        }
        try stream(to: images) { write in
            try write("# IMAGE_ID QW QX QY QZ TX TY TZ CAMERA_ID NAME\n# Image observations are empty: poses are calibrated ARKit measurements, not SfM estimates.\n")
            for (index, frame) in manifest.frames.enumerated() {
                try ProcessingControl.checkpoint()
                guard let pose = frame.transformMatrix else { throw RGBDDatasetError.invalid("Pose inválida: \(frame.id)") }
                let worldToCamera = worldToCOLMAPCamera(pose)
                let rotation = simd_float3x3(columns: (SIMD3(worldToCamera.columns.0.x, worldToCamera.columns.0.y, worldToCamera.columns.0.z),
                    SIMD3(worldToCamera.columns.1.x, worldToCamera.columns.1.y, worldToCamera.columns.1.z),
                    SIMD3(worldToCamera.columns.2.x, worldToCamera.columns.2.y, worldToCamera.columns.2.z)))
                let q = simd_normalize(simd_quatf(rotation)).vector
                let t = worldToCamera.columns.3
                let filename = String(frame.rgbFile.dropFirst("images/".count))
                try write("\(index+1) \(q.w) \(q.x) \(q.y) \(q.z) \(t.x) \(t.y) \(t.z) \(index+1) \(filename)\n\n")
            }
        }
        try MeshExporter.validate(mesh)
        try stream(to: points) { write in
            try write("# LiDAR mesh vertices in meters initialize Gaussian positions. Color starts neutral and is optimized against the photographs.\n")
            var seen = Set<SIMD3<Float>>()
            var count = 0
            for vertex in mesh.vertices where seen.insert(vertex).inserted {
                count += 1
                if count & 1023 == 0 { try ProcessingControl.checkpoint() }
                try write("\(count) \(vertex.x) \(vertex.y) \(vertex.z) 128 128 128 0\n")
            }
        }
    }

    private static func validate(_ frame: RGBDFrameRecord, at directory: URL) throws {
        guard frame.imageWidth > 0, frame.imageHeight > 0, frame.intrinsics.count == 9,
              frame.intrinsics.allSatisfy(\.isFinite), frame.intrinsics[0] > 0, frame.intrinsics[4] > 0,
              let transform = frame.transformMatrix, abs(simd_determinant(transform)) > 0.0001,
              frame.rgbFile.hasPrefix("images/"), !frame.rgbFile.contains(".."),
              !frame.rgbFile.contains("\n"), !frame.rgbFile.contains("\r"),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(frame.rgbFile).path) else {
            throw RGBDDatasetError.invalid("Calibración o fotografía inválida en el frame \(frame.id). Se conservan los originales.")
        }
    }

    private static func stream(to url: URL, body: ((String) throws -> Void) throws -> Void) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = Data()
        try body { line in
            buffer.append(contentsOf: line.utf8)
            if buffer.count > 65536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }
}
