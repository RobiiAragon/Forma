import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Forma

final class RecoveryAndPreviewTests: XCTestCase {
    @MainActor
    func testInterruptedFinalSaveCanRecoverWithoutReplacingAnyPayload() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ScanStore(baseURL: base)
        let mesh = MeshSnapshot(vertices: [.init(0,0,0),.init(1,0,0),.init(0,1,0)],triangles:[0,1,2])
        let saved = await store.save(CaptureResult(mesh: mesh, mode: .lidar, duration: 1))
        let record = try XCTUnwrap(saved)
        let final = store.directory(for: record), pending = base.appendingPathComponent(".pending-" + record.id.uuidString)
        try FileManager.default.moveItem(at: final, to: pending)
        try FileManager.default.removeItem(at: pending.appendingPathComponent("integridad.json"))
        let bytes = try Data(contentsOf: pending.appendingPathComponent("modelo.obj"))
        let report = try await Task.detached { try PendingScanRecovery.recover(in: base) }.value
        XCTAssertEqual(report.recoveredCount, 1); XCTAssertEqual(report.remainingCount, 0)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("modelo.obj")), bytes)
        let manifest = try JSONDecoder().decode(IntegrityManifest.self, from: Data(contentsOf: final.appendingPathComponent("integridad.json")))
        XCTAssertTrue(try manifest.verify(in: final))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    @MainActor
    func testMissingModelInInterruptedSaveStaysPendingAndCancelledRecoveryDoesNotPublish() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ScanStore(baseURL: base)
        let saved = await store.save(CaptureResult(mesh: MeshSnapshot(vertices: [.init(0,0,0),.init(1,0,0),.init(0,1,0)],triangles:[0,1,2]), mode: .lidar, duration: 1))
        let record = try XCTUnwrap(saved)
        let final = store.directory(for: record), pending = base.appendingPathComponent(".pending-" + record.id.uuidString)
        try FileManager.default.moveItem(at: final, to: pending)
        try FileManager.default.removeItem(at: pending.appendingPathComponent("integridad.json"))
        let control = ProcessingControl(); control.cancel()
        do { _ = try await Task.detached { try PendingScanRecovery.recover(in: base, control: control) }.value; XCTFail("Cancelled work must not publish") }
        catch is CancellationError { }
        try FileManager.default.removeItem(at: pending.appendingPathComponent("modelo.obj"))
        let report = try await Task.detached { try PendingScanRecovery.recover(in: base) }.value
        XCTAssertEqual(report.recoveredCount, 0); XCTAssertEqual(report.remainingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.appendingPathComponent("malla.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    }

    func testTexturePreviewAdaptsOnlyDisposableImagesAndPreservesGeometryUVAndOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data:nil,width:64,height:32,bitsPerComponent:8,bytesPerRow:256,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.8,green:0.1,blue:0.2,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:32))
        let image = try XCTUnwrap(context.makeImage()), photo = directory.appendingPathComponent("source.png")
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(encoder,image,nil); XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let geometry = "v 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl photo\nf 1/1 2/2 3/3\n"
        let obj = directory.appendingPathComponent("model.obj")
        try ("mtllib material.mtl\n" + geometry).write(to:obj,atomically:true,encoding:.utf8)
        try "newmtl photo\nmap_Kd source.png\n".write(to:directory.appendingPathComponent("material.mtl"),atomically:true,encoding:.utf8)
        let original = try Data(contentsOf:photo)
        XCTAssertFalse(try TexturePreviewProxy.prepare(obj,budgetBytes:1_000_000,checkCancellation:{}).adapted)
        let adapted = try TexturePreviewProxy.prepare(obj,budgetBytes:2048,checkCancellation:{})
        XCTAssertTrue(adapted.adapted)
        XCTAssertTrue(try String(contentsOf:adapted.url).hasSuffix(geometry))
        XCTAssertEqual(try Data(contentsOf:photo), original)
        XCTAssertEqual(try String(contentsOf:obj),"mtllib material.mtl\n" + geometry)
        let thumb = try XCTUnwrap(CGImageSourceCreateWithURL(adapted.url.deletingLastPathComponent().appendingPathComponent("preview-0.png") as CFURL,nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(thumb,0,nil) as? [CFString:Any])
        XCTAssertLessThan((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 64,64)
    }
}
