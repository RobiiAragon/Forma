import Foundation
import CryptoKit
import SceneKit
import AppKit
import Metal
import simd

/// Bounded standalone validation using the production denoiser, never a substitute
/// model. Compile with ScanModels.swift, ProcessingControl.swift and
/// MeshPlanarDenoiser.swift using swiftc -O -parse-as-library.
@main
enum ValidatePlanarDenoising {
    struct Measurement: Codable {
        var label: String
        var sourcePath: String?
        var sourceSHA256Before: String?
        var sourceSHA256After: String?
        var inputBytes: Int?
        var verticesBefore: Int
        var verticesAfter: Int
        var trianglesBefore: Int
        var trianglesAfter: Int
        var indicesUnchanged: Bool
        var boundsBeforeMeters: [Float]
        var boundsAfterMeters: [Float]
        var metrics: MeshPlanarDenoiser.Metrics?
        var error: String?
        var renders: [String]
    }
    struct Report: Codable {
        var configuration: MeshPlanarDenoiser.Configuration
        var measurements: [Measurement]
        var limitations = [
            "The authored noisy plane demonstrates algorithm behavior; it is not a scan or physical accuracy measurement.",
            "Real mesh flatness is unknown. A rejected region is preserved; acceptance is not ground-truth certification.",
            "All before/after pairs use the same camera, lights, neutral material, resolution and unscaled meter coordinates.",
            "Timing measures this Mac, not iPhone throughput. No settings were relaxed to obtain a result."
        ]
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: validate-planar-denoising input-mesh.json output-directory"); return
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        guard output.path != source.path, !FileManager.default.fileExists(atPath: output.appendingPathComponent("planar-validation.json").path)
        else { throw NSError(domain: "Validation", code: 1) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var configuration = MeshPlanarDenoiser.Configuration(); configuration.enabled = true
        var measurements: [Measurement] = []
        let sourceData = try Data(contentsOf: source)
        let hash = digest(sourceData)
        let real = try JSONDecoder().decode(MeshSnapshot.self, from: sourceData)
        print("Real input: \(source.path), \(sourceData.count) bytes, \(real.vertexCount) vertices, \(real.faceCount) triangles")
        let realMeasurement = try measure(real, label: "real-room", source: source,
            sourceHash: hash, bytes: sourceData.count, configuration: configuration, output: output)
        measurements.append(realMeasurement)
        let fixture = noisyPlane()
        measurements.append(try measure(fixture, label: "authored-noisy-plane", source: nil,
            sourceHash: nil, bytes: nil, configuration: configuration, output: output))
        let report = Report(configuration: configuration, measurements: measurements)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output.appendingPathComponent("planar-validation.json"), options: .atomic)
        print(String(data: try encoder.encode(report), encoding: .utf8)!)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func measure(_ original: MeshSnapshot, label: String, source: URL?, sourceHash: String?, bytes: Int?,
                        configuration: MeshPlanarDenoiser.Configuration, output: URL) throws -> Measurement {
        var value = Measurement(label: label, sourcePath: source?.path, sourceSHA256Before: sourceHash,
            sourceSHA256After: nil, inputBytes: bytes, verticesBefore: original.vertexCount,
            verticesAfter: original.vertexCount, trianglesBefore: original.faceCount,
            trianglesAfter: original.faceCount, indicesUnchanged: true,
            boundsBeforeMeters: array(original.bounds), boundsAfterMeters: array(original.bounds), renders: [])
        do {
            let result = try MeshPlanarDenoiser.process(original, configuration: configuration)
            value.metrics = result.metrics
            value.verticesAfter = result.mesh.vertexCount
            value.trianglesAfter = result.mesh.faceCount
            value.indicesUnchanged = result.mesh.triangles == original.triangles
            value.boundsAfterMeters = array(result.mesh.bounds)
            if source == nil || result.metrics.acceptedRegions > 0 {
                // Camera and lighting are derived once from the ORIGINAL geometry.
                let setup = renderingSetup(original, isFixture: source == nil)
                for (suffix, mesh) in [("before", original), ("after", result.mesh)] {
                    let name = "\(label)-\(suffix).png"
                    try render(mesh, setup: setup, url: output.appendingPathComponent(name))
                    value.renders.append(name)
                }
            }
        } catch { value.error = String(describing: error) }
        if let source {
            value.sourceSHA256After = digest(try Data(contentsOf: source))
            guard value.sourceSHA256After == sourceHash else { throw NSError(domain: "SourceChanged", code: 1) }
        }
        return value
    }
    static func array(_ v: SIMD3<Float>) -> [Float] { [v.x,v.y,v.z] }
    static func noisyPlane() -> MeshSnapshot {
        var vertices: [SIMD3<Float>] = [], triangles: [UInt32] = []
        var random: UInt64 = 173
        for y in 0..<31 { for x in 0..<31 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Float((random >> 32) & 65535) / 65535 - 0.5) * 0.0016
            vertices.append(SIMD3(Float(x) * 0.04, Float(y) * 0.04, noise))
        } }
        for y in 0..<30 { for x in 0..<30 {
            let a = UInt32(y * 31 + x), b = a + 1, c = a + 31, d = c + 1
            triangles += [a,b,c,b,d,c]
        } }
        return MeshSnapshot(vertices: vertices, triangles: triangles)
    }
    struct Setup {
        var center: SCNVector3
        var camera: SCNVector3
        var light: SCNVector3
        var scale: Double
    }
    static func renderingSetup(_ mesh: MeshSnapshot, isFixture: Bool) -> Setup {
        var lo = mesh.vertices[0], hi = lo
        for p in mesh.vertices { lo = simd_min(lo,p); hi = simd_max(hi,p) }
        let center = (lo + hi) * 0.5, extent = Double(simd_length(hi-lo))
        if isFixture {
            return Setup(center: SCNVector3(center), camera: SCNVector3(0.6,-0.6,1.8),
                         light: SCNVector3(-1,-1,0.08), scale: 0.92)
        }
        return Setup(center: SCNVector3(center),
            camera: SCNVector3(center + SIMD3<Float>(0.8,0.6,1) * Float(extent)),
            light: SCNVector3(center + SIMD3<Float>(-1,1,0.5) * Float(extent)), scale: extent * 0.6)
    }
    static func render(_ mesh: MeshSnapshot, setup: Setup, url: URL) throws {
        var normals = Array(repeating: SIMD3<Float>.zero, count: mesh.vertexCount)
        for f in 0..<mesh.faceCount {
            let a = Int(mesh.triangles[f*3]), b = Int(mesh.triangles[f*3+1]), c = Int(mesh.triangles[f*3+2])
            let n = simd_cross(mesh.vertices[b]-mesh.vertices[a],mesh.vertices[c]-mesh.vertices[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        let vertexSource = SCNGeometrySource(vertices: mesh.vertices.map(SCNVector3.init))
        let normalSource = SCNGeometrySource(normals: normals.map { SCNVector3(simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0,0,1)) })
        let element = SCNGeometryElement(indices: mesh.triangles, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource,normalSource], elements: [element])
        let material = SCNMaterial(); material.diffuse.contents = NSColor(white: 0.65, alpha: 1)
        material.lightingModel = .lambert; material.isDoubleSided = true
        geometry.materials = [material]
        let scene = SCNScene(); scene.background.contents = NSColor(white: 0.13, alpha: 1)
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        let cameraNode = SCNNode(); cameraNode.camera = SCNCamera()
        cameraNode.camera!.usesOrthographicProjection = true
        cameraNode.camera!.orthographicScale = setup.scale
        cameraNode.camera!.zNear = 0.001; cameraNode.camera!.zFar = 1000
        cameraNode.camera!.wantsHDR = false
        cameraNode.position = setup.camera; cameraNode.look(at: setup.center)
        scene.rootNode.addChildNode(cameraNode)
        let light = SCNNode(); light.light = SCNLight(); light.light!.type = .directional
        light.light!.intensity = 1000; light.position = setup.light; light.look(at: setup.center)
        scene.rootNode.addChildNode(light)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient
        ambient.light!.intensity = 80; scene.rootNode.addChildNode(ambient)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene; renderer.pointOfView = cameraNode
        let snapshot = renderer.snapshot(atTime: 0, with: CGSize(width: 1600,height: 1200), antialiasingMode: .multisampling4X)
        guard let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Render", code: 1)
        }
        try data.write(to: url, options: .atomic)
    }
}
