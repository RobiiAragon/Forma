import Foundation
import CoreML
import CoreGraphics
import ImageIO

/// Exactly two additional one-tile predictions authorized for this Raw ROI.
@main struct RawTextureComputeComparison {
    typealias Base = RawTextureROIBenchmark
    static func raster(_ url: URL) throws -> (Int, Int, [UInt8]) {
        guard let s=CGImageSourceCreateWithURL(url as CFURL,nil), let image=CGImageSourceCreateImageAtIndex(s,0,nil) else { throw Base.Failure(errorDescription:"Cannot decode existing ROI reference") }
        let w=image.width,h=image.height
        var bytes=[UInt8](repeating:255,count:w*h*4)
        try bytes.withUnsafeMutableBytes { p in
            guard let c=CGContext(data:p.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Base.Failure(errorDescription:"Cannot decode comparison raster") }
            c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        return (w,h,bytes)
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw Base.Failure(errorDescription:"Usage: EXISTING_NE_BENCHMARK_DIRECTORY FRESH_COMPARISON_OUTPUT") }
        let existing=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
        let out=URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL
        let fm=FileManager.default
        try Base.require(!fm.fileExists(atPath:out.path),"Use a fresh output directory")
        try fm.createDirectory(at:out,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let (_,_,original)=try raster(existing.appendingPathComponent("original.png"))
        let (rw,rh,neReference)=try raster(existing.appendingPathComponent("model-output-4x-debug.png"))
        let (_,_,neNative)=try raster(existing.appendingPathComponent("restored-area4-native.png"))
        let side=522,large=2088,plane=large*large
        try Base.require(original.count==side*side*4 && rw==large && rh==large,"Fixed genuine ROI reference shape mismatch")
        let input=try MLMultiArray(shape:[1,3,522,522],dataType:.float32)
        let st=input.strides.map(\.intValue),p=input.dataPointer.assumingMemoryBound(to:Float.self)
        for c in 0..<3 { for y in 0..<side { for x in 0..<side { p[c*st[1]+y*st[2]+x*st[3]]=Float(original[(y*side+x)*4+c])/255 } } }
        var values: [[Float]]=[],rows:[[String:Any]]=[]
        let policies:[(String,MLComputeUnits)]=[("all",.all),("cpuAndGPU",.cpuAndGPU)]
        for (name,policy) in policies {
            let config=MLModelConfiguration();config.computeUnits=policy
            let loadAt=ProcessInfo.processInfo.systemUptime
            let model=try MLModel(contentsOf:existing.appendingPathComponent("compiled.mlmodelc"),configuration:config)
            let load=ProcessInfo.processInfo.systemUptime-loadAt
            let inName=model.modelDescription.inputDescriptionsByName.keys.first!,outName=model.modelDescription.outputDescriptionsByName.keys.first!
            let at=ProcessInfo.processInfo.systemUptime
            let prediction=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:[inName:input]))
            let apiSeconds=ProcessInfo.processInfo.systemUptime-at
            guard let result=prediction.featureValue(for:outName)?.multiArrayValue else { throw Base.Failure(errorDescription:"Missing model tensor") }
            try Base.require(result.shape.map(\.intValue)==[1,3,large,large],"Unexpected output shape")
            let strides=result.strides.map(\.intValue),base=result.dataPointer
            let readySeconds=ProcessInfo.processInfo.systemUptime-at
            var captured=[Float](repeating:0,count:3*plane),native=original
            var maximumVsNE:Float=0,sumVsNE=0.0
            for c in 0..<3 { for y in 0..<large { for x in 0..<large {
                let k=c*strides[1]+y*strides[2]+x*strides[3]
                let v:Float
                switch result.dataType {
                case .float16:v=Float(base.assumingMemoryBound(to:Float16.self)[k])
                case .float32:v=base.assumingMemoryBound(to:Float.self)[k]
                case .double:v=Float(base.assumingMemoryBound(to:Double.self)[k])
                default:throw Base.Failure(errorDescription:"Unsupported tensor output")
                }
                try Base.require(v.isFinite,"Nonfinite output")
                captured[c*plane+y*large+x]=v
                let d=abs(v-Float(neReference[(y*large+x)*4+c])/255)
                maximumVsNE=max(maximumVsNE,d);sumVsNE+=Double(d)
            } } }
            var nativeMaximum=0,nativeSum=0.0
            for y in 0..<side { for x in 0..<side { for c in 0..<3 {
                var sum:Float=0
                for dy in 0..<4 { for dx in 0..<4 { sum+=captured[c*plane+(y*4+dy)*large+x*4+dx] } }
                let k=(y*side+x)*4+c
                native[k]=UInt8(max(0,min(255,(sum/16*255).rounded())))
                let d=abs(Int(native[k])-Int(neNative[k]));nativeMaximum=max(nativeMaximum,d);nativeSum+=Double(d)
            } } }
            try Base.png(native,width:side,height:side,url:out.appendingPathComponent(name+"-restored-native.png"))
            rows.append(["computeUnits":name,"loadSeconds":load,"predictionAPISeconds":apiSeconds,
                "predictionThroughDataPointerReadySeconds":readySeconds,"maxChannelOutputErrorNormalizedVsQuantizedNE":maximumVsNE,
                "meanChannelOutputErrorNormalizedVsQuantizedNE":sumVsNE/Double(3*plane),
                "maxNativeRGB8DifferenceVsNE":nativeMaximum,"meanNativeRGB8DifferenceVsNE":nativeSum/Double(side*side*3),
                "outputDataTypeRawValue":result.dataType.rawValue])
            values.append(captured)
            print(String(format:"COMPUTE %@ predictionAPI %.6f ready %.6f maxVsQuantizedNE %.8f",name,apiSeconds,readySeconds,maximumVsNE));fflush(stdout)
        }
        var maximum:Float=0,sum=0.0
        for i in values[0].indices { let d=abs(values[0][i]-values[1][i]);maximum=max(maximum,d);sum+=Double(d) }
        let report:[String:Any]=["additionalPredictions":2,"policiesInOrder":["all","cpuAndGPU"],"compiledModelReused":true,"modelCopiesCreated":0,
            "trainingWorkerConcurrentPerRoot":true,"trainingWorkerPID":51835,"workerControlled":false,
            "singleLoadedMachineObservationNotGeneralHardwareBenchmark":true,"actualDevicePerLayerNotAsserted":true,
            "referenceCPU_NEPNG8Quantized":true,"NEReferenceQuantizationHalfStepNormalized":0.5/255,
            "rawFloatMaxChannelOutputErrorNormalizedAllVsCPUAndGPU":maximum,
            "rawFloatMeanChannelOutputErrorNormalizedAllVsCPUAndGPU":sum/Double(3*plane),"rows":rows,
            "UVIslandVerified":false,"debugOnlyNotAppliedToAtlas":true]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("compute-comparison.json"),options:.atomic)
    }
}
