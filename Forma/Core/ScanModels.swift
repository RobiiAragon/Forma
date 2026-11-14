import Foundation
import simd

enum ScanMode: String, Codable, CaseIterable, Identifiable {
    case lidar, object, room
    var id: String { rawValue }
    var title: String {
        switch self { case .lidar: return "Espacios"; case .object: return "Objetos"; case .room: return "Planos" }
    }
    var symbol: String {
        switch self { case .lidar: return "viewfinder"; case .object: return "cube.transparent"; case .room: return "square.split.bottomrightquarter" }
    }
    var subtitle: String {
        switch self { case .lidar: return "LiDAR + textura fotográfica"; case .object: return "Fotogrametría local"; case .room: return "Habitaciones con RoomPlan" }
    }
}

struct MeshSnapshot: Codable, Sendable {
    var vertices: [SIMD3<Float>]
    var triangles: [UInt32]
    var vertexCount: Int { vertices.count }
    var faceCount: Int { triangles.count / 3 }
    var bounds: SIMD3<Float> {
        guard let first = vertices.first else { return .zero }
        var lo = first, hi = first
        for v in vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        return hi - lo
    }
    var surfaceArea: Float {
        var area: Float = 0
        for i in stride(from: 0, to: triangles.count - triangles.count % 3, by: 3) {
            let a = Int(triangles[i]), b = Int(triangles[i+1]), c = Int(triangles[i+2])
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
            area += simd_length(simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])) * 0.5
        }
        return area
    }
}

struct HybridResultProvenance: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var jobID: UUID
    var resultID: UUID
    var manifestSHA256: String
    var sourceScanID: UUID?
}

struct ModelGeometryCounts: Sendable {
    var vertexCount: Int
    var faceCount: Int
}

struct CaptureResult: Sendable {
    let id = UUID()
    var mesh: MeshSnapshot?
    var modelURL: URL?
    var auxiliaryURLs: [URL] = []
    var mode: ScanMode
    var duration: TimeInterval
    var isDemo: Bool = false
    var note: String = ""
    /// Owned workspace, removed only after a successful library commit.
    var cleanupDirectory: URL? = nil
    var modelPackageURL: URL? = nil
    var captureDatasetURL: URL? = nil
    var gaussianModelRelativePath: String? = nil
    var statistics: [String: Double]? = nil
    var sourceScanID: UUID? = nil
    var hybridResultProvenance: HybridResultProvenance? = nil
    /// Draw geometry counts when the native package has no MeshSnapshot.
    var modelGeometryCounts: ModelGeometryCounts? = nil
}

struct ScanRecord: Codable, Identifiable {
    var id: UUID
    var name: String
    var mode: ScanMode
    var createdAt: Date
    var vertexCount: Int
    var faceCount: Int
    var duration: TimeInterval
    var isDemo: Bool
    var note: String
    var modelFile: String?
    var exports: [String]
    var datasetDirectory: String? = nil
    var gaussianModelFile: String? = nil
    var statistics: [String: Double]? = nil
    var sourceScanID: UUID? = nil
    var hybridResultProvenance: HybridResultProvenance? = nil
}
