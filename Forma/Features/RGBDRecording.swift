import Foundation
import ARKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Owns only the sensor pixel buffers and copied calibration, never an ARFrame's anchors.
struct RGBDRecordingFrame: @unchecked Sendable {
    let image: CVPixelBuffer
    let depth: CVPixelBuffer?
    let confidence: CVPixelBuffer?
    var record: RGBDFrameRecord

    init(image: CVPixelBuffer, depth: CVPixelBuffer?, confidence: CVPixelBuffer?, record: RGBDFrameRecord) {
        self.image = image
        self.depth = depth
        self.confidence = confidence
        self.record = record
    }

    init(frame: ARFrame, source: String) {
        image = frame.capturedImage
        depth = frame.sceneDepth?.depthMap
        confidence = frame.sceneDepth?.confidenceMap
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        var calibration = frame.camera.intrinsics
        let calibrationSize = frame.camera.imageResolution
        if calibrationSize.width > 0, calibrationSize.height > 0 {
            let sx = Float(width) / Float(calibrationSize.width), sy = Float(height) / Float(calibrationSize.height)
            for column in 0..<3 { calibration[column][0] *= sx; calibration[column][1] *= sy }
        }
        let transform = frame.camera.transform
        var pose: [Float] = [], intrinsics: [Float] = []
        for column in 0..<4 { for row in 0..<4 { pose.append(transform[column][row]) } }
        for column in 0..<3 { for row in 0..<3 { intrinsics.append(calibration[column][row]) } }
        let id = UUID().uuidString
        record = RGBDFrameRecord(id: id, timestamp: frame.timestamp, rgbFile: "images/\(id).jpg",
                                 imageWidth: width, imageHeight: height, cameraToWorld: pose, intrinsics: intrinsics,
                                 depthFile: depth.map { _ in "depth/\(id).f32" },
                                 confidenceFile: confidence.map { _ in "confidence/\(id).u8" },
                                 depthWidth: depth.map(CVPixelBufferGetWidth), depthHeight: depth.map(CVPixelBufferGetHeight),
                                 source: source, exposureDuration: frame.camera.exposureDuration,
                                 exposureOffset: frame.camera.exposureOffset)
        if case .normal = frame.camera.trackingState { record.acquisitionMetrics = ["trackingNormal": 1] }
        else { record.acquisitionMetrics = ["trackingNormal": 0] }
        var sensor = RGBDFrameSensorMetadata()
        sensor.frameSource = "ARFrame; metadata and pose belong to the returned frame"
        switch frame.camera.trackingState {
        case .normal: sensor.trackingState = "normal"
        case .notAvailable: sensor.trackingState = "notAvailable"
        case .limited(let reason):
            sensor.trackingState = "limited"
            switch reason {
            case .excessiveMotion: sensor.trackingLimitedReason = "excessiveMotion"
            case .insufficientFeatures: sensor.trackingLimitedReason = "insufficientFeatures"
            case .initializing: sensor.trackingLimitedReason = "initializing"
            case .relocalizing: sensor.trackingLimitedReason = "relocalizing"
            @unknown default: sensor.trackingLimitedReason = "unknown"
            }
        }
        switch frame.worldMappingStatus {
        case .notAvailable: sensor.worldMappingStatus = "notAvailable"
        case .limited: sensor.worldMappingStatus = "limited"
        case .extending: sensor.worldMappingStatus = "extending"
        case .mapped: sensor.worldMappingStatus = "mapped"
        @unknown default: sensor.worldMappingStatus = "unknown"
        }
        sensor.exif = RGBDFrameEXIFMetadata(exifData: frame.exifData)
        if let estimate = frame.lightEstimate {
            let intensity = Double(estimate.ambientIntensity), temperature = Double(estimate.ambientColorTemperature)
            if intensity.isFinite && intensity >= 0 { sensor.estimatedAmbientIntensity = intensity }
            if temperature.isFinite && temperature > 0 { sensor.estimatedAmbientColorTemperatureKelvin = temperature }
        }
        if let depth {
            sensor.depth = RGBDDepthMetadata(source: "ARFrame.sceneDepth; same returned frame; not smoothedSceneDepth",
                pixelFormat: CVPixelBufferGetPixelFormatType(depth),
                confidencePixelFormat: confidence.map(CVPixelBufferGetPixelFormatType),
                confidenceMeaning: confidence == nil ? nil : "ARConfidenceLevel: 0 low, 1 medium, 2 high; not metric uncertainty")
        }
        record.sensorMetadata = sensor
    }
}

/// One disk writer at a time. Frames retain their native raster and their own timestamp/pose.
@MainActor
final class RGBDRecording {
    enum RecordingError: LocalizedError {
        case busy, closed, invalidCalibration, imageEncoding, depthFormat, confidenceFormat
        var errorDescription: String? {
            switch self {
            case .busy: return "Se está guardando otro fotograma. Espera a que termine la escritura."
            case .closed: return "El conjunto de captura ya se ha cerrado."
            case .invalidCalibration: return "La cámara no entregó una calibración válida para este fotograma."
            case .imageEncoding: return "No se pudo guardar la imagen a su resolución original. Comprueba el espacio disponible."
            case .depthFormat: return "El sensor entregó un formato de profundidad no compatible. No se ha inventado ni convertido su escala."
            case .confidenceFormat: return "El sensor entregó un mapa de confianza no compatible."
            }
        }
    }

    let directory: URL
    private let workspace: URL
    private(set) var frameCount = 0
    private(set) var highResolutionCount = 0
    private(set) var depthFrameCount = 0
    private(set) var lastImageSize = ""
    private(set) var lastCommitSeconds = 0.0
    private(set) var streamMeanCommitSeconds = 0.0
    private var frames: [RGBDFrameRecord] = []
    private var committedIDs: Set<String> = []
    private let createdAt = Date()
    private var pending: Task<RGBDWrittenFrame, Error>?
    private var closed = false
    private var streamCommitSeconds = 0.0
    private var streamCommitCount = 0
    private var totalCommitSeconds = 0.0
    private var maximumCommitSeconds = 0.0
    private var totalSensorBytes = 0.0
    private var captureMetrics: [String: Double] = [:]
    var lidarQuality: LiDARQualitySettings?

    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-LiDAR-\(UUID().uuidString)", isDirectory: true)
        directory = workspace.appendingPathComponent("RGBD", isDirectory: true)
        for folder in ["", "images", "depth", "confidence", "metadata"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try RGBDDatasetManifest(createdAt: createdAt, frames: []).write(to: directory)
        let explanation = """
        Forma RGB-D dataset, schema 1. Local sensor capture, no generated images.
        images/: JPEG at the original CVPixelBuffer dimensions, no rotation or resizing, sRGB.
        depth/: tightly packed Float32 little-endian, row-major, optical depth in meters.
        confidence/: tightly packed UInt8 row-major: 0 low, 1 medium, 2 high.
        Each RGB/depth pair belongs to one ARFrame. High-resolution photos never inherit depth from another frame.
        Intrinsics are scaled to the saved RGB raster. Raster origin: center of top-left pixel.
        Matrices: column-major; cameraToWorld: ARKit right-handed, looks -Z, +Y up.
        Pinhole (right, down, forward) to ARKit camera: diag(1,-1,-1).
        metadata/ and frames.jsonl journal committed frames before the final dataset.json flush.
        Frame counts and dimensions describe real saved files. Sensor accuracy is not certified.
        acquisitionMetrics: seconds for luma sampling, JPEG encoding/writing and depth/confidence writing;
        sampledLuma*01 are sparse encoded-luma values/gradients, not sharpness or geometric-accuracy certificates.
        captureMetrics: measured AR/render callback rates, writer-busy callbacks, commit seconds and sensor file bytes.
        Callback rates do not certify displayed-frame presentation timing or scan completeness.
        sensorMetadata (optional schema 1): frame-bound EXIF ISO/exposure/aperture/focal length/WB mode when ARKit supplies them;
        tracking/mapping and light estimates are from that returned frame. EXIF WB mode is not RGB gains; light temperature is not camera WB.
        Source pixel format/color attachments are separate from the saved sRGB JPEG, orientation 1 with no raster rotation.
        Missing values remain unknown. No current AVCaptureDevice getter is labeled as synchronized photo metadata.
        """
        try explanation.write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    func append(_ frame: RGBDRecordingFrame) async throws -> RGBDFrameRecord {
        guard !closed else { throw RecordingError.closed }
        guard pending == nil else { throw RecordingError.busy }
        let destination = directory
        let task = Task.detached(priority: .userInitiated) { try Self.write(frame, to: destination) }
        pending = task
        do {
            let written = try await task.value
            pending = nil
            guard !closed else { throw RecordingError.closed }
            commit(written)
            return written.record
        } catch { pending = nil; throw error }
    }

    /// Final index is written only after the current frame is durable. No sources are removed on failure.
    func flush() async throws {
        if let pending { commit(try await pending.value) }
        guard !closed else { throw RecordingError.closed }
        var manifest = RGBDDatasetManifest(createdAt: createdAt, frames: frames)
        var metrics = captureMetrics
        metrics["committedFrames"] = Double(frameCount)
        metrics["committedDepthFrames"] = Double(depthFrameCount)
        metrics["committedHighResolutionFrames"] = Double(highResolutionCount)
        metrics["meanCommitSeconds"] = frameCount > 0 ? totalCommitSeconds / Double(frameCount) : 0
        metrics["maximumCommitSeconds"] = maximumCommitSeconds
        metrics["streamMeanCommitSeconds"] = streamMeanCommitSeconds
        metrics["committedSensorFileBytes"] = totalSensorBytes
        manifest.captureMetrics = metrics
        manifest.lidarQuality = lidarQuality
        let directory = directory
        try await Task.detached(priority: .userInitiated) { try manifest.write(to: directory) }.value
    }

    func discard() async {
        closed = true
        if let pending { _ = try? await pending.value }
        let workspace = workspace
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: workspace) }.value
    }

    /// Counters describe observed callbacks/work, never geometric coverage or accuracy.
    func setCaptureMetric(_ name: String, value: Double) {
        guard value.isFinite else { return }
        captureMetrics[name] = value
    }

    private func commit(_ written: RGBDWrittenFrame) {
        let record = written.record
        guard committedIDs.insert(record.id).inserted else { return }
        frames.append(record)
        frameCount = frames.count
        if record.source == "highResolution" { highResolutionCount += 1 }
        if record.depthFile != nil { depthFrameCount += 1 }
        lastImageSize = "\(record.imageWidth) × \(record.imageHeight)"
        lastCommitSeconds = written.commitSeconds
        totalCommitSeconds += written.commitSeconds
        maximumCommitSeconds = max(maximumCommitSeconds, written.commitSeconds)
        totalSensorBytes += written.sensorBytes
        if record.source == "streamRGBD" {
            streamCommitCount += 1
            streamCommitSeconds += written.commitSeconds
            streamMeanCommitSeconds = streamCommitSeconds / Double(streamCommitCount)
        }
    }

    nonisolated private static func write(_ frame: RGBDRecordingFrame, to directory: URL) throws -> RGBDWrittenFrame {
        let started = ProcessInfo.processInfo.systemUptime
        var written = try autoreleasepool { try writeInsidePool(frame, to: directory) }
        written.commitSeconds = ProcessInfo.processInfo.systemUptime - started
        return written
    }

    nonisolated private static func writeInsidePool(_ frame: RGBDRecordingFrame, to directory: URL) throws -> RGBDWrittenFrame {
        let started = ProcessInfo.processInfo.systemUptime
        try Task.checkCancellation()
        var record = frame.record
        guard record.imageWidth > 0, record.imageHeight > 0,
              record.imageWidth == CVPixelBufferGetWidth(frame.image), record.imageHeight == CVPixelBufferGetHeight(frame.image),
              record.intrinsics.count == 9, record.intrinsics.allSatisfy(\.isFinite),
              record.intrinsics[0] > 0, record.intrinsics[4] > 0,
              record.cameraToWorld.count == 16, record.cameraToWorld.allSatisfy(\.isFinite) else {
            throw RecordingError.invalidCalibration
        }
        if let depth = frame.depth {
            guard record.depthFile != nil, CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
                  CVPixelBufferGetWidth(depth) == record.depthWidth,
                  CVPixelBufferGetHeight(depth) == record.depthHeight else { throw RecordingError.depthFormat }
        } else if record.depthFile != nil || record.depthWidth != nil || record.depthHeight != nil { throw RecordingError.depthFormat }
        if let confidence = frame.confidence {
            guard frame.depth != nil, record.confidenceFile != nil,
                  CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferGetWidth(confidence) == record.depthWidth,
                  CVPixelBufferGetHeight(confidence) == record.depthHeight else { throw RecordingError.confidenceFormat }
        } else if record.confidenceFile != nil { throw RecordingError.confidenceFormat }
        var acquisition = record.acquisitionMetrics ?? [:]
        var sensor = record.sensorMetadata ?? RGBDFrameSensorMetadata()
        sensor.image = RGBDImageMetadata(image: frame.image)
        record.sensorMetadata = sensor
        let analysisStarted = ProcessInfo.processInfo.systemUptime
        for (name, value) in RGBDImageEncoding.sampledLumaMetrics(frame.image) { acquisition[name] = value }
        acquisition["lumaAnalysisSeconds"] = ProcessInfo.processInfo.systemUptime - analysisStarted
        let imageURL = directory.appendingPathComponent(record.rgbFile)
        let temporaryImage = imageURL.appendingPathExtension("pending")
        defer { try? FileManager.default.removeItem(at: temporaryImage) }
        let context = RGBDImageEncoding.context
        let image = CIImage(cvPixelBuffer: frame.image).settingProperties([kCGImagePropertyOrientation as String: 1])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let encodingStarted = ProcessInfo.processInfo.systemUptime
        // Direct encoding avoids explicitly materializing a full RGBA CGImage beside the native camera buffer.
        try context.writeJPEGRepresentation(of: image, to: temporaryImage, colorSpace: colorSpace, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0,
            CIImageRepresentationOption(rawValue: kCGImageDestinationEmbedThumbnail as String): false
        ])
        guard let source = CGImageSourceCreateWithURL(temporaryImage as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == record.imageWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == record.imageHeight else {
            throw RecordingError.imageEncoding
        }
        acquisition["jpegEncodeAndWriteSeconds"] = ProcessInfo.processInfo.systemUptime - encodingStarted
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporaryImage, to: imageURL)
        var sensorBytes = Double((try FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
        acquisition["jpegFileBytes"] = sensorBytes
        let depthStarted = ProcessInfo.processInfo.systemUptime
        if let depth = frame.depth, let path = record.depthFile {
            let data = try tightlyPacked(depth, bytesPerPixel: 4)
            try data.write(to: directory.appendingPathComponent(path), options: .atomic)
            sensorBytes += Double(data.count)
        }
        if let confidence = frame.confidence, let path = record.confidenceFile {
            let data = try tightlyPacked(confidence, bytesPerPixel: 1)
            try data.write(to: directory.appendingPathComponent(path), options: .atomic)
            sensorBytes += Double(data.count)
        }
        acquisition["depthConfidenceWriteSeconds"] = ProcessInfo.processInfo.systemUptime - depthStarted
        record.acquisitionMetrics = acquisition
        let data = try JSONEncoder().encode(record)
        try data.write(to: directory.appendingPathComponent("metadata/\(record.id).json"), options: .atomic)
        let journal = directory.appendingPathComponent("frames.jsonl")
        if !FileManager.default.fileExists(atPath: journal.path) { FileManager.default.createFile(atPath: journal.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: journal)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([0x0a]))
        try handle.synchronize()
        return RGBDWrittenFrame(record: record, commitSeconds: ProcessInfo.processInfo.systemUptime - started, sensorBytes: sensorBytes)
    }

    nonisolated private static func tightlyPacked(_ buffer: CVPixelBuffer, bytesPerPixel: Int) throws -> Data {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw RecordingError.depthFormat }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let rowSize = CVPixelBufferGetWidth(buffer) * bytesPerPixel
        let height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), stride >= rowSize else { throw RecordingError.depthFormat }
        var data = Data(count: rowSize * height)
        data.withUnsafeMutableBytes { destination in
            guard let bytes = destination.baseAddress else { return }
            for row in 0..<height { memcpy(bytes.advanced(by: row * rowSize), base.advanced(by: row * stride), rowSize) }
        }
        // All supported iOS and Apple Silicon simulator architectures use little-endian Float32.
        return data
    }
}

private enum RGBDImageEncoding {
    // CIContext is thread-safe; reuse its resources instead of rebuilding an encoder for each keyframe.
    static let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])

    /// Sparse native-raster code-value samples. These describe image content, not reconstruction accuracy.
    static func sampledLumaMetrics(_ image: CVPixelBuffer) -> [String: Double] {
        let planar = CVPixelBufferIsPlanar(image)
        let format = CVPixelBufferGetPixelFormatType(image)
        let lumaPlane = planar && (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        guard lumaPlane || (!planar && format == kCVPixelFormatType_32BGRA),
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return [:] }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        guard width > 2, height > 2,
              let base = lumaPlane ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image) else { return [:] }
        let rowStride = lumaPlane ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
        func luma(_ x: Int, _ y: Int) -> Double {
            let row = base.advanced(by: y * rowStride).assumingMemoryBound(to: UInt8.self)
            if lumaPlane { return Double(row[x]) / 255 }
            return (0.2126 * Double(row[x * 4 + 2]) + 0.7152 * Double(row[x * 4 + 1]) + 0.0722 * Double(row[x * 4])) / 255
        }
        var mean = 0.0, edge = 0.0, clipped = 0.0, count = 0.0
        for y in stride(from: 1, to: height - 1, by: max(1, height / 32)) {
            for x in stride(from: 1, to: width - 1, by: max(1, width / 32)) {
                let value = luma(x, y)
                mean += value
                edge += (abs(luma(x + 1, y) - value) + abs(luma(x, y + 1) - value)) * 0.5
                if value <= 0.01 || value >= 0.99 { clipped += 1 }
                count += 1
            }
        }
        guard count > 0 else { return [:] }
        return ["sampledLumaMean01": mean / count, "sampledLumaEdgeMean01": edge / count,
                "sampledLumaClippedFraction01": clipped / count, "lumaSampleCount": count]
    }
}

private struct RGBDWrittenFrame: Sendable {
    var record: RGBDFrameRecord
    var commitSeconds: Double
    var sensorBytes: Double
}
