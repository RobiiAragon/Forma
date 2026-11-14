import Foundation
import ImageIO

/// Inventory of referenced diffuse maps, never an enumeration of RGB-D photos.
struct TextureAssetInventory {
    struct Asset {
        let relativePath: String
        let url: URL
        let width: Int
        let height: Int
        let materialNames: [String]
    }
    let modelURL: URL
    let mtlURL: URL
    let assets: [Asset]

    static func load(modelURL: URL) throws -> TextureAssetInventory {
        guard modelURL.pathExtension.lowercased() == "obj" else { throw invalid("La mejora local de atlas necesita un OBJ con map_Kd.") }
        return try load(modelURL: modelURL, libraries: libraries(in: modelURL))
    }

    /// Detect and inventory materials in one OBJ read. Native imports without an
    /// MTL remain valid; callers need not scan the complete file before load().
    static func loadIfPresent(modelURL: URL) throws -> TextureAssetInventory? {
        guard modelURL.pathExtension.lowercased() == "obj" else { return nil }
        let names = try libraries(in: modelURL)
        guard !names.isEmpty else { return nil }
        return try load(modelURL: modelURL, libraries: names)
    }

    private static func libraries(in modelURL: URL) throws -> [String] {
        let text = try String(contentsOf: modelURL, encoding: .utf8)
        return text.components(separatedBy: .newlines).compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("mtllib ") ? String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    private static func load(modelURL: URL, libraries: [String]) throws -> TextureAssetInventory {
        let root = modelURL.deletingLastPathComponent()
        guard libraries.count == 1 else { throw invalid("El OBJ debe referenciar una biblioteca MTL.") }
        let mtl = try containedFile(libraries[0], in: root)
        let materialText = try String(contentsOf: mtl, encoding: .utf8)
        var current = "", order: [String] = [], materials: [String: [String]] = [:]
        for line in materialText.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("newmtl ") { current = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("map_Kd ") {
                let name = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                guard !current.isEmpty else { throw invalid("Una textura no tiene material asociado.") }
                if materials[name] == nil { order.append(name) }
                materials[name, default: []].append(current)
            }
        }
        var assets: [Asset] = []
        for name in order {
            let url = try containedFile(name, in: mtl.deletingLastPathComponent())
            guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0 else { throw invalid("No se pudo leer la textura referenciada: \(name)") }
            assets.append(Asset(relativePath: name, url: url, width: width, height: height, materialNames: materials[name] ?? []))
        }
        return TextureAssetInventory(modelURL: modelURL, mtlURL: mtl, assets: assets)
    }

    private static func containedFile(_ name: String, in root: URL) throws -> URL {
        guard ScanStore.safeRelativePath(name) else { throw invalid("Ruta de textura no válida.") }
        var item = root
        for component in name.split(separator: "/") {
            item.appendPathComponent(String(component))
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw invalid("Las texturas referenciadas no pueden ser enlaces simbólicos.")
            }
        }
        guard try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw invalid("Falta el archivo referenciado: \(name)") }
        return item
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "FormaTextureInventory", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
