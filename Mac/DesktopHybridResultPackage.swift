import Foundation

/// Builds a confined result-only bundle. A model package travels completely,
/// including the Gaussian optimizer checkpoint and engine metadata. Source photos
/// and the old library capture/integrity/publication files stay in their library.
enum DesktopHybridResultPackage {
    private static let assetExtensions: Set<String> = [
        "obj", "mtl", "ply", "stl", "splat", "spz", "usd", "usdz", "usda", "usdc", "glb", "gltf", "bin",
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp", "exr", "hdr", "ktx", "ktx2", "basis", "dds", "tga"
    ]

    static func prepare(jobID: UUID, record: ScanRecord, libraryDirectory: URL,
                        libraryRoot: URL, cacheRoot: URL) throws -> HybridTransfer.ResultSource {
        let fm = FileManager.default
        let folder = try confinedDirectory(libraryDirectory, in: libraryRoot)
        guard let model = record.modelFile, ScanStore.safeRelativePath(model) else { throw invalid() }
        _ = try checkedFile(model, in: folder)
        let packaged = model.hasPrefix("modelo/")
        let input = packaged ? try confinedDirectory(folder.appendingPathComponent("modelo"), in: folder) : folder
        let relativeModel = packaged ? String(model.dropFirst("modelo/".count)) : model
        var gaussian: String?
        if let path = record.gaussianModelFile {
            guard ScanStore.safeRelativePath(path), packaged == path.hasPrefix("modelo/") else { throw invalid() }
            _ = try checkedFile(path, in: folder)
            gaussian = packaged ? String(path.dropFirst("modelo/".count)) : path
        }
        let owner = cacheRoot.appendingPathComponent(jobID.uuidString).appendingPathComponent(record.id.uuidString)
        try fm.createDirectory(at: owner, withIntermediateDirectories: true)
        _ = try confinedDirectory(owner, in: cacheRoot)
        let bundle = owner.appendingPathComponent("bundle", isDirectory: true)
        let marker = owner.appendingPathComponent("ready.json")
        let meshURL = folder.appendingPathComponent("malla.json")
        let meshExists = fm.fileExists(atPath: meshURL.path)
        if meshExists { _ = try checkedFile("malla.json", in: folder) }
        let descriptor = HybridTransfer.ResultDescriptor(jobID: jobID, resultID: record.id,
            name: record.name, mode: record.mode.rawValue, duration: record.duration,
            note: "Resultado local de Forma Desktop; captura original conservada.", statistics: record.statistics,
            modelRelativePath: "modelo/" + relativeModel, packageRelativePath: "modelo",
            meshRelativePath: meshExists ? "malla.json" : nil, gaussianModelRelativePath: gaussian)
        try descriptor.validate()
        // Reuse only a complete, independently hashed cache, never an unmarked copy.
        if let bytes = try? Data(contentsOf: marker),
           let previous = try? JSONDecoder().decode(CacheReceipt.self, from: bytes),
           previous.descriptor == descriptor, (try? verify(previous, at: bundle)) == true {
            return .init(descriptor: descriptor, directory: bundle)
        }
        let stage = owner.appendingPathComponent(".preparing-" + UUID().uuidString)
        try fm.createDirectory(at: stage.appendingPathComponent("modelo"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        guard let names = fm.enumerator(atPath: input.path) else { throw invalid() }
        var copied: Set<String> = []
        while let relative = names.nextObject() as? String {
            try Task.checkCancellation()
            guard ScanStore.safeRelativePath(relative) else { throw invalid() }
            let file = input.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw invalid() }
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: { ["fuentes", "dataset", ".pending"].contains($0.lowercased()) }) {
                if values.isDirectory == true { names.skipDescendants() }; continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw invalid() }
            // The complete derived package is preserved regardless of file size or
            // extension. Flat library exports use only model/texture assets, avoiding
            // unrelated capture reports and source metadata at the library root.
            guard packaged || assetExtensions.contains(file.pathExtension.lowercased()) else { continue }
            _ = try checkedFile(relative, in: input)
            let target = stage.appendingPathComponent("modelo/" + relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CooperativeFileIO.copyFile(file, to: target)
            copied.insert(relative)
        }
        guard copied.contains(relativeModel), gaussian.map({ copied.contains($0) }) ?? true else { throw invalid() }
        if meshExists { try CooperativeFileIO.copyFile(meshURL, to: stage.appendingPathComponent("malla.json")) }
        let files = try inventory(stage)
        let receipt = CacheReceipt(descriptor: descriptor, files: files)
        if fm.fileExists(atPath: bundle.path) {
            // This is our derived cache only, never the source library or dataset.
            _ = try confinedDirectory(bundle, in: owner)
            try fm.removeItem(at: bundle)
        }
        try fm.moveItem(at: stage, to: bundle)
        try DesktopRemoteControlLedger.writeDurably(JSONEncoder().encode(receipt), to: marker)
        return .init(descriptor: descriptor, directory: bundle)
    }

    private struct CacheReceipt: Codable { var descriptor: HybridTransfer.ResultDescriptor; var files: [HybridTransfer.FileDescriptor] }
    private static func verify(_ receipt: CacheReceipt, at root: URL) throws -> Bool {
        try inventory(root) == receipt.files
    }
    private static func inventory(_ root: URL) throws -> [HybridTransfer.FileDescriptor] {
        _ = try confinedDirectory(root, in: root.deletingLastPathComponent())
        guard let names = FileManager.default.enumerator(atPath: root.path) else { throw invalid() }
        var files: [HybridTransfer.FileDescriptor] = []
        while let name = names.nextObject() as? String {
            let url = root.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw invalid() }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw invalid() }
            _ = try checkedFile(name, in: root)
            files.append(.init(path: name, bytes: try HybridTransfer.size(url), sha256: try HybridTransfer.digest(url)))
        }
        return files.sorted { $0.path < $1.path }
    }
    private static func confinedDirectory(_ url: URL, in root: URL) throws -> URL {
        let actualRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let standardized = url.standardizedFileURL
        let actual = standardized.resolvingSymlinksInPath()
        let values = try standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true, standardized == actual,
              actual.path.hasPrefix(actualRoot.path + "/") else { throw invalid() }
        return actual
    }
    private static func checkedFile(_ relative: String, in root: URL) throws -> URL {
        guard ScanStore.safeRelativePath(relative) else { throw invalid() }
        var current = root
        let components = relative.split(separator: "/")
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true,
                  index == components.count - 1 ? values.isRegularFile == true : values.isDirectory == true else { throw invalid() }
        }
        let actualRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard current.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(actualRoot.path + "/") else { throw invalid() }
        return current
    }
    private static func invalid() -> HybridTransfer.TransferError {
        .failed("El paquete derivado no está completo o sus rutas necesitan revisión en la Mac; las fuentes se conservan.")
    }
}
