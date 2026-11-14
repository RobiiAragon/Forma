import Foundation
import CoreVideo
import ImageIO

/// Metadata semantics only. Does not create an ARSession or access a camera.
@main struct RGBDMetadataVerification {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(errorDescription: message) }
    }
    static func buffer(_ format: OSType) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        try require(CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, format, nil, &result) == kCVReturnSuccess,
                    "Authored buffer must allocate")
        return result!
    }
    static func main() throws {
        let rgb = try buffer(kCVPixelFormatType_32BGRA)
        CVBufferSetAttachment(rgb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(rgb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let color = RGBDImageMetadata(image: rgb)
        try require(color.sourceColorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String &&
                    color.sourceTransferFunction == kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                    "Source color attachments must remain distinguishable from encoded sRGB")
        try require(color.sourcePixelFormat == kCVPixelFormatType_32BGRA && color.sourceYCbCrRange == nil &&
                    color.savedColorSpace == "sRGB" && color.savedEXIFOrientation == 1,
                    "RGB metadata must preserve source format without inventing YCbCr range")
        let full = RGBDImageMetadata(image: try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        let video = RGBDImageMetadata(image: try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        try require(full.sourceYCbCrRange == "full" && video.sourceYCbCrRange == "video", "420f and 420v ranges must differ")
        try require(full.sourceColorPrimaries == nil, "Unknown colorimetry must stay unknown")
        let exifValues: [String: Any] = [kCGImagePropertyExifISOSpeedRatings as String: [-1, 80, 160, Double.nan],
            kCGImagePropertyExifExposureTime as String: 1.0 / 120,
            kCGImagePropertyExifFNumber as String: 2.8,
            kCGImagePropertyExifFocalLength as String: 6.8,
            kCGImagePropertyExifFocalLenIn35mmFilm as String: 24,
            kCGImagePropertyExifExposureBiasValue as String: -0.7,
            kCGImagePropertyExifBrightnessValue as String: -1.25,
            kCGImagePropertyExifWhiteBalance as String: 0]
        guard let exif = RGBDFrameEXIFMetadata(exifData: exifValues),
              let nested = RGBDFrameEXIFMetadata(exifData: [kCGImagePropertyExifDictionary as String: exifValues]) else {
            throw Failure(errorDescription: "Valid direct/nested EXIF must parse")
        }
        try require(exif.isoSpeedRatings == [80,160] && nested.isoSpeedRatings == exif.isoSpeedRatings &&
                    exif.exposureTimeSeconds == 1.0 / 120 && exif.fNumber == 2.8 && exif.focalLengthMillimeters == 6.8 &&
                    exif.focalLength35mmEquivalentMillimeters == 24 && exif.exposureBiasEV == -0.7 &&
                    exif.brightnessEV == -1.25 && exif.whiteBalanceMode == "auto", "Optics and signed EV values must survive")
        try require(RGBDFrameEXIFMetadata(exifData: [:]) == nil && RGBDFrameEXIFMetadata(exifData: [
            kCGImagePropertyExifISOSpeedRatings as String: [-1, Double.nan],
            kCGImagePropertyExifFNumber as String: Double.infinity,
            kCGImagePropertyExifFocalLength as String: true,
            kCGImagePropertyExifExposureTime as String: -0.01,
            kCGImagePropertyExifWhiteBalance as String: 2]) == nil, "Invalid values must not become fake measurements")
        var sensor = RGBDFrameSensorMetadata()
        sensor.exif = exif; sensor.image = color
        sensor.depth = RGBDDepthMetadata(source: "authored fixture", pixelFormat: kCVPixelFormatType_DepthFloat32,
            confidencePixelFormat: kCVPixelFormatType_OneComponent8, confidenceMeaning: "authored categorical fixture")
        var frame = RGBDFrameRecord(id: "fixture", timestamp: 1, rgbFile: "images/fixture.jpg", imageWidth: 8, imageHeight: 8,
            cameraToWorld: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1], intrinsics: [8,0,0,0,8,0,4,4,1],
            source: "authored fixture", exposureDuration: 1.0 / 120, exposureOffset: -0.7)
        frame.sensorMetadata = sensor
        let manifest = RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 1), frames: [frame])
        let bytes = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(RGBDDatasetManifest.self, from: bytes)
        try require(decoded.frames[0].sensorMetadata?.exif?.isoSpeedRatings == [80,160] &&
                    decoded.frames[0].sensorMetadata?.depth?.pixelFormat == kCVPixelFormatType_DepthFloat32,
                    "Versioned metadata must round-trip without changing native calibration")
        var legacy = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var frames = legacy["frames"] as! [[String: Any]]
        frames[0].removeValue(forKey: "sensorMetadata"); legacy["frames"] = frames
        let old = try JSONDecoder().decode(RGBDDatasetManifest.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(old.frames[0].sensorMetadata == nil && old.frames[0].intrinsics == frame.intrinsics,
                    "Historical captures must decode with unknown metadata and unchanged calibration")
        let report: [String: Any] = ["status": "passed", "cameraOpened": false, "physicalMetadataClaimed": false,
            "actualCoreVideoAttachments": true, "sourceAndSavedColorSpacesSeparate": true, "yuvRangesDistinguished": true,
            "directAndNestedEXIF": true, "invalidNonFiniteAndBooleanMeasurementsOmitted": true,
            "negativeExposureEVPreserved": true, "metadataRoundTrip": true, "legacyCaptureDecodes": true]
        let text = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let output = CommandLine.arguments.dropFirst().first {
            try text.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        print(String(data: text, encoding: .utf8)!)
    }
}
