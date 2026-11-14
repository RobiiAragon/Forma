import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import simd

/// Compile with Mac/DesktopCameraPolicy.swift. Uses synthetic geometry only.
@main struct DesktopCameraVerification {
    @MainActor static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw failure("A real Metal device is required; this check must not silently pass without rendering.")
        }
        let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: "build/Research/desktop-camera-verification", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var evidence: [String: Any] = ["device": device.name, "syntheticGeometryOnly": true]

        let plane = planeGeometry(reversed: false, side: 0.1)
        let nearScene = scene(plane)
        let camera = cameraNode(position: SIMD3(0, 0, 0.05))
        nearScene.rootNode.addChildNode(camera)
        let baseline = try render(nearScene, camera: camera, device: device, output: output.appendingPathComponent("near-default.png"))
        let originalNear = camera.camera!.zNear
        let originalFar = camera.camera!.zFar
        let proof = geometryBytes(plane)
        DesktopCameraPolicy.apply(to: camera.camera!, cameraPosition: camera.simdWorldPosition, contentRadius: 1.2)
        let close = try render(nearScene, camera: camera, device: device, output: output.appendingPathComponent("near-fixed.png"))
        try require(baseline == 0, "The default near plane should clip the plane at distance 0.05.")
        try require(close > 1_000, "The production camera policy must show the nearby front face.")
        try require(geometryBytes(plane) == proof, "Camera correction changed mesh data.")
        try require(plane.materials.allSatisfy { !$0.isDoubleSided && $0.cullMode == .back }, "Backface culling changed.")
        evidence["near"] = ["cameraDistance": 0.05, "defaultNear": originalNear, "defaultFar": originalFar,
                            "defaultVisiblePixels": baseline, "fixedVisiblePixels": close,
                            "fixedNear": camera.camera!.zNear, "fixedFar": camera.camera!.zFar]
        print("PASS: real Metal render, default near plane hides a surface at 0.05; production policy reveals it")

        let reversed = planeGeometry(reversed: true, side: 0.1)
        let reverseScene = scene(reversed)
        let reverseCamera = cameraNode(position: SIMD3(0, 0, 0.05))
        reverseScene.rootNode.addChildNode(reverseCamera)
        DesktopCameraPolicy.apply(to: reverseCamera.camera!, cameraPosition: reverseCamera.simdWorldPosition, contentRadius: 1.2)
        let backPixels = try render(reverseScene, camera: reverseCamera, device: device, output: output.appendingPathComponent("backface-culled.png"))
        try require(backPixels == 0, "A reversed face became visible; culling must remain enabled.")
        evidence["backfaceVisiblePixels"] = backPixels
        print("PASS: reversed triangle winding remains invisible with backface culling")

        let room = roomGeometry()
        let roomProof = geometryBytes(room)
        let roomScene = scene(room)
        let roomCamera = cameraNode(position: SIMD3(0, 0, -1.15))
        // Inspect the wall ahead from inside the room, 0.05 normalized units away.
        roomCamera.look(at: SCNVector3(0, 0, -2.15))
        roomScene.rootNode.addChildNode(roomCamera)
        DesktopCameraPolicy.apply(to: roomCamera.camera!, cameraPosition: roomCamera.simdWorldPosition,
                                  contentRadius: sqrt(3) * 1.2)
        let interior = try render(roomScene, camera: roomCamera, device: device, output: output.appendingPathComponent("interior-room.png"))
        try require(interior > 1_000, "The inward-facing room wall disappeared during interior inspection.")
        try require(geometryBytes(room) == roomProof, "Interior camera correction changed geometry.")
        evidence["interior"] = ["visiblePixels": interior, "near": roomCamera.camera!.zNear, "far": roomCamera.camera!.zFar]
        print("PASS: inspection inside a room preserves inward-facing surfaces and native vertex/index bytes")

        let farPlane = planeGeometry(reversed: false, side: 2.4)
        let farScene = scene(farPlane)
        let farCamera = cameraNode(position: SIMD3(0, 0, 150))
        farScene.rootNode.addChildNode(farCamera)
        let farBaseline = try render(farScene, camera: farCamera, device: device, output: output.appendingPathComponent("far-default.png"))
        DesktopCameraPolicy.apply(to: farCamera.camera!, cameraPosition: farCamera.simdWorldPosition,
                                  contentRadius: sqrt(2) * 1.2)
        let farFixed = try render(farScene, camera: farCamera, device: device, output: output.appendingPathComponent("far-fixed.png"))
        try require(farBaseline == 0 && farFixed > 0, "Dynamic far clipping did not retain the model beyond the default far plane.")
        evidence["far"] = ["cameraDistance": 150, "defaultVisiblePixels": farBaseline,
                           "fixedVisiblePixels": farFixed, "fixedNear": farCamera.camera!.zNear, "fixedFar": farCamera.camera!.zFar]
        print("PASS: perspective zoom beyond 100 units retains the model with dynamic far clipping")

        for radius in [0.01, 1.2, 2.1] {
            for distance in [0.0, radius * 0.5, radius, radius * 2, 150, 1_000_000] {
                let range = DesktopCameraPolicy.clippingRange(contentRadius: radius, cameraDistance: distance)
                try require(range.near.isFinite && range.near > 0 && range.far.isFinite && range.far > range.near,
                            "The camera range became invalid during dolly.")
                try require(range.far > distance + radius, "The far plane clips part of the bounding sphere.")
                if distance > radius {
                    try require(range.near < distance - radius, "The near plane clips the content sphere while outside it.")
                }
            }
        }
        for pair in [(Double.nan, Double.nan), (Double.infinity, Double.infinity), (-1.0, -1.0), (0.0, 0.0)] {
            let range = DesktopCameraPolicy.clippingRange(contentRadius: pair.0, cameraDistance: pair.1)
            try require(range.near.isFinite && range.near > 0 && range.far.isFinite && range.far > range.near,
                        "Invalid inputs propagated nonfinite camera planes.")
        }
        evidence["opticalZoom"] = try verifyOpticalZoom(device: device, output: output)
        evidence["cursorAnchor"] = try verifyCursorAnchor()
        evidence["geometryBytesUnchanged"] = true
        evidence["rangeCasesPassed"] = 22
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("measurements.json"), options: .atomic)
        print("PASS: positive finite ranges, full bounding-sphere coverage, degenerate input fallbacks")
        print("Evidence: \(output.path)")
    }

    @MainActor private static func verifyOpticalZoom(device: MTLDevice, output: URL) throws -> [String: Any] {
        let geometry = planeGeometry(reversed: false, side: 2.4)
        let proof = geometryBytes(geometry)
        let scene = scene(geometry)
        let node = cameraNode(position: SIMD3(0, 0, 4))
        scene.rootNode.addChildNode(node)
        let origin = node.simdWorldPosition
        let radius = sqrt(2) * 1.2
        let initial = 60.0
        let strong = DesktopCameraPolicy.zoomFieldOfView(current: initial, logScale: 100_000)
        node.camera!.fieldOfView = CGFloat(strong)
        DesktopCameraPolicy.apply(to: node.camera!, cameraPosition: node.simdWorldPosition, contentRadius: radius)
        let pixels = try render(scene, camera: node, device: device, output: output.appendingPathComponent("strong-optical-zoom.png"))
        try require(pixels > 1_000, "Strong optical zoom lost the forward-facing surface.")
        try require(node.simdWorldPosition == origin && Double(simd_length(node.simdWorldPosition)) > radius,
                    "Optical zoom moved the camera into or through the model.")
        var field = initial
        for scale in [1_000_000.0, -1_000_000, 20, -20, 0.25, -0.25, 0] {
            field = DesktopCameraPolicy.zoomFieldOfView(current: field, logScale: scale)
            try require(field.isFinite && field > 0 && field < 180, "Repeated strong zoom produced an invalid perspective.")
            node.camera!.fieldOfView = CGFloat(field)
        }
        let ordinaryIn = DesktopCameraPolicy.zoomFieldOfView(current: initial, logScale: 0.8)
        let ordinaryOut = DesktopCameraPolicy.zoomFieldOfView(current: ordinaryIn, logScale: -0.8)
        try require(abs(ordinaryOut - initial) < 0.000_001, "Unsaturated optical zoom in/out is not reversible.")
        try require(geometryBytes(geometry) == proof && node.simdWorldPosition == origin,
                    "Repeated optical zoom changed geometry or the camera position.")
        print("PASS: arbitrarily strong optical zoom preserves camera position outside the model, visible front faces and finite projection")
        return ["strongFieldOfView": strong, "strongVisiblePixels": pixels,
                "cameraPositionUnchanged": true, "cameraDistance": Double(simd_length(origin)),
                "unsaturatedRoundTripErrorDegrees": abs(ordinaryOut - initial)]
    }

    @MainActor private static func verifyCursorAnchor() throws -> [String: Any] {
        var maximumError = 0.0
        var cases = 0
        var maximumAxialDisplacement = 0.0
        // SCNView uses Mac view coordinates here; this unshown test view never opens a window.
        for size in [CGSize(width: 960, height: 600), CGSize(width: 480, height: 800)] {
            for horizontal in [false, true] {
              for cameraPosition: SIMD3<Float> in [SIMD3(0, 0, 4), SIMD3(3, 2, 4)] {
                for logScale in [0.8, -0.8, 20.0] {
                    let view = SCNView(frame: CGRect(origin: .zero, size: size))
                    let scene = scene(planeGeometry(reversed: false, side: 2.4))
                    let node = cameraNode(position: cameraPosition)
                    scene.rootNode.addChildNode(node)
                    view.scene = scene
                    view.pointOfView = node
                    node.camera!.projectionDirection = horizontal ? .horizontal : .vertical
                    DesktopCameraPolicy.apply(to: node.camera!, cameraPosition: node.simdWorldPosition, contentRadius: sqrt(2) * 1.2)
                    SCNTransaction.flush()
                    let anchor = SCNVector3(0.5, 0.35, 0)
                    let before = view.projectPoint(anchor)
                    try require(before.x.isFinite && before.y.isFinite && before.x > 0 && before.y > 0,
                                "SceneKit did not project the initial anchor into Mac view coordinates.")
                    let local = node.convertPosition(anchor, from: nil)
                    let oldField = Double(node.camera!.fieldOfView)
                    let newField = DesktopCameraPolicy.zoomFieldOfView(current: oldField, logScale: logScale)
                    let shift = DesktopCameraPolicy.zoomAnchorShift(oldFieldOfView: oldField, newFieldOfView: newField,
                        viewport: SIMD2(Double(size.width), Double(size.height)), point: SIMD2(Double(before.x), Double(before.y)),
                        depth: -Double(local.z), horizontalProjection: horizontal)
                    let world = node.simdConvertVector(shift, to: nil)
                    let axial = abs(Double(simd_dot(world, node.simdWorldFront)))
                    maximumAxialDisplacement = max(maximumAxialDisplacement, axial)
                    node.simdWorldPosition += world
                    node.camera!.fieldOfView = CGFloat(newField)
                    SCNTransaction.flush()
                    let after = view.projectPoint(anchor)
                    let error = hypot(Double(after.x - before.x), Double(after.y - before.y))
                    try require(error.isFinite && error < 0.5,
                        "Cursor anchor moved by \(error) Mac view points after zoom; viewport=\(size), horizontal=\(horizontal), logScale=\(logScale), before=\(before), after=\(after), shift=\(shift), viewFlipped=\(view.isFlipped).")
                    try require(axial < 0.000_01, "Cursor anchoring moved the camera along its viewing axis.")
                    try require(simd_length(node.simdWorldPosition) >= simd_length(cameraPosition) - 0.000_01,
                                "Cursor zoom moved the initially external camera into the model sphere.")
                    maximumError = max(maximumError, error)
                    cases += 1
                }
              }
            }
        }
        print("PASS: \(cases) SceneKit projectPoint cases retain the cursor anchor within \(maximumError) Mac view points, with zero axial dolly")
        return ["cases": cases, "maxReprojectionErrorViewPoints": maximumError,
                "maxAxialCameraDisplacement": maximumAxialDisplacement,
                "portraitLandscapeAndBothProjectionDirections": true, "rotatedCameraIncluded": true]
    }

    private static func planeGeometry(reversed: Bool, side: Float) -> SCNGeometry {
        let h = side / 2
        let vertices = [SCNVector3(-h, -h, 0), SCNVector3(h, -h, 0), SCNVector3(h, h, 0), SCNVector3(-h, h, 0)]
        return geometry(vertices, indices: reversed ? [0, 2, 1, 0, 3, 2] : [0, 1, 2, 0, 2, 3])
    }

    private static func roomGeometry() -> SCNGeometry {
        let h: Float = 1.2
        let walls: [[SCNVector3]] = [
            [.init(-h,-h,-h), .init(h,-h,-h), .init(h,h,-h), .init(-h,h,-h)],
            [.init(h,-h,h), .init(-h,-h,h), .init(-h,h,h), .init(h,h,h)],
            [.init(-h,-h,h), .init(-h,-h,-h), .init(-h,h,-h), .init(-h,h,h)],
            [.init(h,-h,-h), .init(h,-h,h), .init(h,h,h), .init(h,h,-h)],
            [.init(-h,-h,-h), .init(-h,-h,h), .init(h,-h,h), .init(h,-h,-h)],
            [.init(-h,h,h), .init(-h,h,-h), .init(h,h,-h), .init(h,h,h)]
        ]
        var indices: [Int32] = []
        for wall in walls.indices {
            let offset = Int32(wall * 4)
            indices += [offset, offset + 1, offset + 2, offset, offset + 2, offset + 3]
        }
        return geometry(walls.flatMap { $0 }, indices: indices)
    }

    private static func geometry(_ vertices: [SCNVector3], indices: [Int32]) -> SCNGeometry {
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                  elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(red: 0.9, green: 0.25, blue: 0.1, alpha: 1)
        material.isDoubleSided = false
        material.cullMode = .back
        geometry.materials = [material]
        return geometry
    }

    private static func scene(_ geometry: SCNGeometry) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        return scene
    }

    private static func cameraNode(position: SIMD3<Float>) -> SCNNode {
        let node = SCNNode()
        node.camera = SCNCamera()
        node.camera!.fieldOfView = 60
        node.camera!.wantsHDR = false
        node.simdPosition = position
        node.look(at: SCNVector3Zero)
        return node
    }

    private static func geometryBytes(_ geometry: SCNGeometry) -> [Data] {
        geometry.sources.map(\.data) + geometry.elements.map(\.data)
    }

    @MainActor private static func render(_ scene: SCNScene, camera: SCNNode, device: MTLDevice, output: URL) throws -> Int {
        try autoreleasepool {
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = camera
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 256, height: 256), antialiasingMode: .none)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw failure("Cannot inspect the real Metal render.")
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { throw failure("Cannot save render evidence.") }
            let width = cgImage.width, height = cgImage.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let counted: Int? = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                return stride(from: 0, to: buffer.count, by: 4).reduce(0) { count, offset in
                    count + (Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2]) > 30 ? 1 : 0)
                }
            }
            guard let counted else { throw failure("Cannot read render pixels.") }
            return counted
        }
    }

    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw failure(message) }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FormaDesktopCameraVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
