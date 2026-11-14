import XCTest
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Forma

/// Synthetic, locally authored fixtures validate file and coordinate conventions;
/// they are not evidence of scanning accuracy or a trained Gaussian reconstruction.
final class RGBDIntegrationTests: XCTestCase {
    func testARKitToCOLMAPCameraRoundTripAndPinholePixelConventions() throws {
        var pose = simd_float4x4(simd_quatf(angle: 0.63, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.1))))
        pose.columns.3 = SIMD4(1.5, -0.4, 3.2, 1)
        let arCameraPoint = SIMD4<Float>(0.15, 0.3, -2, 1)
        let world = pose * arCameraPoint
        let worldToCV = COLMAPDatasetExporter.worldToCOLMAPCamera(pose)
        let cv = worldToCV * world
        assertVector(cv, equals: SIMD4(0.15, -0.3, 2, 1))
        assertVector(worldToCV.inverse * cv, equals: world)
        assertVector(worldToCV * pose.columns.3, equals: SIMD4(0, 0, 0, 1))

        let frame = record(id: "posed", filename: "posed.jpg", width: 320, height: 180, pose: pose)
        let pixel = try XCTUnwrap(LiDARTextureBaker.project(worldPoint: SIMD3(world.x, world.y, world.z), frame: frame))
        let expectedU: Float = 320 * 0.15 / 2 + 159.5
        let expectedV: Float = 180 * -0.3 / 2 + 89.5
        XCTAssertEqual(pixel.pixel.x, expectedU, accuracy: 0.0001)
        XCTAssertEqual(pixel.pixel.y, expectedV, accuracy: 0.0001)
        XCTAssertEqual(pixel.uv.x, (expectedU + 0.5) / 320, accuracy: 0.0001)
        XCTAssertEqual(pixel.uv.y, 1 - (expectedV + 0.5) / 180, accuracy: 0.0001)
    }

    func testCOLMAPTextExportsCalibratedPosesNamesAndMetricSeedPointsWithoutChangingImages() throws {
        let root = try directory()
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let firstImage = images.appendingPathComponent("native-frame.jpg")
        let secondImage = images.appendingPathComponent("close-up.jpg")
        try jpeg(at: firstImage, width: 100, height: 100)
        try jpeg(at: secondImage, width: 320, height: 180)
        let firstBytes = try Data(contentsOf: firstImage), secondBytes = try Data(contentsOf: secondImage)
        var secondPose = simd_float4x4(simd_quatf(angle: 0.6, axis: SIMD3(0, 1, 0)))
        secondPose.columns.3 = SIMD4(1, 2, 3, 1)
        let frames = [record(id: "native", filename: "native-frame.jpg"),
                      record(id: "close", filename: "close-up.jpg", width: 320, height: 180, pose: secondPose)]
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 1), frames: frames).write(to: root)
        var mesh = triangle
        mesh.vertices.append(mesh.vertices[0]) // An unused duplicate must not duplicate a Gaussian seed.
        try COLMAPDatasetExporter.prepare(datasetDirectory: root, mesh: mesh)

        let cameras = try dataLines(root.appendingPathComponent("cameras.txt"))
        XCTAssertEqual(cameras.count, 2)
        for (index, line) in cameras.enumerated() {
            let fields = line.split(separator: " ")
            XCTAssertEqual(fields.count, 8)
            XCTAssertEqual(Int(fields[0]), index + 1)
            XCTAssertEqual(fields[1], "PINHOLE")
            XCTAssertEqual(Int(fields[2]), frames[index].imageWidth)
            XCTAssertEqual(Int(fields[3]), frames[index].imageHeight)
            let intrinsicFields = fields.dropFirst(4).compactMap { Float($0) }
            XCTAssertEqual(intrinsicFields, [frames[index].intrinsics[0], frames[index].intrinsics[4],
                                            frames[index].intrinsics[6], frames[index].intrinsics[7]])
        }

        let imageText = try String(contentsOf: root.appendingPathComponent("images.txt"), encoding: .utf8)
        let imageLines = imageText.components(separatedBy: "\n")
        let poses = imageLines.enumerated().filter { !$0.element.isEmpty && !$0.element.hasPrefix("#") }
        XCTAssertEqual(poses.count, 2)
        for (index, entry) in poses.enumerated() {
            let fields = entry.element.split(separator: " ")
            XCTAssertEqual(fields.count, 10)
            XCTAssertEqual(Int(fields[0]), index + 1)
            XCTAssertEqual(Int(fields[8]), index + 1)
            XCTAssertEqual(String(fields[9]), index == 0 ? "native-frame.jpg" : "close-up.jpg")
            XCTAssertEqual(imageLines[entry.offset + 1], "", "A calibrated pose has an explicitly empty observation line")
            let values = fields[1...7].compactMap { Float($0) }
            XCTAssertEqual(values.count, 7)
            let quaternion = simd_quatf(ix: values[1], iy: values[2], iz: values[3], r: values[0])
            var worldToCamera = simd_float4x4(quaternion)
            worldToCamera.columns.3 = SIMD4(values[4], values[5], values[6], 1)
            let pose = try XCTUnwrap(frames[index].transformMatrix)
            let world = pose * SIMD4<Float>(0.2, 0.4, -2, 1)
            assertVector(worldToCamera * world, equals: SIMD4(0.2, -0.4, 2, 1))
        }

        let seeds = try dataLines(root.appendingPathComponent("points3D.txt"))
        XCTAssertEqual(seeds.count, 3)
        for (index, line) in seeds.enumerated() {
            let fields = line.split(separator: " ")
            XCTAssertEqual(fields.count, 8)
            XCTAssertEqual(Int(fields[0]), index + 1)
            let position = fields[1...3].compactMap { Float($0) }
            XCTAssertEqual(position, [triangle.vertices[index].x, triangle.vertices[index].y, triangle.vertices[index].z])
            XCTAssertEqual(fields[4...6].map(String.init), ["128", "128", "128"], "Seed color is explicitly neutral, not advertised as a trained appearance")
            XCTAssertEqual(Float(fields[7]), 0)
        }
        XCTAssertEqual(try Data(contentsOf: firstImage), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondImage), secondBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(secondImage as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 180)
    }

    @MainActor
    func testStorePreservesPortableTextureDependenciesDatasetAndNestedIntegrityAfterCleanup() async throws {
        let workspace = try directory(prefix: "FormaRGBDIntegration-")
        let dataset = workspace.appendingPathComponent("dataset", isDirectory: true)
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let originalURL = images.appendingPathComponent("native-frame.jpg")
        try jpeg(at: originalURL, width: 100, height: 100)
        let original = try Data(contentsOf: originalURL)
        let frames = [record(id: "store-fixture", filename: "native-frame.jpg")]
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 1), frames: frames).write(to: dataset)
        try COLMAPDatasetExporter.prepare(datasetDirectory: dataset, mesh: triangle)
        let package = workspace.appendingPathComponent("textured", isDirectory: true)
        let baked = try LiDARTextureBaker.bake(mesh: triangle, keyframes: frames, datasetDirectory: dataset, outputDirectory: package)
        XCTAssertEqual(baked.texturedFaceCount, 1)
        let library = try directory(prefix: "RGBDIntegrationLibrary-")
        let store = ScanStore(baseURL: library)
        let capture = CaptureResult(mesh: triangle, modelURL: baked.objURL, mode: .lidar, duration: 3,
                                    note: "authored integration fixture", cleanupDirectory: workspace,
                                    modelPackageURL: package, captureDatasetURL: dataset,
                                    statistics: ["texturedFaces": Double(baked.texturedFaceCount)])
        let saved = await store.save(capture)
        let scan = try XCTUnwrap(saved, store.error ?? "The package and its source dataset should commit together")
        XCTAssertNil(store.pendingCapture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), "Cleanup occurs only after the complete library commit")
        XCTAssertEqual(scan.modelFile, "modelo/modelo.obj")
        XCTAssertEqual(scan.datasetDirectory, "fuentes")
        XCTAssertEqual(scan.statistics?["texturedFaces"], 1)

        let model = try XCTUnwrap(store.modelURL(for: scan))
        let obj = try String(contentsOf: model, encoding: .utf8)
        let mtlLine = try XCTUnwrap(obj.components(separatedBy: "\n").first { $0.hasPrefix("mtllib ") })
        let materialURL = model.deletingLastPathComponent().appendingPathComponent(String(mtlLine.dropFirst(7)))
        let materials = try String(contentsOf: materialURL, encoding: .utf8)
        let map = try XCTUnwrap(materials.components(separatedBy: "\n").first { $0.hasPrefix("map_Kd ") })
        let textureURL = materialURL.deletingLastPathComponent().appendingPathComponent(String(map.dropFirst(7)))
        XCTAssertEqual(try Data(contentsOf: textureURL), original, "Relative MTL dependencies survive source-workspace deletion")
        let archiveURL = store.directory(for: scan).appendingPathComponent("modelo-texturizado.zip")
        XCTAssertEqual(Array(try Data(contentsOf: archiveURL).prefix(2)), [0x50, 0x4b])

        let retainedDataset = try XCTUnwrap(store.datasetURL(for: scan))
        XCTAssertEqual(try RGBDDatasetManifest.load(from: retainedDataset).frames.map(\.id), ["store-fixture"])
        XCTAssertEqual(try Data(contentsOf: retainedDataset.appendingPathComponent("images/native-frame.jpg")), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedDataset.appendingPathComponent("images.txt").path))
        let reloaded = ScanStore(baseURL: library)
        XCTAssertEqual(reloaded.scans.first?.id, scan.id)
        XCTAssertEqual(reloaded.datasetURL(for: scan), retainedDataset)

        let integrityURL = store.directory(for: scan).appendingPathComponent("integridad.json")
        let integrity = try JSONDecoder().decode(IntegrityManifest.self, from: Data(contentsOf: integrityURL))
        XCTAssertTrue(integrity.files.contains { $0.name.hasPrefix("modelo/textures/") })
        XCTAssertTrue(integrity.files.contains { $0.name == "fuentes/images/native-frame.jpg" })
        let intact = try await store.verify(scan)
        XCTAssertTrue(intact)
        try Data("modified nested texture".utf8).write(to: textureURL)
        let modified = try await store.verify(scan)
        XCTAssertFalse(modified, "Integrity must cover textures below nested directories, not only the outer ZIP")
        try original.write(to: textureURL)
        let restored = try await store.verify(scan)
        XCTAssertTrue(restored)
    }

    func testGaussian32ByteInterchangePreservesPositionAnisotropyRotationColorAndOpacity() throws {
        let root = try directory()
        let url = root.appendingPathComponent("fixture.splat")
        let first = splat(position: SIMD3(-1, 2, 3), scale: SIMD3(0.1, 0.2, 0.3), rgba: [12, 34, 56, 200], rotationWXYZ: [255, 128, 128, 128])
        let second = splat(position: SIMD3(3, 6, 7), scale: SIMD3(0.4, 0.5, 0.6), rgba: [255, 128, 0, 64], rotationWXYZ: [218, 128, 128, 218])
        XCTAssertEqual(first.count, 32)
        try (first + second).write(to: url)
        let asset = try GaussianAsset.load(url: url)
        XCTAssertEqual(asset.points.count, 2)
        let a = asset.points[0]
        assertVector(a.positionOpacity, equals: SIMD4(-1, 2, 3, Float(200) / 255))
        assertVector(a.scale, equals: SIMD4(0.1, 0.2, 0.3, 0))
        assertVector(a.rotation, equals: SIMD4(0, 0, 0, 1))
        assertVector(a.color, equals: SIMD4(Float(12) / 255, Float(34) / 255, Float(56) / 255, 1))
        let expected = Float(1 / sqrt(2.0))
        assertVector(asset.points[1].rotation, equals: SIMD4(0, 0, expected, expected))
        XCTAssertEqual(asset.points[1].positionOpacity.w, Float(64) / 255, accuracy: 0.00001)
        XCTAssertEqual(asset.center, SIMD3<Float>(1, 4, 5))
        XCTAssertEqual(asset.radius, sqrt(Float(12)), accuracy: 0.00001)
    }

    func testGaussianLoaderRejectsTruncationNaNInvalidScalesAndZeroQuaternion() throws {
        let root = try directory()
        let url = root.appendingPathComponent("invalid.splat")
        let valid = splat(position: SIMD3(1, 2, 3), scale: SIMD3(0.1, 0.2, 0.3))
        let malformed = [Data(), Data(valid.prefix(31)), valid + Data([0]),
                         splat(position: SIMD3(.nan, 2, 3), scale: SIMD3(0.1, 0.2, 0.3)),
                         splat(position: SIMD3(1, 2, 3), scale: SIMD3(.nan, 0.2, 0.3)),
                         splat(position: SIMD3(1, 2, 3), scale: SIMD3(0, 0.2, 0.3)),
                         splat(position: SIMD3(1, 2, 3), scale: SIMD3(0.1, 0.2, 0.3), rotationWXYZ: [128, 128, 128, 128])]
        for (index, data) in malformed.enumerated() {
            try data.write(to: url)
            XCTAssertThrowsError(try GaussianAsset.load(url: url), "Malformed fixture \(index) must not reach the renderer")
        }
    }

    private var triangle: MeshSnapshot {
        MeshSnapshot(vertices: [SIMD3(-0.2, -0.2, -2), SIMD3(0.2, -0.2, -2), SIMD3(0, 0.2, -2)], triangles: [0, 1, 2])
    }

    private func record(id: String, filename: String, width: Int = 100, height: Int = 100,
                        pose: simd_float4x4 = matrix_identity_float4x4) -> RGBDFrameRecord {
        RGBDFrameRecord(id: id, timestamp: 1, rgbFile: "images/" + filename, imageWidth: width, imageHeight: height,
                        cameraToWorld: (0..<4).flatMap { column in (0..<4).map { row in pose[column][row] } },
                        intrinsics: [Float(width), 0, 0, 0, Float(height), 0, (Float(width) - 1) / 2, (Float(height) - 1) / 2, 1],
                        depthFile: nil, confidenceFile: nil, depthWidth: nil, depthHeight: nil,
                        source: "authoredFixture", exposureDuration: nil, exposureOffset: nil)
    }

    private func directory(prefix: String = "RGBDIntegrationTests-") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func dataLines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func assertVector(_ value: SIMD4<Float>, equals expected: SIMD4<Float>, file: StaticString = #filePath, line: UInt = #line) {
        for axis in 0..<4 { XCTAssertEqual(value[axis], expected[axis], accuracy: 0.0001, file: file, line: line) }
    }

    private func splat(position: SIMD3<Float>, scale: SIMD3<Float>, rgba: [UInt8] = [12, 34, 56, 200],
                       rotationWXYZ: [UInt8] = [255, 128, 128, 128]) -> Data {
        var data = Data()
        for value in [position.x, position.y, position.z, scale.x, scale.y, scale.z] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: rgba)
        data.append(contentsOf: rotationWXYZ)
        return data
    }

    private func jpeg(at url: URL, width: Int, height: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1, kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
