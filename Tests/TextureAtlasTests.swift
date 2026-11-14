import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import Forma

/// Authored asymmetric photographic rasters verify native texels and OBJ coordinate conventions.
final class TextureAtlasTests: XCTestCase {
    func testAsymmetricGoldenPixelsKeepOrientationAndNativeTexelDensity() throws {
        let root = try directory()
        let source = try image(root: root, id: 7, width: 8, height: 6) { x, y in
            [UInt8(11 + x * 23), UInt8(7 + y * 37), UInt8(3 + x * 9 + y * 5), 255]
        }
        let face = fullFace(id: 41, sourceID: source.id)
        let result = try TextureAtlasBuilder.build(sources: [source], faces: [face],
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 16, padding: 1, preserveSingleSource: false)
        let material = try XCTUnwrap(result.materials.first)
        XCTAssertEqual(material.pixelWidth, 10)
        XCTAssertEqual(material.pixelHeight, 8)
        XCTAssertFalse(material.isDedicatedOriginal)
        let page = try pixels(material.url)
        let original = try pixels(source.imageURL)
        for y in 0..<6 {
            for x in 0..<8 {
                XCTAssertEqual(page.pixel(x + 1, y + 1), original.pixel(x, y), "Native texel (\(x),\(y)) must keep position and exact decoded color")
            }
        }
        let mapped = try XCTUnwrap(result.faces.first)
        XCTAssertEqual(mapped.id, 41)
        XCTAssertEqual(mapped.a.x, 0.1, accuracy: 0.000001)
        XCTAssertEqual(mapped.a.y, 0.875, accuracy: 0.000001)
        XCTAssertEqual(mapped.b.x, 0.9, accuracy: 0.000001)
        XCTAssertEqual(mapped.c.y, 0.125, accuracy: 0.000001)
        XCTAssertEqual((mapped.b.x - mapped.a.x) * Float(page.width), 8, accuracy: 0.00001)
        XCTAssertEqual((mapped.c.y - mapped.a.y) * Float(page.height), -6, accuracy: 0.00001)
        XCTAssertLessThan(cross(mapped.b - mapped.a, mapped.c - mapped.a), 0, "UV winding must remain unchanged")
        XCTAssertEqual(result.metrics.sourcePixels, 48)
        XCTAssertEqual(result.metrics.croppedPixels, 48)
        XCTAssertEqual(result.metrics.atlasPixels, 80)
    }

    func testCroppingRemapsFractionalUVsWithoutResamplingAnyTexels() throws {
        let root = try directory()
        let source = try image(root: root, id: 3, width: 80, height: 60) { x, y in
            [UInt8(x * 3), UInt8(y * 4), UInt8((x + y) % 256), 255]
        }
        let face = TextureAtlasBuilder.Face(id: 9, sourceID: 3,
            a: SIMD2(21.25 / 80, 1 - 12.75 / 60), b: SIMD2(29.6 / 80, 1 - 13.1 / 60), c: SIMD2(24.2 / 80, 1 - 21.4 / 60))
        let result = try TextureAtlasBuilder.build(sources: [source], faces: [face],
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 32, padding: 2, preserveSingleSource: false)
        let material = try XCTUnwrap(result.materials.first)
        let mapped = try XCTUnwrap(result.faces.first)
        let page = try pixels(material.url), original = try pixels(source.imageURL)
        XCTAssertLessThan(material.pixelWidth, source.pixelWidth)
        XCTAssertLessThan(material.pixelHeight, source.pixelHeight)
        for (uv, target) in [(face.a, mapped.a), (face.b, mapped.b), (face.c, mapped.c)] {
            let expected = original.bilinear(uv), observed = page.bilinear(target)
            for channel in 0..<4 { XCTAssertEqual(observed[channel], expected[channel], accuracy: 0.001) }
        }
        XCTAssertEqual((mapped.b.x - mapped.a.x) * Float(page.width), (face.b.x - face.a.x) * 80, accuracy: 0.0001)
        XCTAssertEqual((mapped.c.y - mapped.a.y) * Float(page.height), (face.c.y - face.a.y) * 60, accuracy: 0.0001)
    }

    func testExtrudedGuttersPreventBilinearBleedingBetweenDifferentPhotos() throws {
        let root = try directory()
        let red = try image(root: root, id: 0, width: 4, height: 4) { _, _ in [255, 0, 0, 255] }
        let blue = try image(root: root, id: 1, width: 4, height: 4) { _, _ in [0, 0, 255, 255] }
        let sourceFaces = [fullFace(id: 0, sourceID: 0), fullFace(id: 1, sourceID: 1)]
        let result = try TextureAtlasBuilder.build(sources: [red, blue], faces: sourceFaces,
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 16, padding: 2)
        XCTAssertEqual(result.materials.count, 1, "Two camera materials should share this page")
        let page = try pixels(XCTUnwrap(result.materials.first).url)
        for face in result.faces {
            let expected: [Double] = face.id == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]
            for sourceUV in [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0.5), SIMD2(0, 0.5)] {
                let uv = face.a + sourceUV.x * (face.b - face.a) + (1 - sourceUV.y) * (face.c - face.a)
                let observed = page.bilinear(uv)
                for channel in 0..<4 { XCTAssertEqual(observed[channel], expected[channel], accuracy: 0.0001) }
            }
        }
        XCTAssertEqual(result.metrics.sourceCount, 2)
        XCTAssertEqual(result.metrics.materialCount, 1)
    }

    func testAdditionalPagesPreserveResolutionInsteadOfShrinkingOrDroppingSources() throws {
        let root = try directory()
        var sources: [TextureAtlasBuilder.Source] = []
        for id in 0..<4 {
            sources.append(try image(root: root, id: id, width: 6, height: 6) { x, y in [UInt8(id * 50), UInt8(x * 30), UInt8(y * 30), 255] })
        }
        let result = try TextureAtlasBuilder.build(sources: sources,
            faces: sources.map { fullFace(id: $0.id, sourceID: $0.id) },
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 8, padding: 1)
        XCTAssertEqual(result.materials.count, 4)
        XCTAssertEqual(result.metrics.pageCount, 4)
        XCTAssertEqual(result.faces.count, 4)
        for face in result.faces {
            let material = try XCTUnwrap(result.materials.first { $0.id == face.materialID })
            XCTAssertEqual(material.pixelWidth, 8)
            XCTAssertEqual(material.pixelHeight, 8)
            let page = try pixels(material.url)
            let original = try pixels(sources[face.id].imageURL)
            for y in 0..<6 {
                for x in 0..<6 { XCTAssertEqual(page.pixel(x + 1, y + 1), original.pixel(x, y)) }
            }
        }
    }

    func testOversizedPatchUsesByteExactDedicatedOriginalAndUnchangedUVs() throws {
        let root = try directory()
        let source = try image(root: root, id: 19, width: 20, height: 3) { x, y in [UInt8(x * 10), UInt8(y * 70), 17, 255] }
        let face = fullFace(id: 73, sourceID: source.id)
        let originalBytes = try Data(contentsOf: source.imageURL)
        let result = try TextureAtlasBuilder.build(sources: [source], faces: [face],
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 8, padding: 1, preserveSingleSource: false)
        let material = try XCTUnwrap(result.materials.first)
        let mapped = try XCTUnwrap(result.faces.first)
        XCTAssertTrue(material.isDedicatedOriginal)
        XCTAssertEqual(material.pixelWidth, 20)
        XCTAssertEqual(material.pixelHeight, 3)
        XCTAssertEqual(try Data(contentsOf: material.url), originalBytes)
        XCTAssertEqual(mapped.a, face.a)
        XCTAssertEqual(mapped.b, face.b)
        XCTAssertEqual(mapped.c, face.c)
        XCTAssertEqual(result.metrics.pageCount, 0)
        XCTAssertEqual(result.metrics.dedicatedOriginalCount, 1)
        XCTAssertEqual(result.metrics.dedicatedOriginalPixels, 60)
        XCTAssertEqual(try Data(contentsOf: source.imageURL), originalBytes, "Source photographs remain available independently of the atlas")
    }

    func testSingleCameraKeepsOriginalAndEmptyCapturePublishesNeutralTextureDirectory() throws {
        let root = try directory()
        let source = try image(root: root, id: 2, width: 5, height: 3) { x, y in [UInt8(x * 40), UInt8(y * 70), 73, 255] }
        let result = try TextureAtlasBuilder.build(sources: [source], faces: [fullFace(id: 0, sourceID: 2)],
            outputDirectory: root.appendingPathComponent("single"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.materials.first).url), try Data(contentsOf: source.imageURL))
        XCTAssertEqual(result.metrics.materialCount, 1)
        XCTAssertEqual(result.metrics.pageCount, 0)
        let emptyURL = root.appendingPathComponent("empty")
        let empty = try TextureAtlasBuilder.build(sources: [], faces: [], outputDirectory: emptyURL)
        XCTAssertTrue(empty.faces.isEmpty)
        XCTAssertTrue(empty.materials.isEmpty)
        XCTAssertEqual(empty.metrics.sourcePixels, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: emptyURL.path), [])
    }

    func testHighBitDepthSourceKeepsItsOriginalPrecisionInsteadOfQuantizingIntoRGBA8() throws {
        let root = try directory()
        var components: [UInt16] = []
        for index in 0..<48 {
            let value: UInt16 = index % 4 == 3 ? UInt16.max : UInt16(index * 997)
            components.append(value.bigEndian)
        }
        let data = components.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder16Big)
        let image = try XCTUnwrap(CGImage(width: 4, height: 3, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 4 * 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let original = root.appendingPathComponent("native16.png")
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithURL(original as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        let source = TextureAtlasBuilder.Source(id: 4, imageURL: original, pixelWidth: 4, pixelHeight: 3)
        let precisionFaces = [TextureAtlasBuilder.Face(id: 0, sourceID: 4, a: SIMD2(0, 1), b: SIMD2(0.2, 1), c: SIMD2(0, 0.8)),
                              TextureAtlasBuilder.Face(id: 1, sourceID: 4, a: SIMD2(0.8, 0.2), b: SIMD2(1, 0.2), c: SIMD2(0.8, 0))]
        let result = try TextureAtlasBuilder.build(sources: [source], faces: precisionFaces,
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 16, padding: 1, preserveSingleSource: false)
        let material = try XCTUnwrap(result.materials.first)
        XCTAssertTrue(material.isDedicatedOriginal)
        XCTAssertEqual(try Data(contentsOf: material.url), try Data(contentsOf: original))
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(material.url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        XCTAssertEqual(decoded.bitsPerComponent, 16)
        XCTAssertEqual(result.metrics.chartCount, 2)
        XCTAssertEqual(result.metrics.dedicatedOriginalCount, 1)
        XCTAssertEqual(result.metrics.renderSourceDecodeCount, 0)
        for (index, face) in result.faces.enumerated() {
            XCTAssertEqual(face.a, precisionFaces[index].a)
            XCTAssertEqual(face.b, precisionFaces[index].b)
            XCTAssertEqual(face.c, precisionFaces[index].c)
        }
    }

    func testCancellationAfterWritingPageRemovesStagingAndDoesNotPublish() throws {
        let root = try directory()
        let source = try image(root: root, id: 0, width: 8, height: 6) { x, y in [UInt8(x * 25), UInt8(y * 35), 9, 255] }
        let originalBytes = try Data(contentsOf: source.imageURL)
        let destination = root.appendingPathComponent("atlas")
        var sawWrittenPage = false
        XCTAssertThrowsError(try TextureAtlasBuilder.build(sources: [source], faces: [fullFace(id: 0, sourceID: 0)],
            outputDirectory: destination, pageSide: 16, padding: 1, preserveSingleSource: false,
            checkCancellation: {
                let staging = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".atlas-") }
                for folder in staging {
                    if try !FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty {
                        sawWrittenPage = true
                        throw CancellationError()
                    }
                }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(sawWrittenPage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".atlas-") })
        XCTAssertEqual(try Data(contentsOf: source.imageURL), originalBytes)
    }

    func testInvalidDimensionsAndOccupiedOutputCannotOverwriteOrPublish() throws {
        let root = try directory()
        var source = try image(root: root, id: 0, width: 8, height: 6) { _, _ in [20, 40, 60, 255] }
        source.pixelWidth = 7
        let destination = root.appendingPathComponent("atlas")
        XCTAssertThrowsError(try TextureAtlasBuilder.build(sources: [source], faces: [fullFace(id: 0, sourceID: 0)], outputDirectory: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: sentinel)
        XCTAssertThrowsError(try TextureAtlasBuilder.build(sources: [], faces: [], outputDirectory: destination))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
    }

    func testDifferentColorProfilesKeepSeparatePagesAndNativeAppearance() throws {
        let root = try directory()
        let a = try image(root: root, id: 0, width: 4, height: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!) { _, _ in [190, 25, 80, 255] }
        let b = try image(root: root, id: 1, width: 4, height: 4, space: CGColorSpace(name: CGColorSpace.displayP3)!) { _, _ in [190, 25, 80, 255] }
        let result = try TextureAtlasBuilder.build(sources: [a, b], faces: [fullFace(id: 0, sourceID: 0), fullFace(id: 1, sourceID: 1)],
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 16, padding: 1)
        XCTAssertEqual(result.metrics.pageCount, 2, "Different ICC profiles cannot be mixed into one unlabelled numeric RGB atlas")
        for face in result.faces {
            let material = try XCTUnwrap(result.materials.first { $0.id == face.materialID })
            let original = try pixels(face.id == 0 ? a.imageURL : b.imageURL)
            let page = try pixels(material.url)
            for channel in 0..<4 {
                XCTAssertEqual(page.bilinear((face.a + face.b + face.c) / 3)[channel], original.bilinear(SIMD2(1.0 / 3, 2.0 / 3))[channel], accuracy: 1)
            }
        }
    }

    func testDisconnectedRegionsSharePageWithOneDecodeAndNativeSamples() throws {
        let root = try directory()
        let source = try image(root: root, id: 3, width: 80, height: 60) { x, y in
            [UInt8(x * 3), UInt8(y * 4), UInt8((x + y) % 256), 255]
        }
        let input = [5, 35, 65].enumerated().map { index, x in
            TextureAtlasBuilder.Face(id: 100 + index, sourceID: 3,
                a: SIMD2(Float(x) / 80, 0.8), b: SIMD2(Float(x + 3) / 80, 0.8), c: SIMD2(Float(x) / 80, 0.75))
        }
        let originalData = try Data(contentsOf: source.imageURL)
        let result = try TextureAtlasBuilder.build(sources: [source], faces: input,
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 64, padding: 2, preserveSingleSource: false)
        XCTAssertEqual(result.metrics.chartCount, 3)
        XCTAssertEqual(result.metrics.materialCount, 1)
        XCTAssertEqual(result.metrics.renderSourceDecodeCount, 1, "One native photograph is decoded once for all its page charts")
        XCTAssertLessThan(result.metrics.croppedPixels, 100)
        let original = try pixels(source.imageURL)
        for (i, face) in result.faces.enumerated() {
            let material = result.materials[face.materialID], page = try pixels(material.url)
            for weights in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0.2, 0.3, 0.5)] {
                let before = original.bilinear(input[i].a * weights.x + input[i].b * weights.y + input[i].c * weights.z)
                let after = page.bilinear(face.a * weights.x + face.b * weights.y + face.c * weights.z)
                for channel in 0..<4 { XCTAssertEqual(after[channel], before[channel], accuracy: 0.002) }
            }
        }
        XCTAssertEqual(try Data(contentsOf: source.imageURL), originalData)
    }

    func testSemiTransparentNativeTexelsAndAlphaSurviveMultipleCharts() throws {
        let root = try directory()
        let source = try image(root: root, id: 8, width: 20, height: 12) { x, y in
            let alpha: UInt8 = x < 10 ? 128 : 224
            return [UInt8(x * 5), UInt8(y * 7), 20, alpha]
        }
        let input = [TextureAtlasBuilder.Face(id: 0, sourceID: 8, a: SIMD2(0.1, 0.9), b: SIMD2(0.3, 0.9), c: SIMD2(0.1, 0.7)),
                     TextureAtlasBuilder.Face(id: 1, sourceID: 8, a: SIMD2(0.7, 0.4), b: SIMD2(0.9, 0.4), c: SIMD2(0.7, 0.2))]
        let result = try TextureAtlasBuilder.build(sources: [source], faces: input,
            outputDirectory: root.appendingPathComponent("atlas"), pageSide: 32, padding: 2, preserveSingleSource: false)
        let original = try pixels(source.imageURL)
        for (i, face) in result.faces.enumerated() {
            let page = try pixels(result.materials[face.materialID].url)
            let before = original.bilinear((input[i].a + input[i].b + input[i].c) / 3)
            let after = page.bilinear((face.a + face.b + face.c) / 3)
            for channel in 0..<4 { XCTAssertEqual(after[channel], before[channel], accuracy: 0.01) }
        }
    }

    private func fullFace(id: Int, sourceID: Int) -> TextureAtlasBuilder.Face {
        .init(id: id, sourceID: sourceID, a: SIMD2(0, 1), b: SIMD2(1, 1), c: SIMD2(0, 0))
    }

    private func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FormaAtlasTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(root: URL, id: Int, width: Int, height: Int,
                       space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                       color: (Int, Int) -> [UInt8]) throws -> TextureAtlasBuilder.Source {
        var rgba: [UInt8] = []
        for y in 0..<height { for x in 0..<width { rgba += color(x, y) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = root.appendingPathComponent("camera-\(id).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return .init(id: id, imageURL: url, pixelWidth: width, pixelHeight: height)
    }

    private struct Raster {
        var width: Int
        var height: Int
        var rgba: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(rgba[(y * width + x) * 4..<(y * width + x + 1) * 4]) }
        func bilinear(_ uv: SIMD2<Float>) -> [Double] {
            let x = Double(uv.x) * Double(width) - 0.5, y = (1 - Double(uv.y)) * Double(height) - 0.5
            let x0 = Int(floor(x)), y0 = Int(floor(y)), tx = x - floor(x), ty = y - floor(y)
            let a = pixel(max(0, min(width - 1, x0)), max(0, min(height - 1, y0)))
            let b = pixel(max(0, min(width - 1, x0 + 1)), max(0, min(height - 1, y0)))
            let c = pixel(max(0, min(width - 1, x0)), max(0, min(height - 1, y0 + 1)))
            let d = pixel(max(0, min(width - 1, x0 + 1)), max(0, min(height - 1, y0 + 1)))
            return (0..<4).map { (1 - ty) * ((1 - tx) * Double(a[$0]) + tx * Double(b[$0])) + ty * ((1 - tx) * Double(c[$0]) + tx * Double(d[$0])) }
        }
    }

    private func pixels(_ url: URL) throws -> Raster {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmap.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Raster(width: image.width, height: image.height, rgba: bytes)
    }
}
