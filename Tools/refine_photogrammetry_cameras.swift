import Foundation
import RealityKit
import Darwin

/// A standalone Apple session using authored requests only. It never imports the
/// library, controls an app/worker, edits sources, or starts Gaussian training.
@main struct RefinePhotogrammetryCameras {
    struct Failure: LocalizedError { var errorDescription: String? }
    struct State: Codable {
        var schemaVersion = 1
        var pid = ProcessInfo.processInfo.processIdentifier
        var startedAt = Date()
        var updatedAt = Date()
        var phase = "preparing"
        var inputCount = 0
        var requests = ["poses", "pointCloud", "bounds"]
        var progress: [String: Double] = [:]
        var outputs: [String: String] = [:]
        var invalidSamples: [String: String] = [:]
        var skippedSamples: [Int] = []
        var automaticDownsampling = false
        var poseCount: Int?
        var pointCount: Int?
        var error: String?
        var compareModels = false
        var experimentalCustomSettings: [String: String]?
    }
    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst()), compare = arguments.contains("--compare-models")
        let paths = arguments.filter { $0 != "--compare-models" }
        guard paths.count == 2 else { throw Failure(errorDescription: "Usage: refine-photogrammetry-cameras DATASET FRESH_OUTPUT [--compare-models]") }
        guard #available(macOS 14.0, *), PhotogrammetrySession.isSupported else { throw Failure(errorDescription: "Apple PhotogrammetrySession is unavailable on this Mac") }
        let dataset = URL(fileURLWithPath: paths[0]).standardizedFileURL
        let directory = URL(fileURLWithPath: paths[1], isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else { throw Failure(errorDescription: "Output must be a fresh directory; no existing artifacts were replaced") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("events.ndjson")
        guard fm.createFile(atPath: logURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let log = try FileHandle(forWritingTo: logURL); defer { try? log.close() }
        var state = State(); state.compareModels = compare
        func persist() throws { state.updatedAt = Date(); try DesktopPhotogrammetryCalibration.writeJSON(state, to: directory.appendingPathComponent("state.json")) }
        func event(_ message: String, fields: [String: Any] = [:]) throws {
            var value = fields; value["event"] = message; value["time"] = Date().timeIntervalSince1970; value["pid"] = state.pid
            var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); try log.write(contentsOf: data)
            print("\(ISO8601DateFormatter().string(from: Date())) \(message) \(fields)"); fflush(stdout)
        }
        if compare {
            state.requests += ["raw", "custom16k"]
            state.experimentalCustomSettings = ["maximumTextureDimension": "sixteenK", "textureFormat": "png", "maximumPolygonCount": "10000000",
                "outputTextureMaps": "diffuseColor,normal",
                "scope": "this comparison only; not an application default or a photo/splat quota"]
        }
        try persist(); try event("started", fields: ["output": directory.path, "compareModels": compare])
        let prepared = try await Task.detached(priority: .userInitiated) {
            try DesktopPhotogrammetryInput.prepare(dataset: dataset, sessionDirectory: directory)
        }.value
        state.inputCount = prepared.items.count; state.phase = "initializing"; try persist()
        try event("input-prepared", fields: ["photos": prepared.items.count])
        let checkpoint = directory.appendingPathComponent("checkpoints", isDirectory: true)
        try fm.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        var configuration = PhotogrammetrySession.Configuration()
        configuration.checkpointDirectory = checkpoint; configuration.featureSensitivity = .high; configuration.sampleOrdering = .sequential
        configuration.isObjectMaskingEnabled = false
        if #available(macOS 15.0, *) { configuration.ignoreBoundingBox = true }
        if compare {
            configuration.customDetailSpecification.maximumTextureDimension = .sixteenK
            configuration.customDetailSpecification.textureFormat = .png
            configuration.customDetailSpecification.maximumPolygonCount = 10_000_000
            configuration.customDetailSpecification.outputTextureMaps = [.diffuseColor, .normal]
        }
        let session = try PhotogrammetrySession(input: prepared.directory, configuration: configuration)
        var requests: [PhotogrammetrySession.Request] = [.poses, .pointCloud, .bounds]
        if compare {
            requests += [.modelFile(url: directory.appendingPathComponent("raw.usdz"), detail: .raw),
                         .modelFile(url: directory.appendingPathComponent("texture16k.usdz"), detail: .custom)]
        }
        func requestName(_ request: PhotogrammetrySession.Request) -> String {
            switch request {
            case .poses: "poses"
            case .pointCloud: "pointCloud"
            case .bounds: "bounds"
            case .modelFile(_, let detail, _): detail == .raw ? "raw" : "custom16k"
            default: "unknown"
            }
        }
        state.phase = "processing"; try persist()
        do {
            try session.process(requests: requests)
            for try await output in session.outputs {
                switch output {
                case .requestProgress(let request, let fraction):
                    guard fraction.isFinite else { throw Failure(errorDescription: "Apple returned nonfinite progress") }
                    let name = requestName(request), previous = state.progress[name] ?? -1
                    state.progress[name] = fraction
                    if abs(previous - fraction) >= 0.005 || fraction == 1 {
                        try persist(); try event("progress", fields: ["request": name, "fraction": fraction])
                    }
                case .inputComplete: try event("input-complete")
                case .requestComplete(let request, let result):
                    let name = requestName(request)
                    switch result {
                    case .poses(let poses):
                        try DesktopPhotogrammetryCalibration.writePoses(poses, items: prepared.items, to: directory.appendingPathComponent("cámaras.json"))
                        state.poseCount = poses.posesBySample.count; state.outputs[name] = "cámaras.json"
                    case .pointCloud(let points):
                        try DesktopPhotogrammetryCalibration.writePointCloud(points, to: directory.appendingPathComponent("puntos.ply"))
                        state.pointCount = points.points.count; state.outputs[name] = "puntos.ply"
                    case .bounds(let bounds):
                        try DesktopPhotogrammetryCalibration.writeBounds(bounds, to: directory.appendingPathComponent("bounds.json")); state.outputs[name] = "bounds.json"
                    case .modelFile(let url):
                        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.path,
                              (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0 > 0 else {
                            throw Failure(errorDescription: "Apple returned an empty model or a path outside the owned output")
                        }
                        state.outputs[name] = url.lastPathComponent
                    default: throw Failure(errorDescription: "Unexpected Apple output")
                    }
                    state.progress[name] = 1; try persist(); try log.synchronize(); try event("request-complete", fields: ["request": name, "file": state.outputs[name] ?? ""])
                case .invalidSample(let id, let reason): state.invalidSamples[String(id)] = reason; try persist(); try event("invalid-sample", fields: ["sampleID": id, "reason": reason])
                case .skippedSample(let id): state.skippedSamples.append(id); try persist(); try event("skipped-sample", fields: ["sampleID": id])
                case .automaticDownsampling: state.automaticDownsampling = true; try persist(); try event("apple-automatic-downsampling")
                case .requestError(let request, let error):
                    try event("request-error", fields: ["request": requestName(request), "error": error.localizedDescription]); throw error
                case .processingCancelled: throw CancellationError()
                case .processingComplete:
                    guard Set(state.outputs.keys) == Set(state.requests) else { throw Failure(errorDescription: "Apple completed without all requested outputs") }
                    state.phase = "completed"; try persist(); try event("completed", fields: ["poses": state.poseCount ?? 0, "points": state.pointCount ?? 0,
                        "seconds": Date().timeIntervalSince(state.startedAt)]); try log.synchronize(); return
                default: break
                }
            }
            throw Failure(errorDescription: "Apple output stream ended without processingComplete")
        } catch {
            session.cancel(); state.phase = error is CancellationError ? "cancelled" : "failed"; state.error = error.localizedDescription
            try? persist(); try? event("failed", fields: ["error": error.localizedDescription]); try? log.synchronize(); throw error
        }
    }
}
