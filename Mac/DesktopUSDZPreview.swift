import AppKit
import SceneKit
import ImageIO
import Metal

/// Display resources are disposable; the USDZ and its embedded images are never rewritten.
enum DesktopUSDZPreview {
    static func load(_ url: URL, mode: DesktopPreviewMode) throws -> SCNScene {
        guard let scene = SCNSceneSource(url: url)?.scene(options: [.convertToYUp: true], statusHandler: { _, _, _, abort in
            if Task.isCancelled { abort.pointee = true }
        }) else { throw RGBDDatasetError.invalid("No se pudo abrir la reconstrucción USDZ.") }
        var materials: [SCNMaterial] = [], seen = Set<ObjectIdentifier>()
        scene.rootNode.enumerateChildNodes { node, _ in
            node.camera = nil; node.light = nil
            node.geometry?.materials.forEach { if seen.insert(ObjectIdentifier($0)).inserted { materials.append($0) } }
        }
        if mode == .geometry {
            for material in materials {
                material.diffuse.contents = NSColor(white: 0.7, alpha: 1)
                material.normal.contents = nil; material.displacement.contents = nil
                material.ambientOcclusion.contents = nil; material.multiply.contents = nil
                material.emission.contents = NSColor.black
                material.lightingModel = .lambert
                material.isDoubleSided = false; material.cullMode = .back
            }
            return scene
        }
        let workingSet = Double(MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? ProcessInfo.processInfo.physicalMemory / 2)
        // Read one embedded image at a time; retaining all full decoded images would
        // defeat the adaptive viewer's purpose on a reconstruction with many atlases.
        var pixels = 0.0
        for material in materials {
            try Task.checkCancellation()
            if let url = material.diffuse.contents as? URL {
                pixels += try autoreleasepool {
                    let source = try imageSource(url)
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                    return Double((properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0)
                        * Double((properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
                }
            }
        }
        let scale = mode == .adaptive ? min(1, sqrt(min(256 * 1_048_576, workingSet / 12) / max(1, pixels * 4 * 4 / 3))) : 1
        for material in materials {
            try Task.checkCancellation()
            if mode == .adaptive, let texture = material.diffuse.contents as? URL {
                material.diffuse.contents = try autoreleasepool {
                    let source = try imageSource(texture)
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 1
                    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 1
                    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(max(width, height)) * scale)),
                        kCGImageSourceCreateThumbnailWithTransform: false,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary) else { throw RGBDDatasetError.invalid("No se pudo preparar una textura USDZ para el visor.") }
                    // Keep explicit pixel dimensions. NSImage's CGImage-backed
                    // representation advertises a Retina 2x size, which can make
                    // the renderer's resource choice ambiguous. CGImage preserves
                    // the same pixels, color and UV orientation without that layer.
                    return thumbnail
                }
            }
            material.lightingModel = .constant; material.emission.contents = NSColor.black
            material.isDoubleSided = false; material.cullMode = .back
        }
        return scene
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        if !query.isEmpty {
            guard url.isFileURL,
                  let offset = query.first(where: { $0.name == "offset" })?.value.flatMap(UInt64.init),
                  let count = query.first(where: { $0.name == "size" })?.value.flatMap(Int.init), count > 0 else {
                throw RGBDDatasetError.invalid("Referencia de textura USDZ no válida.")
            }
            var base = components!; base.query = nil
            guard let file = base.url else { throw RGBDDatasetError.invalid("Ruta USDZ no válida.") }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard offset <= size, UInt64(count) <= size - offset else { throw RGBDDatasetError.invalid("La textura excede el archivo USDZ.") }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count,
                  let source = CGImageSourceCreateWithData(data as CFData, options) else {
                throw RGBDDatasetError.invalid("No se pudo leer la textura incluida en USDZ.")
            }
            return source
        }
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw RGBDDatasetError.invalid("No se pudo leer una textura del modelo.")
        }
        return source
    }
}
