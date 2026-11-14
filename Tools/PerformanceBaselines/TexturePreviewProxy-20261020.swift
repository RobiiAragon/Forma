import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

/// Only the viewer uses these disposable copies. OBJ vertices, UVs and exported photos stay native.
enum BaselineTexturePreviewProxy {
    struct Result { var url: URL; var adapted: Bool }
    static func prepare(_ model: URL, budgetBytes: UInt64? = nil,
                        checkCancellation: () throws -> Void) throws -> Result {
        guard model.pathExtension.lowercased() == "obj" else { return .init(url: model, adapted: false) }
        try checkCancellation()
        let obj = try BaselineReads.text(model)
        let lines = obj.components(separatedBy: .newlines)
        let libraries = lines.compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("mtllib ") ? String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        }
        guard libraries.count == 1, ScanStore.safeRelativePath(libraries[0]) else { return .init(url: model, adapted: false) }
        let mtlURL = model.deletingLastPathComponent().appendingPathComponent(libraries[0])
        guard FileManager.default.fileExists(atPath: mtlURL.path) else { return .init(url: model, adapted: false) }
        let mtl = try BaselineReads.text(mtlURL)
        let materialLines = mtl.components(separatedBy: .newlines)
        struct Source { var name: String; var url: URL; var width: Int; var height: Int }
        var sources: [Source] = [], known = Set<String>(), pixels = 0.0
        var identity = Data((model.path + obj + mtl).utf8)
        for line in materialLines {
            try checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("map_Kd ") else { continue }
            let name = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            guard ScanStore.safeRelativePath(name) else { return .init(url: model, adapted: false) }
            guard known.insert(name).inserted else { continue }
            let url = mtlURL.deletingLastPathComponent().appendingPathComponent(name)
            guard let image = BaselineReads.image(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString:Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
                return .init(url: model, adapted: false)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            identity.append(Data("\(name):\(attributes[.size] ?? 0):\(attributes[.modificationDate] ?? Date.distantPast)".utf8))
            sources.append(.init(name: name, url: url, width: w, height: h)); pixels += Double(w) * Double(h)
        }
        // Include mipmaps in the resource estimate and leave working memory for decoding/geometry.
        let physical = ProcessInfo.processInfo.physicalMemory
        #if os(iOS)
        #if targetEnvironment(simulator)
        let resourceBudget = physical / 8
        #else
        let available = UInt64(os_proc_available_memory())
        let resourceBudget = min(physical / 8, available > 0 ? available / 4 : physical / 32)
        #endif
        #else
        let resourceBudget = physical / 8
        #endif
        let budget = Double(budgetBytes ?? resourceBudget)
        guard !sources.isEmpty, pixels * 4 * 4 / 3 > budget else { return .init(url: model, adapted: false) }
        let requestedScale = min(1, sqrt(max(4, budget) / (pixels * 4 * 4 / 3)))
        let scale = pow(2, floor(log2(requestedScale)))
        identity.append(Data(String(scale).utf8))
        let key = SHA256.hash(data: identity).map { String(format:"%02x", $0) }.joined()
        let cache = model.deletingLastPathComponent().appendingPathComponent("cache", isDirectory: true)
        let final = cache.appendingPathComponent(key, isDirectory: true)
        let output = final.appendingPathComponent("preview.obj")
        if FileManager.default.fileExists(atPath: output.path) { return .init(url: output, adapted: true) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var names: [String:String] = [:]
        for (index, source) in sources.enumerated() {
            try checkCancellation()
            let name = "preview-\(index).png"
            try autoreleasepool {
                guard let imageSource = CGImageSourceCreateWithURL(source.url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceThumbnailMaxPixelSize:max(1, Int(Double(max(source.width, source.height)) * scale)),
                        kCGImageSourceCreateThumbnailWithTransform:false,
                        kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
                      let destination = CGImageDestinationCreateWithURL(staging.appendingPathComponent(name) as CFURL,
                        UTType.png.identifier as CFString, 1, nil) else {
                    throw NSError(domain:"FormaPreview", code:1, userInfo:[NSLocalizedDescriptionKey:"No se pudo preparar la textura de pantalla."])
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            }
            names[source.name] = name
        }
        let proxyMTL = materialLines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("map_Kd ") else { return line }
            let original = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return names[original].map { "map_Kd \($0)" } ?? line
        }.joined(separator:"\n")
        try proxyMTL.write(to: staging.appendingPathComponent("preview.mtl"), atomically: true, encoding: .utf8)
        let proxyOBJ = lines.map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("mtllib ") ? "mtllib preview.mtl" : $0 }.joined(separator:"\n")
        try checkCancellation()
        try proxyOBJ.write(to: staging.appendingPathComponent("preview.obj"), atomically: true, encoding: .utf8)
        do { try FileManager.default.moveItem(at: staging, to: final) }
        catch { guard FileManager.default.fileExists(atPath: output.path) else { throw error } }
        return .init(url: output, adapted: true)
    }
}
