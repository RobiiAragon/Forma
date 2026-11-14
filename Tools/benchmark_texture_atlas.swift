import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Synthetic CPU benchmark; does not measure camera accuracy, iPhone FPS, or Polycam.
@main
struct AtlasBenchmark {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let rootPath = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "build/Benchmarks/TextureAtlas"
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let run = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        let fixtures: URL
        if arguments.contains("--reuse-fixtures") {
            let path = try String(contentsOf: root.appendingPathComponent("fixtures-path.txt"), encoding: .utf8)
            fixtures = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            fixtures = run
            try fixtures.path.write(to: root.appendingPathComponent("fixtures-path.txt"), atomically: true, encoding: .utf8)
        }
        let width = 3840, height = 2160, count = 12
        var sources: [TextureAtlasBuilder.Source] = []
        var faces: [TextureAtlasBuilder.Face] = []
        for id in 0..<count {
            let url = fixtures.appendingPathComponent("source-\(id).jpg")
            if !arguments.contains("--reuse-fixtures") { try autoreleasepool {
                let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap.rawValue) else { throw TextureAtlasBuilder.AtlasError.allocationFailed }
                context.setFillColor(red: CGFloat(id + 1) / CGFloat(count + 1), green: 0.2, blue: 0.7, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                guard let image = context.makeImage(),
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw TextureAtlasBuilder.AtlasError.imageEncoding
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw TextureAtlasBuilder.AtlasError.imageEncoding }
            } }
            sources.append(.init(id: id, imageURL: url, pixelWidth: width, pixelHeight: height))
            let topLeft = SIMD2<Float>(1024.5 / Float(width), 1 - 768.5 / Float(height))
            let topRight = SIMD2<Float>(1535.5 / Float(width), topLeft.y)
            let bottomLeft = SIMD2<Float>(topLeft.x, 1 - 1279.5 / Float(height))
            faces.append(.init(id: id, sourceID: id, a: topLeft, b: topRight, c: bottomLeft))
        }
        if arguments.contains("--prepare-only") {
            print("Fixture photographs saved in \(fixtures.path)")
            return
        }
        let result = try TextureAtlasBuilder.build(sources: sources, faces: faces, outputDirectory: run.appendingPathComponent("atlas"))
        var maximumTexelSpanError: Float = 0
        for face in result.faces {
            let input = faces[face.id]
            let output = result.materials[face.materialID]
            maximumTexelSpanError = max(maximumTexelSpanError,
                abs((face.b.x - face.a.x) * Float(output.pixelWidth) - (input.b.x - input.a.x) * Float(width)),
                abs((face.c.y - face.a.y) * Float(output.pixelHeight) - (input.c.y - input.a.y) * Float(height)))
        }
        let metrics = result.metrics
        let report: [String: Any] = [
            "subject": "12 authored 3840x2160 JPEG photographs; one central 512px native patch per photograph",
            "platform": "macOS CPU; not an iPhone or Polycam performance comparison",
            "sourceCount": metrics.sourceCount, "materialCount": metrics.materialCount, "pageCount": metrics.pageCount,
            "sourcePixels": metrics.sourcePixels, "croppedPixels": metrics.croppedPixels, "atlasPixels": metrics.atlasPixels,
            "totalSeconds": metrics.totalSeconds, "packingSeconds": metrics.packingSeconds,
            "renderingSeconds": metrics.renderingSeconds, "maximumTexelSpanError": maximumTexelSpanError,
            "bytesWritten": metrics.bytesWritten, "path": run.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("latest.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
