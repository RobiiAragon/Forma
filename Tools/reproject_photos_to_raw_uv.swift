import Foundation
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import CryptoKit
import UniformTypeIdentifiers
import simd

/// Research-only raster reprojection of selected native photographs onto existing Raw UVs.
@main struct ReprojectPhotosToRawUV {
    struct Failure: LocalizedError { var errorDescription: String? }
    struct Uniforms {
        var row0: SIMD4<Float>; var row1: SIMD4<Float>; var row2: SIMD4<Float>
        var intrinsics: SIMD4<Float>; var lens: SIMD4<Float>; var image: SIMD4<Float>
    }
    static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Corner { packed_float3 world; packed_float2 uv; };
    struct Uniforms { float4 row0; float4 row1; float4 row2; float4 k; float4 lens; float4 image; };
    struct Varying { float4 position [[position]]; float3 world; };
    vertex Varying project_uv(uint id [[vertex_id]], device const Corner *corners [[buffer(0)]]) {
        Varying out; float2 uv=float2(corners[id].uv);
        out.position=float4(uv*2.0f-1.0f,0,1); out.world=float3(corners[id].world); return out;
    }
    fragment float4 project_photo(Varying in [[stage_in]], constant Uniforms &u [[buffer(1)]],
        device const float *lut [[buffer(2)]], device atomic_uint *overlaps [[buffer(3)]],
        texture2d<float> photo [[texture(0)]], sampler linear_sampler [[sampler(0)]]) {
        float4 world=float4(in.world,1);
        float3 camera=float3(dot(u.row0,world),dot(u.row1,world),dot(u.row2,world));
        if (!all(isfinite(camera)) || camera.z<=0) discard_fragment();
        float2 p=camera.xy/camera.z*u.k.xy+u.k.zw;
        float2 delta=p-u.lens.xy; float radius=length(delta);
        uint count=uint(u.lens.w+0.5f);
        float position=clamp(radius/u.lens.z,0.0f,1.0f)*float(count-1);
        uint index=min(uint(floor(position)),count-2); float fraction=clamp(position-float(index),0.0f,1.0f);
        float magnification=mix(lut[index],lut[index+1],fraction);
        p=u.lens.xy+delta*(1.0f+magnification);
        if (!all(isfinite(p)) || any(p<0.0f) || any(p>u.image.xy-1.0f)) discard_fragment();
        float3 rgb=photo.sample(linear_sampler,(p+0.5f)/u.image.xy).rgb;
        if (u.image.w>0.5f) {
            uint2 pixel=uint2(in.position.xy); uint offset=pixel.y*uint(u.image.z)+pixel.x;
            atomic_fetch_add_explicit(&overlaps[offset],1,memory_order_relaxed);
        }
        return float4(rgb,1);
    }
    """#
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(errorDescription: message) } }
    static func sha(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x",$0) }.joined()
    }
    static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw Failure(errorDescription: "Invalid JSON object: \(url.path)") }; return value
    }
    static func file(_ directory: URL, _ relative: String) throws -> URL {
        try require(!relative.isEmpty && !relative.hasPrefix("/") && !relative.contains("\\") && !relative.contains("\0") && !relative.contains(":"), "Unsafe relative path.")
        var url = directory
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            try require(!component.isEmpty && component != "." && component != "..", "Unsafe relative path component.")
            url.appendPathComponent(String(component))
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey]); try require(info.isSymbolicLink != true, "Symlink input rejected.")
        }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey]); try require(info.isRegularFile == true, "Missing regular input: \(url.path)")
        return url
    }
    static func number(_ object: [String: Any], _ key: String) throws -> Int {
        guard let value = object[key] as? NSNumber, value.doubleValue.isFinite,
              value.doubleValue == Double(value.intValue), value.intValue >= 0 else { throw Failure(errorDescription: "Missing nonnegative integer: \(key)") }; return value.intValue
    }
    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else { throw Failure(errorDescription: "Missing string: \(key)") }; return value
    }
    static func decodeUInt32(_ data: Data, _ index: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index*4, as: UInt32.self)) }
    }
    static func parseCamera(_ camera: URL, _ lensURL: URL, _ expectedWidth: Int, _ expectedHeight: Int) throws -> (Uniforms,[Float]) {
        let lines = try String(contentsOf: camera, encoding: .utf8).split(whereSeparator: \.isNewline)
        try require(lines.count == 2, "Camera must have exactly two lines.")
        let e = lines[0].split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        let k = lines[1].split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        try require(e.count == 12 && k.count == 6 && (e+k).allSatisfy(\.isFinite), "Malformed finite CAM values.")
        try require(k[0] > 0 && k[1] == 0 && k[2] == 0 && k[3] > 0, "Only base CAM intrinsics plus native sidecar are supported.")
        let fields = try String(contentsOf: lensURL, encoding: .utf8).split(whereSeparator: \.isWhitespace)
        try require(fields.count >= 9 && fields[0] == "FORMA_RADIAL_LUT_V1", "Missing native LUT capability/header.")
        guard let w = Int(fields[1]), let h = Int(fields[2]), let cx = Double(fields[3]), let cy = Double(fields[4]), let radius = Double(fields[5]), let count = Int(fields[6]) else { throw Failure(errorDescription: "Invalid native LUT header.") }
        try require(w == expectedWidth && h == expectedHeight && count >= 2 && fields.count == 7+count, "Native LUT dimension/count mismatch.")
        let table = fields.dropFirst(7).compactMap { Float($0) }
        try require(table.count == count && table.allSatisfy(\.isFinite) && cx.isFinite && cy.isFinite && radius.isFinite && radius > 0, "Invalid native lens payload.")
        let actualRadius = hypot(max(cx,Double(w)-cx),max(cy,Double(h)-cy))
        try require(abs(radius-actualRadius) < 1e-8*max(1,actualRadius), "Native maximum-radius convention mismatch.")
        let fx: Double, fy: Double
        if Double(w)/Double(h)*k[3] < 1 { fx=k[0]*Double(h)/k[3]; fy=k[0]*Double(h) }
        else { fx=k[0]*Double(w); fy=k[0]*Double(w)*k[3] }
        // MVE subtracts0.5 after K projection; recover the exact native integer-centered K.
        let uniforms = Uniforms(row0: SIMD4(Float(e[3]),Float(e[4]),Float(e[5]),Float(e[0])),
            row1: SIMD4(Float(e[6]),Float(e[7]),Float(e[8]),Float(e[1])), row2: SIMD4(Float(e[9]),Float(e[10]),Float(e[11]),Float(e[2])),
            intrinsics: SIMD4(Float(fx),Float(fy),Float(k[4]*Double(w)-0.5),Float(k[5]*Double(h)-0.5)),
            lens: SIMD4(Float(cx),Float(cy),Float(radius),Float(count)),image: SIMD4(Float(w),Float(h),0,0))
        return (uniforms,table)
    }
    static func checkCommand(_ command: MTLCommandBuffer) throws {
        command.commit(); command.waitUntilCompleted()
        try require(command.status == .completed, command.error?.localizedDescription ?? "Metal operation did not complete.")
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst()); var options: [String:String] = [:]; var checkOverlap = false; var i = 0
        while i < args.count {
            if args[i] == "--check-overlap" { checkOverlap=true; i+=1; continue }
            try require(i+1 < args.count && ["--input","--scene","--output","--material"].contains(args[i]), "Usage: reproject-photos-to-raw-uv --input UV_INPUT --scene NATIVE_LUT_SCENE --material 2 --output NEW_DIRECTORY [--check-overlap]")
            options[args[i]]=args[i+1]; i+=2
        }
        guard let inputPath=options["--input"], let scenePath=options["--scene"], let outputPath=options["--output"], let material=Int(options["--material"] ?? "2") else { throw Failure(errorDescription: "Missing CLI arguments.") }
        let input=URL(fileURLWithPath:inputPath).standardizedFileURL, scene=URL(fileURLWithPath:scenePath).standardizedFileURL, output=URL(fileURLWithPath:outputPath).standardizedFileURL
        let fm=FileManager.default; try require(!fm.fileExists(atPath: output.path), "Output must be a new directory.")
        let started=Date(), manifestURL=try file(input,"manifest.json"), manifest=try readJSON(manifestURL), sceneReportURL=try file(scene,"prepare-report.json"), sceneReport=try readJSON(sceneReportURL)
        try require(try number(manifest,"schemaVersion") == 1 && manifest["geometryAndLabelOrderValidated"] as? Bool == true, "UV export must validate native geometry and final MVE label order.")
        try require(try number(manifest,"cornerStrideBytes") == 20 && number(manifest,"cornersPerFace") == 3 && string(manifest,"indexType") == "UInt32LE", "Unsupported packed corner/index layout.")
        try require(sceneReport["requiresNativeLUTProjection"] as? Bool == true && sceneReport["requiredTexreconCapability"] as? String == "FORMA_RADIAL_LUT_V1", "Scene must publish verified native JPEG/LUT cameras.")
        guard let materials=manifest["materials"] as? [[String:Any]], let atlas=materials.first(where: { ($0["index"] as? NSNumber)?.intValue == material }) else { throw Failure(errorDescription: "Selected atlas/material is missing.") }
        let width=try number(atlas,"width"), height=try number(atlas,"height"), faceCount=try number(manifest,"faceCount")
        try require(width > 0 && height > 0 && faceCount > 0, "Empty atlas/geometry.")
        let cornerURL=try file(input,string(manifest,"cornersFile")), materialURL=try file(input,string(manifest,"materialIDsFile")), labelURL=try file(input,string(manifest,"labelsFile"))
        let inputHashes = [manifestURL.path:try sha(manifestURL),cornerURL.path:try sha(cornerURL),materialURL.path:try sha(materialURL),labelURL.path:try sha(labelURL),sceneReportURL.path:try sha(sceneReportURL)]
        let corners=try Data(contentsOf:cornerURL,options:.mappedIfSafe), materialIDs=try Data(contentsOf:materialURL,options:.mappedIfSafe), labels=try Data(contentsOf:labelURL,options:.mappedIfSafe)
        try require(corners.count == faceCount*60 && materialIDs.count == faceCount*4 && labels.count == faceCount*4, "Geometry/label buffer length mismatch.")
        guard let sceneRows=sceneReport["files"] as? [[String:Any]] else { throw Failure(errorDescription: "Missing scene camera receipts.") }
        var groups:[Int:[Int]]=[:], unassigned=0, selectedFaces=0
        for face in 0..<faceCount where decodeUInt32(materialIDs,face) == material {
            selectedFaces+=1; let label=Int(decodeUInt32(labels,face))
            if label == 0 { unassigned+=1; continue }
            try require(label <= sceneRows.count, "A face refers to an unknown photograph.")
            groups[label,default:[]].append(face)
        }
        try require(!groups.isEmpty, "Material has no assigned real photograph.")
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { throw Failure(errorDescription: "Metal device/queue unavailable.") }
        let compile=MTLCompileOptions(); compile.mathMode = .safe
        let library=try device.makeLibrary(source:shader,options:compile), descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"project_uv");descriptor.fragmentFunction=library.makeFunction(name:"project_photo");descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm_srgb
        let pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        let textureDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm_srgb,width:width,height:height,mipmapped:false)
        textureDescriptor.usage=[.renderTarget,.shaderRead];textureDescriptor.storageMode = .private
        guard let destination=device.makeTexture(descriptor:textureDescriptor) else { throw Failure(errorDescription: "Atlas allocation failed.") }
        let counterSize=checkOverlap ? width*height*4 : 4
        guard let counter=device.makeBuffer(length:counterSize,options:.storageModeShared) else { throw Failure(errorDescription: "Overlap allocation failed.") }; memset(counter.contents(),0,counterSize)
        let samplerDescriptor=MTLSamplerDescriptor();samplerDescriptor.minFilter = .linear;samplerDescriptor.magFilter = .linear;samplerDescriptor.sAddressMode = .clampToEdge;samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler=device.makeSamplerState(descriptor:samplerDescriptor) else { throw Failure(errorDescription: "Sampler unavailable.") }
        let loader=MTKTextureLoader(device:device)
        var first=true, photoReports:[[String:Any]]=[]
        for label in groups.keys.sorted() {
            try autoreleasepool {
                let row=sceneRows[label-1], stem=String(format:"%08d",label-1)
                try require(try string(row,"photo") == stem+".jpg" && string(row,"camera") == stem+".cam", "MVE labels do not match scene chronological file IDs.")
                let photoURL=try file(scene,stem+".jpg"), cameraURL=try file(scene,stem+".cam"), lutURL=try file(scene,stem+".forma-lut")
                let before=try sha(photoURL);try require(before == string(row,"photoSHA256") && sha(cameraURL) == string(row,"cameraSHA256"), "Source camera/photo changed after validated scene preparation.")
                guard let lutReceipt=row["nativeLUT"] as? [String:Any] else { throw Failure(errorDescription:"Missing per-camera LUT receipt.") }
                try require(try sha(lutURL) == string(lutReceipt,"sidecarSHA256"), "Source LUT changed after validation.")
                let w=try number(row,"nativeWidth"), h=try number(row,"nativeHeight")
                var (uniforms,table)=try parseCamera(cameraURL,lutURL,w,h);uniforms.image.z=Float(width);uniforms.image.w=checkOverlap ? 1 : 0
                guard let source=CGImageSourceCreateWithURL(photoURL as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary), let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:false] as CFDictionary) else { throw Failure(errorDescription:"JPEG decode failed.") }
                try require(image.width == w && image.height == h, "Decoded native JPEG dimensions differ from K.")
                let photo=try loader.newTexture(cgImage:image,options:[.SRGB:true,.origin:MTKTextureLoader.Origin.topLeft.rawValue,.generateMipmaps:false])
                guard let faceList=groups[label] else { throw Failure(errorDescription:"Missing face group.") }
                let byteCount=faceList.count*60
                guard let vertexBuffer=device.makeBuffer(length:byteCount,options:.storageModeShared), let lutBuffer=table.withUnsafeBytes({ device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared) }), let command=queue.makeCommandBuffer() else { throw Failure(errorDescription:"Batch GPU buffer allocation failed.") }
                corners.withUnsafeBytes { raw in
                    for (batchIndex,face) in faceList.enumerated() { memcpy(vertexBuffer.contents().advanced(by:batchIndex*60),raw.baseAddress!.advanced(by:face*60),60) }
                }
                let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=destination;pass.colorAttachments[0].loadAction=first ? .clear : .load;pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
                guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { throw Failure(errorDescription:"Render encoder unavailable.") }
                encoder.setRenderPipelineState(pipeline);encoder.setCullMode(.none);encoder.setViewport(MTLViewport(originX:0,originY:0,width:Double(width),height:Double(height),znear:0,zfar:1))
                encoder.setVertexBuffer(vertexBuffer,offset:0,index:0);encoder.setFragmentBytes(&uniforms,length:MemoryLayout<Uniforms>.stride,index:1);encoder.setFragmentBuffer(lutBuffer,offset:0,index:2);encoder.setFragmentBuffer(counter,offset:0,index:3);encoder.setFragmentTexture(photo,index:0);encoder.setFragmentSamplerState(sampler,index:0)
                encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:faceList.count*3);encoder.endEncoding();try checkCommand(command);first=false
                try require(try sha(photoURL) == before, "Source photograph changed during reprojection.")
                photoReports.append(["label":label,"frameID":row["frameID"] ?? "","photo":photoURL.lastPathComponent,"photoSHA256":before,"cameraSHA256":try sha(cameraURL),"lutSHA256":try sha(lutURL),"faces":faceList.count,"width":w,"height":h])
                if photoReports.count % 25 == 0 || photoReports.count == groups.count { print("Projected \(photoReports.count)/\(groups.count) native photographs",terminator:"\n");fflush(stdout) }
            }
        }
        let bytesPerRow=width*4
        guard let readback=device.makeBuffer(length:bytesPerRow*height,options:.storageModeShared),let command=queue.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder() else { throw Failure(errorDescription:"Readback allocation failed.") }
        blit.copy(from:destination,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:width,height:height,depth:1),to:readback,destinationOffset:0,destinationBytesPerRow:bytesPerRow,destinationBytesPerImage:bytesPerRow*height);blit.endEncoding();try checkCommand(command)
        let pixels=readback.contents().assumingMemoryBound(to:UInt8.self);var validPixels=0, invalidPixels=0, overlapPixels=0, maximumOverlap:UInt32=0;var sums=[UInt64](repeating:0,count:3)
        let overlap=counter.contents().assumingMemoryBound(to:UInt32.self)
        for pixel in 0..<width*height {
            if checkOverlap {
                let count=overlap[pixel];maximumOverlap=max(maximumOverlap,count)
                if count>1 {
                    overlapPixels+=1
                    // Repeated UV coverage has no unique photograph correspondence.
                    // Keep it invalid instead of retaining whichever batch drew last.
                    for c in 0..<4 { pixels[pixel*4+c]=0 }
                }
            }
            if pixels[pixel*4+3] == 0 { invalidPixels+=1 } else { validPixels+=1;for c in 0..<3 { sums[c]+=UInt64(pixels[pixel*4+c]) } }
        }
        try require(validPixels > 0, "No valid source texel was painted; no atlas exported.")
        for (path,expected) in inputHashes { try require(try sha(URL(fileURLWithPath:path)) == expected, "Geometry/scene input changed during rendering.") }
        try fm.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        let stage=output.deletingLastPathComponent().appendingPathComponent(".raw-photo-uv-\(UUID().uuidString)");try fm.createDirectory(at:stage,withIntermediateDirectories:false);defer { try? fm.removeItem(at:stage) }
        let png=stage.appendingPathComponent("material-\(material)-photographic.png")
        let data=Data(bytesNoCopy:readback.contents(),count:bytesPerRow*height,deallocator:.none)
        guard let provider=CGDataProvider(data:data as CFData),let color=CGColorSpace(name:CGColorSpace.sRGB),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:bytesPerRow,space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),let writer=CGImageDestinationCreateWithURL(png as CFURL,UTType.png.identifier as CFString,1,nil) else { throw Failure(errorDescription:"PNG encoder unavailable.") }
        CGImageDestinationAddImage(writer,image,[kCGImagePropertyOrientation:1] as CFDictionary);try require(CGImageDestinationFinalize(writer),"PNG encoding failed.")
        let report:[String:Any]=["schemaVersion":1,"material":material,"width":width,"height":height,"input":input.path,"scene":scene.path,"inputSHA256":inputHashes,"selectedFaces":selectedFaces,"unassignedFaces":unassigned,"assignedFaces":selectedFaces-unassigned,"usedPhotographs":photoReports.count,"photos":photoReports,"validOutputPixels":validPixels,"transparentOutputPixels":invalidPixels,"validPixelFraction":Double(validPixels)/Double(width*height),"meanValidRGB8":sums.map { Double($0)/Double(validPixels) },"overlapChecked":checkOverlap,"paintedOverlapPixels":checkOverlap ? overlapPixels : NSNull(),"maximumPaintedOverlap":checkOverlap ? maximumOverlap : NSNull(),"overlapPixelsMadeTransparent":checkOverlap,"acceptedOutputWithoutPaintedOverlap":checkOverlap ? true : NSNull(),"overlapPolicy":"When checked, every pixel covered by multiple valid triangles is cleared to transparent; no arbitrary view wins overlapping UVs.","outputPNG":png.lastPathComponent,"outputSHA256":try sha(png),"seconds":Date().timeIntervalSince(started),"device":device.name,"photoMemoryPolicy":"One native photograph/texture per batch; command completion before releasing each photograph.","colorPolicy":"Native JPEG CGImage, explicit top-left MTK upload and sRGB source sampling; bilinear interpolation in linear RGB; destination RGBA8 sRGB, no tone or exposure correction.","uvPolicy":"Original UV vertex clip=(UV*2-1,0,1); Metal top-left raster gives PNG y=(1-v)*H; original geometry/winding retained.","sourceProjection":"Native W2CV+K recovered from CAM, then exact radial LUT source=c+(pinhole-c)*(1+LUT(r)); sample at (pixel+0.5)/imageSize.","geometryChanged":false,"AIUsed":false,"libraryModified":false,"note":"Research reprojection intermediate. Selected views and geometry can retain pose, visibility and exposure errors; this does not prove higher accuracy or superiority over another scanner."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:stage.appendingPathComponent("report.json"),options:.atomic);try fm.moveItem(at:stage,to:output)
        print("Saved \(output.path): \(validPixels) real-photo texels, \(photoReports.count) source photographs, \(Date().timeIntervalSince(started)) seconds")
    }
}
