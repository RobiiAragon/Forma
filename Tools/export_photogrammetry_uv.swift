import Foundation
import ModelIO
import ImageIO
import CryptoKit
import simd

/// Standalone CPU research export. Compile with ProcessingControl,
/// CooperativeFileIO and StoredUSDZArchive. No image decode or GPU resource.
@main struct ExportPhotogrammetryUV {
    struct Failure: LocalizedError { let errorDescription: String? }
    struct Part { let mesh: MDLMesh; let transform: simd_float4x4; let vertexOffset: Int; let submeshes: [MDLSubmesh] }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw Failure(errorDescription: message) } }
    static func sha(_ url: URL) throws -> String {
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()};var hash=SHA256()
        while let data=try file.read(upToCount:1<<20),!data.isEmpty { hash.update(data:data) }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func uint<T: FixedWidthInteger>(_ value:T, _ data:inout Data) { var v=value.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)} }
    static func vertexIndex(_ index:Int,_ submesh:MDLSubmesh,_ bytes:UnsafeMutableRawPointer) throws -> Int {
        switch submesh.indexType {
        case .uInt8:return Int(bytes.advanced(by:index).loadUnaligned(as:UInt8.self))
        case .uInt16:return Int(bytes.advanced(by:index*2).loadUnaligned(as:UInt16.self))
        case .uInt32:return Int(bytes.advanced(by:index*4).loadUnaligned(as:UInt32.self))
        default:throw Failure(errorDescription:"Unsupported native index type.")
        }
    }
    static func texture(_ material:MDLMaterial,_ source:URL,_ names:Set<String>) throws -> String {
        var matches=Set<String>()
        for property in material.properties(with:.baseColor) {
            if let reference=property.stringValue {
                let prefix=source.path+"["
                if reference.hasPrefix(prefix),reference.hasSuffix("]") {
                    let name=String(reference.dropFirst(prefix.count).dropLast())
                    try require(names.contains(name),"Material texture does not exist in original USDZ.");matches.insert(name)
                }
            }
        }
        try require(matches.count==1,"A submesh does not have exactly one resolvable native diffuse atlas.")
        return matches.first!
    }
    static func json(_ data:[String:Any],_ url:URL) throws { try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic) }
    static func main() throws {
        let args=Array(CommandLine.arguments.dropFirst())
        guard args.count==6 else { throw Failure(errorDescription:"Usage: export-photogrammetry-uv SOURCE.usdz MESH.ply LABELS.vec SCENE_DIR NEW_OUTPUT_DIR MVE_VALIDATION.json") }
        let source=URL(fileURLWithPath:args[0]).standardizedFileURL,plyURL=URL(fileURLWithPath:args[1]).standardizedFileURL,labelURL=URL(fileURLWithPath:args[2]).standardizedFileURL
        let scene=URL(fileURLWithPath:args[3]).standardizedFileURL,output=URL(fileURLWithPath:args[4]).standardizedFileURL,mveURL=URL(fileURLWithPath:args[5]).standardizedFileURL
        let fm=FileManager.default;try require(!fm.fileExists(atPath:output.path),"Output already exists; no previous evidence is replaced.")
        let inputs=[source,plyURL,labelURL,mveURL,scene.appendingPathComponent("prepare-report.json")]
        var before:[String:String]=[:];for input in inputs { before[input.path]=try sha(input) }
        let mve=try JSONSerialization.jsonObject(with:Data(contentsOf:mveURL)) as? [String:Any] ?? [:]
        try require(mve["calledProductionPrepareMesh"] as? Bool==true && mve["faceIndexOrderExact"] as? Bool==true && mve["worldVerticesExact"] as? Bool==true && mve["removedFaces"] as? Int==0,"Production MVE prepare_mesh did not certify unchanged geometry/order.")
        let ply=try Data(contentsOf:plyURL,options:.mappedIfSafe),marker=Data("end_header\n".utf8)
        guard let headerEnd=ply.range(of:marker)?.upperBound,let header=String(data:ply[..<headerEnd],encoding:.utf8) else { throw Failure(errorDescription:"PLY header missing.") }
        try require(header.contains("format binary_little_endian 1.0") && header.contains("property list uchar uint vertex_indices"),"Expected the exact existing native binary PLY layout.")
        func count(_ kind:String) throws -> Int { guard let row=header.split(separator:"\n").first(where:{$0.hasPrefix("element "+kind+" ")}),let n=Int(row.split(separator:" ").last!) else{throw Failure(errorDescription:"Missing PLY element count.")};return n }
        let vertexCount=try count("vertex"),faceCount=try count("face"),faceOffset=headerEnd+vertexCount*12
        try require(ply.count==faceOffset+faceCount*13,"PLY byte layout/count does not match exporter contract.")
        try require(mve["inputFaceCount"] as? Int==faceCount && mve["outputFaceCount"] as? Int==faceCount,"MVE report face count mismatch.")
        let labels=try Data(contentsOf:labelURL,options:.mappedIfSafe)
        try require(labels.count==faceCount*8,"Expected raw arm64 size_t64 labeling vector, one label per prepared face, without header.")
        let preparation=try JSONSerialization.jsonObject(with:Data(contentsOf:scene.appendingPathComponent("prepare-report.json"))) as? [String:Any] ?? [:]
        guard let files=preparation["files"] as? [[String:Any]] else{throw Failure(errorDescription:"Missing prepared camera inventory.")}
        let views=files.sorted{($0["photo"] as? String ?? "")<($1["photo"] as? String ?? "")}
        var labelMap:[[String:Any]]=[["label":0,"meaning":"No selected photograph; keep native Raw atlas texels."]]
        for (index,file) in views.enumerated() {
            let expected=String(format:"%08d",index)
            try require((file["photo"] as? String)==expected+".jpg" && (file["camera"] as? String)==expected+".cam","Prepared photo/CAM order does not match MVE's sorted view IDs.")
            labelMap.append(["label":index+1,"viewIndex":index,"photo":file["photo"]!,"camera":file["camera"]!,"frameID":file["frameID"]!,"photoSHA256":file["photoSHA256"]!])
        }
        let archive=try StoredUSDZArchive(url:source),entryNames=Set(archive.entries.map(\.name));let asset=MDLAsset(url:source)
        var parts:[Part]=[],totalVertices=0,totalFaces=0
        func visit(_ object:MDLObject) throws {
            if let mesh=object as? MDLMesh {
                guard let submeshes=mesh.submeshes as? [MDLSubmesh],!submeshes.isEmpty else{throw Failure(errorDescription:"Missing submeshes.")}
                let transform=MDLTransform.globalTransform(with:mesh,atTime:0)
                parts.append(.init(mesh:mesh,transform:transform,vertexOffset:totalVertices,submeshes:submeshes));totalVertices+=mesh.vertexCount
                for submesh in submeshes { try require(submesh.geometryType == .triangles && submesh.indexCount%3==0,"No triangulation or face filtering is permitted.");totalFaces+=submesh.indexCount/3 }
            }
            for child in object.children.objects { try visit(child) }
        }
        for index in 0..<asset.count {try visit(asset.object(at:index))}
        try require(totalVertices==vertexCount && totalFaces==faceCount,"ModelIO and source PLY counts differ.")
        let stage=output.deletingLastPathComponent().appendingPathComponent(".uv-export-"+UUID().uuidString)
        try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer{try? fm.removeItem(at:stage)}
        let extracted=try archive.extract(toPrivateDirectory:stage.appendingPathComponent("extracted"))
        for name in ["corners.bin","material-ids.bin","labels.bin"] { try require(fm.createFile(atPath:stage.appendingPathComponent(name).path,contents:nil),"Cannot create binary output.") }
        let cornerFile=try FileHandle(forWritingTo:stage.appendingPathComponent("corners.bin")),materialFile=try FileHandle(forWritingTo:stage.appendingPathComponent("material-ids.bin")),labelFile=try FileHandle(forWritingTo:stage.appendingPathComponent("labels.bin"))
        defer{try? cornerFile.close();try? materialFile.close();try? labelFile.close()}
        var corners=Data(),materialIDs=Data(),newLabels=Data(),materials:[[String:Any]]=[],face=0,maxDifference:Float=0,labelCounts=[Int](repeating:0,count:views.count+1)
        func flush() throws {if corners.count>=1<<20 {try cornerFile.write(contentsOf:corners);corners.removeAll(keepingCapacity:true)};if materialIDs.count>=1<<16{try materialFile.write(contentsOf:materialIDs);materialIDs.removeAll(keepingCapacity:true)};if newLabels.count>=1<<16{try labelFile.write(contentsOf:newLabels);newLabels.removeAll(keepingCapacity:true)}}
        try ply.withUnsafeBytes { plyBytes in try labels.withUnsafeBytes { labelBytes in
            for part in parts {
                guard let p=part.mesh.vertexAttributeData(forAttributeNamed:MDLVertexAttributePosition,as:.float3),let uv=part.mesh.vertexAttributeData(forAttributeNamed:MDLVertexAttributeTextureCoordinate,as:.float2) else{throw Failure(errorDescription:"Missing native position/UV buffers.")}
                try require(p.stride>=12 && uv.stride>=8,"Invalid vertex buffer stride.")
                try require((part.mesh.vertexCount-1)*p.stride+12<=p.bufferSize && (part.mesh.vertexCount-1)*uv.stride+8<=uv.bufferSize,"Incomplete vertex buffer.")
                var world=[SIMD3<Float>]();world.reserveCapacity(part.mesh.vertexCount)
                for index in 0..<part.mesh.vertexCount {
                    let pointer=p.dataStart.advanced(by:index*p.stride),local=SIMD4(pointer.loadUnaligned(as:Float.self),pointer.advanced(by:4).loadUnaligned(as:Float.self),pointer.advanced(by:8).loadUnaligned(as:Float.self),1)
                    let value=part.transform*local;let xyz=SIMD3(value.x,value.y,value.z)
                    for c in 0..<3 {let expected=Float(bitPattern:UInt32(littleEndian:plyBytes.loadUnaligned(fromByteOffset:headerEnd+(part.vertexOffset+index)*12+c*4,as:UInt32.self)));try require(xyz[c].isFinite && xyz[c]==expected,"A global world vertex differs from the existing PLY; no tolerance/registration is introduced.");maxDifference=max(maxDifference,abs(xyz[c]-expected))}
                    world.append(xyz)
                }
                for submesh in part.submeshes {
                    guard let material=submesh.material else{throw Failure(errorDescription:"A native surface has no material.")}
                    let entry=try texture(material,source,entryNames),index=materials.count,start=face
                    guard let textureURL=extracted[entry],let image=CGImageSourceCreateWithURL(textureURL as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),let properties=CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],let width=(properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,let height=(properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {throw Failure(errorDescription:"Cannot inventory original PNG dimensions.")}
                    let mapped=submesh.indexBuffer.map()
                    for offset in stride(from:0,to:submesh.indexCount,by:3) {
                        try require(ply[faceOffset+face*13]==3,"PLY contains a non-triangle face.")
                        for corner in 0..<3 {
                            let local=try vertexIndex(offset+corner,submesh,mapped.bytes);try require(local<part.mesh.vertexCount,"Native corner references a missing vertex.")
                            let expected=UInt32(littleEndian:plyBytes.loadUnaligned(fromByteOffset:faceOffset+face*13+1+corner*4,as:UInt32.self))
                            try require(expected==UInt32(part.vertexOffset+local),"Face order/winding differs from existing PLY.")
                            let coordinate=uv.dataStart.advanced(by:local*uv.stride).loadUnaligned(as:SIMD2<Float>.self)
                            try require(coordinate.x.isFinite && coordinate.y.isFinite && (0...1).contains(coordinate.x) && (0...1).contains(coordinate.y),"Native UV is nonfinite or outside the atlas.")
                            let xyz=world[local];for value in [xyz.x,xyz.y,xyz.z,coordinate.x,coordinate.y] {uint(value.bitPattern,&corners)}
                        }
                        uint(UInt32(index),&materialIDs)
                        let label=UInt64(littleEndian:labelBytes.loadUnaligned(fromByteOffset:face*8,as:UInt64.self));try require(label<=UInt64(views.count),"Label points outside prepared scene views.")
                        uint(UInt32(label),&newLabels);labelCounts[Int(label)]+=1;face+=1;try flush()
                    }
                    materials.append(["index":index,"name":material.name,"textureEntry":entry,"textureFile":"extracted/"+entry,"width":width,"height":height,"firstFace":start,"faceCount":face-start,"textureSHA256":try sha(textureURL)])
                }
            }
        } }
        try cornerFile.write(contentsOf:corners);try materialFile.write(contentsOf:materialIDs);try labelFile.write(contentsOf:newLabels)
        for file in [cornerFile,materialFile,labelFile] {try file.synchronize();try file.close()}
        try require(face==faceCount,"Not every source face was exported.")
        try json(["schemaVersion":1,"labelCount":views.count+1,"labels":labelMap,"sceneDirectory":scene.path],stage.appendingPathComponent("label-map.json"))
        try json(mve,stage.appendingPathComponent("mve-prepare-validation.json"))
        let labelFormat:[String:Any]=["originalFile":labelURL.path,"sourceSHA256":before[labelURL.path]!,"originalType":"std::size_t on arm64 macOS = UInt64 little-endian","headerBytes":0,"originalBytesPerFace":8,"outputType":"UInt32LE","outputBytesPerFace":4,"faceCount":faceCount,"labelHistogram":labelCounts,"meaning":"0=no selected view; label N maps to sorted TextureViews[N-1], scene basename %08d with index N-1.","implementationReferences":["build/Tools/mvs-texturing-source/libs/tex/util.h:vector_to_file","build/Tools/mvs-texturing-source/apps/texrecon/texrecon.cpp:graph.get_label","build/Tools/mvs-texturing-source/libs/tex/generate_texture_patches.cpp:label=i+1"]]
        try json(labelFormat,stage.appendingPathComponent("label-format.json"))
        var after:[String:String]=[:];for input in inputs{after[input.path]=try sha(input)};try require(before==after,"An original input changed during export.")
        var outputSHA:[String:String]=[:];for name in ["corners.bin","material-ids.bin","labels.bin","label-map.json","label-format.json"]{outputSHA[name]=try sha(stage.appendingPathComponent(name))}
        let validation:[String:Any]=["allPLYVerticesCompared":true,"allPLYFaceIndicesCompared":true,"maxWorldXYZDifference":maxDifference,"faceIndexOrderExact":true,"windingPreserved":true,"allReferencedCornersValidated":faceCount*3,"mvePrepareFacesRemoved":0,"mvePrepareFaceOrderExact":true,"MVEValidation":"mve-prepare-validation.json"]
        let manifest:[String:Any]=["schemaVersion":1,"faceCount":faceCount,"vertexCount":vertexCount,"cornersFile":"corners.bin","cornerStrideBytes":20,"cornersPerFace":3,"cornerFields":"float32LE worldXYZ[3],float32LE nativeUV[2]; no SIMD padding","materialIDsFile":"material-ids.bin","labelsFile":"labels.bin","indexType":"UInt32LE","geometryAndLabelOrderValidated":true,"materials":materials,"labelMapFile":"label-map.json","labelFormatFile":"label-format.json","validation":validation,"inputSHA256":before,"inputsUnchanged":true,"outputSHA256":outputSHA,"GPUUsed":false,"UVOrigin":"Native USD bottom-left; PNG row = (1-v)*height; do not flip UV twice.","coordinatePolicy":"Same ModelIO globalTransform(time0), vertex/submesh/face traversal and winding as export_photogrammetry_mesh.swift; no scale, alignment or geometry changes."]
        try json(manifest,stage.appendingPathComponent("manifest.json"));try fm.moveItem(at:stage,to:output)
        print("PASS \(faceCount) faces, \(vertexCount) vertices, \(materials.count) native atlases, all PLY coordinates/indices and MVE face order exact; sources unchanged.")
    }
}
