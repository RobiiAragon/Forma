import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Standalone native driver. No app/library/model/UV modification.
@main struct RecoverPhotographicDetail {
    struct Failure: LocalizedError { var errorDescription: String? }
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure(errorDescription: "Cannot read native image: " + url.path)
        }
        return image
    }
    static func save(_ image: CGImage, _ url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(errorDescription: "Cannot create native PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(errorDescription: "PNG encoding failed") }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else { throw Failure(errorDescription: "Usage: recover_photographic_detail RAW PHOTO FRESH_OUTPUT [--software] [--mask MASK]") }
        var software = false, maskURL: URL?, index = 3
        while index < args.count {
            if args[index] == "--software" { software = true; index += 1 }
            else if args[index] == "--mask", index+1 < args.count { maskURL = URL(fileURLWithPath: args[index+1]); index += 2 }
            else { throw Failure(errorDescription: "Unknown or incomplete option: " + args[index]) }
        }
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure(errorDescription: "Fresh output required; earlier results were preserved") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rawURL = URL(fileURLWithPath: args[0]), photoURL = URL(fileURLWithPath: args[1])
        let raw = try load(rawURL), photo = try load(photoURL), mask = try maskURL.map(load)
        var configuration = PhotographicDetailRecovery.Configuration()
        configuration.backend = software ? .software : .automatic
        configuration.includeConfidenceImage = true
        print("started pid=\(ProcessInfo.processInfo.processIdentifier) width=\(raw.width) height=\(raw.height) backend=\(configuration.backend.rawValue)"); fflush(stdout)
        let result = try PhotographicDetailRecovery.recover(raw: raw, photograph: photo, supportMask: mask, configuration: configuration) { stage, fraction in
            print("\(stage) \(fraction)"); fflush(stdout)
        }
        try save(result.image, output.appendingPathComponent("texture.png"))
        if let confidence = result.confidenceImage { try save(confidence, output.appendingPathComponent("confidence.png")) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.statistics).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        print("completed seconds=\(result.statistics.elapsedSeconds) changed=\(result.statistics.changedPixels) outside=\(result.statistics.outsideMaskChangedPixels) boundary=\(result.statistics.externalSupportBoundaryChangedPixels)")
    }
}
