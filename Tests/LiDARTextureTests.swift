import XCTest
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Forma

/// Authored camera/geometry fixtures verify projection and visibility, not sensor accuracy.
final class LiDARTextureTests: XCTestCase {
    func testNativeCameraProjectionHasCorrectAxesAndPixelCenters() throws {
        let frame = record()
        let center = try XCTUnwrap(LiDARTextureBaker.project(worldPoint: SIMD3(0, 0, -2), frame: frame))
        XCTAssertEqual(center.pixel.x, 49.5, accuracy: 0.00001)
        XCTAssertEqual(center.pixel.y, 49.5, accuracy: 0.00001)
        XCTAssertEqual(center.uv.x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(center.uv.y, 0.5, accuracy: 0.00001)
        let offset = try XCTUnwrap(LiDARTextureBaker.project(worldPoint: SIMD3(0.2, 0.4, -2), frame: frame))
        XCTAssertEqual(offset.pixel.x, 59.5, accuracy: 0.00001)
        XCTAssertEqual(offset.pixel.y, 29.5, accuracy: 0.00001)
        XCTAssertEqual(offset.uv.x, 0.6, accuracy: 0.00001)
        XCTAssertEqual(offset.uv.y, 0.7, accuracy: 0.00001)
        XCTAssertEqual(offset.cameraDepth, 2, accuracy: 0.00001)
        XCTAssertNil(LiDARTextureBaker.project(worldPoint: SIMD3(0, 0, 2), frame: frame))
    }

    func testRotatedTranslatedCameraAndNonSquareRasterReprojectConsistently() throws {
        var pose = simd_float4x4(simd_quatf(angle: 0.6, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(1, 2, 3, 1)
        var frame = record(width: 200, height: 100, pose: pose)
        frame.intrinsics = [200, 0, 0, 0, 100, 0, 99.5, 49.5, 1]
        let world = pose * SIMD4<Float>(0.2, 0.4, -2, 1)
        let projected = try XCTUnwrap(LiDARTextureBaker.project(worldPoint: SIMD3(world.x, world.y, world.z), frame: frame))
        XCTAssertEqual(projected.pixel.x, 119.5, accuracy: 0.0001)
        XCTAssertEqual(projected.pixel.y, 29.5, accuracy: 0.0001)
        XCTAssertEqual(projected.uv.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(projected.uv.y, 0.7, accuracy: 0.0001)
        XCTAssertEqual(projected.cameraDepth, 2, accuracy: 0.0001)
    }

    func testDepthScaledFromRGBAndConfidenceRejectOccludedOrUncertainFaces() throws {
        let root = try directory()
        try jpeg(at: root.appendingPathComponent("frame.jpg"), width: 100, height: 100)
        var frame = record()
        frame.depthFile = "depth.f32"
        frame.confidenceFile = "confidence.u8"
        frame.depthWidth = 10
        frame.depthHeight = 10
        try writeDepth(2, count: 100, to: root.appendingPathComponent("depth.f32"))
        try Data(repeating: 2, count: 100).write(to: root.appendingPathComponent("confidence.u8"))
        let observed = try bake(triangle(), frames: [frame], root: root, name: "observed")
        XCTAssertEqual(observed.texturedFaceCount, 1)
        XCTAssertEqual(observed.unobservedFaceCount, 0)

        try writeDepth(1, count: 100, to: root.appendingPathComponent("depth.f32"))
        let occluded = try bake(triangle(), frames: [frame], root: root, name: "occluded")
        XCTAssertEqual(occluded.texturedFaceCount, 0, "A surface behind the measured surface cannot borrow its color")
        XCTAssertEqual(occluded.unobservedFaceCount, 1)

        try writeDepth(2, count: 100, to: root.appendingPathComponent("depth.f32"))
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("confidence.u8"))
        let uncertain = try bake(triangle(), frames: [frame], root: root, name: "uncertain")
        XCTAssertEqual(uncertain.texturedFaceCount, 0)
    }

    func testHighResolutionWithoutDepthUsesBVHVisibilityAndPreservesAllGeometry() throws {
        let root = try directory()
        try jpeg(at: root.appendingPathComponent("frame.jpg"), width: 100, height: 100)
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        // More than one BVH leaf; only the closest triangle is visible from this camera.
        for index in 0..<16 {
            let z = -1 - Float(index) * 0.1
            vertices += [SIMD3(-0.2, -0.2, z), SIMD3(0.2, -0.2, z), SIMD3(0, 0.2, z)]
            indices += [UInt32(index * 3), UInt32(index * 3 + 1), UInt32(index * 3 + 2)]
        }
        let mesh = MeshSnapshot(vertices: vertices, triangles: indices)
        let result = try bake(mesh, frames: [record()], root: root)
        XCTAssertEqual(result.texturedFaceCount, 1)
        XCTAssertEqual(result.unobservedFaceCount, 15)
        XCTAssertEqual(result.textureURLs.count, 1)
        let obj = try String(contentsOf: result.objURL, encoding: .utf8)
        let lines = obj.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("v ") }.count, vertices.count)
        XCTAssertEqual(lines.filter { $0.hasPrefix("f ") }.count, 16)
        XCTAssertEqual(lines.filter { $0.hasPrefix("vn ") }.count, 16)
        XCTAssertTrue(obj.contains("usemtl unobserved"))
        XCTAssertTrue(obj.contains("f 46//16 47//16 48//16"), "Hidden original triangles are retained with a neutral material")
    }

    func testHigherResolutionViewWinsAndOriginalImageBytesAreNotReduced() throws {
        let root = try directory()
        let lowURL = root.appendingPathComponent("low.jpg")
        let highURL = root.appendingPathComponent("high.jpg")
        try jpeg(at: lowURL, width: 100, height: 100)
        try jpeg(at: highURL, width: 400, height: 400)
        var low = record()
        low.id = "low"
        low.rgbFile = "low.jpg"
        var high = record(width: 400, height: 400)
        high.id = "high"
        high.rgbFile = "high.jpg"
        let result = try bake(triangle(), frames: [low, high], root: root)
        let texture = try XCTUnwrap(result.textureURLs.first)
        XCTAssertEqual(result.texturedFaceCount, 1)
        XCTAssertEqual(result.textureURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: texture), try Data(contentsOf: highURL), "JPEG is copied byte-for-byte, not packed into a smaller atlas")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(texture as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 400)
        let material = try String(contentsOf: result.materialURL, encoding: .utf8)
        XCTAssertTrue(material.contains("map_Kd textures/\(texture.lastPathComponent)"))
        let obj = try String(contentsOf: result.objURL, encoding: .utf8)
        let coordinates = obj.split(separator: "\n").filter { $0.hasPrefix("vt ") }.map {
            $0.split(separator: " ").dropFirst().compactMap { Float($0) }
        }
        XCTAssertEqual(coordinates.count, 3)
        XCTAssertEqual(coordinates[0][0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(coordinates[0][1], 0.4, accuracy: 0.0001)
        XCTAssertEqual(coordinates[2][0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(coordinates[2][1], 0.6, accuracy: 0.0001)
    }

    func testNoViewsProducesHonestNeutralGeometryAndCorruptDepthFailsWithoutPublishing() throws {
        let root = try directory()
        let neutral = try bake(triangle(), frames: [], root: root, name: "neutral")
        XCTAssertEqual(neutral.texturedFaceCount, 0)
        XCTAssertEqual(neutral.unobservedFaceCount, 1)
        XCTAssertTrue(neutral.textureURLs.isEmpty)
        let obj = try String(contentsOf: neutral.objURL, encoding: .utf8)
        XCTAssertTrue(obj.contains("f 1//1 2//1 3//1"))

        try jpeg(at: root.appendingPathComponent("frame.jpg"), width: 100, height: 100)
        try Data([0]).write(to: root.appendingPathComponent("truncated.f32"))
        var corrupt = record()
        corrupt.depthFile = "truncated.f32"
        corrupt.depthWidth = 10
        corrupt.depthHeight = 10
        let output = root.appendingPathComponent("corrupt", isDirectory: true)
        XCTAssertThrowsError(try LiDARTextureBaker.bake(mesh: triangle(), keyframes: [corrupt], datasetDirectory: root, outputDirectory: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("modelo.obj").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 0)
    }

    func testLocalPhotographicDetailWinsOverBlurWithIdenticalCalibration() throws {
        let root = try directory()
        // Authored focus proxy: the upper patch is detailed in one photo, flat in
        // the other. Detail elsewhere in the image must not choose the source.
        try detailJPEG(at: root.appendingPathComponent("sharp.jpg"), sharpRows: 5..<45)
        try detailJPEG(at: root.appendingPathComponent("blur.jpg"), sharpRows: 55..<95)
        var blurry = record()
        blurry.id = "blur"
        blurry.rgbFile = "blur.jpg"
        var sharp = record()
        sharp.id = "sharp"
        sharp.timestamp = 2 // The old geometric tie selected the blurry frame first.
        sharp.rgbFile = "sharp.jpg"
        var mesh = triangle()
        mesh.vertices = mesh.vertices.map { $0 + SIMD3(0, 0.5, 0) }
        let result = try bake(mesh, frames: [blurry, sharp], root: root)
        XCTAssertEqual(result.texturedFaceCount, 1)
        XCTAssertEqual(result.textureURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.textureURLs.first)),
                       try Data(contentsOf: root.appendingPathComponent("sharp.jpg")),
                       "Selection uses detail inside the projected face; source bytes stay intact")
    }

    func testAdjacentFacesUseOneObservedSourceWhenQualityIsNearlyEqual() throws {
        let root = try directory()
        try jpeg(at: root.appendingPathComponent("left.jpg"), width: 100, height: 100)
        try jpeg(at: root.appendingPathComponent("right.jpg"), width: 100, height: 100)
        let frames = translatedFrames(x: 0.05)
        let result = try bake(square(), frames: frames, root: root)
        XCTAssertEqual(result.texturedFaceCount, 2)
        XCTAssertEqual(result.sourceBoundaryEdgesBefore, 1, "Each triangle initially prefers the camera slightly nearer its center")
        XCTAssertEqual(result.sourceBoundaryEdgesAfter, 0)
        XCTAssertEqual(result.coherenceReassignedFaces, 1)
        XCTAssertEqual(result.textureURLs.count, 1)
        let obj = try String(contentsOf: result.objURL, encoding: .utf8)
        XCTAssertEqual(obj.split(separator: "\n").filter { $0.hasPrefix("v ") }.count, 4)
        XCTAssertTrue(obj.contains("f 1/1/1 2/2/1 3/3/1"))
        XCTAssertTrue(obj.contains("f 1/4/2 3/5/2 4/6/2"), "Coherence changes neither original geometry nor triangle order")
        XCTAssertGreaterThanOrEqual(result.selectionSeconds, 0)
        XCTAssertGreaterThanOrEqual(result.coherenceSeconds, 0)
        XCTAssertGreaterThanOrEqual(result.totalSeconds, result.selectionSeconds + result.coherenceSeconds)
        let reversed = try bake(square(), frames: frames.reversed(), root: root, name: "reversed-input")
        XCTAssertEqual(try Data(contentsOf: result.objURL), try Data(contentsOf: reversed.objURL),
                       "Input ordering cannot change deterministic source selection or UVs")
    }

    func testContinuityCannotReplaceASignificantlyBetterView() throws {
        let root = try directory()
        try jpeg(at: root.appendingPathComponent("left.jpg"), width: 100, height: 100)
        try jpeg(at: root.appendingPathComponent("right.jpg"), width: 100, height: 100)
        let result = try bake(square(), frames: translatedFrames(x: 1, z: 1), root: root)
        XCTAssertEqual(result.texturedFaceCount, 2)
        XCTAssertEqual(result.sourceBoundaryEdgesBefore, 1)
        XCTAssertEqual(result.sourceBoundaryEdgesAfter, 1)
        XCTAssertEqual(result.coherenceReassignedFaces, 0, "A source below 95% of the face's best data score is inadmissible")
        XCTAssertEqual(result.sourceTextureCount, 2)
        XCTAssertLessThanOrEqual(result.textureURLs.count, 2, "Native texel packing may combine materials")
    }

    func testCoherenceRechecksOcclusionBeforeBorrowingNeighborsPhoto() throws {
        let root = try directory()
        try jpeg(at: root.appendingPathComponent("left.jpg"), width: 100, height: 100)
        try jpeg(at: root.appendingPathComponent("right.jpg"), width: 100, height: 100)
        var frames = translatedFrames(x: 0.2)
        var rightPose = matrix_identity_float4x4
        rightPose.columns.3 = SIMD4(0.2, 0, 0.3, 1)
        frames[1].cameraToWorld = (0..<4).flatMap { column in (0..<4).map { row in rightPose[column][row] } }
        var mesh = square()
        // A small foreground surface covers the first face's center from the
        // left camera only. It uses independent vertices and is not a neighbor.
        mesh.vertices += [SIMD3(-0.053333, -0.086667, -1), SIMD3(-0.013333, -0.086667, -1), SIMD3(-0.033333, -0.046667, -1)]
        mesh.triangles += [4, 5, 6]
        let result = try bake(mesh, frames: frames, root: root)
        XCTAssertEqual(result.texturedFaceCount, 3)
        XCTAssertEqual(result.sourceBoundaryEdgesBefore, 1)
        XCTAssertEqual(result.sourceBoundaryEdgesAfter, 1)
        XCTAssertEqual(result.coherenceReassignedFaces, 0,
                       "The preferred neighboring camera is occluded for this face and cannot be copied")
        XCTAssertEqual(result.sourceTextureCount, 2)
    }

    func testMeshCenterRejectsThinOccluderInsideDepthTolerance() throws {
        let root = try directory()
        try jpeg(at: root.appendingPathComponent("frame.jpg"), width: 100, height: 100)
        var frame = record()
        frame.depthFile = "depth.f32"
        frame.depthWidth = 10
        frame.depthHeight = 10
        try writeDepth(2, count: 100, to: root.appendingPathComponent("depth.f32"))
        var mesh = triangle()
        mesh.vertices += triangle().vertices.map { $0 + SIMD3(0, 0, 0.02) }
        mesh.triangles += [3, 4, 5]
        let result = try bake(mesh, frames: [frame], root: root)
        XCTAssertEqual(result.texturedFaceCount, 1)
        XCTAssertEqual(result.unobservedFaceCount, 1,
                       "Depth tolerance alone cannot authorize texture on a mesh surface hidden 2 cm behind another")
    }

    func testNonManifoldSharedEdgeDoesNotPropagateCameraLabels() throws {
        let root = try directory()
        try jpeg(at: root.appendingPathComponent("left.jpg"), width: 100, height: 100)
        try jpeg(at: root.appendingPathComponent("right.jpg"), width: 100, height: 100)
        var mesh = square()
        mesh.vertices.append(SIMD3(0.3, -0.2, -2))
        // Three faces now share edge (0,2). Their connectivity is ambiguous and
        // must not be treated as an ordinary surface neighborhood.
        mesh.triangles += [0, 4, 2]
        let result = try bake(mesh, frames: translatedFrames(x: 0.05), root: root)
        XCTAssertEqual(result.texturedFaceCount, 3)
        XCTAssertEqual(result.sourceBoundaryEdgesBefore, 0)
        XCTAssertEqual(result.sourceBoundaryEdgesAfter, 0)
        XCTAssertEqual(result.coherenceReassignedFaces, 0)
        XCTAssertEqual(result.sourceTextureCount, 2, "Non-manifold geometry cannot authorize source propagation")
    }

    func testVisibleSharedWorldPointsReduceExposureSeamAndPreserveOriginalSources() throws {
        let root = try directory()
        let linear = SIMD3<Float>(0.32, 0.20, 0.08)
        try colorPNG(at: root.appendingPathComponent("left.png"), linear: linear)
        try colorPNG(at: root.appendingPathComponent("right.png"), linear: linear * 0.5)
        let leftOriginal = try Data(contentsOf: root.appendingPathComponent("left.png"))
        let rightOriginal = try Data(contentsOf: root.appendingPathComponent("right.png"))
        var frames = translatedFrames(x: 1, z: 1)
        frames[0].rgbFile = "left.png"; frames[1].rgbFile = "right.png"
        let result = try bake(square(), frames: frames, root: root)
        XCTAssertEqual(result.texturedFaceCount, 2)
        XCTAssertEqual(result.sourceTextureCount, 2)
        XCTAssertEqual(result.sourceBoundaryEdgesAfter, 1)
        XCTAssertEqual(result.seamLinkCount, 1)
        XCTAssertGreaterThanOrEqual(result.seamValidationSampleCount, 3)
        XCTAssertEqual(result.adjustedPhotoCount, 1)
        XCTAssertEqual(result.photoExposureGains["left.png"] ?? 0, 0.5, accuracy: 0.012)
        XCTAssertEqual(result.photoExposureGains["right.png"], 1)
        XCTAssertEqual(result.exposureReferencePhotos, ["right.png"])
        XCTAssertLessThan(result.seamRMSEAfter, result.seamRMSEBefore * 0.02)
        XCTAssertLessThan(result.seamLogRMSEAfter, result.seamLogRMSEBefore * 0.02)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("left.png")), leftOriginal)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("right.png")), rightOriginal)
        let colors = try bakedFaceColors(result)
        XCTAssertEqual(colors.count, 2)
        for color in colors {
            XCTAssertEqual(color.x, linear.x * 0.5, accuracy: 0.008)
            XCTAssertEqual(color.y, linear.y * 0.5, accuracy: 0.008)
            XCTAssertEqual(color.z, linear.z * 0.5, accuracy: 0.008)
        }
        XCTAssertLessThan(simd_length(colors[0] - colors[1]), 0.008,
                          "Measured improvement survives PNG encoding and atlas UV remapping")
    }

    func testForegroundDepthAlongSharedEdgeCannotContaminateExposureCalibration() throws {
        let root = try directory()
        try colorPNG(at: root.appendingPathComponent("left.png"), linear: SIMD3(0.32, 0.20, 0.08))
        try colorPNG(at: root.appendingPathComponent("right.png"), linear: SIMD3(0.16, 0.10, 0.04))
        var frames = translatedFrames(x: 1, z: 1)
        let mesh = square()
        for index in frames.indices {
            frames[index].rgbFile = index == 0 ? "left.png" : "right.png"
            frames[index].depthFile = "depth-\(index).f32"
            frames[index].depthWidth = 100; frames[index].depthHeight = 100
            var depth = [Float](repeating: 3, count: 10_000)
            // Fine foreground observations between the mesh selector's vertices
            // and midpoints hide the seam. They must not lend their color to it.
            for sample in 0..<18 {
                let t = (Float(sample) + 0.5) / 18
                let point = mesh.vertices[0] * (1 - t) + mesh.vertices[2] * t
                let projected = try XCTUnwrap(LiDARTextureBaker.project(worldPoint: point, frame: frames[index]))
                let x = Int(projected.pixel.x.rounded()), y = Int(projected.pixel.y.rounded())
                depth[y * 100 + x] = 1
            }
            var bytes = Data()
            for value in depth {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            try bytes.write(to: root.appendingPathComponent("depth-\(index).f32"))
        }
        let result = try bake(mesh, frames: frames, root: root)
        XCTAssertEqual(result.texturedFaceCount, 2)
        XCTAssertEqual(result.sourceTextureCount, 2)
        XCTAssertEqual(result.seamLinkCount, 0)
        XCTAssertEqual(result.adjustedPhotoCount, 0)
        XCTAssertEqual(result.photoExposureGains, ["left.png": 1, "right.png": 1])
    }

    func testHigherPrecisionSourcesAreNotQuantizedByExposureOrAtlas() throws {
        let root = try directory()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for (name, intensity) in [("left.png", Float(0.32)), ("right.png", Float(0.16))] {
            let value = UInt16((PhotometricHarmonizer.encodedSRGB(intensity) * 65535).rounded())
            var pixels = [UInt16](repeating: value, count: 100 * 100 * 4)
            for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = .max }
            let data = pixels.withUnsafeBytes { Data($0) }
            let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
            let image = try XCTUnwrap(CGImage(width: 100, height: 100, bitsPerComponent: 16, bitsPerPixel: 64,
                                             bytesPerRow: 800, space: space,
                                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                             provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        var frames = translatedFrames(x: 1, z: 1)
        frames[0].rgbFile = "left.png"; frames[1].rgbFile = "right.png"
        let originals = try Set(["left.png", "right.png"].map { try Data(contentsOf: root.appendingPathComponent($0)) })
        let result = try bake(square(), frames: frames, root: root)
        XCTAssertEqual(result.sourceTextureCount, 2)
        XCTAssertEqual(result.adjustedPhotoCount, 0)
        XCTAssertEqual(result.seamLinkCount, 0)
        XCTAssertEqual(result.atlasDedicatedOriginalCount, 2)
        XCTAssertEqual(try Set(result.textureURLs.map { try Data(contentsOf: $0) }), originals)
        for url in result.textureURLs {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)).bitsPerComponent, 16)
        }
    }

    func testDisplayP3ExposureDerivativeRetainsNativeColorProfile() throws {
        let root = try directory()
        try colorPNG(at: root.appendingPathComponent("left.png"), linear: SIMD3(0.32, 0.20, 0.08), spaceName: CGColorSpace.displayP3)
        try colorPNG(at: root.appendingPathComponent("right.png"), linear: SIMD3(0.16, 0.10, 0.04), spaceName: CGColorSpace.displayP3)
        var frames = translatedFrames(x: 1, z: 1)
        frames[0].rgbFile = "left.png"; frames[1].rgbFile = "right.png"
        let result = try bake(square(), frames: frames, root: root)
        XCTAssertEqual(result.adjustedPhotoCount, 1)
        XCTAssertLessThan(result.seamLogRMSEAfter, result.seamLogRMSEBefore * 0.02)
        for url in result.textureURLs {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3,
                           "Correction uses original primaries; Display P3 must not be clipped into sRGB")
        }
    }

    func testPhotometricNeighborhoodDecodesEachCameraOnlyOnce() throws {
        let root = try directory()
        let positions: [SIMD3<Float>] = [SIMD3(0, -1, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1), SIMD3(-1, 0, 1)]
        var frames: [RGBDFrameRecord] = []
        for (index, position) in positions.enumerated() {
            let name = "view-\(index).png"
            try colorPNG(at: root.appendingPathComponent(name), linear: SIMD3(0.32, 0.20, 0.08) * (0.5 + Float(index) / 6))
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4(position.x, position.y, position.z, 1)
            var frame = record(pose: pose)
            frame.id = name; frame.rgbFile = name
            frames.append(frame)
        }
        let mesh = MeshSnapshot(vertices: [SIMD3(-0.8, -0.8, -2), SIMD3(0.8, -0.8, -2),
                                           SIMD3(0.8, 0.8, -2), SIMD3(-0.8, 0.8, -2), SIMD3(0, 0, -2)],
                                triangles: [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4])
        let result = try bake(mesh, frames: frames, root: root)
        XCTAssertEqual(result.sourceTextureCount, 4)
        XCTAssertEqual(result.seamLinkCount, 4)
        XCTAssertEqual(result.photometricImageDecodeCount, 4,
                       "Four seam pairs need four camera decodes, rather than two decodes per pair")
        XCTAssertLessThan(result.seamLogRMSEAfter, result.seamLogRMSEBefore * 0.03)
    }

    private func colorPNG(at url: URL, linear: SIMD3<Float>, spaceName: CFString = CGColorSpace.sRGB) throws {
        let space = try XCTUnwrap(CGColorSpace(name: spaceName))
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                             bytesPerRow: 400, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(PhotometricHarmonizer.encodedSRGB(linear.x)),
                                                                   CGFloat(PhotometricHarmonizer.encodedSRGB(linear.y)),
                                                                   CGFloat(PhotometricHarmonizer.encodedSRGB(linear.z)), 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func bakedFaceColors(_ result: LiDARTextureBakeResult) throws -> [SIMD3<Float>] {
        var textures: [String: URL] = [:], material = ""
        for line in try String(contentsOf: result.materialURL, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("newmtl ") { material = String(line.dropFirst(7)) }
            if line.hasPrefix("map_Kd ") {
                textures[material] = result.materialURL.deletingLastPathComponent().appendingPathComponent(String(line.dropFirst(7)))
            }
        }
        var uv: [SIMD2<Float>] = [], colors: [SIMD3<Float>] = []
        for line in try String(contentsOf: result.objURL, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("vt ") {
                let values = line.split(separator: " ").dropFirst().compactMap { Float($0) }
                uv.append(SIMD2(values[0], values[1]))
            } else if line.hasPrefix("usemtl ") { material = String(line.dropFirst(7)) }
            else if line.hasPrefix("f "), let url = textures[material] {
                let indices = line.split(separator: " ").dropFirst().compactMap { Int($0.split(separator: "/")[1]) }
                let center = indices.reduce(SIMD2<Float>.zero) { $0 + uv[$1 - 1] } / Float(indices.count)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                         bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let x = min(image.width - 1, max(0, Int(center.x * Float(image.width))))
                let y = min(image.height - 1, max(0, Int((1 - center.y) * Float(image.height))))
                let index = (y * image.width + x) * 4
                colors.append(SIMD3(PhotometricHarmonizer.linearSRGB(Float(pixels[index]) / 255),
                                    PhotometricHarmonizer.linearSRGB(Float(pixels[index + 1]) / 255),
                                    PhotometricHarmonizer.linearSRGB(Float(pixels[index + 2]) / 255)))
            }
        }
        return colors
    }

    private func square() -> MeshSnapshot {
        MeshSnapshot(vertices: [SIMD3(-0.4, -0.4, -2), SIMD3(0.4, -0.4, -2),
                                SIMD3(0.4, 0.4, -2), SIMD3(-0.4, 0.4, -2)], triangles: [0, 1, 2, 0, 2, 3])
    }

    private func translatedFrames(x: Float, z: Float = 0) -> [RGBDFrameRecord] {
        [-x, x].enumerated().map { index, position in
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4(position, 0, z, 1)
            var frame = record(pose: pose)
            frame.id = index == 0 ? "left" : "right"
            frame.rgbFile = frame.id + ".jpg"
            return frame
        }
    }

    private func detailJPEG(at url: URL, sharpRows: Range<Int>) throws {
        let width = 100, height = 100
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = sharpRows.contains(y) ? ((x / 2 + y / 2).isMultiple(of: 2) ? 20 : 235) : 128
                let index = (y * width + x) * 4
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func triangle() -> MeshSnapshot {
        MeshSnapshot(vertices: [SIMD3(-0.2, -0.2, -2), SIMD3(0.2, -0.2, -2), SIMD3(0, 0.2, -2)], triangles: [0, 1, 2])
    }

    private func record(width: Int = 100, height: Int = 100, pose: simd_float4x4 = matrix_identity_float4x4) -> RGBDFrameRecord {
        RGBDFrameRecord(
            id: "authored-fixture", timestamp: 1, rgbFile: "frame.jpg", imageWidth: width, imageHeight: height,
            cameraToWorld: (0..<4).flatMap { column in (0..<4).map { row in pose[column][row] } },
            intrinsics: [Float(width), 0, 0, 0, Float(height), 0, (Float(width) - 1) / 2, (Float(height) - 1) / 2, 1],
            depthFile: nil, confidenceFile: nil, depthWidth: nil, depthHeight: nil,
            source: "highResolution", exposureDuration: nil, exposureOffset: nil
        )
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiDARTextureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func bake(_ mesh: MeshSnapshot, frames: [RGBDFrameRecord], root: URL, name: String = "baked") throws -> LiDARTextureBakeResult {
        try LiDARTextureBaker.bake(mesh: mesh, keyframes: frames, datasetDirectory: root,
                                   outputDirectory: root.appendingPathComponent(name, isDirectory: true))
    }

    private func writeDepth(_ value: Float, count: Int, to url: URL) throws {
        var bytes = Data()
        for _ in 0..<count {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        try bytes.write(to: url)
    }

    private func jpeg(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.65, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
