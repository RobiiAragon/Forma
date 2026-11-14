import Foundation
import CryptoKit
import simd

/// Standalone local geometry benchmark. Compile with the same MeshContinuity.swift
/// used by the app; no second implementation and no application binary involved.
/// From the repository root:
/// xcrun swiftc -O -parse-as-library Forma/Core/ScanModels.swift Forma/Core/MeshContinuity.swift Tools/MeshContinuityBenchmark.swift -o build/Research/mesh-continuity-benchmark
/// build/Research/mesh-continuity-benchmark /path/source.obj /path/NEW-output-directory
@main
enum MeshContinuityBenchmark {
    struct Report: Codable {
        var schemaVersion = 1
        var createdAtUTC: String
        var inputFile: String
        var inputSHA256: String
        var inputBytes: Int64
        var derivedFile: String
        var derivedSHA256: String
        var algorithm = "Forma MeshContinuity: conservative supported boundary stitching"
        var options: MeshContinuity.Options
        var metrics: MeshContinuity.Metrics
        var sourceUnchangedAfterProcessing: Bool
        var limitations = [
            "Meters are assumed from the source OBJ; no scale is fitted or certified.",
            "Connectivity and boundary-edge counts describe exported topology, not physical holes or accuracy.",
            "Only existing source positions are retained; all faces and their order/winding are preserved through index remapping.",
            "No hole filling, smoothing, subdivision, invented texture, component deletion or downsampling.",
            "Near-boundary stitching is an explicit geometric hypothesis, not evidence that two surfaces are physically connected.",
            "Processing seconds are measured on this Mac; they do not measure iPhone FPS or Polycam performance.",
            "This standalone tool accepts geometry-only triangular OBJ; the app pipeline must preserve/rebake calibrated textures separately."
        ]
    }

    enum ToolError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    static func main() {
        do { try run() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("Usage: mesh-continuity-benchmark input.obj NEW-output-directory\nCompile with ScanModels.swift and MeshContinuity.swift. Original input is never written.")
            return
        }
        guard arguments.count == 2 else { throw ToolError.message("Usage: mesh-continuity-benchmark input.obj NEW-output-directory") }
        let input = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ToolError.message("Choose a new output directory; an existing directory is never overwritten.") }
        let beforeHash = try digest(input)
        let mesh = try loadOBJ(input)
        let options = MeshContinuity.Options()
        let result = try MeshContinuity.process(mesh, options: options)
        guard result.mesh.faceCount == mesh.faceCount, result.mesh.triangles.count == mesh.triangles.count else {
            throw ToolError.message("Face preservation invariant failed; no derived model was written.")
        }
        let afterHash = try digest(input)
        guard beforeHash == afterHash else { throw ToolError.message("The input changed during analysis; no derived model was written.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let derived = output.appendingPathComponent("continuidad.obj")
        try writeOBJ(result.mesh, to: derived)
        let bytes = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let report = Report(createdAtUTC: ISO8601DateFormatter().string(from: Date()), inputFile: input.path,
            inputSHA256: beforeHash, inputBytes: Int64(bytes), derivedFile: derived.lastPathComponent,
            derivedSHA256: try digest(derived), options: options, metrics: result.metrics,
            sourceUnchangedAfterProcessing: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output.appendingPathComponent("continuidad.json"), options: .atomic)
        print(String(data: try encoder.encode(report), encoding: .utf8)!)
    }

    private static func loadOBJ(_ url: URL) throws -> MeshSnapshot {
        let text = try String(contentsOf: url, encoding: .utf8)
        var vertices: [SIMD3<Float>] = [], triangles: [UInt32] = []
        for (lineNumber, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let kind = tokens.first, !kind.hasPrefix("#") else { continue }
            switch kind {
            case "v":
                guard tokens.count == 4, let x = Float(tokens[1]), let y = Float(tokens[2]), let z = Float(tokens[3]), vertices.count < Int(UInt32.max) else {
                    throw ToolError.message("Unsupported or invalid vertex at line \(lineNumber + 1).")
                }
                vertices.append(SIMD3(x,y,z))
            case "f":
                guard tokens.count == 4 else { throw ToolError.message("Only existing triangular faces are supported; no triangulation at line \(lineNumber + 1).") }
                for token in tokens.dropFirst() {
                    guard !token.contains("/"), let value = Int(token), value != 0 else {
                        throw ToolError.message("This benchmark only accepts geometry-only OBJ indices; use the app for textured models.")
                    }
                    let index = value > 0 ? value - 1 : vertices.count + value
                    guard index >= 0, index < vertices.count else { throw ToolError.message("Invalid OBJ index at line \(lineNumber + 1).") }
                    triangles.append(UInt32(index))
                }
            case "vt", "vn", "mtllib", "usemtl":
                throw ToolError.message("This source has UV, normal or material records. The geometry-only benchmark refuses to strip them.")
            default: break
            }
        }
        return MeshSnapshot(vertices: vertices, triangles: triangles)
    }

    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeOBJ(_ mesh: MeshSnapshot, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = Data()
        func append(_ text: String) throws {
            buffer.append(contentsOf: text.utf8)
            if buffer.count >= 65536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        try append("# Forma derived continuity; meters assumed; all original faces retained; no filling, smoothing or texture.\n")
        for p in mesh.vertices { try append("v \(p.x) \(p.y) \(p.z)\n") }
        for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
            try append("f \(UInt64(mesh.triangles[i]) + 1) \(UInt64(mesh.triangles[i + 1]) + 1) \(UInt64(mesh.triangles[i + 2]) + 1)\n")
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }
}
