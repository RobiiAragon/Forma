import XCTest
import AVFoundation
import CoreMedia
@testable import Forma

final class DeviceHardwareReportTests: XCTestCase {
    func testCameraSummariesKeepIndependentFormatMaximaAndUnknownValues() throws {
        let formatA = DeviceHardwareReport.CameraFormat(index: 0, videoDimensions: .init(width: 3840, height: 2160),
            pixelFormat: "420f", frameRates: [.init(minimum: 24, maximum: 30)], fieldOfViewDegrees: nil,
            isBinned: false, supportsHDR: false, photoDimensions: nil, depthFormats: [], aperture: nil)
        let formatB = DeviceHardwareReport.CameraFormat(index: 1, videoDimensions: .init(width: 1920, height: 1080),
            pixelFormat: "420f", frameRates: [.init(minimum: 30, maximum: 120)], fieldOfViewDegrees: 60,
            isBinned: true, supportsHDR: false, photoDimensions: [.init(width: 4032, height: 3024)], depthFormats: [], aperture: nil)
        let camera = DeviceHardwareReport.Camera(index: 0, deviceType: "synthetic-camera", position: "back",
            minimumFocusDistanceMillimeters: nil, formats: [formatA, formatB])
        XCTAssertEqual(camera.largestVideoDimensions, formatA.videoDimensions)
        XCTAssertEqual(camera.largestPhotoDimensions, formatB.photoDimensions?.first)
        XCTAssertEqual(camera.maximumFramesPerSecond, 120)
        XCTAssertNil(camera.minimumFocusDistanceMillimeters)
        XCTAssertNil(camera.formats[0].photoDimensions, "Missing photo dimensions must not become a product-sheet megapixel count")
        XCTAssertNil(camera.formats[0].aperture)

        let report = fixture(cameras: [camera])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(DeviceHardwareReport.self, from: report.jsonData()), report)
    }

    func testExportSchemaOmitsPersonalHardwareIdentifiersAndPreservesUnknownCapabilities() throws {
        let report = fixture(cameras: [])
        let data = try report.jsonData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let forbidden = Set(["serialNumber", "udid", "uniqueID", "identifierForVendor", "deviceName", "localizedName", "location", "latitude", "longitude"])
        func inspect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                XCTAssertTrue(forbidden.isDisjoint(with: dictionary.keys))
                dictionary.values.forEach(inspect)
            } else if let array = value as? [Any] { array.forEach(inspect) }
        }
        inspect(object)
        XCTAssertEqual(object["containsPersonalIdentifiers"] as? Bool, false)
        XCTAssertEqual(object["captureStartedByReport"] as? Bool, false)
        XCTAssertEqual(object["permissionsRequestedByReport"] as? Bool, false)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DeviceHardwareReport.self, from: data)
        XCTAssertNil(decoded.ar.sceneDepth)
        XCTAssertNil(decoded.motion.gyroscope)
        XCTAssertNil(decoded.nearby.preciseDistance)
        XCTAssertNil(decoded.memory.processAvailableBytes)
        XCTAssertNil(decoded.hardwareModel)
    }

    func testMissingDepthDimensionsAndMetalBudgetRemainUnavailableInsteadOfInventingValues() throws {
        for (width, height) in [(0,0), (640,0), (0,480), (-1,480)] {
            let result = DeviceHardwareReport.reportedDepthDimensions(width: width, height: height)
            XCTAssertNil(result.dimensions)
            XCTAssertFalse(try XCTUnwrap(result.unavailableReason).isEmpty)
        }
        let valid = DeviceHardwareReport.reportedDepthDimensions(width: 320, height: 240)
        XCTAssertEqual(valid.dimensions, .init(width: 320, height: 240))
        XCTAssertNil(valid.unavailableReason)
        XCTAssertNil(DeviceHardwareReport.reportedMemoryBudget(0))
        XCTAssertEqual(DeviceHardwareReport.reportedMemoryBudget(8_589_950_976), 8_589_950_976)

        // Preserve the advertised depth type/rates when its descriptor omits the
        // raster. An unknown raster does not mean the camera has no depth support.
        let unavailable = DeviceHardwareReport.DepthFormat(dimensions: nil, dimensionsUnavailableReason: "descriptor returned 0 × 0",
            mediaType: "vide", pixelFormat: "fdep", frameRates: [.init(minimum: 1, maximum: 30)])
        let data = try JSONEncoder().encode(unavailable)
        let recovered = try JSONDecoder().decode(DeviceHardwareReport.DepthFormat.self, from: data)
        XCTAssertEqual(recovered, unavailable)
        XCTAssertNil(recovered.dimensions)
        XCTAssertEqual(recovered.pixelFormat, "fdep")
        XCTAssertEqual(recovered.frameRates, [.init(minimum: 1, maximum: 30)])
    }

    func testDepthDimensionQueryUsesOnlyApplicableVideoDescriptorAndPreservesPositiveRaster() throws {
        var video: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_DepthFloat32,
            width: 320, height: 180, extensions: nil, formatDescriptionOut: &video), noErr)
        let valid = DeviceHardwareReport.queryDepthDimensions(try XCTUnwrap(video))
        XCTAssertEqual(valid.dimensions, .init(width: 320, height: 180))
        XCTAssertNil(valid.unavailableReason)

        var metadata: CMFormatDescription?
        XCTAssertEqual(CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Metadata,
            mediaSubType: 0, extensions: nil, formatDescriptionOut: &metadata), noErr)
        let unknown = DeviceHardwareReport.queryDepthDimensions(try XCTUnwrap(metadata))
        XCTAssertNil(unknown.dimensions, "A generic descriptor must not be passed to the video-specific dimensions API")
        XCTAssertTrue(try XCTUnwrap(unknown.unavailableReason).contains("does not apply"))
    }

    /// Reads capability metadata only. The JSON contains no sensor samples or personal identifiers.
    @MainActor
    func testRuntimeCapabilityInventoryWithoutStartingCaptureOrRequestingPermissions() throws {
        let cameraAuthorizationBefore = AVCaptureDevice.authorizationStatus(for: .video)
        let report = DeviceHardwareReport.capture()
        XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .video), cameraAuthorizationBefore)
        XCTAssertFalse(report.captureStartedByReport)
        XCTAssertFalse(report.sensorStreamsStartedByReport)
        XCTAssertFalse(report.permissionsRequestedByReport)
        XCTAssertFalse(report.containsPersonalIdentifiers)
        XCTAssertFalse(report.operatingSystemVersion.isEmpty)
        if let gpu = report.gpu {
            XCTAssertGreaterThan(gpu.maximumBufferLengthBytes, 0)
            if let recommendation = gpu.recommendedWorkingSetBytes {
                XCTAssertGreaterThan(recommendation, 0)
                XCTAssertNil(gpu.recommendedWorkingSetUnavailableReason)
            } else {
                XCTAssertFalse(try XCTUnwrap(gpu.recommendedWorkingSetUnavailableReason).isEmpty)
            }
            XCTAssertFalse(gpu.name.isEmpty)
        }
        #if targetEnvironment(simulator)
        XCTAssertFalse(report.isPhysicalDevice)
        XCTAssertTrue(report.cameras.isEmpty)
        XCTAssertNil(report.memory.physicalBytes, "Simulator host RAM must not be presented as phone RAM")
        XCTAssertNil(report.ar.sceneDepth)
        #else
        XCTAssertTrue(report.isPhysicalDevice)
        XCTAssertFalse(try XCTUnwrap(report.hardwareModel).isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(report.memory.physicalBytes), 0)
        XCTAssertNotNil(report.memory.processAvailableBytes)
        XCTAssertFalse(report.cameras.isEmpty, "A physical iPhone must expose its supported built-in camera formats")
        #endif
        for (cameraIndex, camera) in report.cameras.enumerated() {
            XCTAssertEqual(camera.index, cameraIndex)
            XCTAssertFalse(camera.formats.isEmpty)
            if let distance = camera.minimumFocusDistanceMillimeters { XCTAssertGreaterThanOrEqual(distance, 0) }
            for (formatIndex, format) in camera.formats.enumerated() {
                XCTAssertEqual(format.index, formatIndex)
                assertDimensions(format.videoDimensions)
                assertRates(format.frameRates)
                if let field = format.fieldOfViewDegrees { XCTAssertTrue(field.isFinite && field > 0 && field < 360) }
                for dimensions in format.photoDimensions ?? [] { assertDimensions(dimensions) }
                for depth in format.depthFormats {
                    if let dimensions = depth.dimensions {
                        assertDimensions(dimensions)
                        XCTAssertNil(depth.dimensionsUnavailableReason)
                    } else {
                        XCTAssertFalse(try XCTUnwrap(depth.dimensionsUnavailableReason).isEmpty)
                    }
                    XCTAssertFalse(depth.mediaType.isEmpty)
                    assertRates(depth.frameRates)
                }
                if let aperture = format.aperture {
                    if let minimum = aperture.minimum { XCTAssertTrue(minimum.isFinite && minimum > 0) }
                    if let maximum = aperture.maximum { XCTAssertTrue(maximum.isFinite && maximum > 0) }
                    if let minimum = aperture.minimum, let maximum = aperture.maximum { XCTAssertLessThanOrEqual(minimum, maximum) }
                    for stop in aperture.recommendedStops ?? [] { XCTAssertTrue(stop.isFinite && stop > 0) }
                }
            }
        }
        for format in report.ar.videoFormats { assertDimensions(format.dimensions); XCTAssertGreaterThan(format.framesPerSecond, 0) }
        if report.ar.sceneDepth == true { XCTAssertEqual(report.ar.worldTracking, true) }
        let attachment = XCTAttachment(data: try report.jsonData(), uniformTypeIdentifier: "public.json")
        attachment.name = "device-hardware-capabilities.json"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertDimensions(_ dimensions: DeviceHardwareReport.Dimensions, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(dimensions.width, 0, file: file, line: line)
        XCTAssertGreaterThan(dimensions.height, 0, file: file, line: line)
    }
    private func assertRates(_ ranges: [DeviceHardwareReport.FrameRateRange], file: StaticString = #filePath, line: UInt = #line) {
        for range in ranges {
            XCTAssertTrue(range.minimum.isFinite && range.maximum.isFinite, file: file, line: line)
            XCTAssertGreaterThan(range.minimum, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(range.maximum, range.minimum, file: file, line: line)
        }
    }
    private func fixture(cameras: [DeviceHardwareReport.Camera]) -> DeviceHardwareReport {
        .init(capturedAt: Date(timeIntervalSince1970: 1_760_000_000), operatingSystemVersion: "fixture",
              hardwareModel: nil, applicationVersion: "fixture", applicationBuild: "fixture", isPhysicalDevice: false,
              cameraAuthorizationStatus: "notDetermined", cameras: cameras, ar: .init(videoFormats: []),
              motion: .init(), nearby: .init(), gpu: nil, memory: .init(), backgroundGPUResourceSupported: nil,
              limitations: ["Synthetic fixture, no hardware queried"])
    }
}
