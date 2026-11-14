import Foundation
import ModelIO
import ImageIO
import CryptoKit
import simd
import Darwin

/// Native preparation for photographic detail. Runs on a worker thread; the caller
/// supplies Raw and Apple poses from the same reconstruction session. ARKit poses
/// are never registered or substituted. Originals and arbitrary missing poses are
/// accounted for, and only the explicit ProcessingControl can pause this work.
enum DesktopPhotographicDetailPreparation {
    struct Prepared: Sendable {
        let directory: URL
        let sceneDirectory: URL
        let geometryDirectory: URL
        let meshURL: URL
        let manifestURL: URL
        let reportURL: URL
        let faceCount: Int
        let vertexCount: Int
        var rawModelURL: URL { directory.appendingPathComponent("source/raw.usdz") }
        var calibrationURL: URL { directory.appendingPathComponent("source/calibration.json") }
    }
    struct PreparationError: LocalizedError {
        let reason: String
        var errorDescription: String? { "No se preparó el detalle fotográfico: " + reason + " Las fuentes originales se conservan." }
    }
    private struct Lens: Decodable { var center: [Double]; var radialLookupTable: [Double] }
    private struct Camera: Decodable {
        var sampleID: Int; var sampleURLFilename: String; var inputFilename: String
        var sourceFile: String; var frameID: String; var timestamp: Double
        var nativeTransformColumnMajor: [Double]; var intrinsicsColumnMajor: [Double]?
        var lensDistortion: Lens?; var inputImageWidth: Int?; var inputImageHeight: Int?; var inputImageOrientation: Int?
    }
    private struct Missing: Decodable { var filename: String; var sourceFile: String; var frameID: String; var timestamp: Double }
    private struct Calibration: Decodable { var schemaVersion: Int; var inputCount: Int; var poseCount: Int; var cameras: [Camera]; var inputsWithoutPose: [Missing] }
    private struct Part { var mesh: MDLMesh; var transform: simd_float4x4; var offset: Int; var submeshes: [MDLSubmesh] }

    static func load(from directory: URL) throws -> Prepared {
        let root = directory.standardizedFileURL
        let report = try jsonObject(safe(root, "preparation.json"))
        try check(try integer(report,"schemaVersion") == 1, "la versión del trabajo no es compatible")
        let geometry = root.appendingPathComponent("geometry")
        _ = try safe(root,"source/raw.usdz"); _ = try safe(root,"source/calibration.json")
        _ = try safe(root,"scene/prepare-report.json"); _ = try safe(geometry,"manifest.json"); _ = try safe(geometry,"mesh.ply")
        return Prepared(directory:root,sceneDirectory:root.appendingPathComponent("scene"),geometryDirectory:geometry,
                        meshURL:geometry.appendingPathComponent("mesh.ply"),manifestURL:geometry.appendingPathComponent("manifest.json"),
                        reportURL:root.appendingPathComponent("preparation.json"),faceCount:try integer(report,"faceCount"),vertexCount:try integer(report,"vertexCount"))
    }

    static func prepare(rawUSDZ: URL, calibration: URL, dataset: URL, output: URL,
                        control: ProcessingControl? = nil,
                        progress: @Sendable (String, Double) -> Void = { _,_ in }) throws -> Prepared {
        try ProcessingControl.withControl(control) {
            try ProcessingControl.checkpoint()
            let fm=FileManager.default, root=output.standardizedFileURL
            try check(!fm.fileExists(atPath:root.path),"la carpeta de trabajo ya existe")
            try regular(rawUSDZ); try regular(calibration); try regular(dataset.appendingPathComponent("dataset.json"))
            try check(rawUSDZ.pathExtension.lowercased()=="usdz","el modelo debe ser USDZ")
            let manifest=try RGBDDatasetManifest.load(from:dataset)
            let frames=manifest.frames.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
            let native=try JSONDecoder().decode(Calibration.self,from:Data(contentsOf:calibration))
            try check(native.schemaVersion==1 && native.inputCount==frames.count && native.poseCount==native.cameras.count && !frames.isEmpty && !native.cameras.isEmpty,"la calibración no corresponde al número de fotos originales")
            try check(Set(frames.map(\.id)).count==frames.count && Set(frames.map(\.rgbFile)).count==frames.count && frames.allSatisfy({$0.timestamp.isFinite}),"las fotografías contienen identidades o tiempos ambiguos")
            var cameras:[String:Camera]=[:], samples=Set<Int>(), filenames=Set<String>()
            let frameByID=Dictionary(uniqueKeysWithValues:frames.map { ($0.id,$0) })
            let ordinalByID=Dictionary(uniqueKeysWithValues:frames.enumerated().map { ($0.element.id,$0.offset) })
            for camera in native.cameras {
                try ProcessingControl.checkpoint()
                guard let frame=frameByID[camera.frameID],let ordinal=ordinalByID[camera.frameID] else { throw failure("una pose no tiene una foto original asociada") }
                let expected=String(format:"%08d",ordinal)+"."+URL(fileURLWithPath:frame.rgbFile).pathExtension.lowercased()
                try check(camera.sourceFile==frame.rgbFile && camera.timestamp==frame.timestamp && camera.inputFilename==expected && camera.sampleURLFilename==expected,
                          "el vínculo entre sample, filename y fotografía no coincide")
                try check(cameras.updateValue(camera,forKey:camera.frameID)==nil && samples.insert(camera.sampleID).inserted && filenames.insert(camera.inputFilename).inserted,
                          "la calibración contiene poses duplicadas")
            }
            let without=frames.filter { cameras[$0.id]==nil }, declared=Dictionary(grouping:native.inputsWithoutPose,by:{$0.frameID})
            try check(Set(declared.keys)==Set(without.map(\.id)) && declared.values.allSatisfy({$0.count==1}),"la lista de originales sin pose no coincide")
            for frame in without {
                let entry=declared[frame.id]![0],ordinal=ordinalByID[frame.id]!
                try check(entry.sourceFile==frame.rgbFile && entry.timestamp==frame.timestamp && entry.filename==String(format:"%08d",ordinal)+"."+URL(fileURLWithPath:frame.rgbFile).pathExtension.lowercased(),"un original sin pose perdió su identidad")
            }
            try fm.createDirectory(at:root.deletingLastPathComponent(),withIntermediateDirectories:true)
            let stage=root.deletingLastPathComponent().appendingPathComponent(".photographic-detail-"+UUID().uuidString)
            try fm.createDirectory(at:stage,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer { try? fm.removeItem(at:stage) }
            let scene=stage.appendingPathComponent("scene"), geometry=stage.appendingPathComponent("geometry"), source=stage.appendingPathComponent("source")
            for directory in [scene,geometry,source] { try fm.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]) }
            progress("Conservando modelo y calibración originales",0)
            let rawSHA=try verifiedCopy(rawUSDZ,to:source.appendingPathComponent("raw.usdz"))
            let calibrationSHA=try verifiedCopy(calibration,to:source.appendingPathComponent("calibration.json"))
            let datasetSHA=try verifiedCopy(dataset.appendingPathComponent("dataset.json"),to:source.appendingPathComponent("dataset.json"))
            let started=Date();var rows:[[String:Any]]=[], originals:[[String:Any]]=[], lutCount=0,totalBytes:UInt64=0
            var inputHashes=[rawUSDZ.path:rawSHA,calibration.path:calibrationSHA,dataset.appendingPathComponent("dataset.json").path:datasetSHA]
            for (index,frame) in frames.enumerated() {
                try ProcessingControl.checkpoint()
                let original=try safe(dataset,frame.rgbFile)
                try check(["jpg","jpeg"].contains(original.pathExtension.lowercased()),"se necesita la fotografía JPEG nativa, sin convertir o redimensionar")
                let dimensions=try imageMetadata(original)
                try check(dimensions.0==frame.imageWidth && dimensions.1==frame.imageHeight && (dimensions.2==nil || dimensions.2==1),"el tamaño u orientación del JPEG original no coincide")
                let posed=cameras[frame.id] != nil
                let archive=(posed ? "source-originals/" : "unregistered-originals/")+frame.rgbFile
                let archived=scene.appendingPathComponent(archive)
                try fm.createDirectory(at:archived.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let photoSHA=try verifiedCopy(original,to:archived);inputHashes[original.path]=photoSHA
                originals.append(["frameID":frame.id,"sourceFile":frame.rgbFile,"sourceSHA256":photoSHA,"archivedFile":archive,"status":posed ? "registered" : "unregistered",
                                  "reason":posed ? "Apple devolvió pose e intrínsecos nativos." : "Apple no devolvió pose estimada; el original se conserva y no se inventa una cámara."])
                if let camera=cameras[frame.id] {
                    let viewIndex=rows.count,stem=String(format:"%08d",viewIndex),photoName=stem+".jpg",cameraName=stem+".cam"
                    _=try verifiedCopy(archived,to:scene.appendingPathComponent(photoName),expected:photoSHA)
                    let projected=try cameraValues(camera,frame:frame)
                    let camText=projected.extrinsics.map(decimal).joined(separator:" ")+"\n"+projected.intrinsics.map(decimal).joined(separator:" ")+"\n"
                    let cameraURL=scene.appendingPathComponent(cameraName);try Data(camText.utf8).write(to:cameraURL,options:.withoutOverwriting)
                    var row:[String:Any]=["frameID":frame.id,"imageID":viewIndex+1,"sourceRelativePath":frame.rgbFile,"photo":photoName,"camera":cameraName,
                                          "photoSHA256":photoSHA,"cameraSHA256":try digest(cameraURL),"bytes":try byteCount(original),"nativeWidth":frame.imageWidth,"nativeHeight":frame.imageHeight,
                                          "sourceInputFilename":camera.inputFilename,"sourceSampleID":camera.sampleID,"nativePixelConversionMaxError":projected.error]
                    if let lens=camera.lensDistortion {
                        let payload=try lensPayload(lens,width:frame.imageWidth,height:frame.imageHeight)
                        let lensURL=scene.appendingPathComponent(stem+".forma-lut")
                        try Data(payload.text.utf8).write(to:lensURL,options:.withoutOverwriting);lutCount+=1
                        row["nativeLUT"]=["sidecar":lensURL.lastPathComponent,"sidecarSHA256":try digest(lensURL),"nativePayloadSHA256":payload.sha,
                                          "nativePayloadHashEncoding":"Float64LE center[2] followed by radial magnifications; exact decoded native calibration values",
                                          "center":lens.center,"radiusMax":payload.radius,"count":lens.radialLookupTable.count,
                                          "formula":"sourcePixel=center+(pinholePixel-center)*(1+interpLUT(radius/rMax)); zero-centered native pixels"]
                    }
                    totalBytes+=try byteCount(original);rows.append(row)
                }
                progress("Conservando fotos nativas y preparando cámaras",Double(index+1)/Double(frames.count))
            }
            let registry:[String:Any]=["schemaVersion":1,"originalFrameCount":frames.count,"registeredFrameCount":rows.count,"unregisteredFrameCount":without.count,"images":originals]
            try writeJSON(registry,to:scene.appendingPathComponent("source-originals-registry.json"))
            let unregistered=originals.filter { ($0["status"] as? String)=="unregistered" }
            let sceneReport:[String:Any]=["schemaVersion":1,"sourceDataset":dataset.path,"nativeCalibrationSHA256":calibrationSHA,"originalSourceFrameCount":frames.count,
                "registeredFrameCount":rows.count,"unregisteredFrameCount":without.count,"unregisteredOriginals":unregistered,"photoCount":rows.count,"photoBytes":totalBytes,"files":rows,
                "allRegisteredPhotographsCopied":true,"photoRasterResized":false,"photoBytesChangedByThisAdapter":false,"hardLinksUsed":false,
                "nativeLUTSidecarCount":lutCount,"projectionKind":lutCount>0 ? "AppleNativeRadialLUT" : "PINHOLE","requiresNativeLUTProjection":lutCount>0,
                "nativeGaussianCompatible":lutCount==0,"requiredTexreconCapability":lutCount>0 ? "FORMA_RADIAL_LUT_V1" : "PINHOLE",
                "pixelConvention":"CAM principal=(native principal+0.5)/dimension; worker subtracts0.5 before applying native radial LUT.",
                "sourceProjectionConvention":"C2W native Apple -> inverse -> diag(1,-1,-1) -> W2CV; same-session Raw coordinates; no ARKit registration or scale fitting.",
                "nativeCalibration": "../source/calibration.json","sourceOriginalsRegistry":"source-originals-registry.json","inputSHA256":inputHashes,
                "sameReconstructionSessionRequiredFromCaller":true,"seconds":Date().timeIntervalSince(started)]
            try writeJSON(sceneReport,to:scene.appendingPathComponent("prepare-report.json"))
            var labelMap:[[String:Any]]=[["label":0,"meaning":"Sin fotografía seleccionada; conservar textura Raw."]]
            for (index,row) in rows.enumerated() { labelMap.append(["label":index+1,"viewIndex":index,"photo":row["photo"]!,"camera":row["camera"]!,"frameID":row["frameID"]!,"photoSHA256":row["photoSHA256"]!]) }
            try writeJSON(["schemaVersion":1,"labelCount":rows.count+1,"labels":labelMap],to:geometry.appendingPathComponent("label-map.json"))
            progress("Exportando superficies y UV nativas",0)
            let geometryReport=try exportGeometry(source.appendingPathComponent("raw.usdz"),to:geometry,control:control,progress:progress)
            try check(try digest(rawUSDZ)==rawSHA && digest(calibration)==calibrationSHA && digest(dataset.appendingPathComponent("dataset.json"))==datasetSHA,"cambió el modelo, la calibración o el manifiesto durante la preparación")
            let report:[String:Any]=["schemaVersion":1,"faceCount":geometryReport.faceCount,"vertexCount":geometryReport.vertexCount,"state":"prepared-awaiting-view-labels",
                                   "originalSourceFrameCount":frames.count,"registeredFrameCount":rows.count,"unregisteredFrameCount":without.count,
                                   "sourceRawSHA256":rawSHA,"calibrationSHA256":calibrationSHA,"inputSHA256":inputHashes,
                                   "sourceRawSnapshot":"source/raw.usdz","sourceCalibrationSnapshot":"source/calibration.json","scene":"scene","geometry":"geometry",
                                   "nativeOnly":true,"pythonUsed":false,"geometryOrOriginalTexturesChanged":false]
            try writeJSON(report,to:stage.appendingPathComponent("preparation.json"));try ProcessingControl.checkpoint()
            try fm.moveItem(at:stage,to:root);progress("Fuentes y geometría preparadas",1)
            return try load(from:root)
        }
    }

    private static func cameraValues(_ camera:Camera,frame:RGBDFrameRecord) throws -> (extrinsics:[Double],intrinsics:[Double],error:Double) {
        let p=camera.nativeTransformColumnMajor
        guard let k=camera.intrinsicsColumnMajor else { throw failure("Apple no guardó los intrínsecos de una cámara; no se sustituyen por datos ARKit") }
        try check(p.count==16 && k.count==9 && (p+k).allSatisfy(\.isFinite),"la pose o los intrínsecos no son finitos")
        try check(camera.inputImageWidth==frame.imageWidth && camera.inputImageHeight==frame.imageHeight && (camera.inputImageOrientation==nil || camera.inputImageOrientation==1),"la calibración no corresponde al raster JPEG nativo")
        try check(k[0]>0 && k[4]>0 && max(abs(k[1]),abs(k[3]),abs(k[2]),abs(k[5]),abs(k[8]-1))<1e-6,"los intrínsecos requieren una transformación de raster no admitida; no se ignora skew")
        try check(max(abs(p[3]),abs(p[7]),abs(p[11]),abs(p[15]-1))<1e-6,"la pose no es una transformación afín")
        let matrix=simd_double4x4(columns:(SIMD4(p[0],p[1],p[2],p[3]),SIMD4(p[4],p[5],p[6],p[7]),SIMD4(p[8],p[9],p[10],p[11]),SIMD4(p[12],p[13],p[14],p[15])))
        let rotation=simd_double3x3(columns:(SIMD3(p[0],p[1],p[2]),SIMD3(p[4],p[5],p[6]),SIMD3(p[8],p[9],p[10])))
        let gram=rotation.transpose*rotation
        try check((0..<3).allSatisfy { c in (0..<3).allSatisfy { r in abs(gram[c][r]-(c==r ? 1:0))<1e-3 } } && abs(simd_determinant(rotation)-1)<1e-3,"la cámara no es rígida; no se introduce una escala aproximada")
        let cv=simd_double4x4(diagonal:SIMD4(1,-1,-1,1))*matrix.inverse
        let r=simd_double3x3(columns:(SIMD3(cv.columns.0.x,cv.columns.0.y,cv.columns.0.z),SIMD3(cv.columns.1.x,cv.columns.1.y,cv.columns.1.z),SIMD3(cv.columns.2.x,cv.columns.2.y,cv.columns.2.z)))
        let normalized=simd_double3x3(simd_normalize(simd_quatd(r)))
        let t=cv.columns.3
        let e=[t.x,t.y,t.z,normalized[0][0],normalized[1][0],normalized[2][0],normalized[0][1],normalized[1][1],normalized[2][1],normalized[0][2],normalized[1][2],normalized[2][2]]
        let w=Double(frame.imageWidth),h=Double(frame.imageHeight),aspect=k[4]/k[0],f=w/h*aspect>=1 ? k[0]/w : k[4]/h
        let cam=[f,0,0,aspect,(k[6]+0.5)/w,(k[7]+0.5)/h]
        let fx=w/h*aspect>=1 ? f*w : f*h/aspect,fy=w/h*aspect>=1 ? f*w*aspect : f*h
        let error=max(abs(fx-k[0]),abs(fy-k[4]),abs(cam[4]*w-0.5-k[6]),abs(cam[5]*h-0.5-k[7]))
        try check((e+cam).allSatisfy(\.isFinite) && error<1e-6,"la conversión CAM no conserva los intrínsecos")
        return (e,cam,error)
    }
    private static func lensPayload(_ lens:Lens,width:Int,height:Int) throws -> (text:String,radius:Double,sha:String) {
        try check(lens.center.count==2 && lens.radialLookupTable.count>=2 && (lens.center+lens.radialLookupTable).allSatisfy(\.isFinite),"la LUT nativa no es válida")
        let cx=lens.center[0],cy=lens.center[1]
        try check(cx>=0 && cx<=Double(width-1) && cy>=0 && cy<=Double(height-1) && lens.radialLookupTable.allSatisfy({$0 > -1}),"la LUT nativa no tiene un dominio físico válido")
        let radius=hypot(max(cx,Double(width)-cx),max(cy,Double(height)-cy))
        let text="FORMA_RADIAL_LUT_V1\n\(width) \(height) "+[cx,cy,radius].map(decimal).joined(separator:" ")+" \(lens.radialLookupTable.count)\n"+lens.radialLookupTable.map(decimal).joined(separator:"\n")+"\n"
        var raw=Data();for value in lens.center+lens.radialLookupTable { append(value.bitPattern,to:&raw) }
        return (text,radius,SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined())
    }

    private struct GeometrySummary { var faceCount:Int; var vertexCount:Int }
    private static func exportGeometry(_ model:URL,to directory:URL,control:ProcessingControl?,progress:@Sendable(String,Double)->Void) throws -> GeometrySummary {
        try autoreleasepool {
            let archive=try StoredUSDZArchive(url:model), names=Set(archive.entries.map(\.name))
            let extracted=try archive.extract(toPrivateDirectory:directory.appendingPathComponent("extracted")) { p in progress("Conservando atlas nativos",p.fraction) }
            let asset=MDLAsset(url:model);var parts:[Part]=[],vertices=0,faces=0
            func visit(_ object:MDLObject) throws {
                try ProcessingControl.checkpoint()
                if let mesh=object as? MDLMesh {
                    guard let submeshes=mesh.submeshes as? [MDLSubmesh],!submeshes.isEmpty else { throw failure("una superficie no tiene submallas") }
                    try check(mesh.vertexCount>0,"una malla no tiene vértices")
                    let transform=MDLTransform.globalTransform(with:mesh,atTime:0)
                    let values=(0..<4).flatMap { c in (0..<4).map { transform[c][$0] } }
                    try check(values.allSatisfy(\.isFinite) && abs(transform.columns.0.w)<1e-6 && abs(transform.columns.1.w)<1e-6 && abs(transform.columns.2.w)<1e-6 && abs(transform.columns.3.w-1)<1e-6,"la transformación global de una malla no es finita o afín")
                    let next=vertices.addingReportingOverflow(mesh.vertexCount)
                    try check(!next.overflow && next.partialValue<=Int(UInt32.max),"el formato de índices del motor no puede representar esta malla")
                    parts.append(Part(mesh:mesh,transform:transform,offset:vertices,submeshes:submeshes));vertices=next.partialValue
                    for submesh in submeshes {
                        try check(submesh.geometryType == .triangles && submesh.indexCount%3==0,"la malla no está triangulada; no se inventan ni filtran caras")
                        let element=try indexBytes(submesh.indexType),required=submesh.indexCount.multipliedReportingOverflow(by:element)
                        try check(!required.overflow && required.partialValue<=submesh.indexBuffer.length,"un buffer de índices está incompleto")
                        let next=faces.addingReportingOverflow(submesh.indexCount/3);try check(!next.overflow,"el número de caras no se puede representar");faces=next.partialValue
                    }
                }
                for child in object.children.objects { try visit(child) }
            }
            for i in 0..<asset.count { try visit(asset.object(at:i)) }
            try check(vertices>0 && faces>0,"el modelo no contiene superficies trianguladas")
            let plyURL=directory.appendingPathComponent("mesh.ply"),cornerURL=directory.appendingPathComponent("corners.bin"),materialURL=directory.appendingPathComponent("material-ids.bin")
            let ply=try newFile(plyURL),cornerOutput=try newFile(cornerURL),materialOutput=try newFile(materialURL)
            defer {try? ply.close();try? cornerOutput.close();try? materialOutput.close()}
            // Same binary layout/header as the independently checked research export.
            let header="ply\nformat binary_little_endian 1.0\ncomment Forma CPU research: original triangle order and global mesh transforms; no UVs, filters or reconstruction\nelement vertex \(vertices)\nproperty float x\nproperty float y\nproperty float z\nelement face \(faces)\nproperty list uchar uint vertex_indices\nend_header\n"
            try ply.write(contentsOf:Data(header.utf8))
            var worldParts:[[SIMD3<Float>]]=[],vertexChunk=Data(),vertexHash=SHA256(),faceHash=SHA256()
            var minimum=SIMD3<Float>(repeating:.infinity),maximum=SIMD3<Float>(repeating:-.infinity)
            for part in parts {
                guard let positions=part.mesh.vertexAttributeData(forAttributeNamed:MDLVertexAttributePosition,as:.float3) else { throw failure("una malla no expone posiciones float3") }
                try bufferBounds(part.mesh.vertexCount,stride:positions.stride,bytes:12,available:positions.bufferSize)
                var world:[SIMD3<Float>]=[];world.reserveCapacity(part.mesh.vertexCount)
                for i in 0..<part.mesh.vertexCount {
                    if i & 8191 == 0 { try ProcessingControl.checkpoint() }
                    let p=positions.dataStart.advanced(by:i*positions.stride)
                    let transformed=part.transform*SIMD4<Float>(p.loadUnaligned(as:Float.self),p.advanced(by:4).loadUnaligned(as:Float.self),p.advanced(by:8).loadUnaligned(as:Float.self),1)
                    let value=SIMD3(transformed.x,transformed.y,transformed.z)
                    try check(value.x.isFinite && value.y.isFinite && value.z.isFinite,"un vértice global no es finito")
                    minimum=simd_min(minimum,value);maximum=simd_max(maximum,value);world.append(value)
                    append(value.x.bitPattern,to:&vertexChunk);append(value.y.bitPattern,to:&vertexChunk);append(value.z.bitPattern,to:&vertexChunk)
                    if vertexChunk.count>=1<<20 {try ply.write(contentsOf:vertexChunk);vertexHash.update(data:vertexChunk);vertexChunk.removeAll(keepingCapacity:true)}
                }
                worldParts.append(world)
            }
            if !vertexChunk.isEmpty {try ply.write(contentsOf:vertexChunk);vertexHash.update(data:vertexChunk)}
            var cornerChunk=Data(),materialChunk=Data(),plyFaces=Data(),canonicalIndices=Data(),emitted=0
            var materials:[[String:Any]]=[],materialByEntry:[String:Int]=[:],materialFaceCounts:[Int]=[]
            func flush() throws {
                if !cornerChunk.isEmpty {
                    try ProcessingControl.checkpoint();try cornerOutput.write(contentsOf:cornerChunk);try materialOutput.write(contentsOf:materialChunk);try ply.write(contentsOf:plyFaces)
                    faceHash.update(data:canonicalIndices)
                    cornerChunk.removeAll(keepingCapacity:true);materialChunk.removeAll(keepingCapacity:true);plyFaces.removeAll(keepingCapacity:true);canonicalIndices.removeAll(keepingCapacity:true)
                }
            }
            for (partIndex,part) in parts.enumerated() {
                guard let uv=part.mesh.vertexAttributeData(forAttributeNamed:MDLVertexAttributeTextureCoordinate,as:.float2) else { throw failure("una superficie no expone UV nativas") }
                try bufferBounds(part.mesh.vertexCount,stride:uv.stride,bytes:8,available:uv.bufferSize)
                for submesh in part.submeshes {
                    guard let material=submesh.material else { throw failure("una superficie no tiene material") }
                    let entry=try diffuseTexture(material,archive:model,entries:names)
                    let materialIndex:Int
                    if let existing=materialByEntry[entry] {materialIndex=existing}
                    else {
                        guard let imageURL=extracted[entry] else {throw failure("falta un atlas original dentro del USDZ")}
                        let dimensions=try imageMetadata(imageURL)
                        materialIndex=materials.count;materialByEntry[entry]=materialIndex;materialFaceCounts.append(0)
                        materials.append(["index":materialIndex,"name":material.name,"textureEntry":entry,"textureFile":"extracted/"+entry,"width":dimensions.0,"height":dimensions.1,"textureSHA256":try digest(imageURL)])
                    }
                    let mapped=submesh.indexBuffer.map()
                    for offset in stride(from:0,to:submesh.indexCount,by:3) {
                        if emitted & 4095 == 0 {try ProcessingControl.checkpoint();progress("Exportando geometría y UV sin modificarlas",Double(emitted)/Double(faces))}
                        plyFaces.append(3)
                        for c in 0..<3 {
                            let local=try index(offset+c,submesh:submesh,pointer:mapped.bytes)
                            try check(local<part.mesh.vertexCount,"un índice apunta fuera de los vértices originales")
                            let global=UInt32(part.offset+local);append(global,to:&plyFaces);append(global,to:&canonicalIndices)
                            let value=worldParts[partIndex][local],p=uv.dataStart.advanced(by:local*uv.stride)
                            let coordinate=SIMD2<Float>(p.loadUnaligned(as:Float.self),p.advanced(by:4).loadUnaligned(as:Float.self))
                            try check(coordinate.x.isFinite && coordinate.y.isFinite && (0...1).contains(coordinate.x) && (0...1).contains(coordinate.y),"una UV no es finita o cae fuera del atlas; el original permanece intacto")
                            append(value.x.bitPattern,to:&cornerChunk);append(value.y.bitPattern,to:&cornerChunk);append(value.z.bitPattern,to:&cornerChunk)
                            append(coordinate.x.bitPattern,to:&cornerChunk);append(coordinate.y.bitPattern,to:&cornerChunk)
                        }
                        append(UInt32(materialIndex),to:&materialChunk);materialFaceCounts[materialIndex]+=1;emitted+=1
                        if cornerChunk.count>=1<<20 {try flush()}
                    }
                }
            }
            try flush();try check(emitted==faces,"no se emitieron todas las caras")
            for handle in [ply,cornerOutput,materialOutput] {try handle.synchronize();try handle.close()}
            for i in materials.indices {materials[i]["faceCount"]=materialFaceCounts[i]}
            let vertexSHA=hex(vertexHash.finalize()),faceSHA=hex(faceHash.finalize())
            try validateGeneratedGeometry(directory,vertices:vertices,faces:faces)
            let outputHashes=["mesh.ply":try digest(plyURL),"corners.bin":try digest(cornerURL),"material-ids.bin":try digest(materialURL),"label-map.json":try digest(directory.appendingPathComponent("label-map.json"))]
            let sourceReport:[String:Any]=["schemaVersion":1,"vertexCount":vertices,"faceCount":faces,"inputMeshSHA256":outputHashes["mesh.ply"]!,"vertexDataSHA256":vertexSHA,"faceIndexDataSHA256":faceSHA,
                                          "worldBoundsMin":[minimum.x,minimum.y,minimum.z],"worldBoundsMax":[maximum.x,maximum.y,maximum.z],"outputSHA256":outputHashes]
            try writeJSON(sourceReport,to:directory.appendingPathComponent("geometry-source.json"))
            let manifest:[String:Any]=["schemaVersion":1,"faceCount":faces,"vertexCount":vertices,"cornersFile":"corners.bin","cornerStrideBytes":20,"cornersPerFace":3,
                "cornerFields":"Float32LE worldXYZ[3], Float32LE nativeUV[2]; no SIMD padding","materialIDsFile":"material-ids.bin","labelsFile":"labels.bin","indexType":"UInt32LE",
                "geometryAndLabelOrderValidated":false,"state":"awaiting-worker-labels","materials":materials,"labelMapFile":"label-map.json","outputSHA256":outputHashes,
                "validation":["allPLYVerticesCompared":true,"allPLYFaceIndicesCompared":true,"maxWorldXYZDifference":0,"faceIndexOrderExact":true,"windingPreserved":true,"mveReceiptValidated":false],
                "coordinatePolicy":"ModelIO globalTransform(time0); all triangle corners equal emitted PLY positions. No welding, filtering, scale registration or UV changes.",
                "UVOrigin":"Native USD bottom-left; PNG row=(1-v)*height.","GPUUsed":false]
            try writeJSON(manifest,to:directory.appendingPathComponent("manifest.json"))
            return GeometrySummary(faceCount:faces,vertexCount:vertices)
        }
    }

    private static func validateGeneratedGeometry(_ directory:URL,vertices:Int,faces:Int) throws {
        let ply=try Data(contentsOf:directory.appendingPathComponent("mesh.ply"),options:.mappedIfSafe)
        let corners=try Data(contentsOf:directory.appendingPathComponent("corners.bin"),options:.mappedIfSafe)
        guard let offset=ply.range(of:Data("end_header\n".utf8))?.upperBound else {throw failure("falta la cabecera PLY generada")}
        try check(ply.count==offset+vertices*12+faces*13 && corners.count==faces*60,"los buffers de geometría generados no tienen los tamaños esperados")
        let faceOffset=offset+vertices*12
        try ply.withUnsafeBytes { p in try corners.withUnsafeBytes { c in
            for face in 0..<faces {
                if face & 4095 == 0 {try ProcessingControl.checkpoint()}
                try check(ply[faceOffset+face*13]==3,"se emitió una cara no triangular")
                for corner in 0..<3 {
                    let vertex=UInt32(littleEndian:p.loadUnaligned(fromByteOffset:faceOffset+face*13+1+corner*4,as:UInt32.self))
                    try check(vertex<vertices,"un índice PLY generado no es válido")
                    for channel in 0..<3 {
                        let a=p.loadUnaligned(fromByteOffset:offset+Int(vertex)*12+channel*4,as:UInt32.self)
                        let b=c.loadUnaligned(fromByteOffset:face*60+corner*20+channel*4,as:UInt32.self)
                        try check(a==b,"una esquina UV no conserva las coordenadas globales PLY")
                    }
                }
            }
        } }
    }

    static func attachLabels(_ labels:URL,geometryReceipt:URL,to prepared:Prepared,control:ProcessingControl?=nil) throws -> URL {
        try ProcessingControl.withControl(control) {
            try ProcessingControl.checkpoint();try regular(labels);try regular(geometryReceipt)
            let directory=prepared.geometryDirectory,source=try jsonObject(safe(directory,"geometry-source.json")),receipt=try jsonObject(geometryReceipt)
            let scene=try jsonObject(safe(prepared.sceneDirectory,"prepare-report.json"))
            let views=try integer(scene,"photoCount"),faces=prepared.faceCount,vertices=prepared.vertexCount
            let plySHA=try digest(safe(directory,"mesh.ply"))
            try check(try integer(receipt,"schemaVersion")==1 && integer(receipt,"vertexCount")==vertices && integer(receipt,"faceCount")==faces && integer(receipt,"removedFaces")==0,
                      "el recibo del motor no coincide con la geometría preparada")
            try check(receipt["faceIndexOrderExact"] as? Bool==true && receipt["worldVerticesExact"] as? Bool==true,"el motor cambió posiciones u orden de caras")
            try check(receipt["inputMeshSHA256"] as? String==plySHA && source["inputMeshSHA256"] as? String==plySHA,"el recibo pertenece a otra malla")
            for (key,sourceKey) in [("beforeVertexSHA256","vertexDataSHA256"),("afterVertexSHA256","vertexDataSHA256"),("beforeFaceIndexSHA256","faceIndexDataSHA256"),("afterFaceIndexSHA256","faceIndexDataSHA256")] {
                try check(receipt[key] as? String==source[sourceKey] as? String,"el motor no conservó los datos geométricos canónicos")
            }
            try check(try integer(receipt,"labelElementBytes")==8 && integer(receipt,"labelCount")==faces && integer(receipt,"textureViewCount")==views && receipt["labelToView"] as? String=="zero=unassigned;N=viewIndex(N-1)","el formato u orden de fotografías de las etiquetas no coincide")
            let rawSHA=try digest(labels);try check(receipt["labelsSHA256"] as? String==rawSHA,"cambió el archivo de etiquetas del motor")
            let raw=try Data(contentsOf:labels,options:.mappedIfSafe);try check(raw.count==faces*8,"el motor no emitió una etiqueta UInt64LE por cara")
            guard let inventory=scene["files"] as? [[String:Any]],inventory.count==views else {throw failure("falta el índice de cámaras preparado")}
            for (index,row) in inventory.enumerated() {
                let stem=String(format:"%08d",index)
                try check(row["photo"] as? String==stem+".jpg" && row["camera"] as? String==stem+".cam","el orden de vistas del motor no coincide con las fotos originales")
            }
            var manifest=try jsonObject(safe(directory,"manifest.json"))
            guard let geometryHashes=source["outputSHA256"] as? [String:String] else {throw failure("falta el índice de integridad geométrica")}
            for (name,expected) in geometryHashes {try check(try digest(safe(directory,name))==expected,"cambió un buffer de geometría antes de añadir las etiquetas")}
            let temporary=directory.appendingPathComponent(".labels-"+UUID().uuidString+".bin")
            let output=try newFile(temporary);defer{try? output.close();try? FileManager.default.removeItem(at:temporary)}
            var converted=Data(),histogram:[Int:Int]=[:]
            try raw.withUnsafeBytes { bytes in
                for face in 0..<faces {
                    if face & 4095 == 0 {try ProcessingControl.checkpoint()}
                    let value=UInt64(littleEndian:bytes.loadUnaligned(fromByteOffset:face*8,as:UInt64.self))
                    try check(value<=UInt64(views) && value<=UInt64(UInt32.max),"una etiqueta apunta fuera de las fotografías registradas")
                    append(UInt32(value),to:&converted);histogram[Int(value),default:0]+=1
                    if converted.count>=1<<20 {try output.write(contentsOf:converted);converted.removeAll(keepingCapacity:true)}
                }
            }
            if !converted.isEmpty {try output.write(contentsOf:converted)};try output.synchronize();try output.close();try ProcessingControl.checkpoint()
            let final=directory.appendingPathComponent("labels.bin"),labelSHA=try digest(temporary)
            if FileManager.default.fileExists(atPath:final.path) {try check(try digest(safe(directory,"labels.bin"))==labelSHA,"ya hay otras etiquetas; se requiere una carpeta de trabajo independiente")}
            else {try FileManager.default.moveItem(at:temporary,to:final)}
            let receiptURL=directory.appendingPathComponent("mve-prepare-validation.json"),receiptSHA=try digest(geometryReceipt)
            if FileManager.default.fileExists(atPath:receiptURL.path) {try check(try digest(safe(directory,"mve-prepare-validation.json"))==receiptSHA,"hay un recibo distinto en esta carpeta")}
            else {_=try verifiedCopy(geometryReceipt,to:receiptURL,expected:receiptSHA)}
            var outputHashes=geometryHashes;outputHashes["labels.bin"]=labelSHA;outputHashes["mve-prepare-validation.json"]=receiptSHA
            manifest["outputSHA256"]=outputHashes;manifest["geometryAndLabelOrderValidated"]=true;manifest["state"]="ready-for-reprojection"
            manifest["validation"]=["allPLYVerticesCompared":true,"allPLYFaceIndicesCompared":true,"maxWorldXYZDifference":0,"faceIndexOrderExact":true,"windingPreserved":true,
                                    "mvePrepareFacesRemoved":0,"mvePrepareFaceOrderExact":true,"mveReceiptValidated":true,"MVEValidation":"mve-prepare-validation.json"]
            manifest["labelFormatFile"]="label-format.json"
            try writeJSON(["schemaVersion":1,"originalType":"UInt64LE","outputType":"UInt32LE","faceCount":faces,"rawLabelsSHA256":rawSHA,"labelCount":views+1,
                           "labelHistogram":Dictionary(uniqueKeysWithValues:histogram.map{(String($0.key),$0.value)}),"meaning":"0=unassigned;N=scene sorted viewIndex(N-1)"],to:directory.appendingPathComponent("label-format.json"))
            try check(try digest(labels)==rawSHA && digest(geometryReceipt)==receiptSHA,"cambió el resultado del motor durante la validación")
            try writeJSON(manifest,to:prepared.manifestURL)
            return directory
        }
    }

    private static func diffuseTexture(_ material:MDLMaterial,archive:URL,entries:Set<String>) throws -> String {
        var matches=Set<String>()
        for property in material.properties(with:.baseColor) {
            if let transform=property.textureSamplerValue?.transform {try check(transform.matrix==matrix_identity_float4x4,"un material transforma sus UV; no se modifica silenciosamente")}
            let references=[property.stringValue,property.urlValue?.absoluteString,property.textureSamplerValue?.texture?.name].compactMap{$0}
            for reference in references {
                if reference==archive.path || reference==archive.absoluteString {continue}
                var name:String?
                for prefix in [archive.path+"[",archive.absoluteString+"["] where reference.hasPrefix(prefix) && reference.hasSuffix("]") {name=String(reference.dropFirst(prefix.count).dropLast())}
                if name==nil && entries.contains(reference) {name=reference}
                if let name {try check(entries.contains(name) && name.lowercased().hasSuffix(".png"),"un atlas está ausente, es externo o no es PNG");matches.insert(name)}
            }
        }
        try check(matches.count==1,"una superficie necesita exactamente un atlas difuso PNG interno")
        return matches.first!
    }
    private static func indexBytes(_ type:MDLIndexBitDepth) throws -> Int {
        switch type {case .uInt8:return 1;case .uInt16:return 2;case .uInt32:return 4;default:throw failure("el formato de índices no está admitido")}
    }
    private static func index(_ index:Int,submesh:MDLSubmesh,pointer:UnsafeMutableRawPointer) throws -> Int {
        switch submesh.indexType {case .uInt8:return Int(pointer.advanced(by:index).loadUnaligned(as:UInt8.self));case .uInt16:return Int(pointer.advanced(by:index*2).loadUnaligned(as:UInt16.self));case .uInt32:return Int(pointer.advanced(by:index*4).loadUnaligned(as:UInt32.self));default:throw failure("el formato de índices no está admitido")}
    }
    private static func bufferBounds(_ count:Int,stride:Int,bytes:Int,available:Int) throws {
        try check(count>0 && stride>=bytes,"el stride de un atributo no es válido")
        let offset=(count-1).multipliedReportingOverflow(by:stride),required=offset.partialValue.addingReportingOverflow(bytes)
        try check(!offset.overflow && !required.overflow && required.partialValue<=available,"un buffer de atributos está incompleto")
    }
    private static func imageMetadata(_ url:URL) throws -> (Int,Int,Int?) {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=(properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,let height=(properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,width>0,height>0 else {throw failure("no se pudo leer el raster nativo de una imagen")}
        return (width,height,(properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue)
    }
    private static func verifiedCopy(_ source:URL,to destination:URL,expected:String?=nil) throws -> String {
        try regular(source);try ProcessingControl.checkpoint()
        let before=try digest(source);if let expected {try check(before==expected,"una fuente cambió antes de copiarse")}
        try check(!FileManager.default.fileExists(atPath:destination.path),"el destino de una copia ya existe")
        let cloned=source.withUnsafeFileSystemRepresentation { a in destination.withUnsafeFileSystemRepresentation { b in a != nil && b != nil && clonefile(a!,b!,0)==0 } }
        if !cloned {try CooperativeFileIO.copyFile(source,to:destination)}
        try regular(destination)
        let a=try FileManager.default.attributesOfItem(atPath:source.path),b=try FileManager.default.attributesOfItem(atPath:destination.path)
        try check(a[.systemFileNumber] as? NSNumber != b[.systemFileNumber] as? NSNumber || a[.systemNumber] as? NSNumber != b[.systemNumber] as? NSNumber,"no se permiten hardlinks a originales")
        try check(try digest(destination)==before && digest(source)==before,"cambió una fuente al conservar su copia")
        try ProcessingControl.checkpoint();return before
    }
    private static func digest(_ url:URL) throws -> String {
        var hash=SHA256();try CooperativeFileIO.readChunks(url){hash.update(data:$0)};return hex(hash.finalize())
    }
    private static func byteCount(_ url:URL) throws -> UInt64 {try regular(url);let value=try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber;guard let value else{throw failure("no se pudo leer el tamaño de un archivo")};return value.uint64Value}
    private static func regular(_ url:URL) throws {let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]);try check(values.isRegularFile==true && values.isSymbolicLink != true,"un archivo no es regular o usa un enlace simbólico")}
    private static func safe(_ root:URL,_ relative:String) throws -> URL {
        try check(!relative.isEmpty && !relative.hasPrefix("/") && !relative.contains("\\") && !relative.contains("\0") && !relative.contains(":"),"una ruta relativa no es segura")
        var url=root
        for component in relative.split(separator:"/",omittingEmptySubsequences:false) {
            try check(!component.isEmpty && component != "." && component != "..","una ruta contiene componentes no seguros")
            url.appendPathComponent(String(component));let value=try url.resourceValues(forKeys:[.isSymbolicLinkKey]);try check(value.isSymbolicLink != true,"un archivo está enlazado fuera de la captura")
        }
        try regular(url)
        try check(url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path+"/"),"un archivo sale de la carpeta de origen")
        return url
    }
    private static func integer(_ object:[String:Any],_ key:String) throws -> Int {guard let value=object[key] as? NSNumber,value.doubleValue.isFinite,value.doubleValue==Double(value.intValue),value.intValue>=0 else{throw failure("falta un entero no negativo: "+key)};return value.intValue}
    private static func jsonObject(_ url:URL) throws -> [String:Any] {guard let result=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any] else{throw failure("un documento JSON no es válido")};return result}
    private static func writeJSON(_ object:[String:Any],to url:URL) throws {try ProcessingControl.checkpoint();try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)}
    private static func newFile(_ url:URL) throws -> FileHandle {try check(!FileManager.default.fileExists(atPath:url.path) && FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]),"no se pudo crear un archivo de trabajo nuevo");return try FileHandle(forWritingTo:url)}
    private static func append<T:FixedWidthInteger>(_ value:T,to data:inout Data) {var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)}}
    private static func hex(_ digest:SHA256.Digest) -> String {digest.map{String(format:"%02x",$0)}.joined()}
    private static func decimal(_ value:Double) -> String {String(format:"%.17g",locale:Locale(identifier:"en_US_POSIX"),value)}
    private static func failure(_ reason:String) -> PreparationError {PreparationError(reason:reason)}
    private static func check(_ condition:Bool,_ reason:String) throws {if !condition {throw failure(reason)}}
}
