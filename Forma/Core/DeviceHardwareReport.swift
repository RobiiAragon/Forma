import Foundation
import AVFoundation
import ARKit
import Metal
import CoreMotion
import NearbyInteraction
import BackgroundTasks
import RealityKit
import RoomPlan
import SwiftUI
import UIKit
import Darwin
import os

/// Capability discovery only: no capture session, sensor stream, location, or permission request.
/// Identifiers are report-local indices; hardware identifiers and user-assigned names are omitted.
struct DeviceHardwareReport: Codable, Equatable, Sendable {
    struct Dimensions: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
        var pixelCount: Int64 { Int64(width) * Int64(height) }
        var label: String { "\(width) × \(height)" }
    }
    struct FrameRateRange: Codable, Equatable, Sendable {
        var minimum: Double
        var maximum: Double
    }
    struct Aperture: Codable, Equatable, Sendable {
        var minimum: Double?
        var maximum: Double?
        var recommendedStops: [Double]?
        var supportsAllParametersLocked: Bool
        var supportsShutterPriority: Bool
    }
    struct DepthFormat: Codable, Equatable, Sendable {
        var dimensions: Dimensions?
        var dimensionsUnavailableReason: String?
        var mediaType: String
        var pixelFormat: String
        var frameRates: [FrameRateRange]
    }
    struct DimensionQuery: Equatable, Sendable {
        var dimensions: Dimensions?
        var unavailableReason: String?
    }
    struct CameraFormat: Codable, Equatable, Sendable, Identifiable {
        var index: Int
        var videoDimensions: Dimensions
        var pixelFormat: String
        var frameRates: [FrameRateRange]
        var fieldOfViewDegrees: Double?
        var isBinned: Bool
        var supportsHDR: Bool
        /// Nil means the API did not provide any dimensions; never inferred from product specifications.
        var photoDimensions: [Dimensions]?
        var depthFormats: [DepthFormat]
        var aperture: Aperture?
        var id: Int { index }
    }
    struct Camera: Codable, Equatable, Sendable, Identifiable {
        var index: Int
        var deviceType: String
        var position: String
        var minimumFocusDistanceMillimeters: Int?
        var formats: [CameraFormat]
        var id: Int { index }
        var largestPhotoDimensions: Dimensions? {
            formats.flatMap { $0.photoDimensions ?? [] }.max { $0.pixelCount < $1.pixelCount }
        }
        var largestVideoDimensions: Dimensions? {
            formats.map(\.videoDimensions).max { $0.pixelCount < $1.pixelCount }
        }
        var maximumFramesPerSecond: Double? { formats.flatMap(\.frameRates).map(\.maximum).max() }
        var displayName: String {
            let lens: String
            switch deviceType {
            case AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue: lens = "Principal"
            case AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue: lens = "Ultra gran angular"
            case AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue: lens = "Teleobjetivo"
            case AVCaptureDevice.DeviceType.builtInTrueDepthCamera.rawValue: lens = "TrueDepth"
            case AVCaptureDevice.DeviceType.builtInLiDARDepthCamera.rawValue: lens = "LiDAR + RGB"
            case AVCaptureDevice.DeviceType.builtInDualCamera.rawValue: lens = "Cámara dual"
            case AVCaptureDevice.DeviceType.builtInDualWideCamera.rawValue: lens = "Cámara dual angular"
            case AVCaptureDevice.DeviceType.builtInTripleCamera.rawValue: lens = "Cámara triple"
            default: lens = "Cámara"
            }
            return lens + (position == "front" ? " · frontal" : position == "back" ? " · trasera" : "")
        }
    }
    struct ARVideoFormat: Codable, Equatable, Sendable, Identifiable {
        var index: Int
        var dimensions: Dimensions
        var framesPerSecond: Int
        var deviceType: String
        var position: String
        var recommendedForHighResolution: Bool
        var supportsHDR: Bool
        var id: Int { index }
    }
    struct ARCapabilities: Codable, Equatable, Sendable {
        var worldTracking: Bool?
        var sceneMesh: Bool?
        var classifiedMesh: Bool?
        var sceneDepth: Bool?
        var smoothedSceneDepth: Bool?
        var objectCapture: Bool?
        var localPhotogrammetry: Bool?
        var roomPlan: Bool?
        var videoFormats: [ARVideoFormat]
    }
    struct MotionCapabilities: Codable, Equatable, Sendable {
        var accelerometer: Bool?
        var gyroscope: Bool?
        var magnetometer: Bool?
        var fusedDeviceMotion: Bool?
        var relativeAltitude: Bool?
        var absoluteAltitude: Bool?
    }
    struct NearbyCapabilities: Codable, Equatable, Sendable {
        var preciseDistance: Bool?
        var direction: Bool?
        var cameraAssistance: Bool?
        var extendedDistance: Bool?
    }
    struct GPU: Codable, Equatable, Sendable {
        var name: String
        var hasUnifiedMemory: Bool
        var recommendedWorkingSetBytes: UInt64?
        var recommendedWorkingSetUnavailableReason: String?
        var maximumBufferLengthBytes: UInt64
        var currentlyAllocatedBytes: UInt64
        var supportedFamilies: [String]
    }
    struct Memory: Codable, Equatable, Sendable {
        var physicalBytes: UInt64?
        /// Instantaneous system estimate, not a fixed app quota or a promise of allocation success.
        var processAvailableBytes: UInt64?
    }
    var schemaVersion: Int = 1
    var capturedAt: Date
    var operatingSystemVersion: String
    var hardwareModel: String?
    var applicationVersion: String?
    var applicationBuild: String?
    var isPhysicalDevice: Bool
    var cameraAuthorizationStatus: String
    var captureStartedByReport: Bool = false
    var sensorStreamsStartedByReport: Bool = false
    var permissionsRequestedByReport: Bool = false
    var containsPersonalIdentifiers: Bool = false
    var cameras: [Camera]
    var ar: ARCapabilities
    var motion: MotionCapabilities
    var nearby: NearbyCapabilities
    var gpu: GPU?
    var memory: Memory
    var backgroundGPUResourceSupported: Bool?
    var limitations: [String]

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    @MainActor
    static func capture(bundle: Bundle = .main) -> Self {
        #if targetEnvironment(simulator)
        let physical = false
        let hardwareModel: String? = nil
        let physicalMemory: UInt64? = nil
        let sensorNote = "Simulator GPU describes the host; physical phone sensor capabilities are unknown."
        #else
        let physical = true
        let hardwareModel = modelIdentifier()
        let physicalMemory: UInt64? = ProcessInfo.processInfo.physicalMemory
        let sensorNote = "No camera, audio, location, or motion stream was started by this report."
        #endif
        let device = MTLCreateSystemDefaultDevice()
        let gpu = device.map { device in
            var families: [(MTLGPUFamily, String)] = [(.apple1,"Apple1"),(.apple2,"Apple2"),(.apple3,"Apple3"),
                (.apple4,"Apple4"),(.apple5,"Apple5"),(.apple6,"Apple6"),(.apple7,"Apple7"),(.apple8,"Apple8"),
                (.apple9,"Apple9"),(.metal3,"Metal3")]
            if #available(iOS 26.0, *) {
                families.append((.apple10,"Apple10"))
                #if !targetEnvironment(simulator)
                families.append((.metal4,"Metal4"))
                #endif
            }
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) { families.append((.apple11,"Apple11")) }
            #endif
            let workingSet = reportedMemoryBudget(device.recommendedMaxWorkingSetSize)
            return GPU(name: device.name, hasUnifiedMemory: device.hasUnifiedMemory,
                       recommendedWorkingSetBytes: workingSet,
                       recommendedWorkingSetUnavailableReason: workingSet == nil
                        ? "Metal returned zero for its working-set recommendation; no usable budget was reported." : nil,
                       maximumBufferLengthBytes: UInt64(device.maxBufferLength),
                       currentlyAllocatedBytes: UInt64(device.currentAllocatedSize),
                       supportedFamilies: families.filter { device.supportsFamily($0.0) }.map(\.1))
        }
        var cameras: [Camera] = []
        var ar = ARCapabilities(videoFormats: [])
        var motion = MotionCapabilities()
        var nearby = NearbyCapabilities()
        var availableMemory: UInt64?
        var backgroundGPU: Bool?
        #if !targetEnvironment(simulator)
            let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera,
                .builtInTelephotoCamera, .builtInTrueDepthCamera, .builtInLiDARDepthCamera,
                .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera]
            let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            cameras = discovered.enumerated().map { index, camera in
                Camera(index: index, deviceType: camera.deviceType.rawValue, position: position(camera.position),
                       minimumFocusDistanceMillimeters: camera.minimumFocusDistance >= 0 ? camera.minimumFocusDistance : nil,
                       formats: camera.formats.enumerated().map { index, format in cameraFormat(format, index: index) })
            }
            ar = ARCapabilities(worldTracking: ARWorldTrackingConfiguration.isSupported,
                sceneMesh: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
                classifiedMesh: ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification),
                sceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
                smoothedSceneDepth: ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
                objectCapture: ObjectCaptureSession.isSupported,
                localPhotogrammetry: PhotogrammetrySession.isSupported, roomPlan: RoomCaptureSession.isSupported,
                videoFormats: ARWorldTrackingConfiguration.supportedVideoFormats.enumerated().map { index, format in
                    ARVideoFormat(index: index, dimensions: .init(width: Int(format.imageResolution.width), height: Int(format.imageResolution.height)),
                        framesPerSecond: format.framesPerSecond, deviceType: format.captureDeviceType.rawValue,
                        position: position(format.captureDevicePosition),
                        recommendedForHighResolution: format.isRecommendedForHighResolutionFrameCapturing,
                        supportsHDR: format.isVideoHDRSupported)
                })
            let manager = CMMotionManager()
            motion = MotionCapabilities(accelerometer: manager.isAccelerometerAvailable, gyroscope: manager.isGyroAvailable,
                magnetometer: manager.isMagnetometerAvailable, fusedDeviceMotion: manager.isDeviceMotionAvailable,
                relativeAltitude: CMAltimeter.isRelativeAltitudeAvailable(), absoluteAltitude: CMAltimeter.isAbsoluteAltitudeAvailable())
            let nearbyDevice = NISession.deviceCapabilities
            nearby = NearbyCapabilities(preciseDistance: nearbyDevice.supportsPreciseDistanceMeasurement,
                direction: nearbyDevice.supportsDirectionMeasurement, cameraAssistance: nearbyDevice.supportsCameraAssistance,
                extendedDistance: nearbyDevice.supportsExtendedDistanceMeasurement)
            availableMemory = UInt64(os_proc_available_memory())
            if #available(iOS 26.0, *) { backgroundGPU = BGTaskScheduler.supportedResources.contains(.gpu) }
        #endif
        return .init(capturedAt: Date(), operatingSystemVersion: UIDevice.current.systemVersion,
            hardwareModel: hardwareModel,
            applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            applicationBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            isPhysicalDevice: physical, cameraAuthorizationStatus: cameraAuthorization(), cameras: cameras,
            ar: ar, motion: motion, nearby: nearby, gpu: gpu,
            memory: .init(physicalBytes: physicalMemory,
                          processAvailableBytes: availableMemory), backgroundGPUResourceSupported: backgroundGPU,
            limitations: ["Capability discovery does not measure captured image resolution, sustained FPS, temperature, or reconstruction accuracy.",
                "GPU working set and process-available memory are system estimates at this instant, not unlimited allocation grants.",
                "Background GPU resource support does not verify that the app signature authorizes background GPU use.",
                "Each camera format is a separate supported configuration; their maxima cannot be combined or assumed simultaneous.",
                "A depth descriptor without positive dimensions and a zero Metal working-set recommendation are reported as unavailable, not as zero physical capability.",
                sensorNote])
    }

    private static func cameraFormat(_ format: AVCaptureDevice.Format, index: Int) -> CameraFormat {
        let photos = format.supportedMaxPhotoDimensions.map { Dimensions(width: Int($0.width), height: Int($0.height)) }
            .filter { $0.width > 0 && $0.height > 0 }
        var aperture: Aperture?
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let stops = format.recommendedLensApertureStops.map { Double($0) }.filter { $0.isFinite && $0 > 0 }
            aperture = .init(minimum: positive(format.minLensAperture), maximum: positive(format.maxLensAperture),
                recommendedStops: stops.isEmpty ? nil : stops,
                supportsAllParametersLocked: format.supportsExposureModeCustom(lensAperture: AVCaptureDevice.currentLensAperture,
                    duration: AVCaptureDevice.currentExposureDuration, iso: AVCaptureDevice.currentISO),
                supportsShutterPriority: format.supportsExposureModeCustom(lensAperture: AVCaptureDevice.autoLensAperture,
                    duration: AVCaptureDevice.currentExposureDuration, iso: AVCaptureDevice.autoISO))
        }
        #endif
        return .init(index: index, videoDimensions: dimensions(format.formatDescription), pixelFormat: fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
            frameRates: frameRates(format), fieldOfViewDegrees: positive(format.videoFieldOfView),
            isBinned: format.isVideoBinned, supportsHDR: format.isVideoHDRSupported,
            photoDimensions: photos.isEmpty ? nil : photos,
            depthFormats: format.supportedDepthDataFormats.map {
                let query = queryDepthDimensions($0.formatDescription)
                return .init(dimensions: query.dimensions, dimensionsUnavailableReason: query.unavailableReason,
                    mediaType: fourCC(CMFormatDescriptionGetMediaType($0.formatDescription)),
                    pixelFormat: fourCC(CMFormatDescriptionGetMediaSubType($0.formatDescription)), frameRates: frameRates($0))
            }, aperture: aperture)
    }
    /// CMVideoFormatDescriptionGetDimensions is a media-specific API. Some real
    /// depth descriptors return 0×0; that does not measure a zero-resolution sensor.
    static func queryDepthDimensions(_ description: CMFormatDescription) -> DimensionQuery {
        let mediaType = CMFormatDescriptionGetMediaType(description)
        guard mediaType == kCMMediaType_Video else {
            return .init(dimensions: nil, unavailableReason:
                "The descriptor has media type \(fourCC(mediaType)); the video-dimensions API does not apply.")
        }
        let reported = CMVideoFormatDescriptionGetDimensions(description)
        return reportedDepthDimensions(width: Int(reported.width), height: Int(reported.height))
    }
    static func reportedDepthDimensions(width: Int, height: Int) -> DimensionQuery {
        guard width > 0, height > 0 else {
            return .init(dimensions: nil, unavailableReason:
                "The format descriptor returned non-positive depth dimensions (\(width) × \(height)); the raster size is unavailable without a valid captured buffer.")
        }
        return .init(dimensions: .init(width: width, height: height), unavailableReason: nil)
    }
    static func reportedMemoryBudget(_ bytes: UInt64) -> UInt64? { bytes > 0 ? bytes : nil }
    private static func dimensions(_ description: CMFormatDescription) -> Dimensions {
        let size = CMVideoFormatDescriptionGetDimensions(description)
        return .init(width: Int(size.width), height: Int(size.height))
    }
    private static func frameRates(_ format: AVCaptureDevice.Format) -> [FrameRateRange] {
        format.videoSupportedFrameRateRanges.map { .init(minimum: $0.minFrameRate, maximum: $0.maxFrameRate) }
    }
    private static func positive(_ value: Float) -> Double? { value.isFinite && value > 0 ? Double(value) : nil }
    private static func position(_ value: AVCaptureDevice.Position) -> String {
        switch value { case .front: return "front"; case .back: return "back"; default: return "unspecified" }
    }
    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [24,16,8,0].map { UInt8(truncatingIfNeeded: value >> $0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(format: "0x%08X", value) }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", value)
    }
    private static func cameraAuthorization() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
    private static func modelIdentifier() -> String? {
        var system = utsname()
        guard uname(&system) == 0 else { return nil }
        return withUnsafeBytes(of: system.machine) { raw in
            guard let pointer = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return nil }
            return String(cString: pointer)
        }
    }
}
