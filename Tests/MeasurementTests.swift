import XCTest
import SceneKit
import UIKit
import simd
import ImageIO
@testable import Forma

/// File-format and SceneKit integration tests. These fixtures are authored geometry,
/// never represented as sensor captures or accuracy evidence.
final class MeasurementTests: XCTestCase {
    @MainActor
    func testTexturedOBJPreservesPhotographAndRestoresItAfterTextureToggle() async throws {
        let folder = try temporaryDirectory()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let authoredPhotograph = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            // Deliberately authored color detail distinguishes a real imported image map from a flat fallback.
            for y in 0..<8 {
                for x in 0..<8 {
                    UIColor(red: CGFloat(x) / 7, green: CGFloat(y) / 7,
                            blue: (x + y).isMultiple(of: 2) ? 1 : 0, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        let textureURL = folder.appendingPathComponent("authored-photo.png")
        try XCTUnwrap(authoredPhotograph.pngData()).write(to: textureURL)
        let material = """
        newmtl authoredPhotograph
        Ka 0 0 0
        Kd 1 1 1
        Ks 0 0 0
        d 1
        illum 1
        map_Kd authored-photo.png

        newmtl unobservedNeutral
        Ka 0 0 0
        Kd 0.42 0.43 0.44
        Ks 0 0 0
        d 1
        illum 1

        """
        try material.write(to: folder.appendingPathComponent("photograph.mtl"), atomically: true, encoding: .utf8)
        let obj = """
        mtllib photograph.mtl
        o authored-photo-surface
        v 0 0 0
        v 1 0 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 0 1
        vn 0 0 1
        g photographic
        usemtl authoredPhotograph
        f 1/1/1 2/2/1 3/3/1
        o unobserved-surface
        g unobserved
        v 2 0 0
        v 3 0 0
        v 2 1 0
        usemtl unobservedNeutral
        f 4//1 5//1 6//1

        """
        let modelURL = folder.appendingPathComponent("photographic.obj")
        try obj.write(to: modelURL, atomically: true, encoding: .utf8)
        let coordinator = MeasurementPreview.Coordinator { _ in }
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        coordinator.attach(view)
        coordinator.update(url: modelURL, measuring: false, wireframe: false, showTexture: true, onMeasurement: { _ in })
        defer { coordinator.stop() }
        let surface = try await loadedSurface(in: view)
        func importedMaterial(named name: String) throws -> SCNMaterial {
            var found: SCNMaterial?
            view.scene?.rootNode.enumerateChildNodes { node, stop in
                if let material = node.geometry?.materials.first(where: { $0.name == name }) {
                    found = material; stop.pointee = true
                }
            }
            return try XCTUnwrap(found, "Explicit OBJ/MTL material \(name) must survive the viewer's fallback styling")
        }
        XCTAssertNotNil(surface.geometry)
        let original = try importedMaterial(named: "authoredPhotograph")
        let originalNeutral = try importedMaterial(named: "unobservedNeutral")
        let originalNeutralColor = try XCTUnwrap(originalNeutral.diffuse.contents as? UIColor)
        XCTAssertFalse(originalNeutral.isDoubleSided)
        XCTAssertEqual(originalNeutral.cullMode, .back)
        XCTAssertFalse(original.isDoubleSided, "Photographs must not appear mirrored through a rear-facing triangle")
        XCTAssertEqual(original.cullMode, .back)
        let expectedPixels = try rgbaPixels(of: XCTUnwrap(authoredPhotograph.cgImage))
        let originalImage = try textureImage(from: original.diffuse.contents, relativeTo: folder)
        XCTAssertEqual(originalImage.width, 8)
        XCTAssertEqual(originalImage.height, 8)
        XCTAssertEqual(try rgbaPixels(of: originalImage), expectedPixels,
                       "OBJ/MTL image detail must survive loading instead of being replaced by an orange material")

        coordinator.update(url: modelURL, measuring: false, wireframe: false, showTexture: false, onMeasurement: { _ in })
        let neutral = try importedMaterial(named: "authoredPhotograph")
        XCTAssertTrue(neutral.diffuse.contents is UIColor, "Disabling texture should display the neutral surface material")
        XCTAssertFalse(neutral.isDoubleSided)
        XCTAssertEqual(neutral.cullMode, .back)

        coordinator.update(url: modelURL, measuring: false, wireframe: false, showTexture: true, onMeasurement: { _ in })
        let restored = try importedMaterial(named: "authoredPhotograph")
        XCTAssertFalse(restored.isDoubleSided)
        XCTAssertEqual(restored.cullMode, .back)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(try rgbaPixels(of: textureImage(from: restored.diffuse.contents, relativeTo: folder)), expectedPixels,
                       "Re-enabling texture must restore the original image, not the neutral material from the previous toggle")
        let restoredNeutral = try importedMaterial(named: "unobservedNeutral")
        XCTAssertEqual(restoredNeutral.diffuse.contents as? UIColor, originalNeutralColor,
                       "An explicit neutral material for an unobserved face must not become the orange OBJ fallback")
        XCTAssertFalse(restoredNeutral.isDoubleSided)
        XCTAssertEqual(restoredNeutral.cullMode, .back)
    }

    @MainActor
    func testExportedMetricOBJMeasuresSurfacePointsInMeters() async throws {
        let folder = try temporaryDirectory()
        let mesh = MeshSnapshot(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 2, 0)],
                                triangles: [0, 1, 2])
        _ = try MeshExporter.write(mesh, to: folder)
        var distances: [Float?] = []
        let coordinator = MeasurementPreview.Coordinator { distances.append($0) }
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        coordinator.attach(view)
        coordinator.update(url: folder.appendingPathComponent("modelo.obj"), measuring: true,
                           wireframe: false, onMeasurement: { distances.append($0) })
        defer { coordinator.stop() }
        let surface = try await loadedSurface(in: view)
        let bounds = surface.geometry!.boundingBox
        XCTAssertEqual(bounds.max.x - bounds.min.x, 1, accuracy: 0.0001,
                       "The app's exported OBJ has meter-valued coordinates")
        XCTAssertEqual(bounds.max.y - bounds.min.y, 2, accuracy: 0.0001)

        // Both points lie strictly inside the real imported triangle, away from edge tolerances.
        try tap(local: SIMD3(0.1, 0.1, 0), on: surface, in: view, coordinator: coordinator)
        try tap(local: SIMD3(0.7, 0.1, 0), on: surface, in: view, coordinator: coordinator)
        let distance = try XCTUnwrap(distances.last.flatMap { $0 })
        XCTAssertEqual(distance, 0.6, accuracy: 0.001,
                       "A display-normalized model must still report the original meter distance")

        coordinator.update(url: folder.appendingPathComponent("modelo.obj"), measuring: false,
                           wireframe: false, onMeasurement: { distances.append($0) })
        await Task.yield()
        XCTAssertNil(distances.last.flatMap { $0 }, "Disabling measurement clears its callback result")
    }

    @MainActor
    func testNestedImportedTransformsAndDisplayNormalizationPreserveSixPointFiveMeters() async throws {
        let folder = try temporaryDirectory()
        let url = folder.appendingPathComponent("nested-metric.scn")
        let fixture = SCNScene()
        let transformed = SCNNode()
        transformed.simdPosition = SIMD3(100, 20, -40)
        transformed.simdScale = SIMD3(2, 3, 0.5)
        transformed.simdOrientation = simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0))
        fixture.rootNode.addChildNode(transformed)
        // A planar quadrilateral, large enough that both tested points are inside its faces.
        let points: [SCNVector3] = [SCNVector3(-1, -2, -3), SCNVector3(2, -2, -3),
                                  SCNVector3(2, 4, 6), SCNVector3(-1, 4, 6)]
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)],
                                   elements: [SCNGeometryElement(indices: [Int32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)])
        let surface = SCNNode(geometry: geometry)
        surface.name = "metric-surface"
        surface.simdPosition = SIMD3(2, 1, -3)
        transformed.addChildNode(surface)
        let wroteFixture = await Task.detached(priority: .utility) {
            fixture.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        }.value
        XCTAssertTrue(wroteFixture)

        var distances: [Float?] = []
        let coordinator = MeasurementPreview.Coordinator { distances.append($0) }
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        coordinator.attach(view)
        coordinator.update(url: url, measuring: true, wireframe: false,
                           onMeasurement: { distances.append($0) })
        defer { coordinator.stop() }
        let imported = try await loadedSurface(in: view, named: "metric-surface")
        // Delta (1, 2, 3), scaled by (2, 3, 0.5), has length sqrt(4 + 36 + 2.25) = 6.5 m.
        // Rotations, translations and the viewer's fit-to-screen scaling cannot change that measure.
        try tap(local: SIMD3(0, 0, 0), on: imported, in: view, coordinator: coordinator)
        try tap(local: SIMD3(1, 2, 3), on: imported, in: view, coordinator: coordinator)
        let distance = try XCTUnwrap(distances.last.flatMap { $0 })
        XCTAssertEqual(distance, 6.5, accuracy: 0.002)
    }

    @MainActor
    func testAreaCoordinatorUsesRealSurfaceHitsInSquareMetersAndResetsBetweenModes() async throws {
        let folder = try temporaryDirectory()
        let mesh = MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(4,0,0), SIMD3(4,3,0), SIMD3(0,3,0)],
                                triangles: [0,1,2, 0,2,3])
        _ = try MeshExporter.write(mesh, to: folder)
        let url = folder.appendingPathComponent("modelo.obj")
        var distances: [Float?] = [], areas: [Float?] = []
        let coordinator = MeasurementPreview.Coordinator { distances.append($0) }
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 480, height: 480))
        coordinator.attach(view)
        coordinator.update(url: url, measuring: true, wireframe: false, viewpoint: .front,
                           measureArea: false, onAreaMeasurement: { areas.append($0) },
                           onMeasurement: { distances.append($0) })
        defer { coordinator.stop() }
        let surface = try await loadedSurface(in: view)
        let a = SIMD3<Float>(0.5,0.5,0), b = SIMD3<Float>(3.5,0.5,0)
        let c = SIMD3<Float>(3.5,2.5,0), d = SIMD3<Float>(0.5,2.5,0)
        try tap(local: a, on: surface, in: view, coordinator: coordinator)
        try tap(local: b, on: surface, in: view, coordinator: coordinator)
        XCTAssertEqual(try XCTUnwrap(distances.last.flatMap { $0 }), 3, accuracy: 0.001)

        let areaModeReset = expectation(description: "Cambiar de distancia a área limpia el resultado anterior")
        coordinator.update(url: url, measuring: true, wireframe: false, viewpoint: .front,
                           measureArea: true, onAreaMeasurement: { areas.append($0) },
                           onMeasurement: { value in distances.append(value); if value == nil { areaModeReset.fulfill() } })
        await fulfillment(of: [areaModeReset], timeout: 1)
        XCTAssertNil(distances.last.flatMap { $0 })
        XCTAssertNil(areas.last.flatMap { $0 })
        // The polygon is deliberately smaller than the imported 12 m² rectangle.
        // Hit tests must use the selected boundary, not the bounding box or display-normalized coordinates.
        try tap(local: a, on: surface, in: view, coordinator: coordinator)
        try tap(local: b, on: surface, in: view, coordinator: coordinator)
        XCTAssertNil(areas.last.flatMap { $0 }, "Two points do not yet enclose a polygon")
        try tap(local: c, on: surface, in: view, coordinator: coordinator)
        XCTAssertEqual(try XCTUnwrap(areas.last.flatMap { $0 }), 3, accuracy: 0.002)
        try tap(local: d, on: surface, in: view, coordinator: coordinator)
        XCTAssertEqual(try XCTUnwrap(areas.last.flatMap { $0 }), 6, accuracy: 0.002)

        let disabledReset = expectation(description: "Desactivar medición limpia el área")
        coordinator.update(url: url, measuring: false, wireframe: false, viewpoint: .front,
                           measureArea: true, onAreaMeasurement: { value in areas.append(value); if value == nil { disabledReset.fulfill() } },
                           onMeasurement: { distances.append($0) })
        await fulfillment(of: [disabledReset], timeout: 1)
        XCTAssertNil(areas.last.flatMap { $0 })

        let distanceModeReset = expectation(description: "Regresar a distancia comienza una selección nueva")
        coordinator.update(url: url, measuring: true, wireframe: false, viewpoint: .front,
                           measureArea: false, onAreaMeasurement: { areas.append($0) },
                           onMeasurement: { value in distances.append(value); if value == nil { distanceModeReset.fulfill() } })
        await fulfillment(of: [distanceModeReset], timeout: 1)
        try tap(local: a, on: surface, in: view, coordinator: coordinator)
        try tap(local: d, on: surface, in: view, coordinator: coordinator)
        XCTAssertEqual(try XCTUnwrap(distances.last.flatMap { $0 }), 2, accuracy: 0.001)
        XCTAssertNil(areas.last.flatMap { $0 }, "An earlier polygon area must not remain visible in distance mode")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeasurementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    private func textureImage(from contents: Any?, relativeTo folder: URL) throws -> CGImage {
        if let image = contents as? UIImage { return try XCTUnwrap(image.cgImage) }
        if let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return contents as! CGImage }
        let url: URL
        if let file = contents as? URL { url = file }
        else if let path = contents as? String {
            if let absoluteURL = URL(string: path), absoluteURL.isFileURL { url = absoluteURL }
            else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
            else { url = folder.appendingPathComponent(path) }
        } else {
            XCTFail("The imported photographic material must contain an image or a texture file, received \(String(describing: contents))")
            throw NSError(domain: "MeasurementTests", code: 1)
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgbaPixels(of image: CGImage) throws -> Data {
        var pixels = Data(count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    @MainActor
    private func loadedSurface(in view: SCNView, named name: String? = nil) async throws -> SCNNode {
        let deadline = Date().addingTimeInterval(5)
        while view.scene == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let scene = try XCTUnwrap(view.scene, "The real viewer should finish loading the local file")
        var surface: SCNNode?
        scene.rootNode.enumerateChildNodes { node, stop in
            if node.geometry != nil, name == nil || node.name == name {
                surface = node
                stop.pointee = true
            }
        }
        return try XCTUnwrap(surface, "The loaded model must contain the authored surface")
    }

    @MainActor
    private func tap(local point: SIMD3<Float>, on surface: SCNNode, in view: SCNView,
                     coordinator: MeasurementPreview.Coordinator) throws {
        let world = surface.simdConvertPosition(point, to: nil)
        let projected = view.projectPoint(SCNVector3(world.x, world.y, world.z))
        let screen = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        XCTAssertTrue(view.bounds.contains(screen), "The authored point must be visible inside the viewer")
        XCTAssertFalse(view.hitTest(screen, options: [.boundingBoxOnly: false, .backFaceCulling: false]).isEmpty,
                       "The measurement tap must intersect actual loaded geometry")
        // UIKit normally dispatches this selector. A positioned tap exercises that same handler,
        // hit test, metric conversion and callback without adding test-only product APIs.
        let action = NSSelectorFromString("tapped:")
        XCTAssertTrue(coordinator.responds(to: action))
        coordinator.perform(action, with: PositionedTap(point: screen))
    }
}

@MainActor
private final class PositionedTap: UITapGestureRecognizer {
    private let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target: nil, action: nil) }
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
}
