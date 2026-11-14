import XCTest
import simd
@testable import Forma

final class FormaTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private var triangle: MeshSnapshot {
        MeshSnapshot(vertices: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0)], triangles: [0,1,2])
    }

    func testExportGeometryAndUnits() throws {
        let folder = try temporaryDirectory()
        let files = try MeshExporter.write(triangle, to: folder)
        XCTAssertEqual(Set(files), Set(["modelo.obj", "modelo.ply", "modelo.stl"]))
        let obj = try String(contentsOf: folder.appendingPathComponent("modelo.obj"), encoding: .utf8)
        XCTAssertTrue(obj.contains("f 1 2 3\n"), "OBJ must use one-based indices")
        let ply = try String(contentsOf: folder.appendingPathComponent("modelo.ply"), encoding: .utf8)
        XCTAssertTrue(ply.contains("element vertex 3\n"))
        XCTAssertTrue(ply.contains("3 0 1 2\n"), "PLY must use zero-based indices")
        let stl = try String(contentsOf: folder.appendingPathComponent("modelo.stl"), encoding: .utf8)
        XCTAssertTrue(stl.contains("facet normal 0.0 0.0 1.0"))
        XCTAssertEqual(triangle.surfaceArea, 0.5, accuracy: 0.0001)
        XCTAssertEqual(triangle.bounds, SIMD3<Float>(1,1,0))
    }

    func testRejectsMalformedGeometryBeforeExport() throws {
        let folder = try temporaryDirectory()
        XCTAssertThrowsError(try MeshExporter.write(.init(vertices: [], triangles: []), to: folder))
        XCTAssertThrowsError(try MeshExporter.write(.init(vertices: triangle.vertices, triangles: [0,1,9]), to: folder))
        XCTAssertThrowsError(try MeshExporter.write(.init(vertices: triangle.vertices, triangles: [0,1]), to: folder))
        XCTAssertThrowsError(try MeshExporter.write(.init(vertices: [SIMD3(.nan,0,0)], triangles: [0,0,0]), to: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 0)
    }

    @MainActor
    func testSaveReloadIntegrityAndDeletion() async throws {
        let folder = try temporaryDirectory()
        let store = ScanStore(baseURL: folder)
        let result = CaptureResult(mesh: triangle, mode: .lidar, duration: 3, note: "test")
        let saved = await store.save(result)
        let scan = try XCTUnwrap(saved)
        XCTAssertEqual(store.scans.count, 1)
        XCTAssertEqual(scan.faceCount, 1)
        let integrity = try await store.verify(scan)
        XCTAssertTrue(integrity)
        let reloaded = ScanStore(baseURL: folder)
        XCTAssertEqual(reloaded.scans.first?.id, scan.id)
        try Data("tampered".utf8).write(to: store.directory(for: scan).appendingPathComponent("modelo.obj"))
        let tampered = try await store.verify(scan)
        XCTAssertFalse(tampered)
        store.delete(scan)
        XCTAssertTrue(store.scans.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: scan).path))
    }

    @MainActor
    func testFailedSaveLeavesNoPartialCapture() async throws {
        let folder = try temporaryDirectory()
        let store = ScanStore(baseURL: folder)
        let saved = await store.save(CaptureResult(mesh: nil, mode: .object, duration: 1))
        XCTAssertNil(saved)
        XCTAssertNotNil(store.error)
        XCTAssertNotNil(store.pendingCapture, "Failed saves must retain the capture for retry")
        XCTAssertTrue(store.scans.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 0)
    }

    @MainActor
    func testPersistenceThroughLibrarySymlinkKeepsIntegrityPathsRelative() async throws {
        let root = try temporaryDirectory()
        let realLibrary = root.appendingPathComponent("actual-library-with-a-longer-canonical-name", isDirectory: true)
        let aliasLibrary = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realLibrary, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: aliasLibrary, withDestinationURL: realLibrary)
        XCTAssertNotEqual(aliasLibrary.path, aliasLibrary.resolvingSymlinksInPath().path)

        let package = root.appendingPathComponent("input-package", isDirectory: true)
        let nested = package.appendingPathComponent("textures", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try MeshExporter.write(triangle, to: package)
        let photographicFixture = Data([0, 17, 63, 127, 255])
        try photographicFixture.write(to: nested.appendingPathComponent("native-fixture.bin"))
        let store = ScanStore(baseURL: aliasLibrary)
        let saved = await store.save(CaptureResult(mesh: triangle, modelURL: package.appendingPathComponent("modelo.obj"),
            mode: .lidar, duration: 1, modelPackageURL: package))
        let scan = try XCTUnwrap(saved, store.error ?? "")
        let directory = store.directory(for: scan)
        let manifest = try JSONDecoder().decode(IntegrityManifest.self, from: Data(contentsOf: directory.appendingPathComponent("integridad.json")))
        let names = Set(manifest.files.map(\.name))
        XCTAssertTrue(names.contains("malla.json"))
        XCTAssertTrue(names.contains("captura.json"))
        XCTAssertTrue(names.contains("modelo/modelo.obj"))
        XCTAssertTrue(names.contains("modelo/textures/native-fixture.bin"))
        XCTAssertTrue(manifest.files.allSatisfy { ScanStore.safeRelativePath($0.name) && !$0.name.contains(".pending-") })
        XCTAssertTrue(try manifest.verify(in: directory), "The public alias and the enumerator's canonical root must identify the same relative files")
        XCTAssertTrue(try manifest.verify(in: directory.resolvingSymlinksInPath()))
        let verified = try await store.verify(scan)
        XCTAssertTrue(verified)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("modelo/textures/native-fixture.bin")), photographicFixture)
        try Data([1]).write(to: directory.appendingPathComponent("modelo/textures/native-fixture.bin"))
        XCTAssertFalse(try manifest.verify(in: directory), "Nested asset tampering must still be detected through the alias")
    }

    @MainActor
    func testTemporarySourcesRemovedOnlyAfterCommit() async throws {
        let library = try temporaryDirectory()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        let model = workspace.appendingPathComponent("empty.usdz")
        try Data().write(to: model)
        let store = ScanStore(baseURL: library)
        let rejected = await store.save(CaptureResult(mesh: nil, modelURL: model, mode: .object, duration: 1, cleanupDirectory: workspace))
        XCTAssertNil(rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path), "Never delete sources after a failed commit")
        XCTAssertNotNil(store.pendingCapture)
        var retry = try XCTUnwrap(store.pendingCapture)
        retry.mesh = triangle
        retry.modelURL = nil
        let saved = await store.save(retry)
        XCTAssertNotNil(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertNil(store.pendingCapture)
    }

    @MainActor
    func testNewResultCannotReplaceUnsavedCapture() async throws {
        let store = ScanStore(baseURL: try temporaryDirectory())
        let original = CaptureResult(mesh: nil, mode: .lidar, duration: 2)
        _ = await store.save(original)
        let newResult = CaptureResult(mesh: triangle, mode: .lidar, duration: 0, isDemo: true)
        let rejected = await store.save(newResult)
        XCTAssertNil(rejected)
        XCTAssertEqual(store.pendingCapture?.id, original.id)
        XCTAssertTrue(store.scans.isEmpty)
        store.discardPendingCapture()
        let saved = await store.save(newResult)
        XCTAssertNotNil(saved)
    }

    @MainActor
    func testPreservesSourceDirectoryAsShareableArchive() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("original input".utf8).write(to: source.appendingPathComponent("frame.txt"))
        let store = ScanStore(baseURL: root.appendingPathComponent("library"))
        let saved = await store.save(CaptureResult(mesh: triangle, auxiliaryURLs: [source], mode: .object, duration: 2))
        let record = try XCTUnwrap(saved)
        XCTAssertTrue(record.exports.contains("datos-1-images.zip"))
        let integrity = try await store.verify(record)
        XCTAssertTrue(integrity)
        let archive = try Data(contentsOf: store.directory(for: record).appendingPathComponent("datos-1-images.zip"))
        XCTAssertEqual(Array(archive.prefix(2)), [0x50, 0x4b])
    }

    func testDemoIsFiniteClosedIndexedSurface() throws {
        let mesh = DemoGeometry.sculpture()
        try MeshExporter.validate(mesh)
        XCTAssertEqual(mesh.vertexCount, 96*48)
        XCTAssertEqual(mesh.faceCount, 96*48*2)
        XCTAssertGreaterThan(mesh.surfaceArea, 0)
    }
}
