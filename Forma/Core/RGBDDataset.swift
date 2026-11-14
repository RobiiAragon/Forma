import Foundation
import simd
import CoreVideo
import ImageIO

/// Native sensor raster: image origin top-left; ARKit camera looks along -Z, +Y up.
/// Matrices are column-major. Intrinsics are expressed in the saved image's pixels.
struct RGBDFrameRecord: Codable, Sendable, Identifiable {
    var id: String
    var timestamp: Double
    var rgbFile: String
    var imageWidth: Int
    var imageHeight: Int
    var cameraToWorld: [Float]
    var intrinsics: [Float]
    var depthFile: String?
    var confidenceFile: String?
    var depthWidth: Int?
    var depthHeight: Int?
    var source: String
    var exposureDuration: Double?
    var exposureOffset: Float?
    var acquisitionMetrics: [String: Double]? = nil
    /// Optional, versioned observations from this frame; absent fields are unknown.
    var sensorMetadata: RGBDFrameSensorMetadata? = nil
}

struct RGBDFrameSensorMetadata: Codable, Sendable {
    var schemaVersion = 1
    var frameSource: String? = nil
    var trackingState: String? = nil
    var trackingLimitedReason: String? = nil
    var worldMappingStatus: String? = nil
    /// ARKit estimates, not a calibrated lux measurement or camera WB gains.
    var estimatedAmbientIntensity: Double? = nil
    var estimatedAmbientColorTemperatureKelvin: Double? = nil
    var exif: RGBDFrameEXIFMetadata? = nil
    var image: RGBDImageMetadata? = nil
    var depth: RGBDDepthMetadata? = nil
}

/// A whitelist of captured-image EXIF values; never sampled from a live device getter.
struct RGBDFrameEXIFMetadata: Codable, Sendable {
    var source = "ARFrame.exifData"
    var isoSpeedRatings: [Double]?
    var exposureTimeSeconds: Double?
    var fNumber: Double?
    var focalLengthMillimeters: Double?
    var focalLength35mmEquivalentMillimeters: Double?
    var exposureBiasEV: Double?
    var brightnessEV: Double?
    /// EXIF records auto/manual only; it does not provide RGB WB gains.
    var whiteBalanceMode: String?
    var lensModel: String?

    init?(exifData: [String: Any]) {
        let values = exifData[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? exifData
        func number(_ key: CFString, positive: Bool = false) -> Double? {
            guard let value = values[key as String] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  !positive || value.doubleValue > 0 else { return nil }
            return value.doubleValue
        }
        if let ratings = values[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] {
            let valid = ratings.filter { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue > 0 }.map(\.doubleValue)
            isoSpeedRatings = valid.isEmpty ? nil : valid
        }
        exposureTimeSeconds = number(kCGImagePropertyExifExposureTime, positive: true)
        fNumber = number(kCGImagePropertyExifFNumber, positive: true)
        focalLengthMillimeters = number(kCGImagePropertyExifFocalLength, positive: true)
        focalLength35mmEquivalentMillimeters = number(kCGImagePropertyExifFocalLenIn35mmFilm, positive: true)
        exposureBiasEV = number(kCGImagePropertyExifExposureBiasValue)
        brightnessEV = number(kCGImagePropertyExifBrightnessValue)
        switch number(kCGImagePropertyExifWhiteBalance) {
        case 0: whiteBalanceMode = "auto"
        case 1: whiteBalanceMode = "manual"
        default: whiteBalanceMode = nil
        }
        if let text = values[kCGImagePropertyExifLensModel as String] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lensModel = text }
        guard isoSpeedRatings != nil || exposureTimeSeconds != nil || fNumber != nil || focalLengthMillimeters != nil ||
              focalLength35mmEquivalentMillimeters != nil || exposureBiasEV != nil || brightnessEV != nil ||
              whiteBalanceMode != nil || lensModel != nil else { return nil }
    }
}

/// Source colorimetry is separate from the explicitly encoded JPEG color space.
struct RGBDImageMetadata: Codable, Sendable {
    var sourcePixelFormat: UInt32
    var sourceColorPrimaries: String?
    var sourceTransferFunction: String?
    var sourceYCbCrMatrix: String?
    var sourceYCbCrRange: String?
    var savedColorSpace = "sRGB"
    var savedEXIFOrientation = 1
    var rasterTransform = "none; original CVPixelBuffer dimensions and raster order"

    init(image: CVPixelBuffer) {
        sourcePixelFormat = CVPixelBufferGetPixelFormatType(image)
        func attachment(_ key: CFString) -> String? {
            CVBufferCopyAttachment(image, key, nil) as? String
        }
        sourceColorPrimaries = attachment(kCVImageBufferColorPrimariesKey)
        sourceTransferFunction = attachment(kCVImageBufferTransferFunctionKey)
        sourceYCbCrMatrix = attachment(kCVImageBufferYCbCrMatrixKey)
        switch sourcePixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            sourceYCbCrRange = "full"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            sourceYCbCrRange = "video"
        default: sourceYCbCrRange = nil
        }
    }
}

struct RGBDDepthMetadata: Codable, Sendable {
    var source: String
    var pixelFormat: UInt32
    var confidencePixelFormat: UInt32?
    var units = "meters"
    var sampleType = "Float32 little-endian optical depth"
    var confidenceMeaning: String? = nil
}

struct RGBDDatasetManifest: Codable, Sendable {
    var schemaVersion: Int = 1
    var createdAt: Date
    var units: String = "meters"
    var matrixLayout: String = "columnMajor"
    var cameraConvention: String = "ARKit right-handed cameraToWorld; looks -Z; +Y up; RGB top-left"
    var frames: [RGBDFrameRecord]
    var captureMetrics: [String: Double]? = nil
    var lidarQuality: LiDARQualitySettings? = nil
    static let filename = "dataset.json"

    static func load(from directory: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent(filename)))
    }
    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}

extension RGBDFrameRecord {
    var transformMatrix: simd_float4x4? {
        guard cameraToWorld.count == 16, cameraToWorld.allSatisfy(\.isFinite) else { return nil }
        return simd_float4x4(columns: (
            SIMD4(cameraToWorld[0],cameraToWorld[1],cameraToWorld[2],cameraToWorld[3]),
            SIMD4(cameraToWorld[4],cameraToWorld[5],cameraToWorld[6],cameraToWorld[7]),
            SIMD4(cameraToWorld[8],cameraToWorld[9],cameraToWorld[10],cameraToWorld[11]),
            SIMD4(cameraToWorld[12],cameraToWorld[13],cameraToWorld[14],cameraToWorld[15])))
    }
}
