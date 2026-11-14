import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
import Darwin

/// Packs real photographic texels without changing their sampling density or triangle winding.
/// Source UVs use OBJ's bottom-left origin; image rectangles and page rows use top-left pixels.
enum TextureAtlasBuilder {
    struct Source: Sendable {
        var id: Int
        var imageURL: URL
        var pixelWidth: Int
        var pixelHeight: Int
    }

    typealias Face = TextureChartBuilder.Face

    struct MappedFace: Sendable {
        var id: Int
        var materialID: Int
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var c: SIMD2<Float>
    }

    struct Material: Sendable {
        var id: Int
        var filename: String
        var url: URL
        var pixelWidth: Int
        var pixelHeight: Int
        var isDedicatedOriginal: Bool
    }

    struct Metrics: Sendable {
        var sourceCount = 0
        var chartCount = 0
        var connectedIslandCount = 0
        /// Explicit RGBA source decodes during page rendering, once per photo/page.
        var renderSourceDecodeCount = 0
        var faceCount = 0
        var sourcePixels: Int64 = 0
        /// Rectangle texels needed by the selected triangles, including bilinear support.
        var croppedPixels: Int64 = 0
        /// Actual encoded page texels, including gutters and unused shelf space.
        var atlasPixels: Int64 = 0
        var dedicatedOriginalPixels: Int64 = 0
        var materialCount = 0
        var pageCount = 0
        var dedicatedOriginalCount = 0
        var bytesWritten: Int64 = 0
        var packingSeconds: Double = 0
        var renderingSeconds: Double = 0
        var totalSeconds: Double = 0
    }

    struct Result: Sendable {
        var materials: [Material]
        var faces: [MappedFace]
        var metrics: Metrics
    }

    enum AtlasError: LocalizedError {
        case invalidConfiguration
        case occupiedOutput
        case invalidSource(Int, String)
        case invalidFace(Int)
        case allocationFailed
        case imageEncoding

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "El tamaño de página o su margen no es válido."
            case .occupiedOutput: return "La carpeta de atlas ya existe. Usa una carpeta nueva."
            case .invalidSource(let id, let reason): return "Fotografía \(id) no válida para el atlas: \(reason)"
            case .invalidFace(let id): return "La cara \(id) tiene una fotografía o coordenadas de textura no válidas."
            case .allocationFailed: return "No hay memoria suficiente para conservar los texeles de esta fotografía."
            case .imageEncoding: return "No se pudo escribir la página de texturas sin pérdida."
            }
        }
    }

    /// `outputDirectory` must not exist. The entire directory is published by one rename.
    /// No photo/page count is capped. A patch larger than a page keeps its original dedicated image.
    static func build(
        sources: [Source], faces: [Face], outputDirectory: URL,
        pageSide: Int = 4096, padding: Int = 2, preserveSingleSource: Bool = true,
        control: ProcessingControl? = nil,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Result {
        try ProcessingControl.withControl(control) {
            try buildControlled(sources: sources, faces: faces, outputDirectory: outputDirectory,
                                pageSide: pageSide, padding: padding, preserveSingleSource: preserveSingleSource,
                                checkCancellation: { try ProcessingControl.checkpoint(); try checkCancellation() })
        }
    }

    private static func buildControlled(
        sources: [Source],
        faces: [Face],
        outputDirectory: URL,
        pageSide: Int = 4096,
        padding: Int = 2,
        preserveSingleSource: Bool = true,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Result {
        let start = ProcessInfo.processInfo.systemUptime
        try checkCancellation()
        guard padding >= 1, pageSide > padding, padding < pageSide - padding else {
            throw AtlasError.invalidConfiguration
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: outputDirectory.path) else { throw AtlasError.occupiedOutput }
        let parent = outputDirectory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".atlas-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let packingStart = ProcessInfo.processInfo.systemUptime
        var sourceByID: [Int: Source] = [:]
        for source in sources {
            guard sourceByID.updateValue(source, forKey: source.id) == nil,
                  source.pixelWidth > 0, source.pixelHeight > 0 else {
                throw AtlasError.invalidSource(source.id, "identificador repetido o dimensiones vacías.")
            }
        }
        let chartResult = try TextureChartBuilder.build(faces: faces,
            dimensions: sourceByID.mapValues { SIMD2($0.pixelWidth, $0.pixelHeight) },
            padding: padding, checkCancellation: checkCancellation)
        let chartsBySource = Dictionary(grouping: chartResult.charts, by: \.sourceID)
        var metrics = Metrics()
        metrics.sourceCount = chartsBySource.count
        metrics.faceCount = faces.count
        metrics.chartCount = chartResult.charts.count
        metrics.connectedIslandCount = chartResult.connectedIslandCount
        var patches: [Patch] = []
        var profiles: [Data] = []
        for id in chartsBySource.keys.sorted() {
            try checkCancellation()
            let source = sourceByID[id]!
            let metadata = try imageMetadata(source)
            let profile = metadata.profile
            let profileIndex: Int
            if let index = profiles.firstIndex(of: profile) { profileIndex = index }
            else { profileIndex = profiles.count; profiles.append(profile) }
            metrics.sourcePixels = try sum(metrics.sourcePixels, product(source.pixelWidth, source.pixelHeight))
            for chart in chartsBySource[id]! {
                metrics.croppedPixels = try sum(metrics.croppedPixels, product(chart.crop.width, chart.crop.height))
                patches.append(Patch(chartID: chart.id, source: source, crop: chart.crop,
                    colorSpace: metadata.colorSpace, profileIndex: profileIndex,
                    preserveNativePrecision: metadata.preserveNativePrecision))
            }
        }

        // Packing never rotates patches, so photographic handedness and UV winding remain intact.
        patches.sort {
            if $0.profileIndex != $1.profileIndex { return $0.profileIndex < $1.profileIndex }
            // Source locality keeps the same photograph on as few pages as fits;
            // rendering then decodes it once per page, never once per tiny chart.
            if $0.source.id != $1.source.id { return $0.source.id < $1.source.id }
            if $0.crop.height != $1.crop.height { return $0.crop.height > $1.crop.height }
            if $0.crop.width != $1.crop.width { return $0.crop.width > $1.crop.width }
            return $0.chartID < $1.chartID
        }
        var pages: [Page] = []
        var dedicated: [Patch] = []
        for patch in patches {
            try checkCancellation()
            let innerSide = pageSide - padding - padding
            if patch.preserveNativePrecision || (preserveSingleSource && metrics.sourceCount == 1) || patch.crop.width > innerSide || patch.crop.height > innerSide {
                dedicated.append(patch)
                continue
            }
            let width = patch.crop.width + padding + padding
            let height = patch.crop.height + padding + padding
            var packed = false
            for pageIndex in pages.indices where pages[pageIndex].profileIndex == patch.profileIndex {
                if pages[pageIndex].place(patch, width: width, height: height, side: pageSide) {
                    packed = true
                    break
                }
            }
            if !packed {
                var page = Page(profileIndex: patch.profileIndex, colorSpace: patch.colorSpace)
                guard page.place(patch, width: width, height: height, side: pageSide) else {
                    throw AtlasError.invalidConfiguration
                }
                pages.append(page)
            }
        }
        metrics.packingSeconds = ProcessInfo.processInfo.systemUptime - packingStart

        let renderingStart = ProcessInfo.processInfo.systemUptime
        var materials: [Material] = []
        var mapping: [Int: Mapping] = [:]
        for (pageIndex, page) in pages.enumerated() {
            try checkCancellation()
            let filename = String(format: "atlas_%06d.png", pageIndex)
            let url = staging.appendingPathComponent(filename)
            metrics.renderSourceDecodeCount += try render(page, padding: padding, to: url, checkCancellation: checkCancellation)
            let materialID = materials.count
            materials.append(Material(id: materialID, filename: filename, url: outputDirectory.appendingPathComponent(filename),
                                      pixelWidth: page.width, pixelHeight: page.height, isDedicatedOriginal: false))
            metrics.atlasPixels = try sum(metrics.atlasPixels, product(page.width, page.height))
            metrics.bytesWritten = try sum(metrics.bytesWritten, fileBytes(url))
            for placement in page.placements {
                mapping[placement.patch.chartID] = Mapping(materialID: materialID, width: page.width, height: page.height,
                    crop: placement.patch.crop, x: placement.x + padding, y: placement.y + padding)
            }
        }
        // One byte-exact original per source, even when several charts need it.
        let dedicatedBySource = Dictionary(grouping: dedicated, by: { $0.source.id })
        for sourceID in dedicatedBySource.keys.sorted() {
            try checkCancellation()
            let source = dedicatedBySource[sourceID]![0].source
            let ext = source.imageURL.pathExtension.lowercased()
            let filename = "source_\(source.id)." + (ext.isEmpty ? "image" : ext)
            let url = staging.appendingPathComponent(filename)
            try fm.copyItem(at: source.imageURL, to: url)
            try checkCancellation()
            let materialID = materials.count
            materials.append(Material(id: materialID, filename: filename, url: outputDirectory.appendingPathComponent(filename),
                                      pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, isDedicatedOriginal: true))
            metrics.dedicatedOriginalPixels = try sum(metrics.dedicatedOriginalPixels, product(source.pixelWidth, source.pixelHeight))
            metrics.bytesWritten = try sum(metrics.bytesWritten, fileBytes(url))
            for patch in dedicatedBySource[sourceID]! {
                mapping[patch.chartID] = Mapping(materialID: materialID, width: source.pixelWidth, height: source.pixelHeight,
                                                 crop: nil, x: 0, y: 0)
            }
        }
        var mapped: [MappedFace] = []
        mapped.reserveCapacity(faces.count)
        for (index, face) in faces.enumerated() {
            if index & 1023 == 0 { try checkCancellation() }
            guard let placement = mapping[chartResult.faceChartIDs[index]], let source = sourceByID[face.sourceID] else { throw AtlasError.invalidFace(face.id) }
            mapped.append(MappedFace(id: face.id, materialID: placement.materialID,
                a: placement.remap(face.a, source: source), b: placement.remap(face.b, source: source), c: placement.remap(face.c, source: source)))
        }
        metrics.renderingSeconds = ProcessInfo.processInfo.systemUptime - renderingStart
        metrics.pageCount = pages.count
        metrics.dedicatedOriginalCount = dedicatedBySource.count
        metrics.materialCount = materials.count
        try checkCancellation()
        guard !fm.fileExists(atPath: outputDirectory.path) else { throw AtlasError.occupiedOutput }
        try fm.moveItem(at: staging, to: outputDirectory)
        metrics.totalSeconds = ProcessInfo.processInfo.systemUptime - start
        return Result(materials: materials, faces: mapped, metrics: metrics)
    }

    private typealias PixelRect = TextureChartBuilder.PixelRect
    private struct Patch {
        var chartID: Int
        var source: Source
        var crop: PixelRect
        var colorSpace: CGColorSpace
        var profileIndex: Int
        var preserveNativePrecision: Bool
    }
    private struct Placement { var patch: Patch; var x: Int; var y: Int }
    private struct Shelf { var y: Int; var height: Int; var nextX: Int }

    private struct Page {
        var profileIndex: Int
        var colorSpace: CGColorSpace
        var placements: [Placement] = []
        var shelves: [Shelf] = []
        var width = 0
        var height = 0

        mutating func place(_ patch: Patch, width patchWidth: Int, height patchHeight: Int, side: Int) -> Bool {
            for index in shelves.indices where patchHeight <= shelves[index].height && patchWidth <= side - shelves[index].nextX {
                let x = shelves[index].nextX, y = shelves[index].y
                shelves[index].nextX += patchWidth
                placements.append(Placement(patch: patch, x: x, y: y))
                width = max(width, x + patchWidth)
                height = max(height, y + patchHeight)
                return true
            }
            let y = shelves.last.map { $0.y + $0.height } ?? 0
            guard patchWidth <= side, patchHeight <= side - y else { return false }
            shelves.append(Shelf(y: y, height: patchHeight, nextX: patchWidth))
            placements.append(Placement(patch: patch, x: 0, y: y))
            width = max(width, patchWidth)
            height = max(height, y + patchHeight)
            return true
        }
    }

    private struct Mapping {
        var materialID: Int
        var width: Int
        var height: Int
        var crop: PixelRect?
        var x: Int
        var y: Int

        func remap(_ uv: SIMD2<Float>, source: Source) -> SIMD2<Float> {
            guard let crop else { return uv }
            // Double arithmetic prevents large native rasters from losing another pixel to intermediate rounding.
            let u = (Double(x - crop.x) + Double(uv.x) * Double(source.pixelWidth)) / Double(width)
            let v = 1 - (Double(y - crop.y) + (1 - Double(uv.y)) * Double(source.pixelHeight)) / Double(height)
            return SIMD2(Float(u), Float(v))
        }
    }

    private static func imageMetadata(_ source: Source) throws -> (colorSpace: CGColorSpace, profile: Data, preserveNativePrecision: Bool) {
        try autoreleasepool {
            guard let container = CGImageSourceCreateWithURL(source.imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil) as? [CFString: Any],
                  let image = CGImageSourceCreateImageAtIndex(container, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width == source.pixelWidth, image.height == source.pixelHeight,
                  (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1 else {
                throw AtlasError.invalidSource(source.id, "la imagen, orientación o dimensiones no coinciden con la calibración.")
            }
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let profile = (space.copyICCData() as Data?) ?? Data((space.name as String? ?? "RGB").utf8)
            // The RGBA8 page path must never silently quantize a higher precision photograph.
            return (space, profile, image.bitsPerComponent > 8)
        }
    }

    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)

    private static func render(_ page: Page, padding: Int, to url: URL, checkCancellation: () throws -> Void) throws -> Int {
        let pageBytes = try byteCount(width: page.width, height: page.height)
        try TextureChartBuilder.checkAvailableMemory(pageBytes)
        guard let pageMemory = calloc(pageBytes, 1) else { throw AtlasError.allocationFailed }
        defer { free(pageMemory) }
        let destination = pageMemory.assumingMemoryBound(to: UInt8.self)
        let placementsBySource = Dictionary(grouping: page.placements, by: { $0.patch.source.id })
        var decodeCount = 0
        for sourceID in placementsBySource.keys.sorted() {
            try checkCancellation()
            try autoreleasepool {
                let placements = placementsBySource[sourceID]!
                let source = placements[0].patch.source
                let sourceBytes = try byteCount(width: source.pixelWidth, height: source.pixelHeight)
                let (twiceSource, overflow) = sourceBytes.multipliedReportingOverflow(by: 2)
                let (workingBytes, sumOverflow) = pageBytes.addingReportingOverflow(twiceSource)
                guard !overflow, !sumOverflow else { throw AtlasError.allocationFailed }
                // One page plus one native photo and decoder working space. This is
                // a fresh hardware-memory check, not a photo or resolution quota.
                try TextureChartBuilder.checkAvailableMemory(workingBytes)
                guard let container = CGImageSourceCreateWithURL(source.imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateImageAtIndex(container, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                      image.width == source.pixelWidth, image.height == source.pixelHeight else {
                    throw AtlasError.invalidSource(source.id, "la imagen cambió o no se pudo decodificar.")
                }
                guard let sourceMemory = calloc(sourceBytes, 1) else { throw AtlasError.allocationFailed }
                defer { free(sourceMemory) }
                guard let context = CGContext(data: sourceMemory, width: source.pixelWidth, height: source.pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: source.pixelWidth * 4, space: page.colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
                    throw AtlasError.allocationFailed
                }
                context.interpolationQuality = .none
                context.setBlendMode(.copy)
                context.draw(image, in: CGRect(x: 0, y: 0, width: source.pixelWidth, height: source.pixelHeight))
                decodeCount += 1
                let pixels = sourceMemory.assumingMemoryBound(to: UInt8.self)
                for placement in placements {
                    try checkCancellation()
                    let crop = placement.patch.crop
                    // Copy native texels 1:1. Every gutter repeats its nearest
                    // crop edge; the crop includes both bilinear neighbours.
                    for localY in -padding..<(crop.height + padding) {
                        if localY & 63 == 0 { try checkCancellation() }
                        let sourceY = crop.y + max(0, min(crop.height - 1, localY))
                        let targetY = placement.y + padding + localY
                        let first = (sourceY * source.pixelWidth + crop.x) * 4
                        let target = (targetY * page.width + placement.x) * 4
                        for x in 0..<padding { memcpy(destination + target + x * 4, pixels + first, 4) }
                        memcpy(destination + target + padding * 4, pixels + first, crop.width * 4)
                        let last = first + (crop.width - 1) * 4
                        for x in 0..<padding { memcpy(destination + target + (padding + crop.width + x) * 4, pixels + last, 4) }
                    }
                }
            }
        }
        try checkCancellation()
        // CGDataProvider borrows the single page buffer until synchronous PNG encoding completes.
        guard let provider = CGDataProvider(dataInfo: nil, data: pageMemory, size: pageBytes, releaseData: { _, _, _ in }),
              let image = CGImage(width: page.width, height: page.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: page.width * 4, space: page.colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AtlasError.imageEncoding
        }
        CGImageDestinationAddImage(encoder, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw AtlasError.imageEncoding }
        try checkCancellation()
        return decodeCount
    }

    private static func byteCount(width: Int, height: Int) throws -> Int {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow, bytes > 0 else { throw AtlasError.allocationFailed }
        return bytes
    }

    private static func product(_ width: Int, _ height: Int) throws -> Int64 {
        let (pixels, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !overflow else { throw AtlasError.allocationFailed }
        return pixels
    }

    private static func sum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw AtlasError.allocationFailed }
        return result
    }

    private static func fileBytes(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
