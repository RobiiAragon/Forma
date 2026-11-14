import XCTest
import CoreVideo
import ImageIO
@testable import Forma

final class RGBDRecordingTests: XCTestCase {
    @MainActor
    func testNativeRasterAndPaddedDepthRowsRoundTripWithoutInventingHighResolutionDepth() async throws {
        let recording = try RGBDRecording()
        let workspace = recording.directory.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        let image = try pixelBuffer(width: 7, height: 5, format: kCVPixelFormatType_32BGRA)
        let depth = try pixelBuffer(width: 3, height: 2, format: kCVPixelFormatType_DepthFloat32)
        let confidence = try pixelBuffer(width: 3, height: 2, format: kCVPixelFormatType_OneComponent8)
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        fillImage(image)
        CVPixelBufferLockBaseAddress(depth, [])
        CVPixelBufferLockBaseAddress(confidence, [])
        for y in 0..<2 {
            let depthRow = CVPixelBufferGetBaseAddress(depth)!.advanced(by: y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
            let confidenceRow = CVPixelBufferGetBaseAddress(confidence)!.advanced(by: y * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<3 { depthRow[x] = Float(y * 3 + x + 1); confidenceRow[x] = UInt8(x) }
        }
        CVPixelBufferUnlockBaseAddress(confidence, [])
        CVPixelBufferUnlockBaseAddress(depth, [])
        let first = record(id: "stream", width: 7, height: 5, hasDepth: true, timestamp: 40)
        _ = try await recording.append(.init(image: image, depth: depth, confidence: confidence, record: first))

        let highResolutionImage = try pixelBuffer(width: 16, height: 12, format: kCVPixelFormatType_32BGRA)
        fillImage(highResolutionImage)
        var highResolution = record(id: "photo", width: 16, height: 12, hasDepth: false, timestamp: 41)
        highResolution.source = "highResolution"
        highResolution.cameraToWorld[12] = 0.25
        _ = try await recording.append(.init(image: highResolutionImage, depth: nil, confidence: nil, record: highResolution))
        try await recording.flush()

        let manifest = try RGBDDatasetManifest.load(from: recording.directory)
        XCTAssertEqual(manifest.frames.count, 2)
        XCTAssertEqual(recording.frameCount, 2)
        XCTAssertEqual(recording.depthFrameCount, 1)
        XCTAssertEqual(recording.highResolutionCount, 1)
        XCTAssertEqual(manifest.frames[0].intrinsics, first.intrinsics)
        XCTAssertEqual(manifest.frames[1].timestamp, 41)
        XCTAssertEqual(manifest.frames[1].cameraToWorld[12], 0.25)
        XCTAssertEqual(manifest.captureMetrics?["committedFrames"], 2)
        XCTAssertEqual(manifest.captureMetrics?["committedDepthFrames"], 1)
        XCTAssertEqual(manifest.captureMetrics?["committedHighResolutionFrames"], 1)
        XCTAssertGreaterThan(recording.lastCommitSeconds, 0)
        XCTAssertGreaterThan(recording.streamMeanCommitSeconds, 0)
        XCTAssertNil(manifest.frames[1].depthFile, "A separate photo must never inherit another timestamp's depth")
        XCTAssertNil(manifest.frames[1].confidenceFile)
        let color = try XCTUnwrap(manifest.frames[0].sensorMetadata?.image)
        XCTAssertEqual(color.sourcePixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(color.sourceColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(color.sourceTransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(color.savedColorSpace, "sRGB")
        XCTAssertEqual(color.savedEXIFOrientation, 1)
        XCTAssertNil(color.sourceYCbCrRange, "RGB buffers must not invent a YCbCr range")
        XCTAssertNil(manifest.frames[1].sensorMetadata?.image?.sourceColorPrimaries,
                     "A later photo must not inherit another buffer's color attachments")
        XCTAssertNil(manifest.frames[1].sensorMetadata?.depth)
        let bytes = try Data(contentsOf: recording.directory.appendingPathComponent(first.depthFile!))
        XCTAssertEqual(bytes.count, 3 * 2 * MemoryLayout<Float>.size, "Pixel-buffer row padding must not enter the depth file")
        let decoded = stride(from: 0, to: bytes.count, by: 4).map { offset in
            bytes.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        }
        XCTAssertEqual(decoded, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(try Data(contentsOf: recording.directory.appendingPathComponent(first.confidenceFile!)), Data([0, 1, 2, 0, 1, 2]))
        for frame in manifest.frames {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(recording.directory.appendingPathComponent(frame.rgbFile) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, frame.imageWidth)
            XCTAssertEqual(image.height, frame.imageHeight)
            let metrics = try XCTUnwrap(frame.acquisitionMetrics)
            XCTAssertGreaterThan(try XCTUnwrap(metrics["lumaSampleCount"]), 0)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(metrics["jpegEncodeAndWriteSeconds"]), 0)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(metrics["lumaAnalysisSeconds"]), 0)
            XCTAssertTrue(metrics.values.allSatisfy(\.isFinite))
            let actualBytes = (try FileManager.default.attributesOfItem(atPath: recording.directory.appendingPathComponent(frame.rgbFile).path)[.size] as? NSNumber)?.doubleValue
            XCTAssertEqual(metrics["jpegFileBytes"], actualBytes, "File-byte telemetry must come from the committed file")
        }
        XCTAssertTrue(workspace.lastPathComponent.hasPrefix("Forma-LiDAR-"))
        XCTAssertEqual(recording.directory.lastPathComponent, "RGBD")
    }

    @MainActor
    func testLumaSamplingDistinguishesAuthoredDetailAndRecordsClippingWithoutResizing() async throws {
        let recording = try RGBDRecording()
        let workspace = recording.directory.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        func authoredImage(stripes: Bool) throws -> CVPixelBuffer {
            let image = try pixelBuffer(width: 8, height: 8, format: kCVPixelFormatType_32BGRA)
            CVPixelBufferLockBaseAddress(image, [])
            defer { CVPixelBufferUnlockBaseAddress(image, []) }
            for y in 0..<8 {
                let row = CVPixelBufferGetBaseAddress(image)!.advanced(by: y * CVPixelBufferGetBytesPerRow(image)).assumingMemoryBound(to: UInt8.self)
                for x in 0..<8 {
                    let value: UInt8 = stripes ? (x.isMultiple(of: 2) ? 0 : 255) : 128
                    row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value; row[x * 4 + 3] = 255
                }
            }
            return image
        }
        let flat = try await recording.append(.init(image: authoredImage(stripes: false), depth: nil, confidence: nil,
            record: record(id: "flat", width: 8, height: 8, hasDepth: false, timestamp: 1)))
        let detailed = try await recording.append(.init(image: authoredImage(stripes: true), depth: nil, confidence: nil,
            record: record(id: "detail", width: 8, height: 8, hasDepth: false, timestamp: 2)))
        XCTAssertEqual(try XCTUnwrap(flat.acquisitionMetrics?["sampledLumaEdgeMean01"]), 0, accuracy: 0.000001)
        XCTAssertGreaterThan(try XCTUnwrap(detailed.acquisitionMetrics?["sampledLumaEdgeMean01"]), 0.2)
        XCTAssertEqual(try XCTUnwrap(flat.acquisitionMetrics?["sampledLumaClippedFraction01"]), 0, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(detailed.acquisitionMetrics?["sampledLumaClippedFraction01"]), 1, accuracy: 0.000001)
        XCTAssertEqual(flat.imageWidth, 8); XCTAssertEqual(detailed.imageHeight, 8)
    }

    @MainActor
    func testInconsistentNativeBufferMetadataIsRejectedBeforeWritingAnImage() async throws {
        let recording = try RGBDRecording()
        let workspace = recording.directory.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        let image = try pixelBuffer(width: 4, height: 4, format: kCVPixelFormatType_32BGRA)
        fillImage(image)
        let wrongSize = record(id: "wrong-size", width: 7, height: 4, hasDepth: false, timestamp: 1)
        do {
            _ = try await recording.append(.init(image: image, depth: nil, confidence: nil, record: wrongSize))
            XCTFail("Saved calibration/raster metadata must match the native buffer")
        } catch {}
        let missingDepth = record(id: "missing-depth", width: 4, height: 4, hasDepth: true, timestamp: 2)
        do {
            _ = try await recording.append(.init(image: image, depth: nil, confidence: nil, record: missingDepth))
            XCTFail("A record must not claim a depth file if no depth buffer exists")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: recording.directory.appendingPathComponent("images").path).isEmpty)
        XCTAssertEqual(recording.frameCount, 0)
    }

    func testLegacyDatasetWithoutOptionalAcquisitionMetricsStillDecodes() throws {
        let frame = record(id: "legacy", width: 4, height: 4, hasDepth: false, timestamp: 1)
        let manifest = RGBDDatasetManifest(createdAt: Date(timeIntervalSinceReferenceDate: 0), frames: [frame])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        object.removeValue(forKey: "captureMetrics")
        var records = try XCTUnwrap(object["frames"] as? [[String: Any]])
        records[0].removeValue(forKey: "acquisitionMetrics")
        records[0].removeValue(forKey: "sensorMetadata")
        object["frames"] = records
        let decoded = try JSONDecoder().decode(RGBDDatasetManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.frames.first?.id, "legacy")
        XCTAssertNil(decoded.captureMetrics)
        XCTAssertNil(decoded.frames.first?.acquisitionMetrics)
        XCTAssertNil(decoded.frames.first?.sensorMetadata)
    }

    func testFrameEXIFKeepsOpticsAndSignedExposureValuesWithoutInventingWhiteBalanceGains() throws {
        let metadata = try XCTUnwrap(RGBDFrameEXIFMetadata(exifData: [
            kCGImagePropertyExifISOSpeedRatings as String: [80, 160],
            kCGImagePropertyExifExposureTime as String: 1.0 / 120.0,
            kCGImagePropertyExifFNumber as String: 2.8,
            kCGImagePropertyExifFocalLength as String: 6.8,
            kCGImagePropertyExifFocalLenIn35mmFilm as String: 24,
            kCGImagePropertyExifExposureBiasValue as String: -0.7,
            kCGImagePropertyExifBrightnessValue as String: -1.25,
            kCGImagePropertyExifWhiteBalance as String: 0,
            kCGImagePropertyExifLensModel as String: "Authored lens fixture"
        ]))
        XCTAssertEqual(metadata.isoSpeedRatings, [80, 160])
        XCTAssertEqual(metadata.exposureTimeSeconds, 1.0 / 120.0)
        XCTAssertEqual(metadata.fNumber, 2.8)
        XCTAssertEqual(metadata.focalLengthMillimeters, 6.8)
        XCTAssertEqual(metadata.focalLength35mmEquivalentMillimeters, 24)
        XCTAssertEqual(metadata.exposureBiasEV, -0.7)
        XCTAssertEqual(metadata.brightnessEV, -1.25)
        XCTAssertEqual(metadata.whiteBalanceMode, "auto")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        XCTAssertNil(json["whiteBalanceGains"], "EXIF auto/manual mode cannot provide synchronized RGB gains")
        XCTAssertEqual(json["source"] as? String, "ARFrame.exifData")
        let nested = try XCTUnwrap(RGBDFrameEXIFMetadata(exifData: [kCGImagePropertyExifDictionary as String:
            [kCGImagePropertyExifISOSpeedRatings as String: [80], kCGImagePropertyExifWhiteBalance as String: 1]]))
        XCTAssertEqual(nested.isoSpeedRatings, [80])
        XCTAssertEqual(nested.whiteBalanceMode, "manual")
    }

    func testMissingAndInvalidEXIFRemainUnknownAndCanBeSerializedSafely() throws {
        XCTAssertNil(RGBDFrameEXIFMetadata(exifData: [:]))
        XCTAssertNil(RGBDFrameEXIFMetadata(exifData: [
            kCGImagePropertyExifISOSpeedRatings as String: [-10, Double.nan, Double.infinity],
            kCGImagePropertyExifExposureTime as String: -1,
            kCGImagePropertyExifFNumber as String: 0,
            kCGImagePropertyExifFocalLength as String: true,
            kCGImagePropertyExifWhiteBalance as String: 99,
            kCGImagePropertyExifLensModel as String: " "
        ]))
        let sparse = try XCTUnwrap(RGBDFrameEXIFMetadata(exifData: [
            kCGImagePropertyExifISOSpeedRatings as String: [-1, 100, Double.nan],
            kCGImagePropertyExifBrightnessValue as String: Double.infinity
        ]))
        XCTAssertEqual(sparse.isoSpeedRatings, [100])
        XCTAssertNil(sparse.brightnessEV)
        XCTAssertNil(sparse.exposureTimeSeconds)
        _ = try JSONEncoder().encode(sparse)
    }

    @MainActor
    func testFailedFramePreservesCommittedSourcesAndAllowsRetry() async throws {
        let recording = try RGBDRecording()
        let workspace = recording.directory.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        let image = try pixelBuffer(width: 4, height: 4, format: kCVPixelFormatType_32BGRA)
        fillImage(image)
        let good = record(id: "valid", width: 4, height: 4, hasDepth: false, timestamp: 1)
        _ = try await recording.append(.init(image: image, depth: nil, confidence: nil, record: good))
        var invalid = record(id: "invalid", width: 4, height: 4, hasDepth: false, timestamp: 2)
        invalid.intrinsics[0] = .nan
        do {
            _ = try await recording.append(.init(image: image, depth: nil, confidence: nil, record: invalid))
            XCTFail("Invalid camera calibration must not produce a committed frame")
        } catch {}
        try await recording.flush()
        let manifest = try RGBDDatasetManifest.load(from: recording.directory)
        XCTAssertEqual(manifest.frames.map(\.id), ["valid"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.directory.appendingPathComponent(good.rgbFile).path))
        let retry = record(id: "retry", width: 4, height: 4, hasDepth: false, timestamp: 3)
        _ = try await recording.append(.init(image: image, depth: nil, confidence: nil, record: retry))
        try await recording.flush()
        XCTAssertEqual(try RGBDDatasetManifest.load(from: recording.directory).frames.map(\.id), ["valid", "retry"])
        await recording.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    private func record(id: String, width: Int, height: Int, hasDepth: Bool, timestamp: Double) -> RGBDFrameRecord {
        .init(id: id, timestamp: timestamp, rgbFile: "images/\(id).jpg", imageWidth: width, imageHeight: height,
              cameraToWorld: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
              intrinsics: [4,0,0, 0,4,0, Float(width) * 0.5,Float(height) * 0.5,1],
              depthFile: hasDepth ? "depth/\(id).f32" : nil,
              confidenceFile: hasDepth ? "confidence/\(id).u8" : nil,
              depthWidth: hasDepth ? 3 : nil, depthHeight: hasDepth ? 2 : nil,
              source: "streamRGBD", exposureDuration: 0.01, exposureOffset: 0)
    }

    private func pixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func fillImage(_ image: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        for y in 0..<CVPixelBufferGetHeight(image) {
            let row = CVPixelBufferGetBaseAddress(image)!.advanced(by: y * CVPixelBufferGetBytesPerRow(image)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<CVPixelBufferGetWidth(image) {
                row[x * 4] = 40; row[x * 4 + 1] = UInt8(y * 10); row[x * 4 + 2] = UInt8(x * 10); row[x * 4 + 3] = 255
            }
        }
    }
}
