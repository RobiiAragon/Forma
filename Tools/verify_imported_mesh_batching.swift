import Foundation
import SceneKit
import CryptoKit

/// Compile with Core/ImportedMeshBatching.swift. No UI, device or source datasets.
@main struct ImportedMeshBatchingVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func indices<T: FixedWidthInteger>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }
    static func triangle(_ values: [UInt32]) -> SCNGeometryElement {
        .init(data: indices(values), primitiveType: .triangles, primitiveCount: values.count/3, bytesPerIndex: 4)
    }
    static func sources() -> [SCNGeometrySource] {
        let vertices: [SIMD3<Float>] = [.init(-1,-1,0),.init(1,-1,0),.init(1,1,0),.init(-1,1,0)]
        let normals = [SIMD3<Float>](repeating: .init(0,0,1), count: 4)
        let uv: [SIMD2<Float>] = [.init(0,0),.init(1,0),.init(1,1),.init(0,1)]
        func source<T>(_ values: [T], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
            .init(data: values.withUnsafeBytes { Data($0) }, semantic: semantic, vectorCount: values.count,
                  usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4,
                  dataOffset: 0, dataStride: MemoryLayout<T>.stride)
        }
        return [source(vertices,.vertex,3),source(normals,.normal,3),source(uv,.texcoord,2)]
    }
    static func scene(_ elements: [SCNGeometryElement], _ materials: [SCNMaterial]) -> (SCNScene,SCNNode,SCNGeometry) {
        let geometry=SCNGeometry(sources:sources(),elements:elements);geometry.materials=materials
        let node=SCNNode(geometry:geometry),scene=SCNScene();scene.rootNode.addChildNode(node)
        return (scene,node,geometry)
    }
    static func sourceProof(_ geometry: SCNGeometry) -> [String] {
        geometry.sources.map { source in
            "\(source.semantic.rawValue):\(source.vectorCount):\(source.componentsPerVector):\(source.dataStride):\(source.dataOffset):" +
                SHA256.hash(data:source.data).map{String(format:"%02x",$0)}.joined()
        }
    }
    static func main() throws {
        let a=SCNMaterial(),b=SCNMaterial();a.name="same-name";b.name="same-name"
        a.isDoubleSided=false;a.cullMode = .back;b.isDoubleSided=false;b.cullMode = .back
        let x=indices([UInt32(0),1,2]),y=indices([UInt32(0),2,3])
        let (value,node,old)=scene([triangle([0,1,2]),triangle([0,2,3]),triangle([3,2,1]),triangle([3,1,0])],[a,b])
        let proof=sourceProof(old),flags=[a.isDoubleSided,b.isDoubleSided],culling=[a.cullMode,b.cullMode]
        let stats=try ImportedMeshBatching.consolidate(in:value)
        let result=node.geometry!
        try require(stats.originalElementCount==4 && stats.batchedElementCount==2 && stats.primitiveCount==4,"Wrong element/face counts")
        try require(result.elements[0].data==x+indices([UInt32(3),2,1]) && result.elements[1].data==y+indices([UInt32(3),1,0]),"Material-to-index mapping changed")
        try require(result.materials[0]===a && result.materials[1]===b,"Materials of same name were incorrectly combined or copied")
        try require(sourceProof(result)==proof,"Vertex, normal, UV bytes/format changed")
        try require([a.isDoubleSided,b.isDoubleSided]==flags && [a.cullMode,b.cullMode]==culling,"Culling changed")
        print("PASS: exact indices per material, same-name material identity, faces, vertex/normal/UV SHA-256 and culling preserved")

        let polygon=SCNGeometryElement(data:indices([UInt32(4),0,1,2,3]),primitiveType:.polygon,primitiveCount:1,bytesPerIndex:4)
        let strip=SCNGeometryElement(data:indices([UInt32(0),1,2,3]),primitiveType:.triangleStrip,primitiveCount:2,bytesPerIndex:4)
        let partial=triangle([0,1,2]);partial.primitiveRange=NSRange(location:0,length:0)
        for barrier in [polygon,strip,partial] {
            let (scene,node,_)=self.scene([triangle([0,1,2]),triangle([0,2,3]),barrier,triangle([0,1,2]),triangle([0,2,3])],[a])
            _=try ImportedMeshBatching.consolidate(in:scene)
            try require(node.geometry!.elementCount==3 && node.geometry!.elements[1]===barrier,"Strip/polygon/range barrier changed or was bridged")
        }
        print("PASS: polygon data, triangle strip winding and partial primitive ranges remain untouched barriers")

        let line=SCNGeometryElement(data:indices([UInt8(0),1]),primitiveType:.line,primitiveCount:1,bytesPerIndex:1)
        let point=SCNGeometryElement(data:indices([UInt16(2)]),primitiveType:.point,primitiveCount:1,bytesPerIndex:2)
        let (mixed,mixedNode,_)=scene([line,triangle([0,1,2]),point,line,point],[a])
        _=try ImportedMeshBatching.consolidate(in:mixed)
        try require(mixedNode.geometry!.elements.map(\.primitiveType)==[.line,.triangles,.point],"Primitive types mixed")
        try require(mixedNode.geometry!.elements.map(\.bytesPerIndex)==[1,4,2],"Index widths changed")
        try require(mixedNode.geometry!.elements[0].data==line.data+line.data && mixedNode.geometry!.elements[2].data==point.data+point.data,"Index bytes changed")
        print("PASS: distinct primitive types/index widths stay valid and retain exact data")

        let transparent=SCNMaterial();transparent.transparency=0.5
        let (alpha,alphaNode,_)=scene((0..<5).map{_ in triangle([0,1,2])},[a,a,transparent,a,a])
        _=try ImportedMeshBatching.consolidate(in:alpha)
        try require(alphaNode.geometry!.elementCount==3 && alphaNode.geometry!.materials[1]===transparent,"Transparent order barrier changed")
        print("PASS: explicit transparency preserves draw-order barriers")

        let (cancelled,cancelNode,cancelGeometry)=scene((0..<10).map{_ in triangle([0,1,2])},[a])
        var checks=0,thrown=false
        do { _=try ImportedMeshBatching.consolidate(in:cancelled) { checks+=1;if checks>=15{throw CancellationError()} } }
        catch is CancellationError { thrown=true }
        try require(thrown && cancelNode.geometry===cancelGeometry && cancelGeometry.elementCount==10,"Cancellation published a partial replacement")
        print("PASS: cancellation during buffer assembly leaves the original imported scene unchanged")

        let (shared,first,sharedGeometry)=scene([triangle([0,1,2]),triangle([0,2,3])],[a])
        let second=SCNNode(geometry:sharedGeometry);shared.rootNode.addChildNode(second)
        let sharedStats=try ImportedMeshBatching.consolidate(in:shared)
        try require(sharedStats.geometryCount==1 && sharedStats.changedGeometryCount==1 && first.geometry===second.geometry,"Shared geometry duplicated or lost")
        print("PASS: instanced geometry is batched once and remains shared")
        let largeCount=104_714,largeTriangle=triangle([0,1,2])
        let (large,largeNode,_)=scene(Array(repeating:largeTriangle,count:largeCount),(0..<largeCount).map{$0%2==0 ? a:b})
        let start=Date(),largeStats=try ImportedMeshBatching.consolidate(in:large)
        try require(largeStats.originalElementCount==largeCount && largeStats.batchedElementCount==2 && largeStats.primitiveCount==largeCount,
                    "Production-size run count lost primitives")
        try require(largeNode.geometry!.elements.reduce(0){$0+$1.data.count}==largeCount*12,"Large index buffer bytes changed")
        print("PASS: 104714 material runs become 2 batches without dropping faces/bytes (\(Date().timeIntervalSince(start)) seconds)")
    }
}
