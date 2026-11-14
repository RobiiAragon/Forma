import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

/// Only the viewer uses these disposable copies. OBJ vertices, UVs and exported photos stay native.
enum TexturePreviewProxy {
    struct Result { var url: URL; var adapted: Bool }
    enum ResourceAccess: String {
        case modelText, materialText, imageMetadata, thumbnailDecode, memoryCacheHit
        case sourceIdentityCheck, cachedOutputCheck
    }

    /// Metadata-only cache. No decoded image, OBJ text or mesh is retained.
    private struct FileStamp: Equatable {
        let url: URL
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init?(_ url: URL) {
            var value = stat()
            guard stat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
            self.url = url; device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
        var cacheIdentity: String {
            "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)"
        }
    }
    private final class Entry: NSObject {
        let result: Result
        let sources: [FileStamp]
        let pixels: Double
        let scale: Double
        init(result: Result, sources: [FileStamp], pixels: Double, scale: Double) {
            self.result = result; self.sources = sources; self.pixels = pixels; self.scale = scale
        }
    }
    private static let reused: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64 // Evictable metadata, never a limit on models or exports.
        return cache
    }()

    static func prepare(_ model: URL, budgetBytes: UInt64? = nil,
                        cacheDirectory: URL? = nil,
                        onResourceAccess: ((ResourceAccess) -> Void)? = nil,
                        checkCancellation: () throws -> Void) throws -> Result {
        guard model.pathExtension.lowercased() == "obj" else { return .init(url: model, adapted: false) }
        try checkCancellation()
        let cache = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FormaPreview", isDirectory: true)
        // Keep the supplied URL identity: lexical normalization across symlink/..
        // paths must not merge two potentially different source locations.
        let memoryKey = (model.absoluteString + "\0" + cache.absoluteString) as NSString
        let budget = Double(budgetBytes ?? resourceBudgetBytes())
        if let entry = reused.object(forKey: memoryKey), entry.scale == previewScale(pixels: entry.pixels, budget: budget) {
            var current = true
            for source in entry.sources {
                try checkCancellation()
                onResourceAccess?(.sourceIdentityCheck)
                if FileStamp(source.url) != source { current = false; break }
            }
            if current {
                onResourceAccess?(.cachedOutputCheck)
                if FileManager.default.fileExists(atPath: entry.result.url.path) {
                    onResourceAccess?(.memoryCacheHit)
                    return entry.result
                }
            }
        }
        // Capture identities before reading. Atomic replacement, same-size edits
        // preserving mtime, texture changes, and MTL changes all invalidate reuse.
        var stamps: [FileStamp] = [], canRemember = true
        func rememberSource(_ url: URL) {
            onResourceAccess?(.sourceIdentityCheck)
            if let stamp = FileStamp(url) { stamps.append(stamp) } else { canRemember = false }
        }
        func finish(_ result: Result, pixels: Double, scale: Double) throws -> Result {
            try checkCancellation()
            if canRemember {
                for source in stamps {
                    try checkCancellation()
                    onResourceAccess?(.sourceIdentityCheck)
                    if FileStamp(source.url) != source { canRemember = false; break }
                }
                if canRemember { reused.setObject(Entry(result: result, sources: stamps, pixels: pixels, scale: scale), forKey: memoryKey) }
            }
            return result
        }
        rememberSource(model)
        onResourceAccess?(.modelText)
        let obj = try String(contentsOf: model, encoding: .utf8)
        let lines = obj.components(separatedBy: .newlines)
        let libraries = lines.compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("mtllib ") ? String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        }
        guard libraries.count == 1, ScanStore.safeRelativePath(libraries[0]) else { return .init(url: model, adapted: false) }
        let mtlURL = model.deletingLastPathComponent().appendingPathComponent(libraries[0])
        guard FileManager.default.fileExists(atPath: mtlURL.path) else { return .init(url: model, adapted: false) }
        rememberSource(mtlURL)
        onResourceAccess?(.materialText)
        let mtl = try String(contentsOf: mtlURL, encoding: .utf8)
        let materialLines = mtl.components(separatedBy: .newlines)
        struct Source { var name: String; var url: URL; var width: Int; var height: Int }
        var sources: [Source] = [], known = Set<String>(), pixels = 0.0
        var identity = Data(("FormaPreview-v2:" + model.path + obj + mtl).utf8)
        for line in materialLines {
            try checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("map_Kd ") else { continue }
            let name = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            guard ScanStore.safeRelativePath(name) else { return .init(url: model, adapted: false) }
            guard known.insert(name).inserted else { continue }
            let url = mtlURL.deletingLastPathComponent().appendingPathComponent(name)
            rememberSource(url)
            onResourceAccess?(.imageMetadata)
            guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString:Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
                return .init(url: model, adapted: false)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            identity.append(Data("\(name):\(attributes[.size] ?? 0):\(attributes[.modificationDate] ?? Date.distantPast)".utf8))
            // A texture can be edited/replaced while retaining size and mtime.
            // Include inode + nanosecond change time in the persistent key too.
            identity.append(Data((FileStamp(url)?.cacheIdentity ?? UUID().uuidString).utf8))
            sources.append(.init(name: name, url: url, width: w, height: h)); pixels += Double(w) * Double(h)
        }
        // Include mipmaps in the resource estimate and leave working memory for decoding/geometry.
        guard !sources.isEmpty, pixels * 4 * 4 / 3 > budget else {
            return try finish(.init(url: model, adapted: false), pixels: pixels, scale: 1)
        }
        let scale = previewScale(pixels: pixels, budget: budget)
        identity.append(Data(String(scale).utf8))
        let key = SHA256.hash(data: identity).map { String(format:"%02x", $0) }.joined()
        let final = cache.appendingPathComponent(key, isDirectory: true)
        let output = final.appendingPathComponent("preview.obj")
        if FileManager.default.fileExists(atPath: output.path) {
            return try finish(.init(url: output, adapted: true), pixels: pixels, scale: scale)
        }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let staging = cache.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        var names: [String:String] = [:]
        for (index, source) in sources.enumerated() {
            try checkCancellation()
            let name = "preview-\(index).png"
            try autoreleasepool {
                onResourceAccess?(.thumbnailDecode)
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
        return try finish(.init(url: output, adapted: true), pixels: pixels, scale: scale)
    }

    private static func previewScale(pixels: Double, budget: Double) -> Double {
        guard pixels > 0, pixels * 4 * 4 / 3 > budget else { return 1 }
        let requested = min(1, sqrt(max(4, budget) / (pixels * 4 * 4 / 3)))
        return pow(2, floor(log2(requested)))
    }

    private static func resourceBudgetBytes() -> UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        #if os(iOS) && !targetEnvironment(simulator)
        let available = UInt64(os_proc_available_memory())
        return min(physical / 8, available > 0 ? available / 4 : physical / 32)
        #else
        return physical / 8
        #endif
    }
}
