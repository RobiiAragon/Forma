import Foundation
import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import simd

/// Read-only, identical captured pinhole viewpoints for two model outputs.
@main struct RenderPhotogrammetryComparison {
    struct Camera: Decodable {
        var sampleID: Int
        var frameID: String
        var nativeTransformColumnMajor: [Float]
        var intrinsicsColumnMajor: [Float]?
        var inputImageWidth: Int?
        var inputImageHeight: Int?
    }
    struct Calibration: Decodable { var cameras: [Camera] }
    struct Failure: LocalizedError { var errorDescription: String? }
    @MainActor static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 || args.count == 6 else { throw fail("Usage: render_photogrammetry_comparison CALIBRATION BASELINE_MODEL CANDIDATE_MODEL FRESH_OUTPUT [BASELINE_LABEL CANDIDATE_LABEL]") }
        let candidateKey = args.count == 6 ? "candidate" : "custom16k"
        let leftLabel = args.count == 6 ? args[4] : "RAW · 4 atlas de 8192²"
        let rightLabel = args.count == 6 ? args[5] : "CUSTOM · color 16384²"
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path), let device = MTLCreateSystemDefaultDevice() else { throw fail("Fresh output and a Metal device are required") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let calibration = try JSONDecoder().decode(Calibration.self, from: Data(contentsOf: URL(fileURLWithPath: args[0])))
        let cameras = [0, 283, 482].compactMap { id in calibration.cameras.first { $0.sampleID == id } }
        guard cameras.count == 3 else { throw fail("Requested captured sampleIDs must exist") }
        var report: [String: Any] = ["sameCapturedCameraAndProjection": true, "cameraConvention": "native cameraToWorld OpenGL; SceneKit -Z forward +Y up", "materials": "native diffuse textures with constant illumination; normal/specular/roughness lighting disabled identically", "backFacesHidden": true, "noModelAlignmentOrSourceWrites": true]
        var models: [[String: Any]] = []
        for (label, path) in zip(["raw", candidateKey], [args[1], args[2]]) {
            try autoreleasepool {
                let scene = try SCNScene(url: URL(fileURLWithPath: path), options: nil)
                scene.background.contents = NSColor(calibratedWhite: 0.055, alpha: 1)
                var materials: [[String: Any]] = [], triangles = 0, meshes = 0
                scene.rootNode.enumerateChildNodes { node, _ in
                    guard let geometry = node.geometry else { return }
                    meshes += 1
                    triangles += geometry.elements.reduce(0) { $0 + ($1.primitiveType == .triangles ? $1.primitiveCount : 0) }
                    for material in geometry.materials {
                        let value = material.diffuse.contents
                        materials.append(["name": material.name ?? "", "diffuseType": value.map { String(describing: type(of: $0)) } ?? "nil", "diffuseResource": (value as? URL)?.absoluteString ?? (value as? String) ?? "loaded image or color", "nativeLightingModel": material.lightingModel.rawValue])
                        material.lightingModel = .constant
                        material.isDoubleSided = false
                        material.cullMode = .back
                        material.normal.contents = nil
                        material.emission.contents = NSColor.black
                    }
                }
                let renderer = SCNRenderer(device: device, options: nil)
                renderer.scene = scene; renderer.autoenablesDefaultLighting = false
                for view in cameras {
                    let camera = try cameraNode(view)
                    scene.rootNode.addChildNode(camera); renderer.pointOfView = camera
                    let width = view.inputImageWidth!, height = view.inputImageHeight!
                    let image = renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
                    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw fail("No rendered pixels") }
                    try save(cg, to: output.appendingPathComponent("\(label)-camera-\(view.sampleID).png"))
                    camera.removeFromParentNode()
                    print("rendered \(label) camera \(view.sampleID) \(width)x\(height)"); fflush(stdout)
                }
                models.append(["label": label, "source": path, "meshes": meshes, "triangles": triangles, "materials": materials])
            }
        }
        for camera in cameras {
            let lhs = try image(output.appendingPathComponent("raw-camera-\(camera.sampleID).png"))
            let rhs = try image(output.appendingPathComponent("\(candidateKey)-camera-\(camera.sampleID).png"))
            let panelWidth = 1600, panelHeight = Int(Double(lhs.height) * Double(panelWidth) / Double(lhs.width))
            let pair = try composite(lhs, rhs, panelWidth: panelWidth, panelHeight: panelHeight,
                leftLabel: leftLabel, rightLabel: rightLabel + " · misma cámara \(camera.sampleID)")
            try save(pair, to: output.appendingPathComponent("comparison-camera-\(camera.sampleID).png"))
            let cropSize = min(1024, min(lhs.width, lhs.height))
            let crop = CGRect(x: (lhs.width-cropSize)/2, y: (lhs.height-cropSize)/2, width: cropSize, height: cropSize)
            guard let l = lhs.cropping(to: crop), let r = rhs.cropping(to: crop) else { throw fail("Cannot crop common pixels") }
            try save(composite(l, r, panelWidth: cropSize, panelHeight: cropSize, leftLabel: leftLabel + " · recorte 100%", rightLabel: rightLabel + " · recorte 100%"), to: output.appendingPathComponent("detail-camera-\(camera.sampleID).png"))
        }
        report["models"] = models
        report["views"] = cameras.map { ["sampleID": $0.sampleID, "frameID": $0.frameID, "nativeTransformColumnMajor": $0.nativeTransformColumnMajor, "intrinsicsColumnMajor": $0.intrinsicsColumnMajor!, "width": $0.inputImageWidth!, "height": $0.inputImageHeight!] as [String: Any] }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("render-report.json"), options: .atomic)
        print("completed \(output.path)")
    }
    static func cameraNode(_ view: Camera) throws -> SCNNode {
        guard let k = view.intrinsicsColumnMajor, k.count == 9, view.nativeTransformColumnMajor.count == 16,
              let width = view.inputImageWidth, let height = view.inputImageHeight, width > 0, height > 0 else { throw fail("Missing native calibration") }
        let m = view.nativeTransformColumnMajor
        let camera = SCNCamera(); camera.wantsHDR = false; camera.wantsExposureAdaptation = false
        camera.zNear = 0.001; camera.zFar = 1000
        let n: Float = 0.001, f: Float = 1000, w = Float(width), h = Float(height)
        let projection = simd_float4x4(columns: (SIMD4(2*k[0]/w,0,0,0), SIMD4(0,2*k[4]/h,0,0),
            SIMD4(1-2*k[6]/w,2*k[7]/h-1,-(f+n)/(f-n),-1), SIMD4(0,0,-2*f*n/(f-n),0)))
        camera.projectionTransform = SCNMatrix4(projection)
        let node = SCNNode(); node.camera = camera
        node.simdTransform = simd_float4x4(columns: (SIMD4(m[0],m[1],m[2],m[3]), SIMD4(m[4],m[5],m[6],m[7]), SIMD4(m[8],m[9],m[10],m[11]), SIMD4(m[12],m[13],m[14],m[15])))
        return node
    }
    static func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw fail("Cannot read PNG") }; return image
    }
    static func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw fail("Cannot write PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw fail("PNG encoding failed") }
    }
    @MainActor static func composite(_ lhs: CGImage, _ rhs: CGImage, panelWidth: Int, panelHeight: Int, leftLabel: String, rightLabel: String) throws -> CGImage {
        let header = 52
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: panelWidth*2, pixelsHigh: panelHeight+header, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw fail("Cannot allocate comparison") }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }; NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill(); NSRect(x:0,y:0,width:panelWidth*2,height:panelHeight+header).fill()
        context.cgContext.interpolationQuality = CGInterpolationQuality.high
        context.cgContext.draw(lhs, in: CGRect(x:0,y:0,width:panelWidth,height:panelHeight))
        context.cgContext.draw(rhs, in: CGRect(x:panelWidth,y:0,width:panelWidth,height:panelHeight))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white]
        (leftLabel as NSString).draw(at: NSPoint(x:16,y:panelHeight+13), withAttributes: attributes)
        (rightLabel as NSString).draw(at: NSPoint(x:panelWidth+16,y:panelHeight+13), withAttributes: attributes)
        guard let cg = bitmap.cgImage else { throw fail("No comparison pixels") }; return cg
    }
    static func fail(_ message: String) -> Failure { Failure(errorDescription: message) }
}
