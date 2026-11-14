import Foundation
import Darwin

/// Only calibrated frames referenced by the capture manifest enter the Apple engine.
/// Copies keep source inodes independent; APFS clones retain native bytes without a
/// second physical copy when supported. UUID source names never imply scan order.
enum DesktopPhotogrammetryInput {
    struct Item: Codable, Sendable, Equatable {
        var filename: String
        var sourceFile: String
        var frameID: String
        var timestamp: Double
    }
    struct Prepared: Sendable { var directory: URL; var items: [Item] }

    static func prepare(dataset: URL, sessionDirectory: URL,
                        progress: @Sendable (Double) -> Void = { _ in }) throws -> Prepared {
        let fm = FileManager.default
        let manifest = try RGBDDatasetManifest.load(from: dataset)
        guard !manifest.frames.isEmpty else { throw RGBDDatasetError.invalid("El manifiesto no contiene fotografías calibradas.") }
        let frames = manifest.frames.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        guard frames.allSatisfy({ $0.timestamp.isFinite }), Set(frames.map(\.id)).count == frames.count else {
            throw RGBDDatasetError.invalid("El manifiesto contiene identificadores duplicados o tiempos inválidos.")
        }
        try fm.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let stage = sessionDirectory.appendingPathComponent(".input-\(UUID().uuidString)", isDirectory: true)
        let destination = sessionDirectory.appendingPathComponent("input", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        var items: [Item] = []
        for (index, frame) in frames.enumerated() {
            try ProcessingControl.checkpoint()
            guard ScanStore.safeRelativePath(frame.rgbFile) else { throw RGBDDatasetError.invalid("Ruta de fotografía inválida en el manifiesto.") }
            let source = dataset.appendingPathComponent(frame.rgbFile)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let base = dataset.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else {
                throw RGBDDatasetError.invalid("La fotografía referenciada no es un archivo original válido.")
            }
            let ext = source.pathExtension.lowercased()
            guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw RGBDDatasetError.invalid("Extensión de fotografía inválida.") }
            let filename = String(format: "%08d", index) + "." + ext
            let output = stage.appendingPathComponent(filename)
            let cloned = source.withUnsafeFileSystemRepresentation { sourcePath in
                output.withUnsafeFileSystemRepresentation { outputPath in
                    guard let sourcePath, let outputPath else { return false }
                    return clonefile(sourcePath, outputPath, 0) == 0
                }
            }
            if !cloned {
                if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                try CooperativeFileIO.copyFile(source, to: output)
            }
            items.append(.init(filename: filename, sourceFile: frame.rgbFile, frameID: frame.id, timestamp: frame.timestamp))
            progress(Double(index + 1) / Double(frames.count))
        }
        try ProcessingControl.checkpoint()
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: stage, to: destination)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: sessionDirectory.appendingPathComponent("input-order.json"), options: .atomic)
        return .init(directory: destination, items: items)
    }
}
