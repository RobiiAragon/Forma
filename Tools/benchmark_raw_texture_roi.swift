import Foundation
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// One genuine Raw-atlas tile, with GPU explicitly excluded. Research only.
#if !FORMA_RAW_TEXTURE_COMPUTE_COMPARISON
@main
#endif
struct RawTextureROIBenchmark {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static func sha(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var h = SHA256()
        while let d = try file.read(upToCount: 1024 * 1024), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func png(_ rgba: [UInt8], width: Int, height: Int, url: URL) throws {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(errorDescription: "Cannot encode ROI output")
        }
        CGImageDestinationAddImage(dest, image, nil)
        try require(CGImageDestinationFinalize(dest), "Cannot finish ROI PNG")
    }
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw Failure(errorDescription: "Usage: MODEL_MLPACKAGE ROI_522_PNG FRESH_OUTPUT") }
        let sourceModel = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let roi = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let out = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: out.path), "Use a fresh owned output directory")
        try fm.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let before = try sha(roi)
        guard let imageSource = CGImageSourceCreateWithURL(roi as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw Failure(errorDescription: "Cannot decode genuine Raw ROI") }
        let side = 522, scale = 4, large = side * scale
        try require(image.width == side && image.height == side, "Input must be a native 522x522 crop, without resizing")
        var rgba = [UInt8](repeating: 255, count: side*side*4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(errorDescription: "Cannot decode ROI raster") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        try png(rgba, width: side, height: side, url: out.appendingPathComponent("original.png"))
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let stride = input.strides.map(\.intValue), pointer = input.dataPointer.assumingMemoryBound(to: Float.self)
        for c in 0..<3 { for y in 0..<side { for x in 0..<side {
            pointer[c*stride[1]+y*stride[2]+x*stride[3]] = Float(rgba[(y*side+x)*4+c])/255
        } } }
        let modelCopy = out.appendingPathComponent("owned-model.mlpackage", isDirectory: true)
        try fm.copyItem(at: sourceModel, to: modelCopy)
        let compileAt = ProcessInfo.processInfo.systemUptime
        let compiledTemp = try MLModel.compileModel(at: modelCopy)
        let compiled = out.appendingPathComponent("compiled.mlmodelc", isDirectory: true)
        try fm.moveItem(at: compiledTemp, to: compiled)
        let compileSeconds = ProcessInfo.processInfo.systemUptime-compileAt
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
        let loadAt = ProcessInfo.processInfo.systemUptime
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let loadSeconds = ProcessInfo.processInfo.systemUptime-loadAt
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first,
              let outputName = model.modelDescription.outputDescriptionsByName.keys.first else { throw Failure(errorDescription: "Invalid model features") }
        try require(model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint?.shape.map(\.intValue) == [1,3,side,side], "Expected RGB NCHW522 model")
        let at = ProcessInfo.processInfo.systemUptime
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: input]))
        let predictionSeconds = ProcessInfo.processInfo.systemUptime-at
        print(String(format: "INFERENCE_CPU_NE_SECONDS %.6f", predictionSeconds)); fflush(stdout)
        guard let result = prediction.featureValue(for: outputName)?.multiArrayValue else { throw Failure(errorDescription: "Missing model output") }
        try require(result.shape.map(\.intValue) == [1,3,large,large], "Expected RGB output2088")
        let s = result.strides.map(\.intValue)
        func sample(_ c: Int, _ x: Int, _ y: Int) -> Float {
            let i = c*s[1]+y*s[2]+x*s[3]
            switch result.dataType {
            case .float32: return result.dataPointer.assumingMemoryBound(to: Float.self)[i]
            case .float16: return Float(result.dataPointer.assumingMemoryBound(to: Float16.self)[i])
            case .double: return Float(result.dataPointer.assumingMemoryBound(to: Double.self)[i])
            default: return .nan
            }
        }
        var restored = rgba, high = [UInt8](repeating: 255, count: large*large*4)
        var outputMinimum = Float.infinity, outputMaximum = -Float.infinity
        for y in 0..<side { for x in 0..<side { for c in 0..<3 {
            var sum: Float = 0
            for dy in 0..<scale { for dx in 0..<scale {
                let xx=x*scale+dx, yy=y*scale+dy, v=sample(c,xx,yy)
                try require(v.isFinite, "CoreML produced nonfinite color")
                sum += v; outputMinimum=min(outputMinimum,v); outputMaximum=max(outputMaximum,v)
                high[(yy*large+xx)*4+c] = UInt8(max(0,min(255,(v*255).rounded())))
            } }
            restored[(y*side+x)*4+c] = UInt8(max(0,min(255,(sum/16*255).rounded())))
        } } }
        try png(high, width: large, height: large, url: out.appendingPathComponent("model-output-4x-debug.png"))
        try png(restored, width: side, height: side, url: out.appendingPathComponent("restored-area4-native.png"))
        var reports: [[String: Any]] = []
        for strength in [0.35,0.65] {
            var mixed=rgba; var absolute=0.0, squared=0.0, maximum=0, changed=0
            for p in 0..<(side*side) {
                var different=false
                for c in 0..<3 {
                    let i=p*4+c, old=Double(rgba[i]), new=old+strength*(Double(restored[i])-old)
                    mixed[i]=UInt8(max(0,min(255,new.rounded())))
                    let d=abs(Int(mixed[i])-Int(rgba[i])); absolute += Double(d); squared += Double(d*d); maximum=max(maximum,d)
                    different = different || d != 0
                }
                if different { changed += 1 }
            }
            let name=String(format:"strength-%.2f.png",strength)
            try png(mixed, width: side, height: side, url: out.appendingPathComponent(name))
            reports.append(["strength":strength,"path":name,"MAE_8bit":absolute/Double(side*side*3),
                "RMSE_8bit":sqrt(squared/Double(side*side*3)),"maximumChange8bit":maximum,"changedPixels":changed])
        }
        try require(try sha(roi) == before, "Input ROI changed")
        let report: [String: Any] = ["computeUnitsRequested":"cpuAndNeuralEngine","gpuAllowed":false,
            "actualLayerDeviceNotAsserted":true,"predictionCount":1,"predictionSeconds":predictionSeconds,
            "compileSeconds":compileSeconds,"loadSeconds":loadSeconds,"inputShape":[1,3,side,side],
            "outputShape":[1,3,large,large],"inputNormalization":"RGB sRGB encoded values /255",
            "nativeReduction":"Exact arithmetic area average of each 4x4 output block, then clamp/round RGB8",
            "outputRangeBeforeClamp":[outputMinimum,outputMaximum],"blends":reports,
            "roiInputSHA256":before,"roiInputUnchanged":true,"additionalPatchesAttempted":false,
            "oneTileOver60Seconds":predictionSeconds>60,"trueDetailRecoveryNotAsserted":true,
            "modelSource":sourceModel.path,"roiSource":roi.path]
        try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("report.json"),options:.atomic)
        print("ROI_REPORT "+out.appendingPathComponent("report.json").path)
    }
}
