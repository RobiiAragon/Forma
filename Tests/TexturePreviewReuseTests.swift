import XCTest
import ImageIO
import CryptoKit
@testable import Forma

final class TexturePreviewReuseTests: XCTestCase {
    func testWarmReuseAvoidsResourceReadsAndKeepsCompleteArtifactsAndSource() throws {
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try Data(contentsOf: fixture.model), pixels = try Data(contentsOf: fixture.photo)
        let cold = try prepare(fixture)
        let before = try artifacts(cold.url)
        var operations: [TexturePreviewProxy.ResourceAccess] = []
        let warm = try prepare(fixture) { operations.append($0) }
        XCTAssertEqual(operations.filter { $0 == .memoryCacheHit }.count, 1)
        XCTAssertEqual(operations.filter { $0 == .sourceIdentityCheck }.count, 3)
        XCTAssertEqual(operations.filter { $0 == .cachedOutputCheck }.count, 1)
        XCTAssertFalse(operations.contains { [.modelText,.materialText,.imageMetadata,.thumbnailDecode].contains($0) })
        XCTAssertEqual(try artifacts(warm.url), before)
        XCTAssertEqual(try Data(contentsOf: fixture.model), source)
        XCTAssertEqual(try Data(contentsOf: fixture.photo), pixels)
        let geometry = try String(contentsOf: warm.url).components(separatedBy: "\n").dropFirst()
        XCTAssertEqual(Array(geometry), Array(try String(contentsOf: fixture.model).components(separatedBy: "\n").dropFirst()))
    }

    func testAtomicOBJReplacementAtSamePathAndMtimeInvalidates() throws {
        let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try prepare(f), date = try f.model.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
        let body = try String(contentsOf: f.model).replacingOccurrences(of:"v 1 0 0",with:"v 2 0 0")
        try Data(body.utf8).write(to:f.model,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:f.model.path)
        var reads: [TexturePreviewProxy.ResourceAccess] = []
        let updated = try prepare(f) { reads.append($0) }
        XCTAssertFalse(reads.contains(.memoryCacheHit)); XCTAssertNotEqual(old.url,updated.url)
        XCTAssertTrue(try String(contentsOf:updated.url).contains("v 2 0 0"))
    }

    func testMaterialChangeAndUnsupportedMapTransformCannotReturnOldProxy() throws {
        let f = try makeFixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let old = try prepare(f)
        try "newmtl photo\nKd 0.5 0.5 0.5\nmap_Kd photo.bmp\n".write(to:f.mtl,atomically:true,encoding:.utf8)
        let changed = try prepare(f)
        XCTAssertNotEqual(old.url,changed.url)
        XCTAssertTrue(try String(contentsOf:changed.url.deletingLastPathComponent().appendingPathComponent("preview.mtl")).contains("Kd 0.5"))
        try "newmtl photo\nmap_Kd -s 2 2 1 photo.bmp\n".write(to:f.mtl,atomically:true,encoding:.utf8)
        let transformed = try prepare(f)
        XCTAssertFalse(transformed.adapted); XCTAssertEqual(transformed.url,f.model,"Unsupported proxy syntax falls back to original importer")
    }

    func testTextureSameSizeAndMtimeIsInvalidatedInMemoryAndOnDisk() throws {
        let f = try makeFixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let old = try prepare(f), hashes = try artifacts(old.url)
        let date = try f.photo.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
        let size = try Data(contentsOf:f.photo).count
        try bmp(red:0,blue:255).write(to:f.photo) // Fixed-size uncompressed raster, same inode.
        XCTAssertEqual(try Data(contentsOf:f.photo).count,size)
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:f.photo.path)
        var reads: [TexturePreviewProxy.ResourceAccess] = []
        let changed = try prepare(f) { reads.append($0) }
        XCTAssertFalse(reads.contains(.memoryCacheHit)); XCTAssertNotEqual(old.url,changed.url)
        XCTAssertNotEqual(try artifacts(changed.url)["preview-0.png"],hashes["preview-0.png"])
    }

    func testBudgetChangesAndDifferentCacheDirectoriesAreRespected() throws {
        let f = try makeFixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let small = try prepare(f)
        let original = try TexturePreviewProxy.prepare(f.model,budgetBytes:UInt64.max,cacheDirectory:f.cache,checkCancellation:{})
        XCTAssertFalse(original.adapted); XCTAssertEqual(original.url,f.model)
        let other = try TexturePreviewProxy.prepare(f.model,budgetBytes:1024,cacheDirectory:f.root.appendingPathComponent("other-cache"),checkCancellation:{})
        XCTAssertTrue(other.adapted); XCTAssertNotEqual(small.url,other.url)
        XCTAssertEqual(try artifacts(small.url),try artifacts(other.url))
    }

    func testMissingDependencyRecoveryAndCancellationDoNotReuseStaleSuccess() throws {
        let f = try makeFixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        _ = try prepare(f)
        try FileManager.default.removeItem(at:f.photo)
        XCTAssertFalse(try prepare(f).adapted)
        try bmp(red:0,blue:255).write(to:f.photo)
        XCTAssertTrue(try prepare(f).adapted)
        XCTAssertThrowsError(try TexturePreviewProxy.prepare(f.model,budgetBytes:1024,cacheDirectory:f.cache,checkCancellation:{ throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertTrue(try prepare(f).adapted,"Cancellation must not poison reusable success")
    }

    func testSinglePassInventoryKeepsMaterialsAndValidationBehavior() throws {
        let f = try makeFixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let strict = try TextureAssetInventory.load(modelURL:f.model)
        let optional = try XCTUnwrap(TextureAssetInventory.loadIfPresent(modelURL:f.model))
        XCTAssertEqual(strict.mtlURL,optional.mtlURL)
        XCTAssertEqual(strict.assets.map(\.relativePath),optional.assets.map(\.relativePath))
        XCTAssertEqual(strict.assets.map(\.width),optional.assets.map(\.width))
        XCTAssertEqual(strict.assets.map(\.height),optional.assets.map(\.height))
        XCTAssertEqual(strict.assets.map(\.materialNames),optional.assets.map(\.materialNames))
        try FileManager.default.removeItem(at:f.photo)
        XCTAssertThrowsError(try TextureAssetInventory.loadIfPresent(modelURL:f.model))
        let body = try String(contentsOf:f.model)
        try body.replacingOccurrences(of:"mtllib model.mtl\n",with:"").write(to:f.model,atomically:true,encoding:.utf8)
        XCTAssertNil(try TextureAssetInventory.loadIfPresent(modelURL:f.model))
        XCTAssertThrowsError(try TextureAssetInventory.load(modelURL:f.model))
        try ("mtllib model.mtl\n"+body).write(to:f.model,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try TextureAssetInventory.loadIfPresent(modelURL:f.model),"Multiple libraries remain an explicit validation error")
    }

    private struct Fixture { let root,model,mtl,photo,cache:URL }
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-Preview-Reuse-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let f = Fixture(root:root,model:root.appendingPathComponent("model.obj"),mtl:root.appendingPathComponent("model.mtl"),photo:root.appendingPathComponent("photo.bmp"),cache:root.appendingPathComponent("cache"))
        try "mtllib model.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl photo\nf 1/1 2/2 3/3\n".write(to:f.model,atomically:true,encoding:.utf8)
        try "newmtl photo\nmap_Kd photo.bmp\n".write(to:f.mtl,atomically:true,encoding:.utf8)
        try bmp(red:255,blue:0).write(to:f.photo)
        for file in [f.model,f.photo] {
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:file.path)
        }
        return f
    }
    private func prepare(_ f:Fixture,onRead:((TexturePreviewProxy.ResourceAccess)->Void)?=nil) throws -> TexturePreviewProxy.Result {
        try TexturePreviewProxy.prepare(f.model,budgetBytes:1024,cacheDirectory:f.cache,onResourceAccess:onRead,checkCancellation:{})
    }
    private func artifacts(_ model:URL) throws -> [String:String] {
        try ["preview.obj","preview.mtl","preview-0.png"].reduce(into:[:]) { result,name in
            let data = try Data(contentsOf:model.deletingLastPathComponent().appendingPathComponent(name))
            result[name] = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        }
    }
    private func bmp(red:UInt8,blue:UInt8) -> Data {
        var data = Data("BM".utf8)
        func u32(_ value:UInt32) { var v=value.littleEndian;withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        func u16(_ value:UInt16) { var v=value.littleEndian;withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        u32(54+64*64*3);u32(0);u32(54);u32(40);u32(64);u32(64);u16(1);u16(24)
        u32(0);u32(64*64*3);u32(2835);u32(2835);u32(0);u32(0)
        for _ in 0..<(64*64) { data.append(contentsOf:[blue,0,red]) }
        return data
    }
}
