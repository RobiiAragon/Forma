import Foundation

enum LiDARProcessingPipeline {
    static func process(mesh: MeshSnapshot, datasetDirectory: URL, duration: TimeInterval, mode: ScanMode,
                        quality: LiDARQualitySettings? = nil,
                        control: ProcessingControl? = nil,
                        progress: @escaping @Sendable (String, Double) -> Void) async throws -> CaptureResult {
        let gate = control ?? ProcessingControl.current
        let worker = Task.detached(priority: .userInitiated) {
            try ProcessingControl.withControl(gate) {
            try ProcessingControl.checkpoint()
            try MeshExporter.validate(mesh)
            let manifest = try RGBDDatasetManifest.load(from: datasetDirectory)
            let settings = quality ?? manifest.lidarQuality ?? LiDARQualitySettings()
            try settings.validate()
            let workspace = datasetDirectory.deletingLastPathComponent()
            let originalMeshURL = datasetDirectory.appendingPathComponent("malla-original.json")
            if FileManager.default.fileExists(atPath: originalMeshURL.path) {
                let stored = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: originalMeshURL))
                guard stored.vertices == mesh.vertices, stored.triangles == mesh.triangles else {
                    throw RGBDDatasetError.invalid("Las fuentes contienen otra malla original. Reprocesa desde esa malla para conservar su procedencia.")
                }
            } else {
                try JSONEncoder().encode(mesh).write(to: originalMeshURL, options: .atomic)
            }
            progress("Uniendo bordes compatibles sin perder superficies", 0)
            var preparedMesh = mesh
            var continuityMetrics: [String: Double] = [:]
            var continuityNote = ""
            do {
                let continuity = try MeshContinuity.process(mesh) { progress("Uniendo bordes compatibles", $0 * 0.08) }
                preparedMesh = continuity.mesh
                continuityMetrics = continuity.metrics.statistics
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Preserve raw ARKit geometry when conservative joining is inapplicable.
                continuityMetrics["continuityKeptOriginal"] = 1
                continuityNote = " Se conservó la malla original sin unir bordes: \(error.localizedDescription)"
            }
            try ProcessingControl.checkpoint()
            progress("Comprobando superficies planas sin alterar bordes", 0.1)
            let planar = try MeshPlanarDenoiser.process(preparedMesh, configuration: settings.planarConfiguration)
            preparedMesh = planar.mesh
            let modelDirectory = workspace.appendingPathComponent("ModeloTexturizado", isDirectory: true)
            if FileManager.default.fileExists(atPath: modelDirectory.path) { try FileManager.default.removeItem(at: modelDirectory) }
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            progress("Preparando fotografías y poses calibradas", 0.12)
            if !manifest.frames.isEmpty { try COLMAPDatasetExporter.prepare(datasetDirectory: datasetDirectory, mesh: mesh) }
            let baked = try LiDARTextureBaker.bake(mesh: preparedMesh, keyframes: manifest.frames,
                datasetDirectory: datasetDirectory, outputDirectory: modelDirectory) { fraction in
                    progress("Afinando fotografías y organizando texturas", 0.12 + 0.88 * fraction)
                }
            let observed = baked.texturedFaceCount
            let total = observed + baked.unobservedFaceCount
            let note = (manifest.frames.isEmpty
                ? "Malla LiDAR sin fotografías. Se conserva material neutro y la malla original; no se añade textura, superficies ni detalle por subdivisión."
                : "LiDAR con textura fotográfica multivista. \(observed.formatted()) de \(total.formatted()) caras tienen una observación válida; el resto conserva material neutro. \(baked.adjustedPhotoCount) fotografías con ajuste de exposición validado; \(baked.atlasMaterialCount) texturas de visualización, sin reducir píxeles de origen. Malla original, fotos y calibración guardadas. No se añaden superficies ni detalle por subdivisión.") + continuityNote + (settings.correctPlanarNoise ? " Corrección conservadora de planos solicitada; tolerancia \(settings.planarToleranceMeters * 1000) mm. Consulta las regiones aceptadas en el informe." : "")
            var result = CaptureResult(mesh: preparedMesh, modelURL: baked.objURL, auxiliaryURLs: [originalMeshURL], mode: mode, duration: duration,
                note: note, cleanupDirectory: workspace)
            result.modelPackageURL = modelDirectory
            result.captureDatasetURL = datasetDirectory
            result.statistics = ["texturedFaces": Double(observed), "unobservedFaces": Double(baked.unobservedFaceCount),
                "keyframes": Double(manifest.frames.count), "maxImageWidth": Double(manifest.frames.map(\.imageWidth).max() ?? 0),
                "maxImageHeight": Double(manifest.frames.map(\.imageHeight).max() ?? 0),
                "textureCoverage": total > 0 ? Double(observed)/Double(total) : 0,
                "textureSelectionSeconds": baked.selectionSeconds,
                "textureCoherenceSeconds": baked.coherenceSeconds,
                "textureProcessingSeconds": baked.totalSeconds,
                "textureSourceBoundaryEdgesBefore": Double(baked.sourceBoundaryEdgesBefore),
                "textureSourceBoundaryEdgesAfter": Double(baked.sourceBoundaryEdgesAfter),
                "textureCoherenceReassignedFaces": Double(baked.coherenceReassignedFaces),
                "photometricSeconds": baked.photometricSeconds,
                "seamSampleCount": Double(baked.seamSampleCount),
                "seamValidationSampleCount": Double(baked.seamValidationSampleCount),
                "seamLinkCount": Double(baked.seamLinkCount),
                "adjustedPhotoCount": Double(baked.adjustedPhotoCount),
                "photometricImageDecodeCount": Double(baked.photometricImageDecodeCount),
                "seamRMSEBefore": baked.seamRMSEBefore,
                "seamRMSEAfter": baked.seamRMSEAfter,
                "seamLogRMSEBefore": baked.seamLogRMSEBefore,
                "seamLogRMSEAfter": baked.seamLogRMSEAfter,
                "sourceTextureCount": Double(baked.sourceTextureCount),
                "atlasPageCount": Double(baked.atlasPageCount),
                "atlasMaterialCount": Double(baked.atlasMaterialCount),
                "atlasDedicatedOriginalCount": Double(baked.atlasDedicatedOriginalCount),
                "atlasSourcePixels": Double(baked.atlasSourcePixels),
                "atlasCroppedPixels": Double(baked.atlasCroppedPixels),
                "atlasEncodedPixels": Double(baked.atlasEncodedPixels),
                "atlasDedicatedOriginalPixels": Double(baked.atlasDedicatedOriginalPixels),
                "atlasBytesWritten": Double(baked.atlasBytesWritten),
                "atlasSeconds": baked.atlasSeconds]
            result.statistics?.merge(continuityMetrics, uniquingKeysWith: { _, new in new })
            result.statistics?.merge(planar.metrics.statistics, uniquingKeysWith: { _, new in new })
            result.statistics?["nativePlaneAssistanceRequested"] = settings.nativePlaneAssistance ? 1 : 0
            result.statistics?["densePhotographsRequested"] = settings.densePhotographs ? 1 : 0
            result.statistics?["planarCorrectionRequested"] = settings.correctPlanarNoise ? 1 : 0
            try JSONEncoder().encode(settings).write(to: modelDirectory.appendingPathComponent("calidad-geometrica.json"), options: .atomic)
            let textureReport: [String: Any] = [
                "schema": 1, "exposureMethod": "anchored scalar gain in linear sRGB; held-out RGB and relative log-luminance validation",
                "photoExposureGains": baked.photoExposureGains,
                "exposureReferencePhotos": baked.exposureReferencePhotos,
                "sourceRastersResized": false, "surfacesAdded": 0,
                "statistics": result.statistics ?? [:]
            ]
            try JSONSerialization.data(withJSONObject: textureReport, options: [.prettyPrinted, .sortedKeys])
                .write(to: modelDirectory.appendingPathComponent("texturizado.json"), options: .atomic)
            for (name, value) in manifest.captureMetrics ?? [:] where value.isFinite {
                result.statistics?["capture_" + name] = value
            }
            progress("Texturas y fuentes listas", 1)
            return result
            }
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
            gate?.cancel()
            worker.cancel()
        })
    }
}
