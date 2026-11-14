import Foundation
import CoreGraphics
import CoreImage

/// Transfers measured photographic luminance detail onto an already aligned,
/// native Raw UV raster. No registration, learned model or generated detail.
enum PhotographicDetailRecovery {
    enum Backend: String, Codable, Sendable { case automatic, software }
    struct Configuration: Sendable {
        var bandSigma: Double = 4
        var backend: Backend = .automatic
        var includeConfidenceImage = false
    }
    struct Statistics: Codable, Sendable {
        var width: Int
        var height: Int
        var validPhotoPixels = 0
        var changedPixels = 0
        var outsideMaskChangedPixels = 0
        var externalSupportBoundaryChangedPixels = 0
        var candidateOutOfGamutPixelsRejected = 0
        var meanConfidence = 0.0
        var lowFrequencySigma12RMSLogLuma = 0.0
        var elapsedSeconds = 0.0
        var inputColorSpaceConverted = false
        var backend: Backend
        var bandSigma: Double
        var registrationEnabled = false
        var qualityAccepted = false
        var implementationNotes: [String] = [
            "Native dimensions; 128-row render strips bound temporary storage, not image resolution or data volume.",
            "Core Image Gaussian inputRadius approximates the OpenCV sigma; results are not claimed byte-identical.",
            "Boundary feather approximates distance smoothstep with radius6 erosion and Gaussian2; an explicit3x3 support/frame-edge guard remains exactly Raw.",
            "Core Image clamp-to-edge replaces OpenCV REFLECT_101 at the outer image extent.",
            "Statistics and exterior byte identity refer to canonical premultiplied RGBA8 sRGB; named other RGB profiles are converted before processing.",
            "Manual pause/cancellation is checked between stages and render strips; an individual Core Image render is not preempted.",
            "Matching/photographic band transfer does not establish geometric accuracy or global visual improvement."
        ]
    }
    struct Result: @unchecked Sendable {
        var image: CGImage
        var confidenceImage: CGImage?
        var statistics: Statistics
    }
    enum RecoveryError: LocalizedError {
        case invalidInput(String), unavailable(String)
        var errorDescription: String? {
            switch self {
            case .invalidInput(let reason): "No se pudo recuperar detalle fotográfico: " + reason
            case .unavailable(let reason): "Core Image no pudo recuperar detalle fotográfico: " + reason
            }
        }
    }

    /// Inputs must be native matching RGB8 rasters. A supplied support mask uses
    /// its red channel at255; the photograph must also have fully opaque alpha.
    /// Without an explicit mask, the photograph's fully opaque alpha is support.
    static func recover(raw: CGImage, photograph: CGImage, supportMask: CGImage? = nil,
                        configuration: Configuration = .init(), context suppliedContext: CIContext? = nil,
                        progress: (@Sendable (String, Double) -> Void)? = nil) throws -> Result {
        let started = ProcessInfo.processInfo.systemUptime
        guard raw.width == photograph.width, raw.height == photograph.height,
              raw.width > 0, raw.height > 0, raw.bitsPerComponent == 8, photograph.bitsPerComponent == 8,
              configuration.bandSigma.isFinite, configuration.bandSigma > 0.6 else {
            throw RecoveryError.invalidInput("las imágenes RGB8 deben tener la misma resolución nativa y una banda válida")
        }
        if let supportMask, supportMask.width != raw.width || supportMask.height != raw.height {
            throw RecoveryError.invalidInput("la máscara debe conservar las dimensiones de la textura")
        }
        let (rowBytes, overflow1) = raw.width.multipliedReportingOverflow(by: 4)
        let (byteCount, overflow2) = rowBytes.multipliedReportingOverflow(by: raw.height)
        guard !overflow1, !overflow2 else { throw RecoveryError.invalidInput("el tamaño no es representable por este proceso") }
        try ProcessingControl.checkpoint()
        let width = raw.width, height = raw.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let (normalizedRaw, rawConverted) = try canonicalSRGB(raw, colorSpace: colorSpace)
        let (normalizedPhoto, photoConverted) = try canonicalSRGB(photograph, colorSpace: colorSpace)
        let rawImage = CIImage(cgImage: normalizedRaw, options: [.colorSpace: NSNull()])
        let photoImage = CIImage(cgImage: normalizedPhoto, options: [.colorSpace: NSNull()])
        let supportImage = supportMask.map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) }
            ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        let context = suppliedContext ?? CIContext(options: [
            .useSoftwareRenderer: configuration.backend == .software,
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
            .workingFormat: NSNumber(value: CIFormat.RGBAf.rawValue), .cacheIntermediates: false
        ])
        let shaders = try Shaders()
        func apply(_ kernel: CIColorKernel, _ inputs: [Any]) throws -> CIImage {
            guard let result = kernel.apply(extent: extent, arguments: inputs) else {
                throw RecoveryError.unavailable("no se pudo preparar una etapa del filtro")
            }
            return result
        }
        func gaussian(_ image: CIImage, _ sigma: Double) -> CIImage {
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma]).cropped(to: extent)
        }
        let valid = try apply(shaders.valid, [photoImage, supportImage])
        let guardMask = valid.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: extent)
        let feather = gaussian(valid.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 6]).cropped(to: extent), 2)
        let rawLog = try apply(shaders.rawLog, [rawImage])
        let photoLog = try apply(shaders.preparedPhotoLog, [photoImage, rawLog, valid])
        try ProcessingControl.checkpoint()
        progress?("bandas", 0.02)
        let rawBand = try apply(shaders.subtract, [gaussian(rawLog, 0.6), gaussian(rawLog, configuration.bandSigma)])
        let photoBand = try apply(shaders.subtract, [gaussian(photoLog, 0.6), gaussian(photoLog, configuration.bandSigma)])
        let rawMean = gaussian(rawBand, 6), photoMean = gaussian(photoBand, 6)
        let rawSquared = gaussian(try apply(shaders.multiply, [rawBand, rawBand]), 6)
        let photoSquared = gaussian(try apply(shaders.multiply, [photoBand, photoBand]), 6)
        let cross = gaussian(try apply(shaders.multiply, [rawBand, photoBand]), 6)
        let moments = try apply(shaders.moments, [rawMean, photoMean, rawSquared, photoSquared, cross])
        let confidence = try apply(shaders.confidence, [moments, gaussian(rawLog, 12), gaussian(photoLog, 12), feather])
        let gatedConfidence = try apply(shaders.gatedConfidence, [confidence, gaussian(confidence, 2), valid, guardMask, Float(width), Float(height)])
        let candidate = try apply(shaders.candidate, [rawImage, rawLog, rawBand, photoBand, gatedConfidence])
        let diagnostic = try apply(shaders.diagnostic, [rawImage, rawLog, rawBand, photoBand, gatedConfidence, valid, guardMask, Float(width), Float(height)])
        try ProcessingControl.checkpoint()
        var output = Data(count: byteCount)
        var confidenceBytes = configuration.includeConfidenceImage ? Data(count: width * height) : nil
        var statistics = Statistics(width: width, height: height, backend: configuration.backend, bandSigma: configuration.bandSigma)
        statistics.inputColorSpaceConverted = rawConverted || photoConverted
        var confidenceSum = 0.0
        // Core Image's rectangle coordinates start at the lower-left; bitmap
        // rows are top-first. Select each top-first strip explicitly.
        for first in stride(from: 0, to: height, by: 128) {
            try ProcessingControl.checkpoint()
            let rows = min(128, height-first), count = width * rows
            let bounds = CGRect(x: 0, y: height-first-rows, width: width, height: rows)
            var base = [UInt8](repeating: 0, count: count * 4)
            var rendered = [UInt8](repeating: 0, count: count * 4)
            var values = [Float](repeating: 0, count: count * 4)
            base.withUnsafeMutableBytes { context.render(rawImage, toBitmap: $0.baseAddress!, rowBytes: rowBytes, bounds: bounds, format: .RGBA8, colorSpace: nil) }
            try ProcessingControl.checkpoint()
            rendered.withUnsafeMutableBytes { context.render(candidate, toBitmap: $0.baseAddress!, rowBytes: rowBytes, bounds: bounds, format: .RGBA8, colorSpace: nil) }
            try ProcessingControl.checkpoint()
            values.withUnsafeMutableBytes { context.render(diagnostic, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: nil) }
            for pixel in 0..<count {
                let i = pixel * 4
                let confidence = values[i].isFinite ? min(max(values[i], 0), 1) : 0
                let code = values[i+2].isFinite ? Int(values[i+2].rounded()) : 0
                let supported = code & 1 != 0, interior = code & 2 != 0
                if supported { statistics.validPhotoPixels += 1; confidenceSum += Double(confidence) }
                if values[i+1] > 0.5 { statistics.candidateOutOfGamutPixelsRejected += 1 }
                if confidence == 0 || !supported || !interior {
                    rendered[i] = base[i]; rendered[i+1] = base[i+1]; rendered[i+2] = base[i+2]; rendered[i+3] = base[i+3]
                }
                let changed = rendered[i] != base[i] || rendered[i+1] != base[i+1] || rendered[i+2] != base[i+2] || rendered[i+3] != base[i+3]
                if changed {
                    statistics.changedPixels += 1
                    if !supported { statistics.outsideMaskChangedPixels += 1 }
                    if supported && !interior { statistics.externalSupportBoundaryChangedPixels += 1 }
                }
                if confidenceBytes != nil { confidenceBytes![first * width + pixel] = UInt8((confidence * 255).rounded()) }
            }
            output.replaceSubrange(first * rowBytes..<(first+rows) * rowBytes, with: rendered)
            try ProcessingControl.checkpoint()
            progress?("detalle", 0.05 + 0.75 * Double(first+rows)/Double(height))
        }
        guard let provider = CGDataProvider(data: output as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw RecoveryError.unavailable("no se pudo publicar la imagen nativa")
        }
        try ProcessingControl.checkpoint()
        let afterLog = try apply(shaders.rawLog, [CIImage(cgImage: image, options: [.colorSpace: NSNull()])])
        let drift = gaussian(try apply(shaders.subtract, [afterLog, rawLog]), 12)
        let driftAndSupport = try apply(shaders.driftSupport, [drift, valid])
        var sumSquared = 0.0, driftCount = 0
        for first in stride(from: 0, to: height, by: 128) {
            try ProcessingControl.checkpoint()
            let rows = min(128, height-first), count = width * rows
            let bounds = CGRect(x: 0, y: height-first-rows, width: width, height: rows)
            var values = [Float](repeating: 0, count: count * 4)
            values.withUnsafeMutableBytes { context.render(driftAndSupport, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: nil) }
            for pixel in 0..<count where values[pixel*4+1] > 0.5 {
                let value = Double(values[pixel*4])
                guard value.isFinite else { throw RecoveryError.unavailable("la medición produjo valores no finitos") }
                sumSquared += value * value; driftCount += 1
            }
            progress?("verificación", 0.8 + 0.2 * Double(first+rows)/Double(height))
        }
        statistics.meanConfidence = statistics.validPhotoPixels > 0 ? confidenceSum / Double(statistics.validPhotoPixels) : 0
        statistics.lowFrequencySigma12RMSLogLuma = driftCount > 0 ? sqrt(sumSquared / Double(driftCount)) : 0
        var confidenceImage: CGImage?
        if let confidenceBytes, let confidenceProvider = CGDataProvider(data: confidenceBytes as CFData) {
            confidenceImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: confidenceProvider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        try ProcessingControl.checkpoint()
        statistics.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        return Result(image: image, confidenceImage: confidenceImage, statistics: statistics)
    }

    private static func canonicalSRGB(_ input: CGImage, colorSpace: CGColorSpace) throws -> (CGImage, Bool) {
        let name = input.colorSpace?.name
        // Untagged/device-RGB capture rasters follow the same sRGB interpretation
        // as the Python prototype. Explicit other profiles are converted.
        if name == CGColorSpace.sRGB || name == CGColorSpaceCreateDeviceRGB().name || name == nil {
            return (input, false)
        }
        guard let context = CGContext(data: nil, width: input.width, height: input.height,
            bitsPerComponent: 8, bytesPerRow: input.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RecoveryError.unavailable("no se pudo convertir el perfil de color") }
        context.interpolationQuality = .none
        context.draw(input, in: CGRect(x: 0, y: 0, width: input.width, height: input.height))
        guard let result = context.makeImage() else { throw RecoveryError.unavailable("no se pudo conservar la imagen sRGB") }
        return (result, true)
    }

    private struct Shaders {
        var valid, rawLog, preparedPhotoLog, subtract, multiply, moments, confidence, gatedConfidence, candidate, diagnostic, driftSupport: CIColorKernel
        init() throws {
            func compile(_ code: String) throws -> CIColorKernel {
                guard let kernel = CIColorKernel(source: code) else { throw RecoveryError.unavailable("el sistema no pudo compilar el filtro fotográfico") }
                return kernel
            }
            let common = """
            vec3 decodeRGB(vec3 v) { return mix(v/12.92,pow((v+0.055)/1.055,vec3(2.4)),step(vec3(0.04045),v)); }
            vec3 encodeRGB(vec3 v) { return mix(v*12.92,1.055*pow(max(v,vec3(0.0)),vec3(1.0/2.4))-0.055,step(vec3(0.0031308),v)); }
            float logY(vec3 v) { return log(dot(decodeRGB(v),vec3(0.2126,0.7152,0.0722))+0.00001); }
            float interiorValue(float valid,float guardValue,float w,float h) {
                vec2 p=destCoord();
                return valid*guardValue*step(1.0,p.x)*step(1.0,p.y)*step(p.x,w-1.0)*step(p.y,h-1.0);
            }
            """
            valid = try compile("kernel vec4 k(__sample p,__sample m) { float v=step(0.999999,p.a)*step(0.999999,m.r)*step(0.999999,m.a); return vec4(v,v,v,1.0); }")
            rawLog = try compile(common + "kernel vec4 k(__sample r) { float v=logY(unpremultiply(r).rgb); return vec4(v,v,v,1.0); }")
            preparedPhotoLog = try compile(common + "kernel vec4 k(__sample p,__sample r,__sample m) { float v=mix(r.r,logY(unpremultiply(p).rgb),m.r); return vec4(v,v,v,1.0); }")
            subtract = try compile("kernel vec4 k(__sample a,__sample b) { float v=a.r-b.r; return vec4(v,v,v,1.0); }")
            multiply = try compile("kernel vec4 k(__sample a,__sample b) { float v=a.r*b.r; return vec4(v,v,v,1.0); }")
            moments = try compile("kernel vec4 k(__sample rm,__sample pm,__sample rs,__sample ps,__sample cross) { return vec4(max(rs.r-rm.r*rm.r,0.0),max(ps.r-pm.r*pm.r,0.0),cross.r-rm.r*pm.r,1.0); }")
            confidence = try compile("""
            kernel vec4 k(__sample stats,__sample rlow,__sample plow,__sample feather) {
                float corr=clamp(stats.b/sqrt(stats.r*stats.g+0.000000000001),0.0,1.0);
                float sharper=clamp((sqrt(stats.g/(stats.r+0.000000000001))-1.0)/0.12,0.0,1.0);
                float signal=stats.r/(stats.r+0.000025);
                float color=(plow.r-rlow.r)/0.5;
                float c=feather.r*corr*corr*sharper*signal*exp(-0.5*color*color);
                return vec4(c,c,c,1.0);
            }
            """)
            gatedConfidence = try compile(common + "kernel vec4 k(__sample c,__sample blurred,__sample valid,__sample guardValue,float w,float h) { float v=min(c.r,blurred.r)*interiorValue(valid.r,guardValue.r,w,h); return vec4(v,v,v,1.0); }")
            let candidateMath = """
                vec3 base=decodeRGB(unpremultiply(r).rgb);
                float y=dot(base,vec3(0.2126,0.7152,0.0722));
                float target=max(exp(rawlog.r+conf.r*(pb.r-rb.r))-0.00001,0.0);
                float scale=y>0.0000000001?target/y:1.0;
                vec3 value=base*scale;
                float good=step(0.0,min(min(value.r,value.g),value.b))*step(max(max(value.r,value.g),value.b),1.0);
            """
            candidate = try compile(common + "kernel vec4 k(__sample r,__sample rawlog,__sample rb,__sample pb,__sample conf) {" + candidateMath + " if(conf.r<=0.0 || good<0.5) return r; return premultiply(vec4(encodeRGB(value),r.a)); }")
            diagnostic = try compile(common + "kernel vec4 k(__sample r,__sample rawlog,__sample rb,__sample pb,__sample conf,__sample valid,__sample guardValue,float w,float h) {" + candidateMath + "float inside=interiorValue(valid.r,guardValue.r,w,h); return vec4(conf.r*good,conf.r>0.0?1.0-good:0.0,valid.r+2.0*inside,1.0); }")
            driftSupport = try compile("kernel vec4 k(__sample d,__sample valid) { return vec4(d.r,valid.r,0.0,1.0); }")
        }
    }
}
