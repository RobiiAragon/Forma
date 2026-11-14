import Foundation
import ImageIO
import Darwin

/// Reuses the app's validated USDZ writer; publishes a derived copy with only
/// explicitly named PNG texture members replaced, preserving every other payload.
@main struct RewriteUSDZTextures {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else { throw failure("Usage: rewrite-usdz-textures ORIGINAL_USDZ REPLACEMENTS_JSON NEW_USDZ") }
        let source = URL(fileURLWithPath: args[0]), destination = URL(fileURLWithPath: args[2])
        let mapping = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard !mapping.isEmpty else { throw failure("No texture replacements were specified.") }
        let archive = try StoredUSDZArchive(url: source)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var replacements: [String: URL] = [:]
        for (name, path) in mapping {
            guard name.lowercased().hasSuffix(".png"), let entry = archive.entries.first(where: { $0.name == name && !$0.isDirectory }) else {
                throw failure("Replacement must name an existing PNG member: \(name)")
            }
            try handle.seek(toOffset: entry.offset)
            let original = try handle.read(upToCount: 33) ?? Data()
            guard original.count == 33, Array(original.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw failure("Source texture is not a PNG.") }
            func u32(_ index: Int) -> Int { original[index..<(index+4)].reduce(0) { ($0 << 8) | Int($1) } }
            let replacement = URL(fileURLWithPath: path)
            guard let image = CGImageSourceCreateWithURL(replacement as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == u32(16),
                  (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == u32(20),
                  (props[kCGImagePropertyDepth] as? NSNumber)?.intValue == Int(original[24]) else {
                throw failure("Replacement texture changed native dimensions or component depth: \(name)")
            }
            replacements[name] = replacement
        }
        try archive.rewrite(to: destination, replacements: replacements)
        let result = try StoredUSDZArchive(url: destination)
        try result.validateCRC()
        guard result.entries.map(\.name) == archive.entries.map(\.name), result.entries.allSatisfy({ $0.offset % 64 == 0 }) else {
            throw failure("USDZ member order or alignment changed unexpectedly.")
        }
        print("Published fresh USDZ with \(replacements.count) native texture replacements; member order, alignment and all CRCs verified.")
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "FormaTextureCopy", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
