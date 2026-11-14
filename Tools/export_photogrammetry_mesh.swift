import Foundation
import ModelIO
import simd
import CryptoKit

/// CPU research adapter: USDZ -> transformed, triangulated PLY. Does not load textures.
@main struct ExportPhotogrammetryMesh {
    struct Failure: LocalizedError { var errorDescription: String? }
    struct Part {
        var mesh: MDLMesh
        var transform: simd_float4x4
        var vertexOffset: Int
        var submeshes: [MDLSubmesh]
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(errorDescription: message) }
    }
    static func sha(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1 << 20), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    static func index(_ i: Int, submesh: MDLSubmesh, bytes: UnsafeMutableRawPointer) throws -> UInt32 {
        switch submesh.indexType {
        case .uInt8: return UInt32(bytes.advanced(by: i).loadUnaligned(as: UInt8.self))
        case .uInt16: return UInt32(bytes.advanced(by: i * 2).loadUnaligned(as: UInt16.self))
        case .uInt32: return bytes.advanced(by: i * 4).loadUnaligned(as: UInt32.self)
        default: throw Failure(errorDescription: "Unsupported index type; no implicit triangulation is allowed.")
        }
    }
    static func export(asset: MDLAsset, to output: URL, source: URL? = nil) throws -> [String: Any] {
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: output.path), "Output must be a new directory; previous results are preserved.")
        let sourceSHA = try source.map(sha)
        let started = Date()
        var parts: [Part] = [], vertices = 0, faces = 0
        func visit(_ object: MDLObject) throws {
            if let mesh = object as? MDLMesh {
                try require(mesh.vertexCount > 0, "Empty mesh encountered; no surface is silently removed.")
                guard let submeshes = mesh.submeshes as? [MDLSubmesh], !submeshes.isEmpty else {
                    throw Failure(errorDescription: "Mesh has no explicit submeshes.")
                }
                let transform = MDLTransform.globalTransform(with: mesh, atTime: 0)
                let matrixValues = (0..<4).flatMap { column in (0..<4).map { row in transform[column][row] } }
                try require(matrixValues.allSatisfy(\.isFinite), "Nonfinite global transform.")
                try require(abs(transform.columns.0.w) < 1e-6 && abs(transform.columns.1.w) < 1e-6 && abs(transform.columns.2.w) < 1e-6 && abs(transform.columns.3.w - 1) < 1e-6,
                            "Non-affine transform cannot be silently approximated.")
                let next = vertices.addingReportingOverflow(mesh.vertexCount)
                try require(!next.overflow && next.partialValue <= Int(UInt32.max), "PLY vertex indices exceed UInt32 representation.")
                parts.append(Part(mesh: mesh, transform: transform, vertexOffset: vertices, submeshes: submeshes))
                vertices = next.partialValue
                for submesh in submeshes {
                    try require(submesh.geometryType == .triangles && submesh.indexCount % 3 == 0, "Input must contain triangles; no triangulation or filtering is performed.")
                    let bytes: Int
                    switch submesh.indexType { case .uInt8: bytes = 1; case .uInt16: bytes = 2; case .uInt32: bytes = 4; default: throw Failure(errorDescription: "Unsupported index type.") }
                    let required = submesh.indexCount.multipliedReportingOverflow(by: bytes)
                    try require(!required.overflow && required.partialValue <= submesh.indexBuffer.length, "Incomplete index buffer.")
                    let nextFaces = faces.addingReportingOverflow(submesh.indexCount / 3)
                    try require(!nextFaces.overflow, "Face count cannot be represented."); faces = nextFaces.partialValue
                }
            }
            for child in object.children.objects { try visit(child) }
        }
        for i in 0..<asset.count { try visit(asset.object(at: i)) }
        try require(!parts.isEmpty && faces > 0, "No triangular mesh found.")
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = output.deletingLastPathComponent().appendingPathComponent(".ply-export-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        let ply = stage.appendingPathComponent("mesh.ply")
        try require(fm.createFile(atPath: ply.path, contents: nil), "Cannot create PLY.")
        let handle = try FileHandle(forWritingTo: ply)
        var buffer = Data(), minimum = SIMD3<Float>(repeating: .infinity), maximum = SIMD3<Float>(repeating: -.infinity)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("ply\nformat binary_little_endian 1.0\ncomment Forma CPU research: original triangle order and global mesh transforms; no UVs, filters or reconstruction\nelement vertex \(vertices)\nproperty float x\nproperty float y\nproperty float z\nelement face \(faces)\nproperty list uchar uint vertex_indices\nend_header\n".utf8))
        func flush(_ force: Bool = false) throws {
            if buffer.count >= 1 << 16 || (force && !buffer.isEmpty) { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        var reports: [[String: Any]] = []
        for part in parts {
            guard let position = part.mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
                throw Failure(errorDescription: "Mesh has no readable float3 positions.")
            }
            try require(position.stride >= 12, "Position stride is too small.")
            let offset = (part.mesh.vertexCount - 1).multipliedReportingOverflow(by: position.stride)
            let required = offset.partialValue.addingReportingOverflow(12)
            try require(!offset.overflow && !required.overflow && required.partialValue <= position.bufferSize, "Incomplete position buffer.")
            var localMin = SIMD3<Float>(repeating: .infinity), localMax = SIMD3<Float>(repeating: -.infinity)
            for i in 0..<part.mesh.vertexCount {
                let pointer = position.dataStart.advanced(by: i * position.stride)
                let p = SIMD4<Float>(pointer.loadUnaligned(as: Float.self), pointer.advanced(by: 4).loadUnaligned(as: Float.self), pointer.advanced(by: 8).loadUnaligned(as: Float.self), 1)
                let transformed = part.transform * p
                let value = SIMD3(transformed.x, transformed.y, transformed.z)
                try require(value.x.isFinite && value.y.isFinite && value.z.isFinite, "Nonfinite transformed position; no vertex is silently removed.")
                minimum = simd_min(minimum, value); maximum = simd_max(maximum, value)
                localMin = simd_min(localMin, value); localMax = simd_max(localMax, value)
                append(value.x.bitPattern, to: &buffer); append(value.y.bitPattern, to: &buffer); append(value.z.bitPattern, to: &buffer)
                try flush()
            }
            reports.append(["mesh": part.mesh.name, "vertices": part.mesh.vertexCount, "faces": part.submeshes.reduce(0) { $0 + $1.indexCount / 3 },
                            "submeshes": part.submeshes.count, "globalTransformColumnMajor": (0..<4).flatMap { c in (0..<4).map { r in part.transform[c][r] } },
                            "globalDeterminant": simd_determinant(part.transform), "worldBoundsMin": [localMin.x, localMin.y, localMin.z], "worldBoundsMax": [localMax.x, localMax.y, localMax.z]])
        }
        try flush(true)
        for part in parts {
            for submesh in part.submeshes {
                let mapped = submesh.indexBuffer.map()
                for i in stride(from: 0, to: submesh.indexCount, by: 3) {
                    buffer.append(3)
                    for corner in 0..<3 {
                        let local = try index(i + corner, submesh: submesh, bytes: mapped.bytes)
                        try require(Int(local) < part.mesh.vertexCount, "Index outside source vertex buffer.")
                        append(UInt32(part.vertexOffset) + local, to: &buffer)
                    }
                    try flush()
                }
            }
        }
        try flush(true); try handle.synchronize(); try handle.close()
        let after = try source.map(sha)
        try require(sourceSHA == after, "Source changed during export.")
        var report: [String: Any] = ["schemaVersion": 1, "vertices": vertices, "faces": faces, "meshes": reports, "worldBoundsMin": [minimum.x, minimum.y, minimum.z], "worldBoundsMax": [maximum.x, maximum.y, maximum.z], "outputPLY": "mesh.ply", "outputSHA256": try sha(ply), "seconds": Date().timeIntervalSince(started), "triangleOrderPreserved": true, "triangleOrderSource": "ModelIO mesh/submesh order; native USD face IDs are not renumbering guarantees.", "vertexTopologyPolicy": "Imported ModelIO UV/normal splits retained without welding or filtering.", "globalTransformsAppliedAtTime": 0, "filtersApplied": false, "uvsExported": false, "texturesLoaded": false, "GPUUsed": false, "coordinatePolicy": "ModelIO globalTransform at time0; no additional axis, unit, ARKit or camera registration. Camera/model CRS must be validated separately."]
        if let source { report["source"] = source.path; report["sourceSHA256Before"] = sourceSHA; report["sourceSHA256After"] = after }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: stage.appendingPathComponent("report.json"), options: .atomic)
        try fm.moveItem(at: stage, to: output)
        return report
    }
    static func fixtureMesh(_ vertices: [Float], _ indices: [UInt32]) -> MDLMesh {
        let allocator = MDLMeshBufferDataAllocator()
        let vd = vertices.withUnsafeBytes { Data($0) }, id = indices.withUnsafeBytes { Data($0) }
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        let submesh = MDLSubmesh(indexBuffer: allocator.newBuffer(with: id, type: .index), indexCount: indices.count, indexType: .uInt32, geometryType: .triangles, material: nil)
        return MDLMesh(vertexBuffer: allocator.newBuffer(with: vd, type: .vertex), vertexCount: vertices.count / 3, descriptor: descriptor, submeshes: [submesh])
    }
    static func selfTest(_ output: URL) throws {
        let asset = MDLAsset(), parent = MDLObject()
        parent.transform = MDLTransform(matrix: simd_float4x4(columns: (SIMD4(0, 2, 0, 0), SIMD4(-3, 0, 0, 0), SIMD4(0, 0, 4, 0), SIMD4(10, 20, 30, 1))))
        let first = fixtureMesh([0,0,0, 1,0,0, 0,1,0], [0,2,1]); first.name = "nested transformed triangle"
        first.transform = MDLTransform(matrix: simd_float4x4(columns: (SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,1,0),SIMD4(1,2,3,1))))
        parent.addChild(first); asset.add(parent)
        let second = fixtureMesh([-1,-1,-1, -2,-1,-1, -1,-2,-1], [1,0,2]); second.name = "independent original winding"; asset.add(second)
        let report = try export(asset: asset, to: output)
        try require(report["vertices"] as? Int == 6 && report["faces"] as? Int == 2, "Fixture lost geometry.")
        let bytes = try Data(contentsOf: output.appendingPathComponent("mesh.ply")), marker = Data("end_header\n".utf8)
        guard let range = bytes.range(of: marker) else { throw Failure(errorDescription: "Missing PLY header.") }
        let payload = bytes.subdata(in: range.upperBound..<bytes.count)
        let expected: [SIMD3<Float>] = [SIMD3(4,22,42),SIMD3(4,24,42),SIMD3(1,22,42),SIMD3(-1,-1,-1),SIMD3(-2,-1,-1),SIMD3(-1,-2,-1)]
        try require(payload.count == expected.count * 12 + 26, "Incorrect PLY payload length.")
        for (i,p) in expected.enumerated() {
            for c in 0..<3 {
                let bits = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 12 + c * 4, as: UInt32.self) }
                try require(Float(bitPattern: UInt32(littleEndian: bits)) == p[c], "Global hierarchy transform changed a fixture coordinate.")
            }
        }
        let offset = expected.count * 12
        for (face, expectedIndices) in [[UInt32(0),2,1],[4,3,5]].enumerated() {
            try require(payload[offset + face * 13] == 3, "Triangle length changed.")
            for (c,expectedIndex) in expectedIndices.enumerated() {
                let value = payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + face * 13 + 1 + c * 4, as: UInt32.self) }
                try require(UInt32(littleEndian: value) == expectedIndex, "Winding or mesh vertex offset changed.")
            }
        }
        print("PASS: hierarchy rotation/translation/nonuniform scale, disconnected surface, exact winding, binary PLY positions and counts; CPU only.")
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2 && args[0] == "--self-test" { try selfTest(URL(fileURLWithPath: args[1])); return }
        guard args.count == 2 else { throw Failure(errorDescription: "Usage: export-photogrammetry-mesh SOURCE.usdz NEW_OUTPUT_DIRECTORY | --self-test NEW_OUTPUT_DIRECTORY") }
        let source = URL(fileURLWithPath: args[0]).standardizedFileURL, output = URL(fileURLWithPath: args[1]).standardizedFileURL
        let resource = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try require(source.pathExtension.lowercased() == "usdz" && resource.isRegularFile == true && resource.isSymbolicLink != true, "Source must be a regular USDZ, without symlinks.")
        try autoreleasepool {
            let report = try export(asset: MDLAsset(url: source), to: output, source: source)
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        }
    }
}
