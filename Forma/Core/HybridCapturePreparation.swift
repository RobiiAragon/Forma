import Foundation

/// The hybrid path preserves sensor sources and geometry without baking photographs on the phone.
enum HybridCapturePreparation {
    static func prepare(mesh: MeshSnapshot, datasetDirectory: URL, duration: TimeInterval,
                        mode: ScanMode) async throws -> CaptureResult {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try MeshExporter.validate(mesh)
            let manifest = try RGBDDatasetManifest.load(from: datasetDirectory)
            let original = datasetDirectory.appendingPathComponent("malla-original.json")
            if FileManager.default.fileExists(atPath: original.path) {
                let stored = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: original))
                guard stored.vertices == mesh.vertices, stored.triangles == mesh.triangles else {
                    throw RGBDDatasetError.invalid("Las fuentes pertenecen a otra malla original.")
                }
            } else {
                try JSONEncoder().encode(mesh).write(to: original, options: .atomic)
            }
            try Task.checkCancellation()
            var result = CaptureResult(mesh: mesh, mode: mode, duration: duration,
                note: "Captura híbrida: geometría LiDAR, fotografías y calibración originales conservadas. La Mac realizará el texturizado; este modelo del iPhone todavía no contiene textura fotográfica.",
                cleanupDirectory: datasetDirectory.deletingLastPathComponent())
            result.captureDatasetURL = datasetDirectory
            result.statistics = ["remoteProcessingPending": 1, "texturedFaces": 0,
                "unobservedFaces": Double(mesh.faceCount), "textureCoverage": 0,
                "keyframes": Double(manifest.frames.count),
                "maxImageWidth": Double(manifest.frames.map(\.imageWidth).max() ?? 0),
                "maxImageHeight": Double(manifest.frames.map(\.imageHeight).max() ?? 0)]
            for (key, value) in manifest.captureMetrics ?? [:] where value.isFinite {
                result.statistics?["capture_" + key] = value
            }
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
