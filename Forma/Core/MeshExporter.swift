import Foundation
import simd
import CryptoKit

enum MeshExportError: LocalizedError {
    case empty, invalidIndex, invalidCoordinate
    var errorDescription: String? {
        switch self {
        case .empty: return "La captura no contiene geometría. Escanea una superficie antes de guardar."
        case .invalidIndex: return "La malla contiene un índice inválido. No se ha guardado un archivo incompleto."
        case .invalidCoordinate: return "La malla contiene coordenadas no válidas. Repite la captura."
        }
    }
}

enum MeshExporter {
    static func validate(_ mesh: MeshSnapshot) throws {
        guard !mesh.vertices.isEmpty, !mesh.triangles.isEmpty else { throw MeshExportError.empty }
        guard mesh.triangles.count.isMultiple(of: 3), mesh.triangles.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            throw MeshExportError.invalidIndex
        }
        guard mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw MeshExportError.invalidCoordinate
        }
    }

    static func write(_ mesh: MeshSnapshot, to directory: URL) throws -> [String] {
        try validate(mesh)
        let obj = directory.appendingPathComponent("modelo.obj")
        try stream(to: obj) { write in
            try write("# Forma | unidades: metros | eje vertical: Y | sin textura\n")
            for v in mesh.vertices { try write("v \(v.x) \(v.y) \(v.z)\n") }
            for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
                try write("f \(UInt64(mesh.triangles[i])+1) \(UInt64(mesh.triangles[i+1])+1) \(UInt64(mesh.triangles[i+2])+1)\n")
            }
        }
        let ply = directory.appendingPathComponent("modelo.ply")
        try stream(to: ply) { write in
            try write("ply\nformat ascii 1.0\ncomment Forma; units meters; Y up\nelement vertex \(mesh.vertexCount)\nproperty float x\nproperty float y\nproperty float z\nelement face \(mesh.faceCount)\nproperty list uchar uint vertex_indices\nend_header\n")
            for v in mesh.vertices { try write("\(v.x) \(v.y) \(v.z)\n") }
            for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
                try write("3 \(mesh.triangles[i]) \(mesh.triangles[i+1]) \(mesh.triangles[i+2])\n")
            }
        }
        let stl = directory.appendingPathComponent("modelo.stl")
        try stream(to: stl) { write in
            try write("solid Forma_meters\n")
            for i in stride(from: 0, to: mesh.triangles.count, by: 3) {
                let a = mesh.vertices[Int(mesh.triangles[i])]
                let b = mesh.vertices[Int(mesh.triangles[i+1])]
                let c = mesh.vertices[Int(mesh.triangles[i+2])]
                let cross = simd_cross(b-a, c-a)
                let n = simd_length_squared(cross) > 1e-16 ? simd_normalize(cross) : .zero
                try write("facet normal \(n.x) \(n.y) \(n.z)\nouter loop\nvertex \(a.x) \(a.y) \(a.z)\nvertex \(b.x) \(b.y) \(b.z)\nvertex \(c.x) \(c.y) \(c.z)\nendloop\nendfacet\n")
            }
            try write("endsolid Forma_meters\n")
        }
        return ["modelo.obj", "modelo.ply", "modelo.stl"]
    }

    // Buffer bounded independently of mesh size; avoid building giant export strings in memory.
    private static func stream(to url: URL, body: ((String) throws -> Void) throws -> Void) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer = Data()
        try body { text in
            buffer.append(contentsOf: text.utf8)
            if buffer.count >= 64 * 1024 {
                try ProcessingControl.checkpoint()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }
}

struct IntegrityManifest: Codable {
    struct Entry: Codable { var name: String; var sha256: String; var bytes: Int }
    var schema: Int = 1
    var createdAt: Date
    var files: [Entry]
    var disclaimer = "Verificación de integridad local. No es una certificación de precisión ni de cadena de custodia."

    static func digest(_ url: URL, progress: (Int64) -> Void = { _ in }) throws -> String {
        var hash = SHA256()
        var completed: Int64 = 0
        try CooperativeFileIO.readChunks(url) { data in
            hash.update(data: data)
            completed += Int64(data.count)
            progress(completed)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func verify(in directory: URL) throws -> Bool {
        for file in files {
            try ProcessingControl.checkpoint()
            guard ScanStore.safeRelativePath(file.name) else { return false }
            let url = directory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path), try Self.digest(url) == file.sha256 else { return false }
        }
        return !files.isEmpty
    }
}
