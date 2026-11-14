import Foundation
import RealityKit
import ModelIO

/// Inputs to Apple's reconstruction, independent of output mesh/texture budgets.
/// More sensitive matching or a larger output is not an accuracy measurement.
struct PhotogrammetryQualityOptions: Equatable, Sendable {
    var highSensitivity = false
    var objectMasking = true
    var sequentialOrdering = true

    var checkpointKey: String {
        "s\(highSensitivity ? 1 : 0)-m\(objectMasking ? 1 : 0)-o\(sequentialOrdering ? 1 : 0)"
    }

    var summary: String {
        "sensibilidad \(highSensitivity ? "alta" : "normal"), máscara \(objectMasking ? "activada" : "desactivada"), orden \(sequentialOrdering ? "secuencial" : "sin ordenar")"
    }

    var statistics: [String: Double] {
        ["photogrammetryHighSensitivity": highSensitivity ? 1 : 0,
         "photogrammetryObjectMasking": objectMasking ? 1 : 0,
         "photogrammetrySequentialOrdering": sequentialOrdering ? 1 : 0]
    }

    func apply(to configuration: inout PhotogrammetrySession.Configuration) {
        configuration.featureSensitivity = highSensitivity ? .high : .normal
        configuration.isObjectMaskingEnabled = objectMasking
        configuration.sampleOrdering = sequentialOrdering ? .sequential : .unordered
    }

    /// Inspect exported geometry; never infer effective counts from requested budgets.
    static func geometryCounts(at url: URL) -> ModelGeometryCounts? {
        autoreleasepool {
            let asset = MDLAsset(url: url)
            var vertices = 0, faces = 0
            var triangulated = true
            func visit(_ object: MDLObject) {
                if let mesh = object as? MDLMesh {
                    vertices += mesh.vertexCount
                    for submesh in mesh.submeshes as? [MDLSubmesh] ?? [] {
                        guard submesh.geometryType == .triangles, submesh.indexCount % 3 == 0 else {
                            triangulated = false; continue
                        }
                        faces += submesh.indexCount / 3
                    }
                }
                for child in object.children.objects { visit(child) }
            }
            for index in 0..<asset.count { visit(asset.object(at: index)) }
            guard triangulated, vertices > 0, faces > 0 else { return nil }
            return ModelGeometryCounts(vertexCount: vertices, faceCount: faces)
        }
    }
}
