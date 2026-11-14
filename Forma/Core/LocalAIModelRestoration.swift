import Foundation
import CryptoKit
import ImageIO

/// Restores diffuse atlases in a new native model. USD geometry is copied as
/// bytes; ModelIO is used only to read its UV coverage, never to re-export it.
enum LocalAIModelRestoration {
    private struct Binding: Codable, Equatable {
        var sourceSHA256: String
        var weightsFingerprint: String
        var strength: Double
    }
    private struct CompletedFile: Codable, Equatable {
        var name: String
        var sha256: String
    }

    static func supports(_ model: URL) -> Bool {
        ["obj", "usdz"].contains(model.pathExtension.lowercased())
    }

    static func textureCount(model: URL) throws -> Int {
        if model.pathExtension.lowercased() == "obj" {
            return try TextureAssetInventory.load(modelURL: model).assets.count
        }
        let archive = try StoredUSDZArchive(url: model)
        return try USDZTextureRestorationAdapter.loadUVMapping(modelURL: model,
            textureEntryNames: pngEntries(archive)).triangles.count
    }

    static func run(model: URL, output: URL, restorer: URL, strength: Double,
                    control: ProcessingControl? = nil,
                    pacing: (@Sendable () throws -> Void)? = nil,
                    cpuOnly: Bool = false, checkpointDirectory: URL? = nil,
                    progress: @Sendable (String, Double) -> Void = { _, _ in }) throws -> LocalAITextureEnhancer.Report {
        if model.pathExtension.lowercased() == "obj" {
            return try LocalAITextureEnhancer.run(package: model.deletingLastPathComponent(), output: output,
                modelURL: restorer, strength: strength, control: control, pacing: pacing, cpuOnly: cpuOnly,
                checkpointDirectory: checkpointDirectory, progress: progress)
        }
        guard model.pathExtension.lowercased() == "usdz", strength.isFinite, (0...1).contains(strength) else {
            throw invalid("Se necesita un OBJ o USDZ y una intensidad válida.")
        }
        return try ProcessingControl.withControl(control) {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: output.path) else { throw invalid("La copia de salida ya existe.") }
            guard !overlaps(output, model.deletingLastPathComponent()) else {
                throw invalid("La copia necesita una carpeta separada del modelo original.")
            }
            let work = checkpointDirectory ?? fm.temporaryDirectory.appendingPathComponent("FormaUSDZAI-" + UUID().uuidString)
            guard !overlaps(work, model.deletingLastPathComponent()), !overlaps(work, output) else {
                throw invalid("La entrada, el avance y la salida necesitan carpetas separadas.")
            }
            if fm.fileExists(atPath: work.path) { try requireRegular(work, directory: true) }
            else { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
            defer { if checkpointDirectory == nil { try? fm.removeItem(at: work) } }
            let binding = Binding(sourceSHA256: try IntegrityManifest.digest(model),
                weightsFingerprint: try fingerprint(restorer), strength: strength)
            let bindingURL = work.appendingPathComponent("source.json")
            if fm.fileExists(atPath: bindingURL.path) {
                try requireRegular(bindingURL)
                guard try JSONDecoder().decode(Binding.self, from: Data(contentsOf: bindingURL)) == binding else {
                    throw invalid("Cambiaron el USDZ, los pesos o la intensidad. Se conserva el avance anterior.")
                }
            } else {
                guard try fm.contentsOfDirectory(atPath: work.path).isEmpty else {
                    throw invalid("La carpeta de avance USDZ no tiene una procedencia válida.")
                }
                try JSONEncoder().encode(binding).write(to: bindingURL, options: .atomic)
            }
            try ProcessingControl.checkpoint(); try pacing?()
            progress("Leyendo geometría y UV originales del USDZ", 0)
            let archive = try StoredUSDZArchive(url: model)
            let mapping = try USDZTextureRestorationAdapter.loadUVMapping(modelURL: model,
                textureEntryNames: pngEntries(archive))
            guard !mapping.triangles.isEmpty else { throw invalid("El USDZ no contiene atlas difusos con UV compatibles.") }
            let input = work.appendingPathComponent("input", isDirectory: true)
            if fm.fileExists(atPath: input.path) { try validateExtracted(archive: archive, original: model, directory: input) }
            else { _ = try archive.extract(toPrivateDirectory: input) }
            guard let rootEntry = archive.entries.first else { throw invalid("El USDZ está vacío.") }
            let layer = input.appendingPathComponent(rootEntry.name)
            var assets: [TextureAssetInventory.Asset] = []
            for path in mapping.triangles.keys.sorted() {
                let url = input.appendingPathComponent(path)
                guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let values = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                      let width = (values[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                      let height = (values[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                      width > 0, height > 0 else { throw invalid("No se pudo leer un atlas del USDZ.") }
                assets.append(.init(relativePath: path, url: url, width: width, height: height, materialNames: []))
            }
            let inventory = TextureAssetInventory(modelURL: layer, mtlURL: layer, assets: assets)
            let restored = work.appendingPathComponent("restored", isDirectory: true)
            let integrity = work.appendingPathComponent("restored-integrity.json")
            if fm.fileExists(atPath: restored.path), !fm.fileExists(atPath: integrity.path) {
                // Keep an interrupted publication, then rebuild from the source.
                // A report by itself cannot authenticate completed atlas bytes.
                try requireRegular(restored, directory: true)
                try fm.moveItem(at: restored, to: work.appendingPathComponent("unverified-restored-" + UUID().uuidString))
            }
            var report: LocalAITextureEnhancer.Report
            if fm.fileExists(atPath: restored.path) {
                try requireRegular(integrity)
                guard try JSONDecoder().decode([CompletedFile].self, from: Data(contentsOf: integrity)) == completedFiles(restored) else {
                    throw invalid("Las texturas terminadas no coinciden con su avance guardado.")
                }
                try validateRestoredContents(original: model, extracted: restored, replaced: Set(mapping.triangles.keys))
                let receipt = restored.appendingPathComponent("ia-local.json")
                try requireRegular(receipt)
                report = try JSONDecoder().decode(LocalAITextureEnhancer.Report.self, from: Data(contentsOf: receipt))
            } else {
                report = try LocalAITextureEnhancer.run(package: input, output: restored,
                    modelURL: restorer, strength: strength, control: control, pacing: pacing, cpuOnly: cpuOnly,
                    checkpointDirectory: work.appendingPathComponent("atlases", isDirectory: true),
                    preparedInput: .init(inventory: inventory, triangles: mapping.triangles, modelRelativePath: rootEntry.name),
                    progress: { message, fraction in progress(message, fraction * 0.9) })
                try JSONEncoder().encode(completedFiles(restored)).write(to: integrity, options: .atomic)
            }
            try ProcessingControl.checkpoint(); try pacing?()
            progress("Empaquetando USDZ con geometría original", 0.9)
            let publication = output.deletingLastPathComponent().appendingPathComponent(".usdz-ai-" + UUID().uuidString)
            defer { try? fm.removeItem(at: publication) }
            try fm.createDirectory(at: publication, withIntermediateDirectories: true)
            let newModel = publication.appendingPathComponent("modelo.usdz")
            let replacements = Dictionary(uniqueKeysWithValues: mapping.triangles.keys.map { ($0, restored.appendingPathComponent($0)) })
            try archive.rewrite(to: newModel, replacements: replacements)
            try validateGeometry(original: model, candidate: newModel)
            report.packageURL = output; report.modelURL = output.appendingPathComponent("modelo.usdz")
            try JSONEncoder().encode(report).write(to: publication.appendingPathComponent("ia-local.json"), options: .atomic)
            try ProcessingControl.checkpoint()
            try fm.moveItem(at: publication, to: output)
            progress("Copia USDZ restaurada; geometría y originales conservados", 1)
            return report
        }
    }

    static func restoredReport(package: URL, sourceModel: URL) throws -> LocalAITextureEnhancer.Report {
        let candidate = package.appendingPathComponent(sourceModel.pathExtension.lowercased() == "usdz" ? "modelo.usdz" : "modelo.obj")
        try validateGeometry(original: sourceModel, candidate: candidate)
        var report = try JSONDecoder().decode(LocalAITextureEnhancer.Report.self,
            from: Data(contentsOf: package.appendingPathComponent("ia-local.json")))
        report.packageURL = package; report.modelURL = candidate
        return report
    }

    static func validateGeometry(original: URL, candidate: URL) throws {
        if original.pathExtension.lowercased() == "obj" {
            let source = try TextureAssetInventory.load(modelURL: original)
            let restored = try TextureAssetInventory.load(modelURL: candidate)
            guard FileManager.default.contentsEqual(atPath: original.path, andPath: candidate.path),
                  FileManager.default.contentsEqual(atPath: source.mtlURL.path, andPath: restored.mtlURL.path) else {
                throw invalid("La copia no conserva la geometría y materiales originales.")
            }
            return
        }
        let source = try StoredUSDZArchive(url: original), target = try StoredUSDZArchive(url: candidate)
        guard source.entries.map(\.name) == target.entries.map(\.name) else { throw invalid("La copia cambió los miembros del USDZ.") }
        let diffuse = Set(try USDZTextureRestorationAdapter.loadUVMapping(modelURL: original,
            textureEntryNames: pngEntries(source)).triangles.keys)
        for (a, b) in zip(source.entries, target.entries) where !diffuse.contains(a.name) {
            guard a.size == b.size, try equalBytes(original, offset: a.offset, candidate, offset: b.offset, count: a.size) else {
                throw invalid("La copia cambió geometría, UV o un recurso que no es color difuso.")
            }
        }
    }

    private static func validateExtracted(archive: StoredUSDZArchive, original: URL, directory: URL) throws {
        try requireRegular(directory, directory: true)
        let files = try CooperativeFileIO.inventory(directory).filter { !$0.directory }
        guard Set(files.map(\.name)) == Set(archive.entries.filter { !$0.isDirectory }.map(\.name)) else { throw invalid("La extracción guardada no coincide con el USDZ original.") }
        for entry in archive.entries where !entry.isDirectory {
            let file = directory.appendingPathComponent(entry.name); try requireRegular(file)
            guard try fileSize(file) == entry.size,
                  try equalBytes(original, offset: entry.offset, file, offset: 0, count: entry.size) else {
                throw invalid("La extracción guardada fue modificada; las fuentes se conservan.")
            }
        }
    }
    private static func validateRestoredContents(original: URL, extracted: URL, replaced: Set<String>) throws {
        let archive = try StoredUSDZArchive(url: original)
        let files = try CooperativeFileIO.inventory(extracted).filter { !$0.directory }
        guard Set(files.map(\.name)) == Set(archive.entries.filter { !$0.isDirectory }.map(\.name)).union(["ia-local.json"]) else {
            throw invalid("El resultado intermedio contiene archivos inesperados.")
        }
        for entry in archive.entries where !entry.isDirectory && !replaced.contains(entry.name) {
            let file = extracted.appendingPathComponent(entry.name); try requireRegular(file)
            guard try fileSize(file) == entry.size,
                  try equalBytes(original, offset: entry.offset, file, offset: 0, count: entry.size) else {
                throw invalid("El resultado intermedio cambió la geometría original.")
            }
        }
    }
    private static func equalBytes(_ first: URL, offset firstOffset: UInt64, _ second: URL, offset secondOffset: UInt64, count: UInt64) throws -> Bool {
        let a = try FileHandle(forReadingFrom: first), b = try FileHandle(forReadingFrom: second)
        defer { try? a.close(); try? b.close() }
        try a.seek(toOffset: firstOffset); try b.seek(toOffset: secondOffset)
        var remaining = count
        while remaining > 0 {
            try ProcessingControl.checkpoint()
            let length = Int(min(remaining, 1024*1024))
            let x = try a.read(upToCount: length), y = try b.read(upToCount: length)
            guard let x, let y, x.count == length, x == y else { return false }
            remaining -= UInt64(length)
        }
        return true
    }
    private static func fileSize(_ url: URL) throws -> UInt64 {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 else { throw invalid("Tamaño de archivo inválido.") }
        return UInt64(size)
    }
    private static func requireRegular(_ url: URL, directory: Bool = false) throws {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard value.isSymbolicLink != true, directory ? value.isDirectory == true : value.isRegularFile == true else {
            throw invalid("La copia necesita archivos y carpetas regulares.")
        }
    }
    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let x = a.resolvingSymlinksInPath().standardizedFileURL.path, y = b.resolvingSymlinksInPath().standardizedFileURL.path
        return x == y || x.hasPrefix(y+"/") || y.hasPrefix(x+"/")
    }
    private static func fingerprint(_ url: URL) throws -> String {
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true { return try IntegrityManifest.digest(url) }
        var hash = SHA256()
        for item in try CooperativeFileIO.inventory(url).filter({ !$0.directory }).sorted(by: { $0.name < $1.name }) {
            hash.update(data: Data((item.name + (try IntegrityManifest.digest(item.url))).utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func completedFiles(_ directory: URL) throws -> [CompletedFile] {
        try CooperativeFileIO.inventory(directory).filter { !$0.directory }.sorted(by: { $0.name < $1.name }).map {
            .init(name: $0.name, sha256: try IntegrityManifest.digest($0.url))
        }
    }
    private static func pngEntries(_ archive: StoredUSDZArchive) -> Set<String> {
        Set(archive.entries.filter { !$0.isDirectory && URL(fileURLWithPath: $0.name).pathExtension.lowercased() == "png" }.map(\.name))
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "FormaUSDZRestoration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
