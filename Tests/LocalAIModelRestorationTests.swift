import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib
@testable import Forma

final class LocalAIModelRestorationTests: XCTestCase {
    private let fm = FileManager.default
    private func root() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("FormaUSDZRestorationTest-" + UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func png(_ url: URL, alternate: Bool = false) throws {
        var bytes = [UInt8](repeating: 255, count: 64*64*4)
        for y in 0..<64 { for x in 0..<64 {
            let i = (y*64+x)*4, checker = ((x/3+y/3)%2)*45
            bytes[i] = UInt8(45+x*2+checker)
            bytes[i+1] = UInt8(45+y*2+checker)
            bytes[i+2] = UInt8(alternate ? 210 : 75+checker)
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width:64,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination,image,nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func raster(_ url: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.width,64); XCTAssertEqual(image.height,64)
        var data = [UInt8](repeating:0,count:64*64*4)
        try data.withUnsafeMutableBytes { pointer in
            let context = try XCTUnwrap(CGContext(data:pointer.baseAddress,width:64,height:64,bitsPerComponent:8,
                bytesPerRow:256,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image,in:CGRect(x:0,y:0,width:64,height:64))
        }
        return data
    }
    private func fixture(in root: URL) throws -> URL {
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        let layer = """
        #usda 1.0
        (defaultPrim = "Root"; upAxis = "Y"; metersPerUnit = 1)
        def Xform "Root" {
            def Material "Material" {
                token outputs:surface.connect = </Root/Material/Surface.outputs:surface>
                def Shader "Surface" {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor.connect = </Root/Material/Image.outputs:rgb>
                    token outputs:surface
                }
                def Shader "UV" {
                    uniform token info:id = "UsdPrimvarReader_float2"
                    token inputs:varname = "st"
                    float2 outputs:result
                }
                def Shader "Image" {
                    uniform token info:id = "UsdUVTexture"
                    asset inputs:file = @0/atlas.png@
                    token inputs:sourceColorSpace = "sRGB"
                    float2 inputs:st.connect = </Root/Material/UV.outputs:result>
                    float3 outputs:rgb
                }
            }
            def Mesh "Mesh" {
                point3f[] points = [(0,0,0),(1,0,0),(0,1,0),(1,1,0)]
                int[] faceVertexCounts = [3,3]
                int[] faceVertexIndices = [0,1,2,1,3,2]
                uniform token subdivisionScheme = "none"
                texCoord2f[] primvars:st = [(0,0),(1,0),(0,1),(1,0),(1,1),(0,1)] (interpolation = "faceVarying")
                rel material:binding = </Root/Material>
            }
        }
        """
        let atlas = root.appendingPathComponent("atlas.png"), other = root.appendingPathComponent("normal.png")
        try png(atlas); try png(other,alternate:true)
        let entries:[(String,Data)] = [("scene.usda",Data(layer.utf8)),("0/atlas.png",try Data(contentsOf:atlas)),
                                      ("0/normal.png",try Data(contentsOf:other)),("capture-info.txt",Data("preserve this non-diffuse payload\n".utf8))]
        let model = source.appendingPathComponent("modelo.usdz")
        try storedFixture(entries).write(to:model)
        return model
    }
    // Independent small fixture writer: known stored members, CRCs and USDZ
    // alignment. Production archive reader/repacker remains under test.
    private func storedFixture(_ entries: [(String,Data)]) -> Data {
        var output=Data(), central=Data()
        func append<T: FixedWidthInteger>(_ value:T, to data:inout Data) { var x=value.littleEndian;withUnsafeBytes(of:&x){data.append(contentsOf:$0)} }
        for (name,payload) in entries {
            let nameBytes=Data(name.utf8),offset=UInt32(output.count)
            let checksum=payload.withUnsafeBytes { pointer in crc32(0,pointer.bindMemory(to:Bytef.self).baseAddress,uInt(pointer.count)) }
            let padding = (64 - (output.count + 30 + nameBytes.count + 4)%64)%64
            append(UInt32(0x04034b50),to:&output);append(UInt16(20),to:&output);append(UInt16(0),to:&output);append(UInt16(0),to:&output)
            append(UInt16(0),to:&output);append(UInt16(0),to:&output);append(UInt32(checksum),to:&output)
            append(UInt32(payload.count),to:&output);append(UInt32(payload.count),to:&output)
            append(UInt16(nameBytes.count),to:&output);append(UInt16(padding+4),to:&output);output.append(nameBytes)
            append(UInt16(0x1986),to:&output);append(UInt16(padding),to:&output);output.append(Data(repeating:0,count:padding));output.append(payload)
            append(UInt32(0x02014b50),to:&central);append(UInt16(0x0314),to:&central);append(UInt16(20),to:&central)
            append(UInt16(0),to:&central);append(UInt16(0),to:&central);append(UInt16(0),to:&central);append(UInt16(0),to:&central)
            append(UInt32(checksum),to:&central);append(UInt32(payload.count),to:&central);append(UInt32(payload.count),to:&central)
            append(UInt16(nameBytes.count),to:&central);append(UInt16(0),to:&central);append(UInt16(0),to:&central)
            append(UInt16(0),to:&central);append(UInt16(0),to:&central);append(UInt32(0o100600)<<16,to:&central);append(offset,to:&central);central.append(nameBytes)
        }
        let offset=UInt32(output.count);output.append(central)
        append(UInt32(0x06054b50),to:&output);append(UInt16(0),to:&output);append(UInt16(0),to:&output)
        append(UInt16(entries.count),to:&output);append(UInt16(entries.count),to:&output)
        append(UInt32(central.count),to:&output);append(offset,to:&output);append(UInt16(0),to:&output)
        return output
    }

    func testUSDZInventoryUsesDiffuseOnlyAndAllNativeUVs() throws {
        let temporary=try root();defer{try? fm.removeItem(at:temporary)}
        let model=try fixture(in:temporary), original=try IntegrityManifest.digest(model)
        XCTAssertTrue(LocalAIModelRestoration.supports(model))
        XCTAssertEqual(try LocalAIModelRestoration.textureCount(model:model),1)
        let mapping=try USDZTextureRestorationAdapter.loadUVMapping(modelURL:model,textureEntryNames:["0/atlas.png","0/normal.png"])
        XCTAssertEqual(mapping.triangleCount,2)
        XCTAssertEqual(Set(mapping.triangles.keys),["0/atlas.png"])
        XCTAssertEqual(try IntegrityManifest.digest(model),original)
    }

    func testRealCoreMLUSDZRestorationResumesCommittedAtlasAndPreservesNativeGeometry() throws {
        let candidateWeights = ProcessInfo.processInfo.environment["FORMA_TEST_RESTORER_URL"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "RealESRGAN_general_522_fp16", withExtension: "mlmodelc")
        let weights = try XCTUnwrap(candidateWeights, "Se necesita el modelo real incluido en Forma o FORMA_TEST_RESTORER_URL.")
        let temporary=try root();defer{try? fm.removeItem(at:temporary)}
        let model=try fixture(in:temporary), original=try IntegrityManifest.digest(model)
        let output=temporary.appendingPathComponent("derived"),checkpoint=temporary.appendingPathComponent("checkpoint")
        let control=ProcessingControl(),restorer=weights
        XCTAssertThrowsError(try LocalAIModelRestoration.run(model:model,output:output,restorer:restorer,strength:0.5,
            control:control,cpuOnly:true,checkpointDirectory:checkpoint,progress:{ message,_ in
                if message.contains("avance guardado") { control.cancel() }
            })) { XCTAssertTrue($0 is CancellationError,"Unexpected first-run failure: \($0)") }
        XCTAssertFalse(fm.fileExists(atPath:output.path))
        let stateURL=checkpoint.appendingPathComponent("atlases/checkpoint.json")
        let state=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL)) as? [String:Any])
        XCTAssertEqual(state["nextAssetIndex"] as? Int,1)
        let committed=checkpoint.appendingPathComponent("atlases/package/0/atlas.png")
        let committedSHA=try IntegrityManifest.digest(committed)
        let report=try LocalAIModelRestoration.run(model:model,output:output,restorer:restorer,strength:0.5,
            cpuOnly:true,checkpointDirectory:checkpoint)
        XCTAssertEqual(report.modelURL,output.appendingPathComponent("modelo.usdz"))
        XCTAssertEqual(report.processedTextureCount,1);XCTAssertEqual(report.skippedTextureCount,0)
        XCTAssertEqual(report.inferenceTileCount,1);XCTAssertGreaterThan(report.changedPixels,0)
        let sourceArchive=try StoredUSDZArchive(url:model),targetArchive=try StoredUSDZArchive(url:report.modelURL)
        try targetArchive.validateCRC()
        XCTAssertEqual(sourceArchive.entries.map(\.name),targetArchive.entries.map(\.name))
        let a=temporary.appendingPathComponent("a"),b=temporary.appendingPathComponent("b")
        _=try sourceArchive.extract(toPrivateDirectory:a);_=try targetArchive.extract(toPrivateDirectory:b)
        for entry in sourceArchive.entries where entry.name != "0/atlas.png" {
            XCTAssertEqual(try Data(contentsOf:a.appendingPathComponent(entry.name)),try Data(contentsOf:b.appendingPathComponent(entry.name)),entry.name)
        }
        XCTAssertEqual(try IntegrityManifest.digest(b.appendingPathComponent("0/atlas.png")),committedSHA,"Resume recomputed or replaced the committed atlas")
        let before=try raster(a.appendingPathComponent("0/atlas.png")),after=try raster(b.appendingPathComponent("0/atlas.png"))
        for y in 0..<64 { for x in 0..<64 {
            let i=(y*64+x)*4
            XCTAssertEqual(before[i+3],after[i+3])
            if x<2 || y<2 || x>=62 || y>=62 { XCTAssertEqual(Array(before[i..<i+4]),Array(after[i..<i+4]),"Protected gutter changed") }
        } }
        try LocalAIModelRestoration.validateGeometry(original:model,candidate:report.modelURL)
        let recovered=try LocalAIModelRestoration.restoredReport(package:output,sourceModel:model)
        XCTAssertEqual(recovered.inferenceTileCount,1)
        XCTAssertEqual(try IntegrityManifest.digest(model),original)
        // The durable restored cache can be published again after interruption
        // without running inference, while retaining all non-diffuse bytes.
        let repeated=try LocalAIModelRestoration.run(model:model,output:temporary.appendingPathComponent("retry"),restorer:restorer,
            strength:0.5,cpuOnly:true,checkpointDirectory:checkpoint)
        XCTAssertEqual(repeated.inferenceTileCount,1)
        XCTAssertEqual(try IntegrityManifest.digest(repeated.modelURL),try IntegrityManifest.digest(report.modelURL))
        let tampered=checkpoint.appendingPathComponent("restored/0/atlas.png")
        try Data("tamper".utf8).write(to:tampered)
        XCTAssertThrowsError(try LocalAIModelRestoration.run(model:model,output:temporary.appendingPathComponent("rejected"),restorer:restorer,
            strength:0.5,cpuOnly:true,checkpointDirectory:checkpoint))
        XCTAssertFalse(fm.fileExists(atPath:temporary.appendingPathComponent("rejected").path))
        XCTAssertEqual(try IntegrityManifest.digest(model),original)
        print("USDZ_REAL_COREML_PASS inferenceTiles=\(report.inferenceTileCount) changedPixels=\(report.changedPixels) firstPredictionSeconds=\(report.firstPredictionSeconds)")
    }
}
