import Foundation
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import simd

/// Optional native Core ML restoration. Sensor sources and mesh/UV/MTL bytes are immutable.
enum LocalAITextureEnhancer {
    struct PreparedInput {
        var inventory: TextureAssetInventory
        var triangles: [String: [USDZTextureRestorationAdapter.Triangle]]
        var modelRelativePath: String
    }
    struct Report: Codable, Sendable {
        var packageURL: URL
        var modelURL: URL
        var processedTextureCount = 0
        var skippedTextureCount = 0
        var eligiblePixels: Int64 = 0
        var observedUVPixels: Int64 = 0
        var islandCount = 0
        var isolatedPatchCount = 0
        var totalTexturePixels: Int64 = 0
        var changedPixels: Int64 = 0
        var inferenceTileCount = 0
        var skippedTileCount = 0
        var firstPredictionSeconds = 0.0
        var warmPredictionSeconds = 0.0
        var totalSeconds = 0.0
        var modelFingerprint = ""
        var skippedReasons: [String] = []
    }

    static func run(package: URL, output: URL, modelURL: URL, strength: Double,
                    control: ProcessingControl? = nil,
                    pacing: (@Sendable () throws -> Void)? = nil,
                    cpuOnly: Bool = false,
                    checkpointDirectory: URL? = nil,
                    preparedInput: PreparedInput? = nil,
                    progress: @Sendable (String, Double) -> Void = { _, _ in }) throws -> Report {
        try ProcessingControl.withControl(control) {
            let start = ProcessInfo.processInfo.systemUptime
            guard strength.isFinite, (0...1).contains(strength) else { throw invalid("La intensidad debe estar entre 0 y 1.") }
            let fm = FileManager.default
            guard !fm.fileExists(atPath: output.path) else { throw invalid("La copia de salida ya existe.") }
            let inventory = try preparedInput?.inventory ?? TextureAssetInventory.load(modelURL: package.appendingPathComponent("modelo.obj"))
            let modelRelativePath = preparedInput?.modelRelativePath ?? "modelo.obj"
            guard ScanStore.safeRelativePath(modelRelativePath) else { throw invalid("Ruta de modelo inválida.") }
            try ProcessingControl.checkpoint()
            try pacing?()
            let runner = try Runner(modelURL: modelURL, cpuOnly: cpuOnly)
            let masks = try preparedInput?.triangles ?? triangles(in: inventory)
            let cache = try checkpointDirectory.map {
                try DurableCheckpoint(directory: $0, source: package, output: output, inventory: inventory,
                                      strength: strength, modelFingerprint: runner.fingerprint, pacing: pacing,
                                      modelRelativePath: modelRelativePath)
            }
            let staging = try cache?.preparePackage() ?? output.deletingLastPathComponent().appendingPathComponent(".local-ai-\(UUID().uuidString)")
            defer { if cache == nil { try? fm.removeItem(at: staging) } }
            if cache == nil { try CooperativeFileIO.copyDirectory(package, to: staging) }
            var report = cache?.state.report ?? Report(packageURL: output, modelURL: output.appendingPathComponent(modelRelativePath))
            report.packageURL = output; report.modelURL = output.appendingPathComponent(modelRelativePath)
            report.modelFingerprint = runner.fingerprint
            let firstAsset = cache?.state.nextAssetIndex ?? 0
            let previousSeconds = report.totalSeconds
            if firstAsset > 0 {
                progress("Continuando desde \(firstAsset) texturas guardadas", Double(firstAsset) / Double(max(1, inventory.assets.count)))
            }
            for (index, asset) in inventory.assets.enumerated() {
                guard index >= firstAsset else { continue }
                try ProcessingControl.checkpoint()
                try pacing?()
                report.totalTexturePixels += Int64(asset.width) * Int64(asset.height)
                progress("IA local: \(asset.relativePath)", Double(index) / Double(max(1, inventory.assets.count)))
                try autoreleasepool {
                    guard strength > 0, asset.url.pathExtension.lowercased() == "png",
                          let source = CGImageSourceCreateWithURL(asset.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                          image.bitsPerComponent <= 8, image.colorSpace?.name == CGColorSpace.sRGB else {
                        report.skippedTextureCount += 1
                        report.skippedReasons.append(asset.relativePath + ": se conserva original (necesita PNG sRGB de 8 bits e intensidad positiva)")
                        return
                    }
                    let width = asset.width, height = asset.height
                    var rgba = try raster(image, width: width, height: height)
                    let original = rgba
                    var mask = try coverage(masks[asset.relativePath] ?? [], width: width, height: height)
                    for pixel in mask.indices where original[pixel * 4 + 3] != 255 { mask[pixel] = 0 }
                    report.observedUVPixels += mask.reduce(Int64(0)) { $0 + Int64($1) }
                    let distance = feather(mask, width: width, height: height, radius: 4)
                    let weights = distance.map { $0 > 2 ? $0 - 2 : 0 }
                    let eligible = weights.reduce(Int64(0)) { $0 + ($1 > 0 ? 1 : 0) }
                    report.eligiblePixels += eligible
                    guard eligible > 0 else {
                        report.skippedTextureCount += 1
                        report.skippedReasons.append(asset.relativePath + ": sin interior UV seguro; isla/gutters originales intactos")
                        return
                    }
                    let regions = try islands(mask, width: width, height: height)
                    let jobs = try patches(regions.islands, labels: regions.labels, weights: weights,
                                           width: width, core: runner.core)
                    report.islandCount += regions.islands.count
                    report.isolatedPatchCount += jobs.count
                    let pages = try pack(jobs, side: runner.side, halo: runner.halo)
                    for (pageIndex, page) in pages.enumerated() {
                        defer {
                            progress("IA local: \(asset.relativePath) · bloque \(pageIndex + 1)/\(pages.count)",
                                (Double(index) + Double(pageIndex + 1) / Double(pages.count)) / Double(max(1, inventory.assets.count)))
                        }
                        try ProcessingControl.checkpoint()
                        try pacing?()
                        try autoreleasepool {
                                let tile = try runner.input(rgba: original, labels: regions.labels, width: width, height: height, placements: page)
                                try ProcessingControl.checkpoint()
                                let predictedAt = ProcessInfo.processInfo.systemUptime
                                let prediction = try runner.model.prediction(from: MLDictionaryFeatureProvider(dictionary: [runner.inputName: tile]))
                                let elapsed = ProcessInfo.processInfo.systemUptime - predictedAt
                                if report.inferenceTileCount == 0 { report.firstPredictionSeconds = elapsed }
                                else { report.warmPredictionSeconds += elapsed }
                                report.inferenceTileCount += 1
                                try pacing?()
                                try ProcessingControl.checkpoint()
                                guard let restored = prediction.featureValue(for: runner.outputName)?.multiArrayValue,
                                      restored.shape.map(\.intValue) == [1, 3, runner.side * runner.scale, runner.side * runner.scale] else {
                                    throw invalid("El modelo produjo una imagen con dimensiones incompatibles.")
                                }
                                let sampler = try Sampler(restored)
                                try withExtendedLifetime(restored) {
                                for placement in page {
                                  let patch = placement.patch
                                  for row in patch.y..<(patch.y + patch.height) {
                                    if row & 15 == 0 { try ProcessingControl.checkpoint() }
                                    for column in patch.x..<(patch.x + patch.width)
                                        where regions.labels[row * width + column] == patch.island && weights[row * width + column] > 0 {
                                        let offset = (row * width + column) * 4
                                        var changed = false
                                        for channel in 0..<3 {
                                            var sum: Float = 0
                                            for sy in 0..<runner.scale { for sx in 0..<runner.scale {
                                                sum += sampler.value(channel: channel,
                                                    x: (placement.x + column - patch.x + runner.halo) * runner.scale + sx,
                                                    y: (placement.y + row - patch.y + runner.halo) * runner.scale + sy)
                                            } }
                                            guard sum.isFinite else { throw invalid("El modelo produjo colores no finitos.") }
                                            let value = max(0, min(1, Double(sum) / Double(runner.scale * runner.scale)))
                                            let old = Double(original[offset + channel])
                                            let amount = strength * Double(weights[row * width + column]) / 2
                                            let byte = UInt8(max(0, min(255, (old + amount * (value * 255 - old)).rounded())))
                                            changed = changed || byte != original[offset + channel]
                                            rgba[offset + channel] = byte
                                        }
                                        if changed { report.changedPixels += 1 }
                                    }
                                  }
                                }
                                }
                        }
                        try pacing?()
                    }
                    // All ineligible texels (including gutters) and the source alpha remain exact.
                    for pixel in mask.indices where weights[pixel] == 0 {
                        let offset = pixel * 4
                        guard rgba[offset..<(offset + 4)].elementsEqual(original[offset..<(offset + 4)]) else {
                            throw invalid("La restauración intentó cambiar un margen protegido.")
                        }
                    }
                    let relativeRoot = preparedInput == nil
                        ? inventory.mtlURL.deletingLastPathComponent().standardizedFileURL.path
                        : package.standardizedFileURL.path
                    let packageRoot = package.standardizedFileURL.path
                    let mtlDirectory = relativeRoot == packageRoot ? "" : String(relativeRoot.dropFirst(packageRoot.count + 1)) + "/"
                    let destination = staging.appendingPathComponent(mtlDirectory + asset.relativePath)
                    try writePNG(rgba, width: width, height: height, to: destination)
                    report.processedTextureCount += 1
                }
                if let cache {
                    report.totalSeconds = previousSeconds + ProcessInfo.processInfo.systemUptime - start
                    try cache.commitAsset(index: index, report: report)
                    progress("IA local: \(asset.relativePath) · avance guardado", Double(index + 1) / Double(max(1, inventory.assets.count)))
                }
                try pacing?()
            }
            try ProcessingControl.checkpoint()
            report.totalSeconds = previousSeconds + ProcessInfo.processInfo.systemUptime - start
            try JSONEncoder().encode(report).write(to: staging.appendingPathComponent("ia-local.json"), options: .atomic)
            try ProcessingControl.checkpoint()
            if let cache {
                // Copy into a hidden sibling before the final rename. This remains
                // atomic even when a caller keeps checkpoints on another volume.
                try cache.validateForPublication()
                let publication = output.deletingLastPathComponent().appendingPathComponent(".local-ai-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: publication) }
                try CooperativeFileIO.copyDirectory(staging, to: publication)
                try ProcessingControl.checkpoint()
                try fm.moveItem(at: publication, to: output)
                try? fm.removeItem(at: cache.directory)
            } else {
                try fm.moveItem(at: staging, to: output)
            }
            progress("Copia derivada de texturas guardada; originales conservados", 1)
            return report
        }
    }

    /// Owns a dedicated resumable directory. Only fully written atlases advance
    /// the cursor; a failed/incomplete atlas is always recomputed from the source.
    private final class DurableCheckpoint {
        struct FileRecord: Codable, Equatable {
            var path: String
            var bytes: Int64
            var directory: Bool
            var sha256: String
        }
        struct State: Codable {
            var schema = 1
            var strength: Double
            var modelFingerprint: String
            var sourceFiles: [FileRecord]
            var assetPaths: [String]
            var copiedAllSources = false
            var nextAssetIndex = 0
            var completedAssets: [FileRecord] = []
            var report: Report
        }
        let directory: URL
        private let source: URL
        private let pacing: (@Sendable () throws -> Void)?
        private let fm = FileManager.default
        private(set) var state: State
        private var packageURL: URL { directory.appendingPathComponent("package", isDirectory: true) }
        private var stateURL: URL { directory.appendingPathComponent("checkpoint.json") }

        init(directory: URL, source: URL, output: URL, inventory: TextureAssetInventory,
             strength: Double, modelFingerprint: String, pacing: (@Sendable () throws -> Void)?,
             modelRelativePath: String = "modelo.obj") throws {
            // Resolve existing parent aliases before creating the directory. On
            // iOS, standardizing a path before/after creation can choose different
            // /var and /private/var spellings. Never compare only one normalized side.
            if FileManager.default.fileExists(atPath: directory.path) {
                guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw Self.incompatible("la carpeta de avance es un enlace simbólico")
                }
            }
            let checkpointRoot = directory.resolvingSymlinksInPath().standardizedFileURL
            self.directory = checkpointRoot
            self.source = source.standardizedFileURL
            self.pacing = pacing
            func overlaps(_ a: URL, _ b: URL) -> Bool {
                let ap = a.resolvingSymlinksInPath().standardizedFileURL.path
                let bp = b.resolvingSymlinksInPath().standardizedFileURL.path
                return ap == bp || ap.hasPrefix(bp + "/") || bp.hasPrefix(ap + "/")
            }
            guard !overlaps(directory, source), !overlaps(directory, output), !overlaps(source, output) else {
                throw invalid("El avance de IA, la entrada y la salida necesitan carpetas separadas.")
            }
            let sourceFiles = try Self.records(in: source, pacing: pacing)
            let root = source.standardizedFileURL.path + "/"
            let assetPaths = try inventory.assets.map { asset -> String in
                let path = asset.url.standardizedFileURL.path
                guard path.hasPrefix(root) else { throw invalid("Una textura no pertenece a la captura original.") }
                return String(path.dropFirst(root.count))
            }
            let stateURL = checkpointRoot.appendingPathComponent("checkpoint.json")
            if fm.fileExists(atPath: checkpointRoot.path) {
                let values = try checkpointRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw Self.incompatible("carpeta no válida") }
                let names = try fm.contentsOfDirectory(atPath: checkpointRoot.path)
                guard names.allSatisfy({ $0 == "checkpoint.json" || $0 == "package" }) else {
                    throw Self.incompatible("la carpeta contiene archivos ajenos")
                }
                if names.isEmpty {
                    state = State(strength: strength, modelFingerprint: modelFingerprint, sourceFiles: sourceFiles,
                                  assetPaths: assetPaths, report: Report(packageURL: output, modelURL: output.appendingPathComponent(modelRelativePath)))
                } else {
                    let metadata = try stateURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else {
                        throw Self.incompatible("el estado guardado no es un archivo regular")
                    }
                    guard let data = try? Data(contentsOf: stateURL), let stored = try? JSONDecoder().decode(State.self, from: data) else {
                        throw Self.incompatible("no se pudo leer el estado guardado")
                    }
                    guard stored.schema == 1, stored.strength == strength, stored.modelFingerprint == modelFingerprint,
                          stored.sourceFiles == sourceFiles, stored.assetPaths == assetPaths,
                          stored.nextAssetIndex >= 0, stored.nextAssetIndex <= assetPaths.count,
                          stored.completedAssets.count == stored.nextAssetIndex,
                          stored.completedAssets.map(\.path) == Array(assetPaths.prefix(stored.nextAssetIndex)),
                          stored.copiedAllSources || stored.nextAssetIndex == 0 else {
                        throw Self.incompatible("cambiaron las fuentes, el modelo, la intensidad o la lista de texturas")
                    }
                    state = stored
                }
            } else {
                state = State(strength: strength, modelFingerprint: modelFingerprint, sourceFiles: sourceFiles,
                              assetPaths: assetPaths, report: Report(packageURL: output, modelURL: output.appendingPathComponent(modelRelativePath)))
                #if os(iOS)
                try fm.createDirectory(at: checkpointRoot, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                #else
                try fm.createDirectory(at: checkpointRoot, withIntermediateDirectories: true)
                #endif
            }
            try saveState()
        }

        func preparePackage() throws -> URL {
            if !state.copiedAllSources {
                if fm.fileExists(atPath: packageURL.path) {
                    // This is a partial copy owned by a validated checkpoint, not
                    // a completed atlas or an arbitrary caller-owned directory.
                    try rejectSymlink(packageURL)
                    try fm.removeItem(at: packageURL)
                }
                try CooperativeFileIO.copyDirectory(source, to: packageURL)
                state.copiedAllSources = true
                try saveState()
            } else {
                do { try validatePackage(repairUnfinishedTextures: true) }
                catch is CancellationError { throw CancellationError() }
                catch { throw Self.incompatible("no se pudo verificar el paquete guardado: \(error.localizedDescription)") }
            }
            return packageURL
        }

        func commitAsset(index: Int, report: Report) throws {
            try ProcessingControl.checkpoint()
            guard index == state.nextAssetIndex, index < state.assetPaths.count else { throw Self.incompatible("cursor de textura no válido") }
            let path = state.assetPaths[index], file = packageURL.appendingPathComponent(path)
            try rejectSymlink(file)
            try synchronize(file)
            let record = try Self.record(path: path, at: file, pacing: pacing)
            var next = state
            next.completedAssets.append(record); next.nextAssetIndex = index + 1; next.report = report
            // The cursor changes in memory only after its atomic file is durable.
            try writeState(next)
            state = next
        }

        func validateForPublication() throws {
            guard state.nextAssetIndex == state.assetPaths.count else { throw Self.incompatible("faltan texturas por completar") }
            guard try Self.records(in: source, pacing: pacing) == state.sourceFiles else {
                throw Self.incompatible("las fuentes cambiaron durante el procesamiento")
            }
            try validatePackage(repairUnfinishedTextures: false)
        }

        private func validatePackage(repairUnfinishedTextures: Bool) throws {
            try rejectSymlink(packageURL)
            let inventory = try CooperativeFileIO.inventory(packageURL)
            let expected = Set(state.sourceFiles.map(\.path))
            guard inventory.allSatisfy({ expected.contains($0.name) || $0.name == "ia-local.json" }) else {
                throw Self.incompatible("el paquete guardado contiene archivos ajenos")
            }
            let completed = Dictionary(uniqueKeysWithValues: state.completedAssets.map { ($0.path, $0) })
            let unfinished = Set(state.assetPaths.dropFirst(state.nextAssetIndex))
            for original in state.sourceFiles {
                try ProcessingControl.checkpoint()
                let file = packageURL.appendingPathComponent(original.path)
                if repairUnfinishedTextures && unfinished.contains(original.path) {
                    // A PNG may have been written just before interruption but not
                    // committed. Restore it from the raw source before retrying.
                    if fm.fileExists(atPath: file.path) {
                        try rejectSymlink(file)
                        try fm.removeItem(at: file)
                    }
                    try CooperativeFileIO.copyFile(source.appendingPathComponent(original.path), to: file)
                    continue
                }
                let actual = try Self.record(path: original.path, at: file, pacing: pacing)
                if original.path == "ia-local.json" { continue } // Regenerated before every publication.
                guard actual == (completed[original.path] ?? original) else {
                    throw Self.incompatible("falló la integridad de \(original.path)")
                }
            }
        }

        private func rejectSymlink(_ url: URL) throws {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw Self.incompatible("la carpeta de avance es un enlace simbólico")
            }
            var current = directory
            let rootComponents = directory.pathComponents, components = url.pathComponents
            guard components.starts(with: rootComponents) else { throw Self.incompatible("ruta fuera de la carpeta de avance") }
            for component in components.dropFirst(rootComponents.count) {
                guard component != ".", component != ".." else { throw Self.incompatible("componente de ruta no válido") }
                current.appendPathComponent(component)
                guard try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Self.incompatible("enlace simbólico") }
            }
            // Only after checking the original components may canonical paths be
            // compared; resolving first would conceal an in-package symlink.
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
            let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard candidate == root || candidate.hasPrefix(root + "/") else { throw Self.incompatible("ruta fuera de la carpeta de avance") }
        }

        private static func records(in root: URL, pacing: (@Sendable () throws -> Void)?) throws -> [FileRecord] {
            try CooperativeFileIO.inventory(root).map { try record(path: $0.name, at: $0.url, pacing: pacing) }
        }
        private static func record(path: String, at file: URL, pacing: (@Sendable () throws -> Void)?) throws -> FileRecord {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw incompatible("enlace simbólico") }
            if values.isDirectory == true { return FileRecord(path: path, bytes: 0, directory: true, sha256: "") }
            guard values.isRegularFile == true else { throw incompatible("archivo no regular") }
            var hash = SHA256()
            try CooperativeFileIO.readChunks(file) { bytes in
                try pacing?()
                hash.update(data: bytes)
            }
            return FileRecord(path: path, bytes: Int64(values.fileSize ?? 0), directory: false,
                              sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        private func saveState() throws { try writeState(state) }
        private func writeState(_ value: State) throws {
            try ProcessingControl.checkpoint()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: stateURL, options: .atomic)
            try synchronize(stateURL)
        }
        private func synchronize(_ file: URL) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        private static func incompatible(_ detail: String) -> NSError {
            invalid("El avance guardado de IA no es compatible: \(detail). Conserva el original; usa Reiniciar para crear otro avance.")
        }
    }

    private final class Runner {
        let model: MLModel
        let inputName: String, outputName: String
        let side: Int, scale: Int
        let halo = 40
        var core: Int { side - 2 * halo }
        let fingerprint: String
        private let compiled: URL?

        init(modelURL: URL, cpuOnly: Bool = false) throws {
            try ProcessingControl.checkpoint()
            guard ["mlmodel", "mlpackage", "mlmodelc"].contains(modelURL.pathExtension.lowercased()) else {
                throw invalid("Selecciona un modelo Core ML (.mlmodel, .mlpackage o .mlmodelc).")
            }
            let compiledURL: URL
            let temporaryWorkspace: URL?
            if modelURL.pathExtension.lowercased() == "mlmodelc" { compiledURL = modelURL; temporaryWorkspace = nil }
            else {
                let prepared = try Self.compileOwned(modelURL)
                compiledURL = prepared.model
                temporaryWorkspace = prepared.workspace
            }
            compiled = temporaryWorkspace
            var initialized = false
            defer { if !initialized, let temporaryWorkspace { try? FileManager.default.removeItem(at: temporaryWorkspace) } }
            try ProcessingControl.checkpoint()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = cpuOnly ? .cpuOnly : .cpuAndGPU
            model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            let inputs = model.modelDescription.inputDescriptionsByName
            let outputs = model.modelDescription.outputDescriptionsByName
            guard inputs.count == 1, outputs.count == 1,
                  let input = inputs.first, let output = outputs.first,
                  let shape = input.value.multiArrayConstraint?.shape.map(\.intValue),
                  let outShape = output.value.multiArrayConstraint?.shape.map(\.intValue),
                  shape.count == 4, shape[0] == 1, shape[1] == 3, shape[2] == shape[3], shape[2] > 80,
                  outShape.count == 4, outShape[0] == 1, outShape[1] == 3,
                  outShape[2] > 0, outShape[3] > 0, outShape[2] % shape[2] == 0,
                  outShape[3] / shape[3] == outShape[2] / shape[2] else {
                throw invalid("El modelo debe recibir y producir RGB NCHW [1,3,H,W], con tamaño fijo y escala entera. No se adivina la normalización.")
            }
            inputName = input.key; outputName = output.key; side = shape[2]; scale = outShape[2] / shape[2]
            // This profile is deliberately explicit: RGB [0,1], SRVGG local support <=40.
            guard side == 522, scale == 4 else { throw invalid("Este perfil validado necesita RGB [0,1], 522→2088 y halo de 40 píxeles (RealESRGAN general_x4v3).") }
            var hash = SHA256()
            if modelURL.pathExtension.lowercased() == "mlmodel" {
                hash.update(data: Data(try IntegrityManifest.digest(modelURL).utf8))
            } else if let enumerator = FileManager.default.enumerator(atPath: modelURL.path) {
                let names = enumerator.allObjects.compactMap { $0 as? String }.sorted()
                for name in names {
                    try ProcessingControl.checkpoint()
                    let url = modelURL.appendingPathComponent(name)
                    if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        hash.update(data: Data((name + (try IntegrityManifest.digest(url))).utf8))
                    }
                }
            }
            fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
            initialized = true
        }
        deinit { if let compiled { try? FileManager.default.removeItem(at: compiled) } }

        private static func compileOwned(_ source: URL) throws -> (workspace: URL, model: URL) {
            let fm = FileManager.default, token = UUID().uuidString
            let workspace = fm.temporaryDirectory.appendingPathComponent("FormaCoreML-\(token)", isDirectory: true)
            try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
            var succeeded = false
            defer { if !succeeded { try? fm.removeItem(at: workspace) } }
            // A unique input basename also isolates Core ML's compiler output;
            // another window/process cannot delete this runner's mapped weights.
            let copy = workspace.appendingPathComponent("model-\(token)." + source.pathExtension)
            if source.pathExtension.lowercased() == "mlpackage" { try CooperativeFileIO.copyDirectory(source, to: copy) }
            else { try CooperativeFileIO.copyFile(source, to: copy) }
            try ProcessingControl.checkpoint()
            let compiled = try MLModel.compileModel(at: copy)
            defer { try? fm.removeItem(at: compiled) }
            let owned = workspace.appendingPathComponent("compiled.mlmodelc", isDirectory: true)
            try fm.moveItem(at: compiled, to: owned)
            try ProcessingControl.checkpoint()
            succeeded = true
            return (workspace, owned)
        }

        func input(rgba: [UInt8], labels: [Int], width: Int, height: Int, placements: [Placement]) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
            let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
            pointer.initialize(repeating: 0, count: array.count)
            for placement in placements {
                try ProcessingControl.checkpoint()
                let patch = placement.patch, patchWidth = patch.width + 2*halo, patchHeight = patch.height + 2*halo
                var nearest = [Int](repeating: -1, count: patchWidth*patchHeight), queue: [Int] = []
                queue.reserveCapacity(nearest.count)
                for row in 0..<patchHeight {
                    let sy = patch.y + row - halo
                    guard sy >= 0, sy < height else { continue }
                    for column in 0..<patchWidth {
                        let sx = patch.x + column - halo
                        if sx >= 0, sx < width, labels[sy*width+sx] == patch.island {
                            let i = row*patchWidth+column
                            nearest[i] = i; queue.append(i)
                        }
                    }
                }
                guard !queue.isEmpty else { throw invalid("Una isla UV no contiene muestras para su contexto.") }
                var next = 0
                while next < queue.count {
                    if next & 8191 == 0 { try ProcessingControl.checkpoint() }
                    let i = queue[next], x = i % patchWidth, y = i / patchWidth
                    next += 1
                    func extend(_ n: Int) {
                        if nearest[n] == -1 { nearest[n] = nearest[i]; queue.append(n) }
                    }
                    if x > 0 { extend(i-1) }; if x+1 < patchWidth { extend(i+1) }
                    if y > 0 { extend(i-patchWidth) }; if y+1 < patchHeight { extend(i+patchWidth) }
                }
                for row in 0..<patchHeight {
                    if row & 15 == 0 { try ProcessingControl.checkpoint() }
                    for column in 0..<patchWidth {
                        let seed = nearest[row*patchWidth+column]
                        let sy = patch.y + seed / patchWidth - halo, sx = patch.x + seed % patchWidth - halo
                        // Every seed was admitted only by this exact component label.
                        let source = (sy*width+sx)*4, target = (placement.y+row)*side+placement.x+column
                        for channel in 0..<3 { pointer[channel*side*side+target] = Float(rgba[source+channel])/255 }
                    }
                }
            }
            return array
        }
    }

    private struct Island { let id: Int, x: Int, y: Int, width: Int, height: Int }
    private struct Patch { let island: Int, x: Int, y: Int, width: Int, height: Int }
    private struct Placement { let patch: Patch, x: Int, y: Int }

    private static func islands(_ mask: [UInt8], width: Int, height: Int) throws -> (labels: [Int], islands: [Island]) {
        var labels = [Int](repeating: 0, count: mask.count), regions: [Island] = [], queue: [Int] = []
        for seed in mask.indices where mask[seed] != 0 && labels[seed] == 0 {
            try ProcessingControl.checkpoint()
            let id = regions.count + 1
            queue.removeAll(keepingCapacity: true); queue.append(seed); labels[seed] = id
            var next = 0, left = seed % width, right = left, top = seed / width, bottom = top
            while next < queue.count {
                if next & 8191 == 0 { try ProcessingControl.checkpoint() }
                let i = queue[next], x = i % width, y = i / width
                next += 1
                left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y)
                func extend(_ n: Int) {
                    if mask[n] != 0 && labels[n] == 0 { labels[n] = id; queue.append(n) }
                }
                if x > 0 { extend(i-1) }; if x+1 < width { extend(i+1) }
                if y > 0 { extend(i-width) }; if y+1 < height { extend(i+width) }
            }
            regions.append(Island(id:id,x:left,y:top,width:right-left+1,height:bottom-top+1))
        }
        return (labels, regions)
    }
    private static func patches(_ regions: [Island], labels: [Int], weights: [UInt8], width: Int, core: Int) throws -> [Patch] {
        var result: [Patch] = []
        for region in regions {
            try ProcessingControl.checkpoint()
            for y in stride(from: region.y, to: region.y+region.height, by: core) {
                for x in stride(from: region.x, to: region.x+region.width, by: core) {
                    let w = min(core, region.x+region.width-x), h = min(core, region.y+region.height-y)
                    var active = false
                    for row in y..<(y+h) where !active {
                        for column in x..<(x+w) where labels[row*width+column] == region.id && weights[row*width+column] > 0 { active = true; break }
                    }
                    if active { result.append(Patch(island:region.id,x:x,y:y,width:w,height:h)) }
                }
            }
        }
        return result
    }
    private static func pack(_ patches: [Patch], side: Int, halo: Int) throws -> [[Placement]] {
        let ordered = patches.sorted {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.island != $1.island { return $0.island < $1.island }
            return $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y
        }
        var pages: [[Placement]] = [], page: [Placement] = [], x = 0, y = 0, rowHeight = 0
        for patch in ordered {
            try ProcessingControl.checkpoint()
            let w = patch.width+halo*2, h = patch.height+halo*2
            guard w <= side, h <= side else { throw invalid("Un parche excede el tamaño de entrada del modelo.") }
            if x+w > side { x = 0; y += rowHeight; rowHeight = 0 }
            if y+h > side { pages.append(page); page = []; x = 0; y = 0; rowHeight = 0 }
            page.append(Placement(patch:patch,x:x,y:y)); x += w; rowHeight = max(rowHeight,h)
        }
        if !page.isEmpty { pages.append(page) }
        return pages
    }

    private struct Sampler {
        let array: MLMultiArray
        let data: UnsafeMutableRawPointer
        let channelStride: Int, rowStride: Int, columnStride: Int
        let type: MLMultiArrayDataType
        init(_ array: MLMultiArray) throws {
            guard [.float16, .float32, .double].contains(array.dataType) else { throw invalid("El modelo produjo un tipo numérico no compatible.") }
            self.array = array
            data = array.dataPointer
            let strides = array.strides.map(\.intValue)
            channelStride = strides[1]; rowStride = strides[2]; columnStride = strides[3]; type = array.dataType
        }
        @inline(__always) func value(channel: Int, x: Int, y: Int) -> Float {
            let index = channel * channelStride + y * rowStride + x * columnStride
            let value: Float
            switch type {
            case .float16:
                // Float16 is unavailable on the x86_64 slice of the universal Mac target.
                let bits = UInt32(data.assumingMemoryBound(to: UInt16.self)[index])
                let sign = (bits & 0x8000) << 16, exponent = (bits >> 10) & 31, fraction = bits & 1023
                if exponent == 0 { value = (sign == 0 ? 1 : -1) * Float(fraction) * 0.000000059604644775390625 }
                else if exponent == 31 { value = fraction == 0 ? (sign == 0 ? .infinity : -.infinity) : .nan }
                else { value = Float(bitPattern: sign | ((exponent + 112) << 23) | (fraction << 13)) }
            case .float32: value = data.assumingMemoryBound(to: Float.self)[index]
            case .double: value = Float(data.assumingMemoryBound(to: Double.self)[index])
            default: value = .nan
            }
            return value
        }
    }

    private typealias Triangle = USDZTextureRestorationAdapter.Triangle
    private static func triangles(in inventory: TextureAssetInventory) throws -> [String: [Triangle]] {
        var map: [String: String] = [:]
        for asset in inventory.assets { for name in asset.materialNames { map[name] = asset.relativePath } }
        var result: [String: [Triangle]] = [:], coordinates: [SIMD2<Float>] = [], material = ""
        let text = try String(contentsOf: inventory.modelURL, encoding: .utf8)
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            if index & 4095 == 0 { try ProcessingControl.checkpoint() }
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let kind = parts.first else { continue }
            if kind == "vt", parts.count >= 3, let u = Float(parts[1]), let v = Float(parts[2]), u.isFinite, v.isFinite {
                coordinates.append(SIMD2(u, v))
            } else if kind == "usemtl" { material = parts.dropFirst().joined(separator: " ") }
            else if kind == "f", let name = map[material] {
                let polygon = parts.dropFirst().compactMap { token -> SIMD2<Float>? in
                    let refs = token.split(separator: "/", omittingEmptySubsequences: false)
                    guard refs.count > 1, let raw = Int(refs[1]) else { return nil }
                    let offset = raw > 0 ? raw - 1 : coordinates.count + raw
                    return coordinates.indices.contains(offset) ? coordinates[offset] : nil
                }
                guard polygon.count == parts.count - 1, polygon.count >= 3 else { continue }
                for vertex in 1..<(polygon.count - 1) { result[name, default: []].append(.init(a: polygon[0], b: polygon[vertex], c: polygon[vertex + 1])) }
            }
        }
        return result
    }

    private static func coverage(_ triangles: [Triangle], width: Int, height: Int) throws -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        func point(_ uv: SIMD2<Float>) -> SIMD2<Float> { SIMD2(uv.x * Float(width), (1 - uv.y) * Float(height)) }
        func edge(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ p: SIMD2<Float>) -> Float {
            let lhs: Float = (b.x - a.x) * (p.y - a.y)
            let rhs: Float = (b.y - a.y) * (p.x - a.x)
            return lhs - rhs
        }
        func inUnitSquare(_ uv: SIMD2<Float>) -> Bool {
            let insideX: Bool = uv.x >= 0 && uv.x <= 1
            let insideY: Bool = uv.y >= 0 && uv.y <= 1
            return insideX && insideY
        }
        for (index, triangle) in triangles.enumerated() {
            if index & 255 == 0 { try ProcessingControl.checkpoint() }
            guard inUnitSquare(triangle.a), inUnitSquare(triangle.b), inUnitSquare(triangle.c) else { continue }
            let a = point(triangle.a), b = point(triangle.b), c = point(triangle.c)
            guard abs(edge(a,b,c)) > 0.000_001 else { continue }
            let left = max(0, Int(floor(min(a.x,min(b.x,c.x))))), right = min(width - 1, Int(ceil(max(a.x,max(b.x,c.x)))))
            let top = max(0, Int(floor(min(a.y,min(b.y,c.y))))), bottom = min(height - 1, Int(ceil(max(a.y,max(b.y,c.y)))))
            guard left <= right, top <= bottom else { continue }
            for y in top...bottom {
                if y & 31 == 0 { try ProcessingControl.checkpoint() }
                for x in left...right {
                    let p = SIMD2(Float(x)+0.5, Float(y)+0.5)
                    let e = SIMD3(edge(a,b,p),edge(b,c,p),edge(c,a,p))
                    let allPositive: Bool = e.x >= 0 && e.y >= 0 && e.z >= 0
                    let allNegative: Bool = e.x <= 0 && e.y <= 0 && e.z <= 0
                    if allPositive || allNegative { mask[y * width + x] = 1 }
                }
            }
        }
        return mask
    }
    private static func erode(_ mask: inout [UInt8], width: Int, height: Int, radius: Int) throws {
        var horizontal = mask
        for y in 0..<height {
            try ProcessingControl.checkpoint()
            var prefix = [Int](repeating: 0, count: width + 1)
            for x in 0..<width { prefix[x+1] = prefix[x] + Int(mask[y*width+x]) }
            for x in 0..<width { horizontal[y*width+x] = x >= radius && x+radius < width && prefix[x+radius+1]-prefix[x-radius] == radius*2+1 ? 1 : 0 }
        }
        for x in 0..<width {
            if x & 15 == 0 { try ProcessingControl.checkpoint() }
            var prefix = [Int](repeating: 0, count: height + 1)
            for y in 0..<height { prefix[y+1] = prefix[y] + Int(horizontal[y*width+x]) }
            for y in 0..<height { mask[y*width+x] = y >= radius && y+radius < height && prefix[y+radius+1]-prefix[y-radius] == radius*2+1 ? 1 : 0 }
        }
    }
    private static func feather(_ mask: [UInt8], width: Int, height: Int, radius: UInt8) -> [UInt8] {
        var distance = mask.map { $0 == 0 ? UInt8(0) : radius }
        for y in 0..<height { for x in 0..<width where mask[y*width+x] != 0 {
            distance[y*width+x] = UInt8(min(Int(radius), min(min(x+1, width-x), min(y+1, height-y))))
        } }
        for y in 0..<height { for x in 0..<width where distance[y*width+x] != 0 {
            let i = y*width+x
            if x > 0 { distance[i] = min(distance[i], distance[i-1] + 1) }
            if y > 0 { distance[i] = min(distance[i], distance[i-width] + 1) }
        } }
        for y in stride(from: height-1, through: 0, by: -1) { for x in stride(from: width-1, through: 0, by: -1) where distance[y*width+x] != 0 {
            let i = y*width+x
            if x+1 < width { distance[i] = min(distance[i], distance[i+1] + 1) }
            if y+1 < height { distance[i] = min(distance[i], distance[i+width] + 1) }
        } }
        return distance
    }
    private static func raster(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw invalid("No se pudo decodificar el atlas.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
    private static func writePNG(_ rgba: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent),
              let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw invalid("No se pudo preparar el PNG derivado.") }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw invalid("No se pudo guardar el PNG derivado.") }
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "FormaLocalAI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
