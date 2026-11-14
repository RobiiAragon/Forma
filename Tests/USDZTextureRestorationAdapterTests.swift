import XCTest
import ModelIO
import simd
@testable import Forma

final class USDZTextureRestorationAdapterTests: XCTestCase {
    private let archive = URL(fileURLWithPath: "/private/test/modelo.usdz")
    private func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }
    private func asset(uv: [SIMD2<Float>] = [.init(0, 1), .init(1, 1), .init(0, 0)],
                       indices: [UInt16] = [2, 0, 1], texture: String = "0/atlas.png") -> MDLAsset {
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 0, bufferIndex: 1)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)
        descriptor.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD2<Float>>.stride)
        let material = MDLMaterial(name: "surface", scatteringFunction: MDLScatteringFunction())
        material.setProperty(MDLMaterialProperty(name: "diffuseColor", semantic: .baseColor,
                                                string: archive.path + "[" + texture + "]"))
        let submesh = MDLSubmesh(indexBuffer: MDLMeshBufferData(type: .index, data: bytes(indices)),
                                indexCount: indices.count, indexType: .uInt16, geometryType: .triangles, material: material)
        let mesh = MDLMesh(vertexBuffers: [
            MDLMeshBufferData(type: .vertex, data: bytes([SIMD3<Float>](repeating: .zero, count: uv.count))),
            MDLMeshBufferData(type: .vertex, data: bytes(uv))
        ], vertexCount: uv.count, descriptor: descriptor, submeshes: [submesh])
        let result = MDLAsset(); result.add(mesh); return result
    }

    func testIndexedUVsRetainNativeVAndMaterialBinding() throws {
        let mapping = try USDZTextureRestorationAdapter.mapping(in: asset(), archiveURL: archive,
                                                                textureEntryNames: ["0/atlas.png"])
        XCTAssertEqual(mapping.vertexCount, 3)
        XCTAssertEqual(mapping.triangleCount, 1)
        XCTAssertEqual(mapping.materialCount, 1)
        let triangle = try XCTUnwrap(mapping.triangles["0/atlas.png"]?.first)
        XCTAssertEqual(triangle.a, SIMD2<Float>(0, 0))
        XCTAssertEqual(triangle.b, SIMD2<Float>(0, 1))
        XCTAssertEqual(triangle.c, SIMD2<Float>(1, 1))
        // Native USD v=1 maps to the PNG's top raster row in the existing
        // coverage rasterizer. The adapter must not add a second vertical flip.
        XCTAssertEqual((1 - triangle.b.y) * 4, 0)
    }

    func testUnresolvedMaterialAndUnsafeEntryFailExplicitly() {
        XCTAssertThrowsError(try USDZTextureRestorationAdapter.mapping(in: asset(texture: "0/missing.png"),
            archiveURL: archive, textureEntryNames: ["0/atlas.png"]))
        XCTAssertThrowsError(try USDZTextureRestorationAdapter.mapping(in: asset(texture: "../atlas.png"),
            archiveURL: archive, textureEntryNames: ["../atlas.png"]))
    }

    func testInvalidIndicesAndNonFiniteOrRepeatedUVsFailBeforeReadingOutsideBuffer() {
        XCTAssertThrowsError(try USDZTextureRestorationAdapter.mapping(in: asset(indices: [0, 1, 3]),
            archiveURL: archive, textureEntryNames: ["0/atlas.png"]))
        XCTAssertThrowsError(try USDZTextureRestorationAdapter.mapping(in: asset(uv: [.init(.nan, 0), .init(1, 1), .zero]),
            archiveURL: archive, textureEntryNames: ["0/atlas.png"]))
        XCTAssertThrowsError(try USDZTextureRestorationAdapter.mapping(in: asset(uv: [.init(0, 1.01), .init(1, 1), .zero]),
            archiveURL: archive, textureEntryNames: ["0/atlas.png"]))
    }

    func testEverySubmeshAndNestedMeshIsKeptWithoutSampling() throws {
        let all = MDLAsset()
        let first = asset(), second = asset(texture: "0/second.png")
        let parent = MDLObject()
        parent.children.add(second.object(at: 0))
        all.add(first.object(at: 0)); all.add(parent)
        let mapping = try USDZTextureRestorationAdapter.mapping(in: all, archiveURL: archive,
            textureEntryNames: ["0/atlas.png", "0/second.png"])
        XCTAssertEqual(mapping.vertexCount, 6)
        XCTAssertEqual(mapping.triangleCount, 2)
        XCTAssertEqual(mapping.materialCount, 2)
        XCTAssertEqual(Set(mapping.triangles.keys), ["0/atlas.png", "0/second.png"])
    }
}
