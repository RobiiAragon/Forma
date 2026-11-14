import XCTest
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Forma

final class SavedScanRefinementTests: XCTestCase {
    @MainActor
    func testPlanarCorrectionReprojectsDerivedGeometryAndExportsItKeepingRawSource() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var vertices: [SIMD3<Float>] = [], triangles: [UInt32] = []
        var random: UInt64 = 173
        for y in 0..<31 { for x in 0..<31 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Float((random >> 32) & 65535) / 65535 - 0.5) * 0.0016
            vertices.append(SIMD3(Float(x) * 0.04, Float(y) * 0.04, noise))
        } }
        for y in 0..<30 { for x in 0..<30 {
            let a = UInt32(y * 31 + x), b = a + 1, c = a + 31, d = c + 1
            triangles += [a,b,c,b,d,c]
        } }
        let source = MeshSnapshot(vertices: vertices, triangles: triangles)
        let store = ScanStore(baseURL: folder.appendingPathComponent("library"))
        let saved = await store.save(CaptureResult(mesh: source, mode: .lidar, duration: 1))
        let original = try XCTUnwrap(saved)
        let sourceURL = store.directory(for: original).appendingPathComponent("malla.json")
        let sourceBytes = try Data(contentsOf: sourceURL)
        var quality = LiDARQualitySettings()
        quality.correctPlanarNoise = true
        let result = try await SavedScanRefinement.process(scan: original, directory: store.directory(for: original), quality: quality) { _, _ in }
        XCTAssertGreaterThan(result.statistics?["planarMovedVertices"] ?? 0, 500)
        XCTAssertEqual(result.mesh?.triangles, triangles)
        XCTAssertEqual(result.mesh?.vertexCount, source.vertexCount)
        let derivedSave = await store.save(result)
        let derived = try XCTUnwrap(derivedSave, store.error ?? "")
        let output = store.directory(for: derived)
        let exportedMesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: output.appendingPathComponent("malla.json")))
        XCTAssertEqual(exportedMesh.vertices, result.mesh?.vertices)
        XCTAssertEqual(exportedMesh.triangles, triangles)
        let obj = try String(contentsOf: try XCTUnwrap(store.modelURL(for: derived)))
        XCTAssertEqual(obj.split(separator: "\n").filter { $0.hasPrefix("f ") }.count, source.faceCount)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        let retainedURL = try XCTUnwrap(SavedScanRefinement.originalMeshURL(scan: derived, directory: output))
        let retained = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: retainedURL))
        XCTAssertEqual(retained.vertices, source.vertices)
        XCTAssertEqual(derived.statistics?["planarCorrectionRequested"], 1)
        let verified = try await store.verify(derived)
        XCTAssertTrue(verified)
    }
    @MainActor
    func testLegacyMeshRefinesIntoAnotherRecordKeepingTheOriginalAndAllFaces() async throws {
        let library = try directory()
        defer { try? FileManager.default.removeItem(at: library) }
        let store = ScanStore(baseURL: library)
        let originalSave = await store.save(CaptureResult(mesh: splitSquare, mode: .lidar, duration: 10))
        let original = try XCTUnwrap(originalSave)
        let originalDirectory = store.directory(for: original)
        let rawURL = originalDirectory.appendingPathComponent("malla.json")
        let originalBytes = try Data(contentsOf: rawURL)
        let result = try await SavedScanRefinement.process(scan: original, directory: originalDirectory) { _,_ in }
        XCTAssertNil(result.captureDatasetURL,"A legacy mesh must not acquire a fake photographic dataset")
        XCTAssertEqual(result.sourceScanID,original.id)
        XCTAssertEqual(result.mesh?.triangles.count,splitSquare.triangles.count)
        XCTAssertEqual(result.statistics?["continuityVerticesMerged"],2)
        let refinedSave = await store.save(result)
        let refined = try XCTUnwrap(refinedSave,store.error ?? "")
        XCTAssertNotEqual(refined.id,original.id)
        XCTAssertEqual(refined.sourceScanID,original.id)
        XCTAssertTrue(refined.name.contains("Refinada"))
        XCTAssertEqual(store.scans.count,2)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.directory(for: refined).appendingPathComponent("informe.json"))) as? [String: Any])
        XCTAssertEqual(report["representation"] as? String,"geometry","A neutral package is not a photographic texture")
        XCTAssertEqual(try Data(contentsOf: rawURL),originalBytes)
        let originalIntact = try await store.verify(original)
        XCTAssertTrue(originalIntact)
        let refinedIntact = try await store.verify(refined)
        XCTAssertTrue(refinedIntact)
        let retainedOriginal = try XCTUnwrap(SavedScanRefinement.originalMeshURL(scan: refined,directory: store.directory(for: refined)))
        let retained = try JSONDecoder().decode(MeshSnapshot.self,from: Data(contentsOf: retainedOriginal))
        XCTAssertEqual(retained.vertices,splitSquare.vertices)
        XCTAssertEqual(retained.triangles,splitSquare.triangles)
        let reloaded = ScanStore(baseURL: library)
        XCTAssertEqual(reloaded.scans.first(where: { $0.id == refined.id })?.sourceScanID,original.id)
    }

    @MainActor
    func testPhotographicReprocessingCopiesSourcesAndUsesTheRawMeshForEveryGeneration() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset")
        try FileManager.default.createDirectory(at: dataset.appendingPathComponent("images"),withIntermediateDirectories: true)
        let photo = dataset.appendingPathComponent("images/native.png")
        let pixels = [UInt8](repeating: 150,count: 100*100*4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 100,height: 100,bitsPerComponent: 8,bitsPerPixel: 32,
            bytesPerRow: 400,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: photo)
        let frame = RGBDFrameRecord(id: "native",timestamp: 1,rgbFile: "images/native.png",imageWidth: 100,imageHeight: 100,
            cameraToWorld: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],intrinsics: [100,0,0, 0,100,0, 49.5,49.5,1],source: "synthetic-test")
        try RGBDDatasetManifest(createdAt: Date(),frames: [frame]).write(to: dataset)
        let sourceMesh = MeshSnapshot(vertices: [SIMD3(-0.1,-0.1,-1),SIMD3(0.1,-0.1,-1),SIMD3(0,0.1,-1)],triangles: [0,1,2])
        let package = root.appendingPathComponent("package")
        let baked = try LiDARTextureBaker.bake(mesh: sourceMesh,keyframes: [frame],datasetDirectory: dataset,outputDirectory: package)
        let store = ScanStore(baseURL: root.appendingPathComponent("library"))
        let saved = await store.save(CaptureResult(mesh: sourceMesh,modelURL: baked.objURL,mode: .lidar,duration: 2,
            modelPackageURL: package,captureDatasetURL: dataset,statistics: ["texturedFaces":1]))
        let original = try XCTUnwrap(saved,store.error ?? "")
        let sourceDirectory = try XCTUnwrap(store.datasetURL(for: original))
        let originalManifest = try Data(contentsOf: sourceDirectory.appendingPathComponent("dataset.json"))
        let refinedResult = try await SavedScanRefinement.process(scan: original,directory: store.directory(for: original)) { _,_ in }
        XCTAssertEqual(refinedResult.statistics?["texturedFaces"],1)
        let copied = try XCTUnwrap(refinedResult.captureDatasetURL)
        XCTAssertNotEqual(copied,sourceDirectory)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("images/native.png")),bytes)
        XCTAssertEqual(try Data(contentsOf: sourceDirectory.appendingPathComponent("dataset.json")),originalManifest)
        let refinedSave = await store.save(refinedResult)
        let refined = try XCTUnwrap(refinedSave,store.error ?? "")
        let refinedIntact = try await store.verify(refined)
        XCTAssertTrue(refinedIntact)
        let rawMeshURL = try XCTUnwrap(SavedScanRefinement.originalMeshURL(scan: refined,directory: store.directory(for: refined)))
        let rawMesh = try JSONDecoder().decode(MeshSnapshot.self,from: Data(contentsOf: rawMeshURL))
        XCTAssertEqual(rawMesh.vertices,sourceMesh.vertices)
        let third = try await SavedScanRefinement.process(scan: refined,directory: store.directory(for: refined)) { _,_ in }
        defer { if let directory = third.cleanupDirectory { try? FileManager.default.removeItem(at: directory) } }
        XCTAssertEqual(third.mesh?.vertices,sourceMesh.vertices,"Repeated refinements start from raw geometry, not cumulative rounding")
        XCTAssertEqual(try Data(contentsOf: sourceDirectory.appendingPathComponent("images/native.png")),bytes)
    }

    @MainActor
    func testCancellationKeepsSavedCaptureIntact() async throws {
        let library = try directory()
        defer { try? FileManager.default.removeItem(at: library) }
        let store = ScanStore(baseURL: library)
        let originalSave = await store.save(CaptureResult(mesh: splitSquare,mode: .lidar,duration: 1))
        let original = try XCTUnwrap(originalSave)
        let directory = store.directory(for: original)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("malla.json"))
        let task = Task { () throws -> CaptureResult in
            return try await SavedScanRefinement.process(scan: original,directory: directory) { _,_ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled processing must not return a derived capture") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("malla.json")),bytes)
        let originalIntact = try await store.verify(original)
        XCTAssertTrue(originalIntact)
        XCTAssertEqual(store.scans.count,1)
    }

    private var splitSquare: MeshSnapshot {
        MeshSnapshot(vertices: [SIMD3(-1,-1,-1),SIMD3(1,-1,-1),SIMD3(-1,1,-1),
                                SIMD3(1,-1,-1),SIMD3(1,1,-1),SIMD3(-1,1,-1)],triangles: [0,1,2,3,4,5])
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FormaRefinementTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false)
        return directory
    }
}
