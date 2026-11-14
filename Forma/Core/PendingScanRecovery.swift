import Foundation
import ImageIO

/// Recover only the final persistence stage, after capture.json was written.
/// Incomplete acquisition/baking folders stay untouched and are never published.
enum PendingScanRecovery {
    private static let stagingPrefixes = [".pending-", ".restore-"]

    static func isStagingDirectoryName(_ name: String) -> Bool {
        stagingPrefixes.contains { name.hasPrefix($0) }
    }

    struct Report: Sendable {
        var recoveredCount = 0
        var remainingCount = 0
        var failures: [String] = []
    }
    static func recover(in base: URL, control: ProcessingControl? = nil,
                        progress: @Sendable (String, Double) -> Void = { _,_ in }) throws -> Report {
        try ProcessingControl.withControl(control) {
            let pending = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                .filter { isStagingDirectoryName($0.lastPathComponent) }
            var report = Report()
            for folder in pending {
                try ProcessingControl.checkpoint()
                do {
                    guard try folder.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey]).isSymbolicLink != true else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let record = try JSONDecoder().decode(ScanRecord.self, from: Data(contentsOf: folder.appendingPathComponent("captura.json")))
                    guard stagingPrefixes.contains(where: { folder.lastPathComponent == $0 + record.id.uuidString }),
                          let main = record.modelFile, ScanStore.safeRelativePath(main),
                          !record.exports.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    let destination = base.appendingPathComponent(record.id.uuidString, isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                    for name in Set(record.exports + [main, "informe.json"]).subtracting(["integridad.json"]) {
                        guard ScanStore.safeRelativePath(name) else { throw CocoaError(.fileReadInvalidFileName) }
                        let file = folder.appendingPathComponent(name)
                        guard FileManager.default.fileExists(atPath: file.path),
                              (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                            throw CocoaError(.fileReadNoSuchFile)
                        }
                    }
                    let info = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("informe.json"))) as? [String:Any]
                    guard info?["app"] as? String == "Forma" else { throw CocoaError(.fileReadCorruptFile) }
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("malla.json").path) {
                        let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: folder.appendingPathComponent("malla.json")))
                        try MeshExporter.validate(mesh)
                        guard mesh.faceCount == record.faceCount, mesh.vertexCount == record.vertexCount else { throw CocoaError(.fileReadCorruptFile) }
                    }
                    if let relative = record.datasetDirectory {
                        guard ScanStore.safeRelativePath(relative) else { throw CocoaError(.fileReadInvalidFileName) }
                        try validateDataset(folder.appendingPathComponent(relative))
                    }
                    let manifestURL = folder.appendingPathComponent("integridad.json")
                    let files = try regularFiles(in: folder).filter { $0.0 != "integridad.json" }
                    if FileManager.default.fileExists(atPath: manifestURL.path) {
                        let manifest = try JSONDecoder().decode(IntegrityManifest.self, from: Data(contentsOf: manifestURL))
                        let expected = Dictionary(uniqueKeysWithValues: files.map { ($0.0, $0.2) })
                        guard manifest.files.count == expected.count,
                              Set(manifest.files.map(\.name)) == Set(expected.keys),
                              manifest.files.allSatisfy({ expected[$0.name] == $0.bytes }) else { throw CocoaError(.fileReadCorruptFile) }
                        guard try manifest.verify(in: folder) else { throw CocoaError(.fileReadCorruptFile) }
                    } else {
                        let total = files.reduce(0.0) { $0 + Double($1.2) }
                        var done = 0.0
                        var entries: [IntegrityManifest.Entry] = []
                        for (name, file, size) in files {
                            try ProcessingControl.checkpoint()
                            progress("Verificando guardado pendiente: \(name)", total > 0 ? done / total : 0)
                            let sha = try IntegrityManifest.digest(file) { completed in
                                progress("Verificando guardado pendiente: \(name)", total > 0 ? (done + Double(completed)) / total : 0)
                            }
                            entries.append(.init(name: name, sha256: sha, bytes: size))
                            done += Double(size)
                        }
                        try ProcessingControl.checkpoint()
                        try JSONEncoder().encode(IntegrityManifest(createdAt: Date(), files: entries)).write(to: manifestURL, options: .atomic)
                    }
                    try ProcessingControl.checkpoint()
                    try FileManager.default.moveItem(at: folder, to: destination)
                    report.recoveredCount += 1
                    progress("Captura recuperada sin reemplazar originales", 1)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    report.remainingCount += 1
                    report.failures.append(folder.lastPathComponent + ": " + error.localizedDescription)
                }
            }
            return report
        }
    }

    private static func regularFiles(in directory: URL) throws -> [(String,URL,Int)] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { throw CocoaError(.fileReadUnknown) }
        var files: [(String,URL,Int)] = []
        while let name = enumerator.nextObject() as? String {
            try ProcessingControl.checkpoint()
            guard ScanStore.safeRelativePath(name) else { throw CocoaError(.fileReadInvalidFileName) }
            let url = directory.appendingPathComponent(name)
            let resources = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
            guard resources.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            if resources.isRegularFile == true {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                files.append((name,url,size))
            }
        }
        return files.sorted { $0.0 < $1.0 }
    }

    private static func validateDataset(_ directory: URL) throws {
        let manifest = try RGBDDatasetManifest.load(from: directory)
        for frame in manifest.frames {
            try ProcessingControl.checkpoint()
            guard frame.transformMatrix != nil, frame.intrinsics.count == 9, frame.intrinsics.allSatisfy(\.isFinite),
                  frame.imageWidth > 0, frame.imageHeight > 0, ScanStore.safeRelativePath(frame.rgbFile) else { throw CocoaError(.fileReadCorruptFile) }
            let imageURL = directory.appendingPathComponent(frame.rgbFile)
            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == frame.imageWidth,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == frame.imageHeight else { throw CocoaError(.fileReadCorruptFile) }
            for (name, bytesPerPixel) in [(frame.depthFile, 4), (frame.confidenceFile, 1)] {
                if let name {
                    guard ScanStore.safeRelativePath(name), let width = frame.depthWidth, let height = frame.depthHeight,
                          width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let actual = (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
                    let (pixels, overflowPixels) = Int64(width).multipliedReportingOverflow(by: Int64(height))
                    let (expected, overflowBytes) = pixels.multipliedReportingOverflow(by: Int64(bytesPerPixel))
                    guard !overflowPixels, !overflowBytes, actual == expected else { throw CocoaError(.fileReadCorruptFile) }
                }
            }
        }
    }
}
