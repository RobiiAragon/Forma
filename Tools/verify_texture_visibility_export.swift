import Foundation
import CoreGraphics
import ImageIO
import simd
@testable import Forma

/// Runs the complete production bake on the benchmark's authored edge fixture.
@main struct VisibilityExportVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(errorDescription: message) }
    }
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        try require(arguments.count == 2, "Usage: verify-visibility-export AUTHORED_FIXTURE NEW_OUTPUT")
        let root = URL(fileURLWithPath: arguments[0]), output = URL(fileURLWithPath: arguments[1])
        let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("malla.json")))
        let dataset = root.appendingPathComponent("dataset")
        let frames = try RGBDDatasetManifest.load(from: dataset).frames
        let originalPhotos = try frames.map { try Data(contentsOf: dataset.appendingPathComponent($0.rgbFile)) }
        let result = try LiDARTextureBaker.bake(mesh: mesh, keyframes: frames, datasetDirectory: dataset, outputDirectory: output)
        let lines = try String(contentsOf: result.objURL, encoding: .utf8).split(whereSeparator: \.isNewline)
        let geometry = lines.filter { $0.hasPrefix("v ") }.map { line in line.split(separator: " ").dropFirst().compactMap { Float($0) } }
        try require(geometry.count == mesh.vertices.count && zip(geometry, mesh.vertices).allSatisfy {
            $0.0 == [$0.1.x, $0.1.y, $0.1.z]
        }, "Production bake must preserve every original vertex")
        let faces = lines.filter { $0.hasPrefix("f ") }
        let indices = faces.flatMap { $0.split(separator: " ").dropFirst().compactMap { UInt32($0.split(separator: "/")[0]) }.map { $0 - 1 } }
        try require(indices == mesh.triangles && result.texturedFaceCount == 2, "Both original triangles/order must remain observed")
        let uvs = lines.filter { $0.hasPrefix("vt ") }.map { line -> SIMD2<Float> in
            let values = line.split(separator: " ").dropFirst().compactMap { Float($0) }
            return SIMD2(values[0], values[1])
        }
        var activeMaterial = "", targetMaterial = ""
        for line in lines {
            if line.hasPrefix("usemtl ") { activeMaterial = String(line.dropFirst(7)) }
            if line.hasPrefix("f ") { targetMaterial = activeMaterial; break }
        }
        var textureName: String?
        for line in try String(contentsOf: result.materialURL, encoding: .utf8).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("newmtl ") { activeMaterial = String(line.dropFirst(7)) }
            if activeMaterial == targetMaterial && line.hasPrefix("map_Kd ") { textureName = String(line.dropFirst(7)) }
        }
        guard let textureName, let source = CGImageSourceCreateWithURL(output.appendingPathComponent(textureName) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(errorDescription: "Actual target material must contain its texture") }
        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw Failure(errorDescription: "Atlas pixel readback must allocate")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let uv = (uvs[0] + uvs[1] + uvs[2]) / 3
        let x = min(image.width - 1, max(0, Int(uv.x * Float(image.width))))
        let y = min(image.height - 1, max(0, Int((1 - uv.y) * Float(image.height))))
        let offset = (y * image.width + x) * 4
        let observed = Array(pixels[offset..<offset + 3]), expected = [40,180,60]
        try require(zip(observed, expected).allSatisfy { abs(Int($0.0) - $0.1) <= 2 },
                    "Exported target must use the unobstructed green photo, not the occluded red photo: \(observed)")
        for (frame, original) in zip(frames, originalPhotos) {
            try require(try Data(contentsOf: dataset.appendingPathComponent(frame.rgbFile)) == original, "Original photograph bytes must remain unchanged")
        }
        let report: [String: Any] = ["status": "passed", "scope": "Authored fixture; full production selection/coherence/atlas/OBJ export",
            "bothTrianglesTextured": true, "originalGeometryAndTriangleOrderPreserved": true,
            "exportedTargetRGB": observed, "expectedUnobstructedPhotoRGB": expected,
            "maximumAllowedEncodingError8Bit": 2, "originalPhotographsByteIdentical": true,
            "noCapturedRoomQualityClaim": true, "materialCount": result.atlasMaterialCount]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("verification.json"), options: .atomic)
        print(String(data: data, encoding: .utf8)!)
    }
}
