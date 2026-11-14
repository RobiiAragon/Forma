import Foundation
import CryptoKit
import simd
@testable import Forma

/// Read-only acceptance of production viewpoint math against the captured poses
/// and independently exported COLMAP extrinsics. No image is decoded or uploaded.
@main struct GaussianViewpointVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(errorDescription: message) }
    }
    static func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try require(args.count == 2, "Usage: verify-gaussian-viewpoint DATASET NEW_OWNED_OUTPUT")
        let dataset = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: output.path), "Output must be new")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let files = [RGBDDatasetManifest.filename, "cameras.txt", "images.txt"]
        let original = try Dictionary(uniqueKeysWithValues: files.map { ($0, try digest(dataset.appendingPathComponent($0))) })
        let manifest = try RGBDDatasetManifest.load(from: dataset)
        let views = try await GaussianViewpoint.load(fromDataset: dataset)
        try require(views.count == manifest.frames.count, "Every observation must be retained")
        var colmap: [String: simd_float4x4] = [:]
        let flip = simd_float4x4(diagonal: SIMD4<Float>(1,-1,-1,1))
        for line in try String(contentsOf: dataset.appendingPathComponent("images.txt"), encoding: .utf8).split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10, Int(fields[0]) != nil else { continue }
            let values = fields[1...7].compactMap { Float($0) }
            guard values.count == 7 else { continue }
            let quaternion = simd_normalize(simd_quatf(ix: values[1], iy: values[2], iz: values[3], r: values[0]))
            var worldToCamera = simd_float4x4(quaternion)
            worldToCamera.columns.3 = SIMD4(values[4],values[5],values[6],1)
            colmap[String(fields[9])] = simd_inverse(worldToCamera) * flip
        }
        var maximumCOLMAPError: Float = 0, maximumRayError: Float = 0, maximumMetalError: Float = 0
        var checkedRays = 0
        for view in views {
            let name = view.rgbFile.hasPrefix("images/") ? String(view.rgbFile.dropFirst(7)) : view.rgbFile
            guard let independent = colmap[name] else { throw Failure(errorDescription: "Missing COLMAP pose: " + name) }
            for column in 0..<4 { for row in 0..<4 {
                maximumCOLMAPError = max(maximumCOLMAPError, abs(independent[column][row] - view.cameraToWorld[column][row]))
            } }
            let pixels: [SIMD2<Float>] = [SIMD2(0,0), SIMD2(Float(view.imageWidth - 1),0),
                SIMD2(0,Float(view.imageHeight - 1)), SIMD2(Float(view.imageWidth - 1),Float(view.imageHeight - 1)),
                SIMD2(view.intrinsics[2][0],view.intrinsics[2][1])]
            for quarterTurns in 0..<4 {
                let presented = try view.rotatedForPresentation(quarterTurns: quarterTurns)
                try require(presented.frameID == view.frameID && presented.sourceFrameIndex == view.sourceFrameIndex &&
                            presented.position == view.position && presented.backward == view.backward,
                            "Presentation cannot move the camera or replace source identity")
                for pixel in pixels {
                    let pinhole = simd_inverse(view.intrinsics) * SIMD3(pixel,1)
                    let cameraPoint = SIMD4(pinhole.x * 2,-pinhole.y * 2,-pinhole.z * 2,1)
                    let world = view.cameraToWorld * cameraPoint
                    var expected = pixel, width = view.imageWidth, height = view.imageHeight
                    for _ in 0..<quarterTurns {
                        expected = SIMD2(Float(height - 1) - expected.y,expected.x); swap(&width,&height)
                    }
                    guard let projected = presented.project(worldPoint: SIMD3(world.x,world.y,world.z)) else {
                        throw Failure(errorDescription: "A preserved native ray became unprojectable")
                    }
                    maximumRayError = max(maximumRayError, abs(projected.pixel.x - expected.x), abs(projected.pixel.y - expected.y))
                    for viewport in [SIMD2<Float>(1200,900),SIMD2<Float>(900,1200)] {
                        let projection = try presented.projection(viewport: viewport, near: 0.001, far: 1000)
                        let clip = projection.matrix * presented.viewMatrix * world
                        let drawable = projection.viewportOrigin + SIMD2((clip.x / clip.w + 1) / 2, (1 - clip.y / clip.w) / 2) * projection.viewportSize
                        let scale = min(viewport.x / Float(width),viewport.y / Float(height))
                        let actualExpected = projection.viewportOrigin + (expected + SIMD2(repeating: 0.5)) * scale
                        maximumMetalError = max(maximumMetalError,abs(drawable.x - actualExpected.x),abs(drawable.y - actualExpected.y))
                        checkedRays += 1
                    }
                }
            }
            let upright = try view.uprightPresentation
            for turns in 0..<4 {
                try require(upright.up.y >= view.rotatedForPresentation(quarterTurns: turns).up.y - 0.000001,
                            "Upright presentation must maximize world-Y up among equivalent rays")
            }
        }
        try require(maximumCOLMAPError < 0.00005 && maximumRayError < 0.01 && maximumMetalError < 0.01,
                    "Camera/raster conversion precision regression: \(maximumCOLMAPError), \(maximumRayError), \(maximumMetalError)")
        let after = try Dictionary(uniqueKeysWithValues: files.map { ($0, try digest(dataset.appendingPathComponent($0))) })
        try require(after == original, "Calibrated input bytes must remain unchanged")
        let first = views.first
        let upright = try first?.uprightPresentation
        let report: [String: Any] = ["status": "passed", "scope": "Actual Swift production API, every captured pose, all corner rays and COLMAP extrinsics; no render or appearance claim",
            "inputFrameCount": manifest.frames.count, "returnedViewpointCount": views.count, "testedDrawableRays": checkedRays,
            "maximumCOLMAPPoseError": maximumCOLMAPError, "maximumNativePixelRayError": maximumRayError,
            "maximumMetalDrawablePixelError": maximumMetalError,
            "presentationRotationsPreserveCameraEyeAndForward": true, "allFramesAndSourceIdentitiesPreserved": true,
            "firstNativeFrameID": first?.frameID as Any? ?? NSNull(),
            "firstUprightQuarterTurns": upright?.presentationQuarterTurns as Any? ?? NSNull(),
            "firstNativeUp": first.map { [$0.up.x,$0.up.y,$0.up.z] } as Any? ?? NSNull(),
            "firstUprightUp": upright.map { [$0.up.x,$0.up.y,$0.up.z] } as Any? ?? NSNull(),
            "sourceSHA256Unchanged": true, "sourceSHA256": original,
            "imageDecoded": false, "cameraOpened": false, "GPUUsed": false, "networkUsed": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("verification.json"), options: .atomic)
        print(String(data: data, encoding: .utf8)!)
    }
}
