import Foundation

/// Every refinement owns a fresh workspace. Saved models, photos and calibration
/// are read only; a failed or cancelled run cannot replace an existing capture.
enum SavedScanRefinement {
    /// Only this service's fresh, unpublished workspace can be discarded here.
    static func discardUnpublished(_ result: CaptureResult) {
        guard let workspace = result.cleanupDirectory,
              workspace.lastPathComponent.hasPrefix("FormaRefinement-"),
              workspace.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL ==
                FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: workspace)
    }

    static func originalMeshURL(scan: ScanRecord, directory: URL) -> URL? {
        var paths: [String] = []
        if let dataset = scan.datasetDirectory, ScanStore.safeRelativePath(dataset) {
            paths.append(dataset + "/malla-original.json")
        }
        paths += scan.exports.filter { ScanStore.safeRelativePath($0) && $0.hasSuffix("malla-original.json") }
        paths.append("malla.json")
        return paths.map { directory.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func canRefine(scan: ScanRecord, directory: URL) -> Bool {
        scan.mode == .lidar && !scan.isDemo && scan.gaussianModelFile == nil &&
        (scan.datasetDirectory != nil || (scan.statistics?["texturedFaces"] ?? 0) == 0) &&
        originalMeshURL(scan: scan, directory: directory) != nil
    }

    static func process(scan: ScanRecord, directory: URL,
                        quality: LiDARQualitySettings? = nil, control: ProcessingControl? = nil,
                        progress: @escaping @Sendable (String, Double) -> Void) async throws -> CaptureResult {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("FormaRefinement-\(UUID().uuidString)", isDirectory: true)
        var returnedWorkspace = false
        defer { if !returnedWorkspace { try? FileManager.default.removeItem(at: workspace) } }
        let copyWorker = Task.detached(priority: .userInitiated) { () throws -> (MeshSnapshot, URL, Bool) in
            return try ProcessingControl.withControl(control) {
            try Task.checkCancellation()
            guard canRefine(scan: scan, directory: directory), let meshURL = originalMeshURL(scan: scan, directory: directory) else {
                throw RGBDDatasetError.invalid("Esta captura no conserva una malla LiDAR reutilizable.")
            }
            let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: meshURL))
            try MeshExporter.validate(mesh)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            let dataset = workspace.appendingPathComponent("dataset", isDirectory: true)
            if let source = scan.datasetDirectory {
                guard ScanStore.safeRelativePath(source) else { throw RGBDDatasetError.invalid("Ruta de fuentes no válida.") }
                try CooperativeFileIO.copyDirectory(directory.appendingPathComponent(source), to: dataset)
                let manifest = try RGBDDatasetManifest.load(from: dataset)
                try Task.checkCancellation()
                return (mesh, dataset, !manifest.frames.isEmpty)
            }
            try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: false)
            try RGBDDatasetManifest(createdAt: scan.createdAt, frames: []).write(to: dataset)
            try Task.checkCancellation()
            return (mesh, dataset, false)
            }
        }
        progress("Preparando una versión nueva", 0)
        let (mesh, dataset, hasPhotos) = try await withTaskCancellationHandler(operation: {
            try await copyWorker.value
        }, onCancel: { copyWorker.cancel(); control?.cancel() })
        try Task.checkCancellation()
        var result = try await LiDARProcessingPipeline.process(mesh: mesh, datasetDirectory: dataset,
            duration: scan.duration, mode: .lidar, quality: quality, control: control) { title, fraction in progress(title, fraction) }
        try Task.checkCancellation()
        result.sourceScanID = scan.id
        result.statistics?["refinedFromSavedCapture"] = 1
        if !hasPhotos {
            result.captureDatasetURL = nil
            result.note = "Versión derivada de una captura anterior sin fotografías. La captura original sigue en tu biblioteca. No se ha generado textura ni detalle nuevo. " + result.note
        } else {
            result.note = "Reprocesada con sus fotografías originales; la captura anterior sigue en tu biblioteca. " + result.note
        }
        returnedWorkspace = true
        return result
    }
}
