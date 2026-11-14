import Foundation
import ModelIO
import simd

/// Reads material-bound UVs without exporting, changing or retaining the USD scene.
/// The archive writer preserves USD payloads separately; these triangles are only
/// the existing atlas restoration mask input, never replacement geometry.
enum USDZTextureRestorationAdapter {
    struct Triangle: Sendable, Equatable {
        let a: SIMD2<Float>
        let b: SIMD2<Float>
        let c: SIMD2<Float>
    }
    struct Mapping: Sendable {
        let triangles: [String: [Triangle]]
        let vertexCount: Int
        let triangleCount: Int
        let materialCount: Int
    }

    static func loadUVMapping(modelURL: URL, textureEntryNames: Set<String>) throws -> Mapping {
        try ProcessingControl.checkpoint()
        guard modelURL.isFileURL, modelURL.pathExtension.lowercased() == "usdz" else {
            throw invalid("La restauración USDZ necesita un archivo local USDZ.")
        }
        let values = try modelURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw invalid("El USDZ debe ser un archivo regular, sin enlaces simbólicos.")
        }
        // Do not call loadTextures(): Model IO is used only to read CPU mesh/UV
        // buffers. The four 8K atlases, for example, need not reside in the GPU.
        return try autoreleasepool {
            let asset = MDLAsset(url: modelURL)
            return try mapping(in: asset, archiveURL: modelURL, textureEntryNames: textureEntryNames)
        }
    }

    /// Internal entry point also permits small, authored Model IO fixtures.
    static func mapping(in asset: MDLAsset, archiveURL: URL, textureEntryNames: Set<String>) throws -> Mapping {
        guard !textureEntryNames.isEmpty,
              textureEntryNames.allSatisfy({ safePath($0) && URL(fileURLWithPath: $0).pathExtension.lowercased() == "png" }) else {
            throw invalid("El USDZ no tiene una lista válida de atlas PNG internos.")
        }
        var result: [String: [Triangle]] = [:]
        var vertexCount = 0, triangleCount = 0, materialCount = 0
        func visit(_ object: MDLObject) throws {
            try ProcessingControl.checkpoint()
            if let mesh = object as? MDLMesh {
                let submeshes = mesh.submeshes as? [MDLSubmesh] ?? []
                guard let uv = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2),
                      uv.format == .float2, uv.stride >= MemoryLayout<SIMD2<Float>>.size,
                      mesh.vertexCount > 0 else { throw invalid("Una malla USDZ no expone coordenadas UV compatibles.") }
                let required = try checkedByteCount(count: mesh.vertexCount, stride: uv.stride,
                                                    elementBytes: MemoryLayout<SIMD2<Float>>.size)
                guard required <= uv.bufferSize else { throw invalid("El buffer UV del USDZ está incompleto.") }
                let nextVertices = vertexCount.addingReportingOverflow(mesh.vertexCount)
                guard !nextVertices.overflow else { throw invalid("El número de vértices no se puede representar.") }
                vertexCount = nextVertices.partialValue
                for submesh in submeshes {
                    try ProcessingControl.checkpoint()
                    guard submesh.geometryType == .triangles, submesh.indexCount % 3 == 0,
                          let material = submesh.material else {
                        throw invalid("La restauración USDZ requiere triángulos con material explícito.")
                    }
                    let entry = try textureEntry(material: material, archiveURL: archiveURL, allowed: textureEntryNames)
                    let elementBytes: Int
                    switch submesh.indexType {
                    case .uInt8: elementBytes = 1
                    case .uInt16: elementBytes = 2
                    case .uInt32: elementBytes = 4
                    default: throw invalid("El USDZ usa un formato de índices no compatible.")
                    }
                    let bytes = submesh.indexCount.multipliedReportingOverflow(by: elementBytes)
                    guard !bytes.overflow, bytes.partialValue <= submesh.indexBuffer.length else {
                        throw invalid("El buffer de índices del USDZ está incompleto.")
                    }
                    let indices = submesh.indexBuffer.map()
                    func coordinate(_ index: Int) throws -> SIMD2<Float> {
                        let address = indices.bytes.advanced(by: index * elementBytes)
                        let vertex: Int
                        switch elementBytes {
                        case 1: vertex = Int(address.loadUnaligned(as: UInt8.self))
                        case 2: vertex = Int(address.loadUnaligned(as: UInt16.self))
                        default: vertex = Int(address.loadUnaligned(as: UInt32.self))
                        }
                        guard vertex < mesh.vertexCount else { throw invalid("Un índice USDZ apunta fuera del buffer UV.") }
                        let value = uv.dataStart.advanced(by: vertex * uv.stride).loadUnaligned(as: SIMD2<Float>.self)
                        guard value.x.isFinite, value.y.isFinite,
                              (0...1).contains(value.x), (0...1).contains(value.y) else {
                            throw invalid("El atlas USDZ usa UV no finitas o repetidas fuera de 0…1; se conserva original.")
                        }
                        return value
                    }
                    var triangles = result.removeValue(forKey: entry) ?? []
                    let count = triangles.count.addingReportingOverflow(submesh.indexCount / 3)
                    guard !count.overflow else { throw invalid("El número de triángulos no se puede representar.") }
                    triangles.reserveCapacity(count.partialValue)
                    for index in stride(from: 0, to: submesh.indexCount, by: 3) {
                        if index & 4095 == 0 { try ProcessingControl.checkpoint() }
                        triangles.append(try Triangle(a: coordinate(index), b: coordinate(index + 1), c: coordinate(index + 2)))
                    }
                    result[entry] = triangles
                    let nextTriangles = triangleCount.addingReportingOverflow(submesh.indexCount / 3)
                    guard !nextTriangles.overflow else { throw invalid("El número de triángulos no se puede representar.") }
                    triangleCount = nextTriangles.partialValue
                    materialCount += 1
                }
            }
            for child in object.children.objects { try visit(child) }
        }
        for index in 0..<asset.count { try visit(asset.object(at: index)) }
        guard triangleCount > 0 else { throw invalid("El USDZ no contiene superficies UV restaurables.") }
        return Mapping(triangles: result, vertexCount: vertexCount, triangleCount: triangleCount, materialCount: materialCount)
    }

    private static func textureEntry(material: MDLMaterial, archiveURL: URL, allowed: Set<String>) throws -> String {
        var candidates = Set<String>()
        for property in material.properties(with: .baseColor) {
            if let transform = property.textureSamplerValue?.transform, transform.matrix != matrix_identity_float4x4 {
                throw invalid("El material USDZ transforma las UV de la textura; se conserva original.")
            }
            // USDZ importers expose archive[entry] in stringValue. urlValue can
            // refer only to the containing archive and must not be guessed.
            let references = [property.stringValue, property.urlValue?.absoluteString,
                              property.textureSamplerValue?.texture?.name].compactMap { $0 }
            for reference in references {
                if reference == archiveURL.absoluteString || reference == archiveURL.path { continue }
                var entry: String?
                for prefix in [archiveURL.path + "[", archiveURL.absoluteString + "["]
                    where reference.hasPrefix(prefix) && reference.hasSuffix("]") {
                    entry = String(reference.dropFirst(prefix.count).dropLast())
                }
                if entry == nil, safePath(reference), allowed.contains(reference) { entry = reference }
                if let entry {
                    guard safePath(entry), allowed.contains(entry) else {
                        throw invalid("El material USDZ referencia una textura ausente o externa.")
                    }
                    candidates.insert(entry)
                } else if property.type == .string || property.type == .URL || property.type == .texture {
                    throw invalid("No se pudo asociar una textura USDZ interna de forma inequívoca.")
                }
            }
        }
        guard candidates.count == 1, let entry = candidates.first else {
            throw invalid("Cada superficie USDZ necesita exactamente un atlas difuso interno compatible.")
        }
        return entry
    }

    private static func checkedByteCount(count: Int, stride: Int, elementBytes: Int) throws -> Int {
        let offset = (count - 1).multipliedReportingOverflow(by: stride)
        let size = offset.partialValue.addingReportingOverflow(elementBytes)
        guard !offset.overflow, !size.overflow else { throw invalid("El tamaño del buffer UV no se puede representar.") }
        return size.partialValue
    }
    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "FormaUSDZTextureRestoration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
