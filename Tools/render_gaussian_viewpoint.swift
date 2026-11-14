import Foundation
import Metal
import CoreGraphics
import ImageIO
import CryptoKit
import simd

/// Offline research rendering. Its optional output resizing never changes model populations or app limits.
@main
struct GaussianViewpointRender {
    struct RenderError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }
    struct Options {
        var model: URL, dataset: URL, library: URL, output: URL
        var maxWidth: Int?
        var canvas: SIMD2<Int>?
        var compareRGB = false
        init() throws {
            var values: [String: String] = [:], flags: Set<String> = []
            let args = Array(CommandLine.arguments.dropFirst())
            var index = 0
            while index < args.count {
                let key = args[index]
                if key == "--compare-rgb" { flags.insert(key); index += 1; continue }
                guard ["--model", "--dataset", "--library", "--out", "--max-width", "--canvas"].contains(key),
                      index + 1 < args.count else { throw RenderError("Usage: render_gaussian_viewpoint.sh --model MODEL.ply --dataset DATASET --library default.metallib --out FOLDER [--max-width 1024] [--canvas WIDTHxHEIGHT] [--compare-rgb]") }
                values[key] = args[index + 1]; index += 2
            }
            func required(_ name: String) throws -> URL {
                guard let path = values[name], !path.isEmpty else { throw RenderError("Missing " + name) }
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            model = try required("--model"); dataset = try required("--dataset")
            library = try required("--library"); output = try required("--out")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: model.path, isDirectory: &isDirectory), isDirectory.boolValue {
                model.appendPathComponent("gaussianas.ply")
            }
            if let value = values["--max-width"] {
                guard let parsed = Int(value), parsed > 0 else { throw RenderError("--max-width must be a positive research output width") }
                maxWidth = parsed
            }
            if let value = values["--canvas"] {
                let dimensions = value.lowercased().split(separator: "x")
                guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]), width > 0, height > 0 else {
                    throw RenderError("--canvas must be WIDTHxHEIGHT")
                }
                canvas = SIMD2(width, height)
            }
            compareRGB = flags.contains("--compare-rgb")
            let destination = output.resolvingSymlinksInPath().path
            let sourceDataset = dataset.resolvingSymlinksInPath().path
            guard destination != sourceDataset, !destination.hasPrefix(sourceDataset + "/"),
                  destination != model.deletingLastPathComponent().resolvingSymlinksInPath().path else {
                throw RenderError("Research outputs must use a separate folder, outside original datasets/model packages")
            }
        }
    }
    struct Camera {
        var view: simd_float4x4
        var projection: simd_float4x4
        var viewport: SIMD4<Float>
        var eyeAndDegree: SIMD4<Float>
    }
    struct Raster {
        var width: Int, height: Int
        var rgba: [UInt8]
    }
    static let background = SIMD4<Double>(0.055, 0.06, 0.067, 1)

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try autoreleasepool(invoking: { try handle.read(upToCount: 1024 * 1024) }), !bytes.isEmpty { digest.update(data: bytes) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func matrix(_ value: simd_float4x4) -> [[Float]] {
        (0..<4).map { c in (0..<4).map { value[c][$0] } }
    }
    static func matrix(_ value: simd_float3x3) -> [[Float]] {
        (0..<3).map { c in (0..<3).map { value[c][$0] } }
    }
    static func commitAndWait(_ command: MTLCommandBuffer) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
    }
    static func sourceImage(_ url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
            throw RenderError("Could not decode the original sensor raster: " + url.path)
        }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError("Could not decode RGB pixels") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Raster(width: width, height: height, rgba: rgba)
    }
    static func image(_ raster: Raster) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(raster.rgba) as CFData),
              let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: raster.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw RenderError("Could not construct PNG pixels") }
        return image
    }
    static func writePNG(_ raster: Raster, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw RenderError("Could not open research PNG output")
        }
        CGImageDestinationAddImage(destination, try image(raster), nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError("Could not finalize PNG") }
    }
    static func rotated(_ source: Raster, turns: Int) -> Raster {
        var raster = source
        for _ in 0..<((turns % 4 + 4) % 4) {
            var output = Raster(width: raster.height, height: raster.width, rgba: [UInt8](repeating: 0, count: raster.rgba.count))
            for y in 0..<raster.height { for x in 0..<raster.width {
                let from = (y * raster.width + x) * 4
                let to = (x * output.width + raster.height - 1 - y) * 4
                for channel in 0..<4 { output.rgba[to + channel] = raster.rgba[from + channel] }
            } }
            raster = output
        }
        return raster
    }
    static func fitted(_ source: Raster, width: Int, height: Int,
                       projection: GaussianViewpoint.CalibratedProjection) throws -> Raster {
        var output = Raster(width: width, height: height, rgba: [UInt8](repeating: 0, count: width * height * 4))
        let sourceImage = try image(source)
        try output.rgba.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError("Could not resize reference RGB") }
            context.setFillColor(CGColor(red: background.x, green: background.y, blue: background.z, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(sourceImage, in: CGRect(x: Double(projection.viewportOrigin.x), y: Double(projection.viewportOrigin.y),
                width: Double(projection.viewportSize.x), height: Double(projection.viewportSize.y)))
        }
        return output
    }
    static func differences(_ render: Raster, _ reference: Raster, rect: MTLScissorRect) -> [String: Any] {
        var absolute = 0.0, squared = 0.0
        var count = 0
        for y in rect.y..<(rect.y + rect.height) { for x in rect.x..<(rect.x + rect.width) {
            let offset = (y * render.width + x) * 4
            for channel in 0..<3 {
                let delta = Double(render.rgba[offset + channel]) - Double(reference.rgba[offset + channel])
                absolute += abs(delta); squared += delta * delta; count += 1
            }
        } }
        return ["MAE_0_255": absolute / Double(count), "RMSE_0_255": sqrt(squared / Double(count)),
                "samplesRGBChannels": count, "comparedRectangle": [rect.x, rect.y, rect.width, rect.height],
                "interpretation": "Descriptive source RGB byte error after exact quarter-turn presentation and CoreGraphics aspect-fit resizing. No photometric alignment, held-out validation, metric-accuracy or Polycam superiority claim."]
    }
    static func statistics(_ raster: Raster, rect: MTLScissorRect) -> [String: Any] {
        var low = [255, 255, 255], high = [0, 0, 0], total = [Double](repeating: 0, count: 3), squares = total
        let count = Double(rect.width * rect.height)
        for y in rect.y..<(rect.y + rect.height) { for x in rect.x..<(rect.x + rect.width) {
            let offset = (y * raster.width + x) * 4
            for channel in 0..<3 {
                let value = Int(raster.rgba[offset + channel])
                low[channel] = min(low[channel], value); high[channel] = max(high[channel], value)
                total[channel] += Double(value); squares[channel] += Double(value * value)
            }
        } }
        let mean = total.map { $0 / count }
        let deviation = (0..<3).map { sqrt(max(0, squares[$0] / count - mean[$0] * mean[$0])) }
        return ["minRGB": low, "maxRGB": high, "meanRGB": mean, "standardDeviationRGB": deviation,
                "nearlyUniform": (0..<3).allSatisfy { high[$0] - low[$0] <= 1 }]
    }

    static func main() async throws {
        let options = try Options(), fm = FileManager.default
        let originalURLs = [options.model, options.dataset.appendingPathComponent("dataset.json"), options.library]
        var before = try Dictionary(uniqueKeysWithValues: originalURLs.map { ($0.path, try hash($0)) })
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw RenderError("Metal device/queue unavailable") }
        let library = try device.makeLibrary(URL: options.library)
        guard let vertex = library.makeFunction(name: "formaGaussianVertex"), let fragment = library.makeFunction(name: "formaGaussianFragment") else {
            throw RenderError("The supplied app default.metallib does not contain the Gaussian viewer shaders")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm; color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try await device.makeRenderPipelineState(descriptor: descriptor)
        let loadStarted = Date()
        let asset = try GaussianAsset.load(url: options.model)
        let views = try await GaussianViewpoint.load(fromDataset: options.dataset)
        guard !views.isEmpty, !asset.points.isEmpty else { throw RenderError("Model/dataset is empty") }
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        let pointBytes = asset.points.count * MemoryLayout<GaussianPoint>.stride
        let harmonicBytes = max(1, asset.harmonics.count) * MemoryLayout<SIMD4<Float>>.stride
        guard let points = asset.points.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: pointBytes, options: .storageModeShared) }) else { throw RenderError("Could not upload every Gaussian point") }
        let harmonics: MTLBuffer?
        if asset.harmonics.isEmpty { var zero = SIMD4<Float>.zero; harmonics = device.makeBuffer(bytes: &zero, length: harmonicBytes, options: .storageModeShared) }
        else { harmonics = asset.harmonics.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: harmonicBytes, options: .storageModeShared) } }
        guard let harmonics else { throw RenderError("Could not upload the complete SH coefficients") }
        try fm.createDirectory(at: options.output, withIntermediateDirectories: true)
        var evidence: [[String: Any]] = []
        let selected = Array(Set([0, views.count / 2, views.count - 1])).sorted()
        for index in selected {
            let native = views[index]
            guard !native.rgbFile.hasPrefix("/"), !native.rgbFile.contains("\\"), native.rgbFile.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw RenderError("Unsafe source RGB path") }
            let rgbURL = options.dataset.appendingPathComponent(native.rgbFile)
            before[rgbURL.path] = try hash(rgbURL)
            let source = options.compareRGB ? try sourceImage(rgbURL) : nil
            for presentation in ["native", "upright"] {
                let cameraView = try presentation == "native" ? native : native.uprightPresentation
                let width = options.canvas?.x ?? min(cameraView.imageWidth, options.maxWidth ?? cameraView.imageWidth)
                let height = options.canvas?.y ?? max(1, Int((Double(cameraView.imageHeight) * Double(width) / Double(cameraView.imageWidth)).rounded()))
                let near = max(Float(0.0000001), asset.radius * 0.00001), far = max(asset.radius * 100, asset.radius * 3.2 * 20)
                let calibrated = try cameraView.projection(viewport: SIMD2(Float(width), Float(height)), near: near, far: far)
                let origin = calibrated.viewportOrigin, size = calibrated.viewportSize
                let sx = max(0, Int(floor(origin.x))), sy = max(0, Int(floor(origin.y)))
                let scissor = MTLScissorRect(x: sx, y: sy, width: min(width - sx, Int(ceil(origin.x + size.x)) - sx),
                    height: min(height - sy, Int(ceil(origin.y + size.y)) - sy))
                let sortStarted = Date()
                let order = try GaussianDepthOrder.sortedIndices(points: asset.points, direction: cameraView.backward)
                guard order.count == asset.points.count,
                      let orderBuffer = order.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                    throw RenderError("Could not sort/draw the complete Gaussian population")
                }
                let sortSeconds = Date().timeIntervalSince(sortStarted)
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                textureDescriptor.storageMode = .private; textureDescriptor.usage = [.renderTarget, .shaderRead]
                let rowBytes = ((width * 4 + 255) / 256) * 256
                guard let target = device.makeTexture(descriptor: textureDescriptor),
                      let readback = device.makeBuffer(length: rowBytes * height, options: .storageModeShared),
                      let command = queue.makeCommandBuffer() else { throw RenderError("Could not allocate offline Metal target/readback") }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: background.x, green: background.y, blue: background.z, alpha: 1)
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError("Could not create render encoder") }
                encoder.setViewport(MTLViewport(originX: Double(origin.x), originY: Double(origin.y), width: Double(size.x), height: Double(size.y), znear: 0, zfar: 1))
                encoder.setScissorRect(scissor)
                var camera = Camera(view: cameraView.viewMatrix, projection: calibrated.matrix,
                    viewport: SIMD4(size.x, size.y, calibrated.focalPixels.x, calibrated.focalPixels.y),
                    eyeAndDegree: SIMD4(cameraView.position, Float(asset.harmonicDegree)))
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(points, offset: 0, index: 0)
                encoder.setVertexBuffer(orderBuffer, offset: 0, index: 1)
                encoder.setVertexBytes(&camera, length: MemoryLayout<Camera>.stride, index: 2)
                encoder.setVertexBuffer(harmonics, offset: 0, index: 3)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: asset.points.count)
                encoder.endEncoding()
                guard let blit = command.makeBlitCommandEncoder() else { throw RenderError("Could not create readback encoder") }
                blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: readback, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
                blit.endEncoding()
                let renderStarted = Date(); await commitAndWait(command)
                guard command.status == .completed else { throw RenderError("Metal render failed: " + (command.error?.localizedDescription ?? "unknown command error")) }
                let renderSeconds = Date().timeIntervalSince(renderStarted)
                var raster = Raster(width: width, height: height, rgba: [UInt8](repeating: 0, count: width * height * 4))
                let raw = readback.contents().assumingMemoryBound(to: UInt8.self)
                for y in 0..<height { for x in 0..<width {
                    let from = y * rowBytes + x * 4, to = (y * width + x) * 4
                    raster.rgba[to] = raw[from + 2]; raster.rgba[to + 1] = raw[from + 1]
                    raster.rgba[to + 2] = raw[from]; raster.rgba[to + 3] = raw[from + 3]
                } }
                let prefix = String(format: "%05d", index) + "-" + presentation
                let png = options.output.appendingPathComponent(prefix + ".png")
                try writePNG(raster, to: png)
                var item: [String: Any] = ["viewIndex": index, "sourceFrameIndex": cameraView.sourceFrameIndex,
                    "frameID": cameraView.frameID, "timestamp": cameraView.timestamp, "presentation": presentation, "presentationClockwiseQuarterTurns": cameraView.presentationQuarterTurns,
                    "sourceRGB": rgbURL.path, "sourceRGBSHA256": before[rgbURL.path]!, "nativeSensorSize": [native.imageWidth, native.imageHeight],
                    "presentedRasterSize": [cameraView.imageWidth, cameraView.imageHeight], "outputSize": [width, height],
                    "viewportOrigin": [origin.x, origin.y], "viewportSize": [size.x, size.y], "scissor": [sx, sy, scissor.width, scissor.height],
                    "focalPixels": [calibrated.focalPixels.x, calibrated.focalPixels.y], "near": near, "far": far,
                    "viewMatrixColumnMajor": matrix(cameraView.viewMatrix), "cameraToWorldColumnMajor": matrix(cameraView.cameraToWorld),
                    "intrinsicsColumnMajor": matrix(cameraView.intrinsics), "projectionColumnMajor": matrix(calibrated.matrix),
                    "drawnInstances": asset.points.count, "harmonicDegree": asset.harmonicDegree, "sortSeconds": sortSeconds,
                    "renderWaitSeconds": renderSeconds, "gpuSeconds": max(0, command.gpuEndTime - command.gpuStartTime),
                    "png": png.lastPathComponent, "pngSHA256": try hash(png), "renderRGBStatistics": statistics(raster, rect: scissor)]
                if let source {
                    guard source.width == native.imageWidth, source.height == native.imageHeight else { throw RenderError("RGB dimensions differ from saved calibration") }
                    let reference = try fitted(rotated(source, turns: cameraView.presentationQuarterTurns), width: width, height: height, projection: calibrated)
                    let referenceURL = options.output.appendingPathComponent(prefix + "-reference.png")
                    try writePNG(reference, to: referenceURL)
                    item["referencePNG"] = referenceURL.lastPathComponent
                    item["referencePNGSHA256"] = try hash(referenceURL)
                    item["sourceRGBComparison"] = differences(raster, reference, rect: scissor)
                }
                evidence.append(item)
                print("Rendered \(prefix): \(asset.points.count) points SH\(asset.harmonicDegree), \(width)x\(height), \(String(format: "%.3f", renderSeconds)) s")
            }
        }
        for (path, expected) in before { guard try hash(URL(fileURLWithPath: path)) == expected else { throw RenderError("Original source changed during research rendering: " + path) } }
        let report: [String: Any] = ["schemaVersion": 1, "tool": "offline production GaussianAsset + GaussianViewpoint + GaussianDepthOrder + supplied app Metal shaders",
            "platform": "macOS", "metalDevice": device.name, "model": options.model.path, "dataset": options.dataset.path, "library": options.library.path,
            "sourceSHA256": before, "sourceFilesUnchanged": true, "pointCount": asset.points.count, "harmonicDegree": asset.harmonicDegree,
            "SHFloat4Count": asset.harmonics.count, "cameraUniformStride": MemoryLayout<Camera>.stride, "allDatasetViewsValidated": views.count,
            "selectedViewIndices": selected, "loadSeconds": loadSeconds, "backgroundRGBA": [background.x, background.y, background.z, background.w],
            "maxWidthResearchOutputOnly": options.maxWidth as Any? ?? NSNull(), "fixedCanvasResearchOutputOnly": options.canvas.map { [$0.x, $0.y] } as Any? ?? NSNull(),
            "interpretation": "All Gaussians and SH bands retained. Optional resizing affects only these research PNGs. Source-RGB metrics describe these training observations; they do not establish held-out quality, physical accuracy or superiority to another app.", "renders": evidence]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: options.output.appendingPathComponent("render-report.json"), options: .atomic)
        print("Completed \(evidence.count) calibrated Metal outputs; all original model, dataset metadata, shader and sampled RGB SHA-256 hashes unchanged. Rendering completion does not certify visual quality.")
    }
}
