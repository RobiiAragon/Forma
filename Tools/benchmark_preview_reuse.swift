import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

enum ScanStore {
    static func safeRelativePath(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains("\0") &&
        name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum BaselineReads {
    static var counts: [String:Int] = [:]
    static func text(_ url: URL) throws -> String {
        counts[url.pathExtension == "obj" ? "modelText" : "materialText", default: 0] += 1
        return try String(contentsOf: url, encoding: .utf8)
    }
    static func image(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource? {
        counts["imageMetadata", default: 0] += 1
        return CGImageSourceCreateWithURL(url, options)
    }
}

@main struct PreviewReuseBenchmark {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 2 else { fatalError("Pass an owned fixture directory") }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("grid.obj")
        if !FileManager.default.fileExists(atPath: model.path) {
            FileManager.default.createFile(atPath: model.path, contents: nil)
            let handle = try FileHandle(forWritingTo: model); defer { try? handle.close() }
            try handle.write(contentsOf: Data("mtllib grid.mtl\nusemtl photo\n".utf8))
            let n = 360
            var chunk = ""
            for y in 0..<n { for x in 0..<n {
                chunk += "v \(Float(x)/100) \(Float(y)/100) 0\nvt \(Float(x)/Float(n-1)) \(Float(y)/Float(n-1))\n"
                if chunk.utf8.count > 64_000 { try handle.write(contentsOf: Data(chunk.utf8)); chunk = "" }
            } }
            for y in 0..<(n-1) { for x in 0..<(n-1) {
                let a = y*n+x+1,b = a+1,c = a+n,d = c+1
                chunk += "f \(a)/\(a) \(b)/\(b) \(c)/\(c)\nf \(b)/\(b) \(d)/\(d) \(c)/\(c)\n"
                if chunk.utf8.count > 64_000 { try handle.write(contentsOf: Data(chunk.utf8)); chunk = "" }
            } }
            try handle.write(contentsOf: Data(chunk.utf8))
            try "newmtl photo\nmap_Kd photo.png\n".write(to: root.appendingPathComponent("grid.mtl"), atomically: true, encoding: .utf8)
            let context = CGContext(data: nil,width: 1024,height: 1024,bitsPerComponent: 8,bytesPerRow: 4096,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2,green: 0.6,blue: 0.9,alpha: 1));context.fill(CGRect(x:0,y:0,width:1024,height:1024))
            let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("photo.png") as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,context.makeImage()!,nil);precondition(CGImageDestinationFinalize(destination))
        }
        #if INVENTORY_BENCHMARK
        try inventoryBenchmark(model: model)
        #else
        let sourceHash = SHA256.hash(data: try Data(contentsOf: model)).map { String(format:"%02x",$0) }.joined()
        var rows: [[String:Any]] = []
        _ = try BaselineTexturePreviewProxy.prepare(model,budgetBytes: 16_384,checkCancellation: {})
        #if CANDIDATE
        _ = try TexturePreviewProxy.prepare(model,budgetBytes: 16_384,cacheDirectory: root.appendingPathComponent("cache"),checkCancellation: {})
        #endif
        for run in 0..<7 {
            // Alternate order; same source and pixel budget, warm disk + warm process cache.
            for candidate in (run % 2 == 0 ? [false,true] : [true,false]) {
                #if !CANDIDATE
                if candidate { continue }
                #endif
                try autoreleasepool {
                    BaselineReads.counts = [:]
                    var reads: [String:Int] = [:]
                    let start = ProcessInfo.processInfo.systemUptime
                    let output: URL
                    if candidate {
                        #if CANDIDATE
                        output = try TexturePreviewProxy.prepare(model,budgetBytes: 16_384,
                            cacheDirectory: root.appendingPathComponent("cache"),
                            onResourceAccess: { reads[$0.rawValue,default:0] += 1 },checkCancellation: {}).url
                        #else
                        fatalError("not compiled")
                        #endif
                    } else {
                        output = try BaselineTexturePreviewProxy.prepare(model,budgetBytes: 16_384,checkCancellation: {}).url
                        reads = BaselineReads.counts
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime-start
                    let outputHash = SHA256.hash(data: try Data(contentsOf: output)).map { String(format:"%02x",$0) }.joined()
                    let artifacts = try ["preview.obj", "preview.mtl", "preview-0.png"].reduce(into: [String:String]()) { result, name in
                        result[name] = SHA256.hash(data: try Data(contentsOf: output.deletingLastPathComponent().appendingPathComponent(name))).map { String(format:"%02x",$0) }.joined()
                    }
                    rows.append(["artifactsSHA256":artifacts,"variant":candidate ? "candidate" : "baseline","run":run,"seconds":seconds,"resourceOperations":reads,"outputSHA256":outputHash])
                }
            }
        }
        let unchanged = sourceHash == SHA256.hash(data: try Data(contentsOf: model)).map { String(format:"%02x",$0) }.joined()
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        let report: [String:Any] = ["platform":"macOS native; metadata/proxy preparation only, not rendering or reconstruction",
            "sourceSHA256":sourceHash,"sourceUnchanged":unchanged,"sourceBytes":try model.resourceValues(forKeys:[.fileSizeKey]).fileSize!,
            "budgetBytes":16384,"runs":rows,"peakRSSBytesWholeProcess":usage.ru_maxrss]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
        #endif
    }
    #if INVENTORY_BENCHMARK
    static func inventoryBenchmark(model: URL) throws {
        var rows: [[String:Any]] = []
        for run in 0..<7 {
            for candidate in (run % 2 == 0 ? [false,true] : [true,false]) {
                #if !INVENTORY_CANDIDATE
                if candidate { continue }
                #endif
                try autoreleasepool {
                    BaselineReads.counts = [:]
                    let start = ProcessInfo.processInfo.systemUptime
                    let summary: [[String:Any]]
                    if candidate {
                        #if INVENTORY_CANDIDATE
                        let inventory = try MeasuredTextureAssetInventory.loadIfPresent(modelURL:model)
                        summary = (inventory?.assets ?? []).map { ["path":$0.relativePath,"width":$0.width,"height":$0.height,"materials":$0.materialNames] }
                        #else
                        fatalError("not compiled")
                        #endif
                    } else {
                        let hasMaterials = try BaselineReads.text(model).components(separatedBy:.newlines).contains { $0.trimmingCharacters(in:.whitespaces).hasPrefix("mtllib ") }
                        let inventory = hasMaterials ? try BaselineTextureAssetInventory.load(modelURL:model) : nil
                        summary = (inventory?.assets ?? []).map { ["path":$0.relativePath,"width":$0.width,"height":$0.height,"materials":$0.materialNames] }
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime-start
                    rows.append(["variant":candidate ? "candidate" : "baseline","run":run,"seconds":seconds,"resourceOperations":BaselineReads.counts,"inventory":summary])
                }
            }
        }
        print(String(data:try JSONSerialization.data(withJSONObject:["platform":"macOS native; Desktop OBJ inventory only","runs":rows],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
    #endif

}
