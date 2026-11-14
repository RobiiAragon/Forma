// Run with scripts/verify_local_ai.sh. Links the production engine and its real
// dependencies; there is no Core ML, file-store, or cancellation substitute here.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import FormaLocalAI

private struct VerificationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var failure: Error?
    private var lastFraction = 0.0
    func once() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !requested else { return false }
        requested = true; return true
    }
    func put(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
    func error() -> Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func recordProgress(_ fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        if !fraction.isFinite || fraction < lastFraction || fraction < 0 || fraction > 1 {
            failure = VerificationFailure(message: "Non-monotonic or non-finite progress: \(fraction)")
        }
        lastFraction = fraction
    }
}

private struct Raster {
    let width: Int, height: Int
    var bytes: [UInt8]
    static let color = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width; self.height = height; self.bytes = bytes
    }
    init(url: URL, centerCrop: Int? = nil) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VerificationFailure(message: "Cannot decode \(url.path)")
        }
        if let side = centerCrop {
            guard image.width >= side, image.height >= side,
                  let cropped = image.cropping(to: CGRect(x: (image.width - side) / 2,
                    y: (image.height - side) / 2, width: side, height: side)) else {
                throw VerificationFailure(message: "Photo must contain a native \(side)×\(side) crop; no resizing is performed")
            }
            image = cropped
        }
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: Self.color,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw VerificationFailure(message: "Cannot allocate sRGB raster")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    func write(to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: Self.color,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                UTType.png.identifier as CFString, 1, nil) else {
            throw VerificationFailure(message: "Cannot create PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try Verification.check(CGImageDestinationFinalize(destination), "PNG encoding failed")
    }
    func equalPixel(_ other: Self, x: Int, y: Int) -> Bool {
        let i = (y * width + x) * 4
        return bytes[i..<(i + 4)].elementsEqual(other.bytes[i..<(i + 4)])
    }
}

@main private struct Verification {
    static let fm = FileManager.default
    static let header = "mtllib modelo.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\n"
    static let fullUV = header + "vt 0 0\nvt 1 0\nvt 0 1\nvt 1 1\nusemtl surface\nf 1/1 2/2 3/3\nf 2/2 4/4 3/3\n"

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationFailure(message: message) }
    }
    static func json<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func stats(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }
    static func snapshot(_ folder: URL) throws -> [String: String] {
        guard let iterator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw VerificationFailure(message: "Cannot enumerate source")
        }
        var hashes: [String: String] = [:]
        for case let file as URL in iterator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                hashes[String(file.path.dropFirst(folder.path.count + 1))] = try IntegrityManifest.digest(file)
            }
        }
        return hashes
    }
    static func makePackage(_ path: URL, image: Raster, obj: String = fullUV) throws {
        try fm.createDirectory(at: path, withIntermediateDirectories: true)
        try image.write(to: path.appendingPathComponent("atlas.png"))
        try obj.write(to: path.appendingPathComponent("modelo.obj"), atomically: true, encoding: .utf8)
        try "newmtl surface\nmap_Kd atlas.png\n".write(to: path.appendingPathComponent("modelo.mtl"), atomically: true, encoding: .utf8)
    }
    static func geometryExact(input: URL, output: URL) throws {
        for name in ["modelo.obj", "modelo.mtl"] {
            try check(try IntegrityManifest.digest(input.appendingPathComponent(name)) == IntegrityManifest.digest(output.appendingPathComponent(name)), "Geometry/UV/MTL bytes changed: \(name)")
        }
    }
    static func synthetic() -> Raster {
        let side = 522
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side { for x in 0..<side {
            let i = (y * side + x) * 4
            bytes[i] = UInt8(50 + ((x / 3 + y / 3) % 2) * 90)
            bytes[i + 1] = UInt8(40 + (y * 120 / side))
            bytes[i + 2] = UInt8(30 + (x * 80 / side))
        } }
        return Raster(width: side, height: side, bytes: bytes)
    }
    static func runPackage(input: URL, output: URL, model: URL, strength: Double) throws -> LocalAITextureEnhancer.Report {
        let report = try LocalAITextureEnhancer.run(package: input, output: output, modelURL: model, strength: strength) { title, fraction in
            print(String(format: "%.1f%% %@", fraction * 100, title)); fflush(stdout)
        }
        let encoded = try JSONEncoder().encode(report)
        print("REPORT " + String(decoding: encoded, as: UTF8.self))
        return report
    }
    static func cropTest(root: URL, model: URL, photo: URL?) throws -> [String: Any] {
        let input = root.appendingPathComponent("crop-input"), output = root.appendingPathComponent("crop-derived")
        let image = try photo.map { try Raster(url: $0, centerCrop: 522) } ?? synthetic()
        try makePackage(input, image: image)
        let unused = "fuentes/images/not-referenced.png"
        try fm.createDirectory(at: input.appendingPathComponent("fuentes/images"), withIntermediateDirectories: true)
        try synthetic().write(to: input.appendingPathComponent(unused))
        let beforeHashes = try snapshot(input)
        let report = try LocalAITextureEnhancer.run(package: input, output: output, modelURL: model, strength: 0.5)
        let before = try Raster(url: input.appendingPathComponent("atlas.png")), after = try Raster(url: output.appendingPathComponent("atlas.png"))
        try check(after.width == before.width && after.height == before.height, "Native dimensions changed")
        var protected = 0, changed = 0; var squared = 0.0
        for y in 0..<522 { for x in 0..<522 {
            let same = before.equalPixel(after, x: x, y: y)
            if !same { changed += 1 }
            if x < 2 || y < 2 || x >= 520 || y >= 520 {
                try check(same, "Protected full-UV boundary changed"); protected += 1
            }
            let offset = (y * 522 + x) * 4
            for c in 0..<3 { let d = Double(before.bytes[offset + c]) - Double(after.bytes[offset + c]); squared += d * d }
        } }
        try check(changed > 0 && report.inferenceTileCount > 0, "No real inference/change on crop")
        try check(try snapshot(input) == beforeHashes, "Crop source files changed")
        try check(try IntegrityManifest.digest(output.appendingPathComponent(unused)) == beforeHashes[unused], "Unreferenced source photograph changed")
        try check(report.processedTextureCount == 1 && report.totalTexturePixels == 522 * 522, "Engine processed unreferenced source photos")
        try geometryExact(input: input, output: output)
        try json(report, to: root.appendingPathComponent("crop-report.json"))
        print("PASS native crop; geometry/UV/MTL, source hashes, dimensions and boundary exact")
        return ["kind": photo == nil ? "synthetic" : "native photo center crop",
                "changedPixels": changed, "protectedBoundaryPixelsExact": protected,
                "unreferencedSourceCopiedExactly": true,
                "rgbRMSEAgainstInput_NotQualityScore": sqrt(squared / Double(522 * 522 * 3))]
    }
    static func islandTest(root: URL, model: URL) throws -> [String: Any] {
        let w = 320, h = 180
        func make(_ name: String, blue: Bool) throws -> URL {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4; bytes[i + 3] = 255
                if (20..<148).contains(x) && (20..<160).contains(y) {
                    bytes[i] = UInt8(170 + ((x / 4 + y / 4) % 2) * 30); bytes[i + 1] = 30; bytes[i + 2] = 20
                }
                if (152..<300).contains(x) && (20..<160).contains(y) { bytes[i + 1] = blue ? 0 : 220; bytes[i + 2] = blue ? 220 : 0 }
            } }
            var obj = header
            for (left, right) in [(20.0, 148.0), (152.0, 300.0)] {
                for (x, y) in [(left, 160.0), (right, 160.0), (left, 20.0), (right, 20.0)] {
                    obj += "vt \(x / Double(w)) \(1 - y / Double(h))\n"
                }
            }
            obj += "usemtl surface\nf 1/1 2/2 3/3\nf 2/2 4/4 3/3\nf 1/5 2/6 3/7\nf 2/6 4/8 3/7\n"
            let path = root.appendingPathComponent(name)
            try makePackage(path, image: Raster(width: w, height: h, bytes: bytes), obj: obj)
            return path
        }
        let green = try make("islands-green", blue: false), blue = try make("islands-blue", blue: true)
        let gh = try snapshot(green), bh = try snapshot(blue)
        let ga = root.appendingPathComponent("islands-green-derived"), ba = root.appendingPathComponent("islands-blue-derived")
        let report = try LocalAITextureEnhancer.run(package: green, output: ga, modelURL: model, strength: 0.5)
        _ = try LocalAITextureEnhancer.run(package: blue, output: ba, modelURL: model, strength: 0.5)
        try check(report.islandCount == 2 && report.isolatedPatchCount == 2 && report.inferenceTileCount == 1, "Two islands did not pack independently into one prediction")
        let a = try Raster(url: ga.appendingPathComponent("atlas.png")), b = try Raster(url: ba.appendingPathComponent("atlas.png")), original = try Raster(url: green.appendingPathComponent("atlas.png"))
        var redChanged = 0, protected = 0
        for y in 0..<h { for x in 0..<w {
            if (20..<148).contains(x) && (20..<160).contains(y) {
                try check(a.equalPixel(b, x: x, y: y), "Changing adjacent green island to blue contaminated red island")
                if !a.equalPixel(original, x: x, y: y) { redChanged += 1 }
            }
            let left = (22..<146).contains(x) && (22..<158).contains(y)
            let right = (154..<298).contains(x) && (22..<158).contains(y)
            if !left && !right {
                try check(a.equalPixel(original, x: x, y: y), "Gutter/protected two-pixel island boundary changed")
                protected += 1
            }
        } }
        try check(redChanged > 0, "Red island was never processed")
        try check(try snapshot(green) == gh && snapshot(blue) == bh, "Island source bytes changed")
        try geometryExact(input: green, output: ga); try geometryExact(input: blue, output: ba)
        try json(report, to: root.appendingPathComponent("islands-report.json"))
        print("PASS two islands; neighbor perturbation max difference 0; real changes \(redChanged)")
        return ["islands": report.islandCount, "isolatedPatches": report.isolatedPatchCount,
                "inferenceTiles": report.inferenceTileCount, "observedUVPixels": report.observedUVPixels,
                "eligiblePixels": report.eligiblePixels, "redChangedPixels": redChanged,
                "protectedPixelsExact": protected, "neighborPerturbationRedMaxDifference": 0]
    }
    static func edgeAndControlTests(root: URL, model: URL, photo: URL?) throws -> [String: Any] {
        var image = try photo.map { try Raster(url: $0, centerCrop: 522) } ?? synthetic()
        for y in 70..<110 { for x in 70..<110 {
            let i = (y * 522 + x) * 4
            image.bytes[i] = 64; image.bytes[i + 1] = 32; image.bytes[i + 2] = 16; image.bytes[i + 3] = 128
        } }
        let obj = header + "vt 0 0.5\nvt 1 0.5\nvt 0 1\nvt 1 1\nusemtl surface\nf 1/1 2/2 3/3\nf 2/2 4/4 3/3\n"
        let input = root.appendingPathComponent("edge-input"), output = root.appendingPathComponent("edge-derived")
        try makePackage(input, image: image, obj: obj)
        let hashes = try snapshot(input)
        let report = try LocalAITextureEnhancer.run(package: input, output: output, modelURL: model, strength: 0.5)
        let before = try Raster(url: input.appendingPathComponent("atlas.png")), after = try Raster(url: output.appendingPathComponent("atlas.png"))
        var top = 0, bottom = 0, alpha = 0
        for y in 0..<522 { for x in 0..<522 {
            if !before.equalPixel(after, x: x, y: y) { if y < 261 { top += 1 } else { bottom += 1 } }
            if before.bytes[(y * 522 + x) * 4 + 3] != 255 {
                try check(before.equalPixel(after, x: x, y: y), "Semi-transparent texel channels changed"); alpha += 1
            }
        } }
        try check(top > 0 && bottom == 0 && alpha == 1600, "Asymmetric top-half UV/alpha protection failed")
        try check(report.inferenceTileCount > 1, "Control fixture needs multiple real predictions")
        let cancel = ProcessingControl(), cancelled = root.appendingPathComponent("cancelled")
        let namesBefore = Set(try fm.contentsOfDirectory(atPath: root.path))
        do {
            _ = try LocalAITextureEnhancer.run(package: input, output: cancelled, modelURL: model, strength: 0.5, control: cancel) { _, p in
                if p > 0 && p < 1 { cancel.cancel() }
            }
            throw VerificationFailure(message: "Cancellation was ignored")
        } catch is CancellationError { }
        try check(!fm.fileExists(atPath: cancelled.path), "Cancelled result published")
        let namesAfter = Set(try fm.contentsOfDirectory(atPath: root.path))
        try check(namesAfter == namesBefore, "Cancellation leaked staging files")
        let paused = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let box = LockedResult(), control = ProcessingControl { if $0.phase == .paused { paused.signal() } }
        let resumed = root.appendingPathComponent("resumed")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try LocalAITextureEnhancer.run(package: input, output: resumed, modelURL: model, strength: 0.5, control: control) { _, p in
                    box.recordProgress(p)
                    if p > 0 && p < 1 && box.once() { control.requestPause() }
                }
            } catch { box.put(error) }
            done.signal()
        }
        guard paused.wait(timeout: .now() + 120) == .success else {
            control.cancel(); throw VerificationFailure(message: "Pause not acknowledged at a safe checkpoint")
        }
        try check(!fm.fileExists(atPath: resumed.path), "Paused work published prematurely")
        control.resume()
        guard done.wait(timeout: .now() + 120) == .success else {
            control.cancel(); throw VerificationFailure(message: "Resume did not finish")
        }
        if let error = box.error() { throw error }
        try check(fm.fileExists(atPath: resumed.path), "Resumed result missing")

        let cancelPaused = DispatchSemaphore(value: 0), cancelDone = DispatchSemaphore(value: 0)
        let pausedBox = LockedResult(), pausedCancel = ProcessingControl { if $0.phase == .paused { cancelPaused.signal() } }
        let cancelledFromPause = root.appendingPathComponent("cancelled-from-pause")
        let beforePausedCancel = Set(try fm.contentsOfDirectory(atPath: root.path))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try LocalAITextureEnhancer.run(package: input, output: cancelledFromPause,
                    modelURL: model, strength: 0.5, control: pausedCancel) { _, p in
                    if p > 0 && p < 1 && pausedBox.once() { pausedCancel.requestPause() }
                }
                pausedBox.put(VerificationFailure(message: "Cancel while paused was ignored"))
            } catch is CancellationError { } catch { pausedBox.put(error) }
            cancelDone.signal()
        }
        guard cancelPaused.wait(timeout: .now() + 120) == .success else {
            pausedCancel.cancel(); throw VerificationFailure(message: "Second pause was not acknowledged")
        }
        pausedCancel.cancel()
        try check(cancelDone.wait(timeout: .now() + 120) == .success, "Cancellation did not wake paused worker")
        if let error = pausedBox.error() { throw error }
        try check(Set(try fm.contentsOfDirectory(atPath: root.path)) == beforePausedCancel,
                  "Cancellation while paused published or leaked staging")
        try check(try snapshot(input) == hashes, "Pause/cancel/asymmetry changed source files")
        try geometryExact(input: input, output: output); try geometryExact(input: input, output: resumed)
        try json(report, to: root.appendingPathComponent("edges-report.json"))
        print("PASS asymmetric UV top \(top)/bottom \(bottom), alpha \(alpha), cancellation, staging cleanup, pause/resume, cancel while paused, monotonic progress")
        return ["topChangedPixels": top, "bottomChangedPixels": bottom,
                "semiTransparentPixelsExact": alpha, "eligiblePixels": report.eligiblePixels,
                "cancelledUnpublished": true, "cancelledStagingRemoved": true,
                "pauseAcknowledged": true, "resumeCompleted": true, "monotonicProgress": true,
                "cancelWhilePausedWokeAndUnpublished": true,
                "sourceHashesUnchanged": true]
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 4, args[0] == "run" || args[0] == "test" else {
            print("Usage:\n  verify-local-ai run PACKAGE NEW_OUTPUT MODEL [STRENGTH]\n  verify-local-ai test NEW_OUTPUT MODEL PHOTO_OR_- [REAL_PACKAGE]\nUse '-' for a synthetic native 522px photo. Output must not exist. No download or library changes.")
            throw VerificationFailure(message: "Invalid arguments")
        }
        if args[0] == "run" {
            let strength = args.count > 4 ? Double(args[4]) ?? .nan : 0.5
            _ = try runPackage(input: URL(fileURLWithPath: args[1]), output: URL(fileURLWithPath: args[2]),
                               model: URL(fileURLWithPath: args[3]), strength: strength)
        } else {
            let root = URL(fileURLWithPath: args[1]).standardizedFileURL
            try check(!fm.fileExists(atPath: root.path), "Test output already exists; choose a new directory")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let model = URL(fileURLWithPath: args[2]), photo = args[3] == "-" ? nil : URL(fileURLWithPath: args[3])
            var summary: [String: Any] = ["crop": try cropTest(root: root, model: model, photo: photo),
                "twoIslands": try islandTest(root: root, model: model),
                "asymmetryAlphaPauseCancel": try edgeAndControlTests(root: root, model: model, photo: photo)]
            if args.count > 4 {
                let source = URL(fileURLWithPath: args[4]), before = try snapshot(source)
                let report = try runPackage(input: source, output: root.appendingPathComponent("real-package-derived"), model: model, strength: 0.5)
                try check(try snapshot(source) == before, "Real-package source hashes changed")
                try geometryExact(input: source, output: root.appendingPathComponent("real-package-derived"))
                try json(report, to: root.appendingPathComponent("real-package-report.json"))
                summary["realPackageSourceUnchanged"] = true
            }
            try stats(summary, to: root.appendingPathComponent("verification.json"))
            print("PASS all verification cases; results at \(root.path)")
        }
    }
}
