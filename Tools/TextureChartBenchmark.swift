import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import simd

/// Repack a REAL exported OBJ's photographic regions, without changing geometry.
/// xcrun swiftc -O -parse-as-library Forma/Core/ProcessingControl.swift \
///   Forma/Core/TextureChartBuilder.swift Forma/Core/TextureAtlasBuilder.swift \
///   Tools/TextureChartBenchmark.swift -o /tmp/forma-chart-benchmark
/// /tmp/forma-chart-benchmark /absolute/original/modelo.obj /absolute/new-output
/// This measures Mac CPU repacking of existing textures, not fresh capture,
/// photometric selection, iPhone FPS or superiority over another application.
@main
struct TextureChartBenchmark {
    enum Failure: Error { case input(String) }
    struct StoredFace { var tokens: [String]; var sourceID: Int? }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure.input("Expected input OBJ and a new output directory") }
        let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        let root = input.deletingLastPathComponent(), fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw Failure.input("Output must be new") }
        let objHash = try digest(input)
        let text = try String(contentsOf: input, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        guard let mtlLine = lines.first(where: { $0.hasPrefix("mtllib ") }) else { throw Failure.input("Missing MTL") }
        let mtlURL = root.appendingPathComponent(String(mtlLine.dropFirst(7)))
        let mtl = try String(contentsOf: mtlURL, encoding: .utf8)
        var materialName = "", imageByMaterial: [String: String] = [:]
        for line in mtl.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("newmtl ") { materialName = String(line.dropFirst(7)) }
            if line.hasPrefix("map_Kd ") { imageByMaterial[materialName] = String(line.dropFirst(7)) }
        }
        let materialNames = imageByMaterial.keys.sorted()
        let sourceIDByName = Dictionary(uniqueKeysWithValues: materialNames.enumerated().map { ($0.element, $0.offset) })
        var sources: [TextureAtlasBuilder.Source] = [], originalHashes: [Int: String] = [:]
        var beforePixels: Int64 = 0, beforeBytes: Int64 = 0
        for (id, name) in materialNames.enumerated() {
            let url = root.appendingPathComponent(imageByMaterial[name]!).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"),
                  let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw Failure.input("Image metadata") }
            sources.append(.init(id: id, imageURL: url, pixelWidth: width, pixelHeight: height))
            originalHashes[id] = try digest(url)
            beforePixels += Int64(width) * Int64(height)
            beforeBytes += (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        var uvs: [SIMD2<Float>] = [], stored: [StoredFace] = [], atlasFaces: [TextureAtlasBuilder.Face] = []
        var geometryLines: [Substring] = []
        for line in lines {
            if line.hasPrefix("v ") || line.hasPrefix("vn ") { geometryLines.append(line) }
            else if line.hasPrefix("vt ") {
                let fields = line.split(separator: " ")
                guard fields.count >= 3, let u = Float(fields[1]), let v = Float(fields[2]) else { throw Failure.input("UV") }
                uvs.append(SIMD2(u, v))
            } else if line.hasPrefix("usemtl ") { materialName = String(line.dropFirst(7)) }
            else if line.hasPrefix("f ") {
                let tokens = line.split(separator: " ").dropFirst().map(String.init)
                guard tokens.count == 3 else { throw Failure.input("Expected triangular mesh") }
                let id = stored.count, sourceID = sourceIDByName[materialName]
                stored.append(StoredFace(tokens: tokens, sourceID: sourceID))
                if let sourceID {
                    let points = try tokens.map { token -> SIMD2<Float> in
                        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
                        guard parts.count >= 2, let index = Int(parts[1]), index > 0, index <= uvs.count else { throw Failure.input("Face UV index") }
                        return uvs[index - 1]
                    }
                    atlasFaces.append(.init(id: id, sourceID: sourceID, a: points[0], b: points[1], c: points[2]))
                }
            }
        }
        let result = try TextureAtlasBuilder.build(sources: sources, faces: atlasFaces,
            outputDirectory: output.appendingPathComponent("textures"), preserveSingleSource: false)
        let mappings = Dictionary(uniqueKeysWithValues: result.faces.map { ($0.id, $0) })
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var maximumSpanError: Double = 0
        for (before, after) in zip(atlasFaces, result.faces) {
            guard before.id == after.id else { throw Failure.input("Face order changed") }
            let source = sourceByID[before.sourceID]!, material = result.materials[after.materialID]
            for (old, new) in [(before.b - before.a, after.b - after.a), (before.c - before.a, after.c - after.a)] {
                maximumSpanError = max(maximumSpanError,
                    abs(Double(new.x) * Double(material.pixelWidth) - Double(old.x) * Double(source.pixelWidth)),
                    abs(Double(new.y) * Double(material.pixelHeight) - Double(old.y) * Double(source.pixelHeight)))
            }
        }
        let outputOBJ = output.appendingPathComponent("modelo.obj")
        fm.createFile(atPath: outputOBJ.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputOBJ)
        var buffer = "# Native chart repack; original vertex and normal lines, face order and winding retained\nmtllib modelo.mtl\n"
        func append(_ string: String) throws {
            buffer += string
            if buffer.utf8.count >= 256 * 1024 { try handle.write(contentsOf: Data(buffer.utf8)); buffer = "" }
        }
        for line in geometryLines { try append(String(line) + "\n") }
        var nextVT = 1, currentMaterial = ""
        for (id, face) in stored.enumerated() {
            if let mapped = mappings[id] {
                for uv in [mapped.a, mapped.b, mapped.c] { try append("vt \(uv.x) \(uv.y)\n") }
                let name = "photo_\(mapped.materialID)"
                if name != currentMaterial { try append("usemtl \(name)\n"); currentMaterial = name }
                let tokens = face.tokens.enumerated().map { corner, token in
                    let parts = token.split(separator: "/", omittingEmptySubsequences: false)
                    let normal = parts.count > 2 ? String(parts[2]) : ""
                    return "\(parts[0])/\(nextVT + corner)/\(normal)"
                }
                try append("f " + tokens.joined(separator: " ") + "\n"); nextVT += 3
            } else {
                if currentMaterial != "unobserved" { try append("usemtl unobserved\n"); currentMaterial = "unobserved" }
                // Neutral source faces have no photographic UV. Strip obsolete vt
                // indices, preserving every original vertex and normal index.
                let tokens = face.tokens.map { token in
                    let parts = token.split(separator: "/", omittingEmptySubsequences: false)
                    return parts.count > 2 ? "\(parts[0])//\(parts[2])" : String(parts[0])
                }
                try append("f " + tokens.joined(separator: " ") + "\n")
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: Data(buffer.utf8)) }
        try handle.close()
        var outputMTL = "newmtl unobserved\nKd 0.55 0.55 0.55\nd 1\nillum 2\n\n"
        // Preserve the authored neutral material when available.
        if let start = mtl.range(of: "newmtl unobserved\n") {
            let rest = mtl[start.lowerBound...], end = rest.dropFirst(7).range(of: "newmtl ")
            outputMTL = end.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        }
        for material in result.materials {
            outputMTL += "\nnewmtl photo_\(material.id)\nKa 0.2 0.2 0.2\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 2\nmap_Kd textures/\(material.filename)\n"
        }
        try outputMTL.write(to: output.appendingPathComponent("modelo.mtl"), atomically: true, encoding: .utf8)
        var originalsUnchanged = try digest(input) == objHash
        for source in sources { if try digest(source.imageURL) != originalHashes[source.id] { originalsUnchanged = false } }
        let metrics = result.metrics
        let originalsByFaceID = Dictionary(uniqueKeysWithValues: atlasFaces.map { ($0.id, $0) })
        let report: [String: Any] = [
            "scope": "Mac CPU native-texel repack of real captured OBJ plus its existing photographic textures; not fresh RGB-D selection, iPhone FPS or Polycam superiority",
            "inputOBJ": input.path, "inputOBJSHA256": objHash, "outputOBJ": outputOBJ.path,
            "originalsByteUnchanged": originalsUnchanged,
            "allFacesBefore": stored.count, "allFacesAfter": stored.count,
            "photographicFacesBefore": atlasFaces.count, "photographicFacesAfter": result.faces.count,
            "photographicSources": sources.count,
            "beforePhotographicMaterials": sources.count, "afterPhotographicMaterials": metrics.materialCount,
            "beforeTexturePixels": beforePixels, "afterTexturePixels": metrics.atlasPixels + metrics.dedicatedOriginalPixels,
            "beforeTextureBytes": beforeBytes, "afterTextureBytes": metrics.bytesWritten,
            "chartCount": metrics.chartCount, "connectedIslandCount": metrics.connectedIslandCount,
            "croppedPixels": metrics.croppedPixels, "pageCount": metrics.pageCount,
            "dedicatedOriginalCount": metrics.dedicatedOriginalCount,
            "renderSourceDecodeCount": metrics.renderSourceDecodeCount,
            "packingSeconds": metrics.packingSeconds, "renderingSeconds": metrics.renderingSeconds,
            "totalSeconds": metrics.totalSeconds, "maximumNativeTexelSpanError": maximumSpanError,
            "noGeometrySubdivisionOrPositionChanges": true, "uvFaces": result.faces.map { face -> [String: Any] in
                let original = originalsByFaceID[face.id]!
                return ["id": face.id, "sourceID": original.sourceID, "materialID": face.materialID,
                        "before": [[original.a.x, original.a.y], [original.b.x, original.b.y], [original.c.x, original.c.y]],
                        "after": [[face.a.x, face.a.y], [face.b.x, face.b.y], [face.c.x, face.c.y]]]
            }
        ]
        // Keep all per-face mappings for independent verification, outside the concise summary.
        var compact = report
        let mappingsJSON = compact.removeValue(forKey: "uvFaces")!
        try JSONSerialization.data(withJSONObject: mappingsJSON).write(to: output.appendingPathComponent("face-mappings.json"))
        let data = try JSONSerialization.data(withJSONObject: compact, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("measurements.json"))
        print(String(decoding: data, as: UTF8.self))
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
