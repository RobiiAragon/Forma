import Foundation

/// Research entry point for the production baker. Uses the supplied mesh and
/// original calibrated photographs, writing only to a new output directory.
@main struct BakeMeshDataset {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3 else {
            throw NSError(domain: "Forma.BakeMesh", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: bake-mesh-dataset MESH_JSON DATASET NEW_OUTPUT"])
        }
        let meshURL = URL(fileURLWithPath: args[0])
        let dataset = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[2])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "Forma.BakeMesh", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "El resultado requiere una carpeta nueva."])
        }
        let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: meshURL))
        let frames = try RGBDDatasetManifest.load(from: dataset).frames
        let result = try LiDARTextureBaker.bake(mesh: mesh, keyframes: frames,
            datasetDirectory: dataset, outputDirectory: output)
        let metrics: [String: Any] = [
            "mesh": meshURL.path, "dataset": dataset.path, "output": output.path,
            "vertices": mesh.vertexCount, "faces": mesh.faceCount, "photographs": frames.count,
            "texturedFaces": result.texturedFaceCount, "unobservedFaces": result.unobservedFaceCount,
            "totalSeconds": result.totalSeconds, "selectionSeconds": result.selectionSeconds,
            "atlasPixels": result.atlasEncodedPixels, "atlasMaterials": result.atlasMaterialCount,
            "seamRMSEBefore": result.seamRMSEBefore, "seamRMSEAfter": result.seamRMSEAfter,
            "geometryChangedByBaker": false, "GPUUsed": false,
            "qualityClaim": "Requires inspection against the same source geometry and camera."
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("bake-metrics.json"), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
