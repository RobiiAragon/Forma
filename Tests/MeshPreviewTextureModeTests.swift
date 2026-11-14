import XCTest
import SceneKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import Forma

/// Authored assets exercise the actual SceneKit importer and texture dependencies.
final class MeshPreviewTextureModeTests: XCTestCase {
    @MainActor
    func testGeometryAppearanceRemovesMapsThatSimulateSurfaceReliefWithoutChangingSourceMaterial() {
        let geometry = SCNPlane(width: 1, height: 1)
        let original = SCNMaterial()
        original.normal.contents = "normals.png"
        original.displacement.contents = "displacement.png"
        original.ambientOcclusion.contents = "occlusion.png"
        original.diffuse.contents = "color.png"
        geometry.materials = [original]
        let appearances = MeshPreviewMaterials(geometry: geometry)
        appearances.apply(wireframe: false, showTexture: false)
        XCTAssertNil(geometry.firstMaterial?.normal.contents)
        XCTAssertNil(geometry.firstMaterial?.displacement.contents)
        XCTAssertNil(geometry.firstMaterial?.ambientOcclusion.contents)
        XCTAssertEqual(original.normal.contents as? String, "normals.png")
        appearances.apply(wireframe: false, showTexture: true)
        XCTAssertEqual(geometry.firstMaterial?.normal.contents as? String, "normals.png")
        XCTAssertEqual(geometry.firstMaterial?.diffuse.contents as? String, "color.png")
    }
    @MainActor
    func testOriginalImportUsesNativeTextureDespiteProxyBudgetAndKeepsGeometryAndSourceBytes() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("model.obj")
        let names = ["model.obj", "material.mtl", "source.png"]
        let before = try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        // A small injected resource budget gives the authored fixture a real
        // reduced proxy without allocating a large image or exhausting a phone.
        let light = try MeshPreviewPreparation.load(url: model, texturePreviewBudgetBytes: 2048, checkCancellation: {})
        let proxyURL = try XCTUnwrap(light.sourceURL)
        defer { if proxyURL != model { try? FileManager.default.removeItem(at: proxyURL.deletingLastPathComponent()) } }
        XCTAssertTrue(light.texturePreviewAdapted, "The compatible default remains the lightweight path")
        XCTAssertNotEqual(proxyURL, model)
        let original = try MeshPreviewPreparation.load(url: model, textureMode: .original,
            texturePreviewBudgetBytes: 0, checkCancellation: {})
        XCTAssertEqual(original.sourceURL, model, "Original must give the native asset URL to SceneKit")
        XCTAssertFalse(original.texturePreviewAdapted)
        let nativeImage = try textureImage(in: original, relativeTo: model.deletingLastPathComponent())
        let lightImage = try textureImage(in: light, relativeTo: proxyURL.deletingLastPathComponent())
        XCTAssertEqual(nativeImage.width, 64); XCTAssertEqual(nativeImage.height, 32)
        XCTAssertLessThan(lightImage.width, nativeImage.width)
        XCTAssertLessThan(lightImage.height, nativeImage.height)
        XCTAssertEqual(original.low, light.low); XCTAssertEqual(original.high, light.high)
        XCTAssertEqual(original.materialSets.count, light.materialSets.count)
        for materials in original.materialSets + light.materialSets {
            XCTAssertFalse(try XCTUnwrap(materials.textured.first).isDoubleSided)
            XCTAssertEqual(try XCTUnwrap(materials.textured.first).cullMode, .back)
            XCTAssertFalse(materials.geometry.sources(for: .texcoord).isEmpty)
        }
        XCTAssertEqual(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }, before,
                       "Changing display texture resolution may not rewrite model, UVs, material or source pixels")
    }

    #if os(iOS)
    @MainActor
    func testSwitchingTextureModeRetainsZoomCameraAndFirstMetricPoint() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("model.obj")
        var distances: [Float?] = []
        let view = SCNView(frame: CGRect(x: 0,y: 0,width: 480,height: 480))
        let coordinator = MeasurementPreview.Coordinator { distances.append($0) }
        coordinator.attach(view)
        defer { coordinator.stop() }
        coordinator.update(url: model, measuring: true, wireframe: false, viewpoint: .front,
                           onMeasurement: { distances.append($0) })
        let first = try await loadedSurface(in: view)
        try tap(local: SIMD3(0.1,0.1,0), on: first, in: view, coordinator: coordinator)
        await Task.yield()
        let camera = try XCTUnwrap(view.pointOfView)
        camera.position = SCNVector3(0.25,0.15,5.3)
        camera.look(at: SCNVector3Zero)
        camera.camera?.fieldOfView = 37
        let expectedTransform = camera.simdWorldTransform
        let expectedTarget = view.defaultCameraController.target
        let callbacks = distances.count
        coordinator.update(url: model, measuring: true, wireframe: false, textureMode: .original,
                           viewpoint: .front, onMeasurement: { distances.append($0) })
        let second = try await loadedSurface(in: view)
        XCTAssertEqual(distances.count, callbacks, "Selecting native texture cannot clear the active measurement")
        let restored = try XCTUnwrap(view.pointOfView)
        XCTAssertEqual(restored.camera?.fieldOfView, 37)
        for column in 0..<4 { for row in 0..<4 {
            XCTAssertEqual(restored.simdWorldTransform[column][row], expectedTransform[column][row], accuracy: 0.000001)
        } }
        XCTAssertEqual(view.defaultCameraController.target.x, expectedTarget.x)
        XCTAssertEqual(view.defaultCameraController.target.y, expectedTarget.y)
        XCTAssertEqual(view.defaultCameraController.target.z, expectedTarget.z)
        try tap(local: SIMD3(0.7,0.1,0), on: second, in: view, coordinator: coordinator)
        XCTAssertEqual(try XCTUnwrap(distances.last.flatMap { $0 }), 0.6, accuracy: 0.001,
                       "The first selected surface point must survive texture reloading in metric coordinates")
        XCTAssertEqual(second.geometry?.materials.first?.cullMode, .back)
    }

    @MainActor private func loadedSurface(in view: SCNView) async throws -> SCNNode {
        let deadline = Date().addingTimeInterval(5)
        while view.scene == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        var surface: SCNNode?
        view.scene?.rootNode.enumerateChildNodes { node,stop in
            if node.geometry != nil { surface = node; stop.pointee = true }
        }
        return try XCTUnwrap(surface)
    }
    @MainActor private func tap(local point: SIMD3<Float>, on surface: SCNNode, in view: SCNView,
                                coordinator: MeasurementPreview.Coordinator) throws {
        let world = surface.simdConvertPosition(point, to: nil)
        let projected = view.projectPoint(SCNVector3(world.x,world.y,world.z))
        let screen = CGPoint(x: CGFloat(projected.x),y: CGFloat(projected.y))
        XCTAssertTrue(view.bounds.contains(screen))
        XCTAssertFalse(view.hitTest(screen,options: [.boundingBoxOnly:false,.backFaceCulling:true]).isEmpty)
        coordinator.perform(NSSelectorFromString("tapped:"),with: TextureModePositionedTap(point: screen))
    }
    #endif

    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-TextureMode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data:nil,width:64,height:32,bitsPerComponent:8,bytesPerRow:256,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<64 {
            context.setFillColor(CGColor(red:CGFloat(x)/63,green:0.25,blue:CGFloat(63-x)/63,alpha:1))
            context.fill(CGRect(x:x,y:0,width:1,height:32))
        }
        let image = try XCTUnwrap(context.makeImage())
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent("source.png") as CFURL,
            UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(encoder,image,nil); XCTAssertTrue(CGImageDestinationFinalize(encoder))
        try "newmtl photo\nKd 1 1 1\nmap_Kd source.png\n".write(to:folder.appendingPathComponent("material.mtl"),atomically:true,encoding:.utf8)
        try "mtllib material.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl photo\nf 1/1 2/2 3/3\n".write(to:folder.appendingPathComponent("model.obj"),atomically:true,encoding:.utf8)
        return folder
    }

    @MainActor private func textureImage(in prepared: MeshPreviewPreparation.Prepared, relativeTo folder: URL) throws -> CGImage {
        let contents = try XCTUnwrap(prepared.materialSets.first?.textured.first?.diffuse.contents)
        #if os(iOS)
        if let image = contents as? UIImage { return try XCTUnwrap(image.cgImage) }
        #else
        if let image = contents as? NSImage { return try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)) }
        #endif
        if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return contents as! CGImage }
        let url: URL
        if let value = contents as? URL { url = value }
        else if let value = contents as? String {
            if let parsed = URL(string:value), parsed.isFileURL { url = parsed }
            else if value.hasPrefix("/") { url = URL(fileURLWithPath:value) }
            else { url = folder.appendingPathComponent(value) }
        } else { throw NSError(domain:"TextureModeFixture",code:1) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
    }
}

#if os(iOS)
@MainActor private final class TextureModePositionedTap: UITapGestureRecognizer {
    private let point: CGPoint
    init(point: CGPoint) { self.point = point; super.init(target:nil,action:nil) }
    override func location(in view: UIView?) -> CGPoint { point }
    override var state: UIGestureRecognizer.State { get { .ended } set {} }
}
#endif
