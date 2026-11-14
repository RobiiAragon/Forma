import Foundation
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct LiDARTextureBakeResult: Sendable {
    var objURL: URL
    var materialURL: URL
    var textureURLs: [URL]
    var texturedFaceCount: Int
    var unobservedFaceCount: Int
    /// Measured processing time and topological source boundaries, not sensor accuracy.
    var selectionSeconds: Double = 0
    var coherenceSeconds: Double = 0
    var totalSeconds: Double = 0
    var sourceBoundaryEdgesBefore: Int = 0
    var sourceBoundaryEdgesAfter: Int = 0
    var coherenceReassignedFaces: Int = 0
    var photometricSeconds: Double = 0
    var seamSampleCount: Int = 0
    var seamValidationSampleCount: Int = 0
    var seamLinkCount: Int = 0
    var adjustedPhotoCount: Int = 0
    var photometricImageDecodeCount: Int = 0
    var seamRMSEBefore: Double = 0
    var seamRMSEAfter: Double = 0
    var seamLogRMSEBefore: Double = 0
    var seamLogRMSEAfter: Double = 0
    var photoExposureGains: [String: Double] = [:]
    var exposureReferencePhotos: [String] = []
    var sourceTextureCount: Int = 0
    var atlasPageCount: Int = 0
    var atlasMaterialCount: Int = 0
    var atlasDedicatedOriginalCount: Int = 0
    var atlasSourcePixels: Int64 = 0
    var atlasCroppedPixels: Int64 = 0
    var atlasEncodedPixels: Int64 = 0
    var atlasDedicatedOriginalPixels: Int64 = 0
    var atlasBytesWritten: Int64 = 0
    var atlasSeconds: Double = 0
}

/// Projects real photographs onto the original mesh, selecting one observed view per face.
/// Native pixels are retained in lossless atlas crops. Exposure changes need
/// co-visible evidence; no synthetic surface/color replaces an unobserved face.
enum LiDARTextureBaker {
    struct Projection {
        var pixel: SIMD2<Float>
        var uv: SIMD2<Float>
        var cameraDepth: Float
    }

    enum BakeError: LocalizedError {
        case invalidMesh(String)
        case invalidFrame(String)
        case occupiedOutput
        case imageEncoding

        var errorDescription: String? {
            switch self {
            case .invalidMesh(let reason): return "Malla no válida para texturizar: \(reason)"
            case .invalidFrame(let reason): return "Fotograma no válido para texturizar: \(reason)"
            case .occupiedOutput: return "El paquete de texturas ya contiene archivos de salida. Usa otra carpeta."
            case .imageEncoding: return "No se pudo conservar la fotografía a su resolución original."
            }
        }
    }

    static func bake(
        mesh: MeshSnapshot,
        keyframes: [RGBDFrameRecord],
        datasetDirectory: URL,
        outputDirectory: URL,
        control: ProcessingControl? = nil,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> LiDARTextureBakeResult {
        try ProcessingControl.withControl(control) {
            try bakeControlled(mesh: mesh, keyframes: keyframes, datasetDirectory: datasetDirectory,
                               outputDirectory: outputDirectory, progress: progress)
        }
    }

    private static func bakeControlled(
        mesh: MeshSnapshot,
        keyframes: [RGBDFrameRecord],
        datasetDirectory: URL,
        outputDirectory: URL,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> LiDARTextureBakeResult {
        let startTime = ProcessInfo.processInfo.systemUptime
        progress(0)
        try ProcessingControl.checkpoint()
        guard !mesh.vertices.isEmpty, !mesh.triangles.isEmpty, mesh.triangles.count % 3 == 0 else {
            throw BakeError.invalidMesh("se necesitan vértices y triángulos completos.")
        }
        guard mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              mesh.triangles.allSatisfy({ Int($0) < mesh.vertices.count }) else {
            throw BakeError.invalidMesh("coordenadas no finitas o índices fuera de rango.")
        }
        let fileManager = FileManager.default
        let finalOBJ = outputDirectory.appendingPathComponent("modelo.obj")
        let finalMTL = outputDirectory.appendingPathComponent("modelo.mtl")
        let finalTextures = outputDirectory.appendingPathComponent("textures", isDirectory: true)
        guard ![finalOBJ, finalMTL, finalTextures].contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw BakeError.occupiedOutput
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let staging = outputDirectory.appendingPathComponent(".bake-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let frames = try keyframes.map { try FrameCamera($0, datasetDirectory: datasetDirectory) }.sorted {
            // Try the highest real pixel density first; this also avoids unnecessary ray tests.
            let leftPixels = Double($0.record.imageWidth) * Double($0.record.imageHeight)
            let rightPixels = Double($1.record.imageWidth) * Double($1.record.imageHeight)
            if leftPixels != rightPixels { return leftPixels > rightPixels }
            if $0.record.timestamp != $1.record.timestamp { return $0.record.timestamp < $1.record.timestamp }
            if $0.record.id != $1.record.id { return $0.record.id < $1.record.id }
            return $0.record.rgbFile < $1.record.rgbFile
        }
        let faces = faceGeometry(mesh)
        // A neutral export needs no acceleration structure or photographic analysis.
        let visibility = frames.isEmpty ? nil : try MeshVisibility(mesh: mesh, faces: faces)
        progress(0.05)
        var assignments = [Int](repeating: -1, count: faces.count)
        var scores = [Float](repeating: 0, count: faces.count)
        var faceUVs = [FaceUV](repeating: .zero, count: faces.count)

        let selectionStart = ProcessInfo.processInfo.systemUptime
        for (frameIndex, camera) in frames.enumerated() {
            try ProcessingControl.checkpoint()
            let depth = try DepthRaster(camera.record, datasetDirectory: datasetDirectory)
            let detail = try PhotographicDetail(camera)
            for faceIndex in faces.indices {
                if faceIndex & 255 == 0 { try ProcessingControl.checkpoint() }
                guard let visibility,
                      let observation = observe(faceIndex, mesh: mesh, faces: faces, camera: camera,
                                                depth: depth, detail: detail, visibility: visibility,
                                                minimumScore: scores[faceIndex]),
                      observation.score > scores[faceIndex] else { continue }
                scores[faceIndex] = observation.score
                assignments[faceIndex] = frameIndex
                faceUVs[faceIndex] = observation.uv
            }
            progress(0.05 + 0.72 * Double(frameIndex + 1) / Double(max(1, frames.count)))
        }
        let selectionSeconds = ProcessInfo.processInfo.systemUptime - selectionStart
        let coherenceStart = ProcessInfo.processInfo.systemUptime
        let coherence = try makeCoherent(mesh: mesh, faces: faces, frames: frames, visibility: visibility,
                                         datasetDirectory: datasetDirectory, assignments: &assignments,
                                         scores: scores, uvs: &faceUVs) { fraction in
            progress(0.77 + 0.07 * fraction)
        }
        let coherenceSeconds = ProcessInfo.processInfo.systemUptime - coherenceStart

        let usedFrames = Set(assignments.filter { $0 >= 0 }).sorted()
        let photometricStart = ProcessInfo.processInfo.systemUptime
        let photometric = try harmonizeSeams(mesh: mesh, faces: faces, frames: frames,
                                            visibility: visibility, assignments: assignments,
                                            datasetDirectory: datasetDirectory)
        let photometricSeconds = ProcessInfo.processInfo.systemUptime - photometricStart
        progress(0.88)
        let sourceTextures = staging.appendingPathComponent(".texture-sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceTextures, withIntermediateDirectories: false)
        var atlasSources: [TextureAtlasBuilder.Source] = []
        for (index, frameIndex) in usedFrames.enumerated() {
            try ProcessingControl.checkpoint()
            let camera = frames[frameIndex]
            let gain = photometric.gains[frameIndex] ?? 1
            let name = gain < 1 - 0.000001
                ? try correctedImage(camera, gain: gain, frameIndex: frameIndex, directory: sourceTextures)
                : try preserveImage(camera, frameIndex: frameIndex, directory: sourceTextures)
            atlasSources.append(.init(id: frameIndex, imageURL: sourceTextures.appendingPathComponent(name),
                                      pixelWidth: camera.record.imageWidth, pixelHeight: camera.record.imageHeight))
            progress(0.88 + 0.05 * Double(index + 1) / Double(max(1, usedFrames.count)))
        }

        let texturesDirectory = staging.appendingPathComponent("textures", isDirectory: true)
        let atlasFaces = faces.indices.compactMap { index -> TextureAtlasBuilder.Face? in
            guard assignments[index] >= 0 else { return nil }
            let uv = faceUVs[index]
            return .init(id: index, sourceID: assignments[index], a: uv.a, b: uv.b, c: uv.c)
        }
        let atlas = try TextureAtlasBuilder.build(sources: atlasSources, faces: atlasFaces,
                                                   outputDirectory: texturesDirectory)
        var materialAssignments = assignments
        for face in atlas.faces {
            materialAssignments[face.id] = face.materialID
            faceUVs[face.id] = FaceUV(a: face.a, b: face.b, c: face.c)
        }
        let textureFilenames = Dictionary(uniqueKeysWithValues: atlas.materials.map { ($0.id, $0.filename) })

        let obj = staging.appendingPathComponent("modelo.obj")
        let mtl = staging.appendingPathComponent("modelo.mtl")
        try writeMaterials(textureFilenames, to: mtl)
        try writeOBJ(mesh: mesh, faces: faces, assignments: materialAssignments, uvs: faceUVs, to: obj)
        progress(0.97)
        try ProcessingControl.checkpoint()
        var committed: [URL] = []
        do {
            for name in ["textures", "modelo.mtl", "modelo.obj"] {
                let target = outputDirectory.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: target.path) else { throw BakeError.occupiedOutput }
                try fileManager.moveItem(at: staging.appendingPathComponent(name), to: target)
                committed.append(target)
            }
        } catch {
            for url in committed { try? fileManager.removeItem(at: url) }
            throw error
        }
        progress(1)
        let textured = assignments.reduce(0) { $0 + ($1 >= 0 ? 1 : 0) }
        return LiDARTextureBakeResult(
            objURL: finalOBJ,
            materialURL: finalMTL,
            textureURLs: atlas.materials.map { finalTextures.appendingPathComponent($0.filename) },
            texturedFaceCount: textured,
            unobservedFaceCount: faces.count - textured,
            selectionSeconds: selectionSeconds, coherenceSeconds: coherenceSeconds,
            totalSeconds: ProcessInfo.processInfo.systemUptime - startTime,
            sourceBoundaryEdgesBefore: coherence.before, sourceBoundaryEdgesAfter: coherence.after,
            coherenceReassignedFaces: coherence.changed,
            photometricSeconds: photometricSeconds,
            seamSampleCount: photometric.sampleCount,
            seamValidationSampleCount: photometric.validationSampleCount,
            seamLinkCount: photometric.linkCount,
            adjustedPhotoCount: photometric.adjustedPhotoCount,
            photometricImageDecodeCount: photometric.imageDecodeCount,
            seamRMSEBefore: photometric.seamRMSEBefore, seamRMSEAfter: photometric.seamRMSEAfter,
            seamLogRMSEBefore: photometric.seamLogRMSEBefore, seamLogRMSEAfter: photometric.seamLogRMSEAfter,
            photoExposureGains: Dictionary(usedFrames.map {
                (frames[$0].record.rgbFile, photometric.gains[$0] ?? 1)
            }, uniquingKeysWith: { first, _ in first }),
            exposureReferencePhotos: photometric.referenceFrames.map { frames[$0].record.rgbFile },
            sourceTextureCount: usedFrames.count, atlasPageCount: atlas.metrics.pageCount,
            atlasMaterialCount: atlas.metrics.materialCount,
            atlasDedicatedOriginalCount: atlas.metrics.dedicatedOriginalCount,
            atlasSourcePixels: atlas.metrics.sourcePixels, atlasCroppedPixels: atlas.metrics.croppedPixels,
            atlasEncodedPixels: atlas.metrics.atlasPixels,
            atlasDedicatedOriginalPixels: atlas.metrics.dedicatedOriginalPixels,
            atlasBytesWritten: atlas.metrics.bytesWritten, atlasSeconds: atlas.metrics.totalSeconds
        )
    }

    /// Testable projection in native sensor pixels, not a cropped or rotated UIKit viewport.
    static func project(worldPoint: SIMD3<Float>, frame: RGBDFrameRecord) -> Projection? {
        guard let camera = try? FrameCamera(frame) else { return nil }
        return camera.project(worldPoint)
    }

    private struct FaceUV {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var c: SIMD2<Float>
        static let zero = FaceUV(a: .zero, b: .zero, c: .zero)
    }

    private struct FaceGeometry {
        var center: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    private static func faceGeometry(_ mesh: MeshSnapshot) -> [FaceGeometry] {
        stride(from: 0, to: mesh.triangles.count, by: 3).map { index in
            let a = mesh.vertices[Int(mesh.triangles[index])]
            let b = mesh.vertices[Int(mesh.triangles[index + 1])]
            let c = mesh.vertices[Int(mesh.triangles[index + 2])]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            let normal = length.isFinite && length > 0.00000001 ? cross / length : .zero
            return FaceGeometry(center: a / 3 + b / 3 + c / 3, normal: normal)
        }
    }

    private struct Observation {
        var score: Float
        var uv: FaceUV
    }

    private static func observe(_ faceIndex: Int, mesh: MeshSnapshot, faces: [FaceGeometry],
                                camera: FrameCamera, depth: DepthRaster?, detail: PhotographicDetail,
                                visibility: MeshVisibility, minimumScore: Float) -> Observation? {
        let face = faces[faceIndex]
        let toCamera = camera.center - face.center
        let distanceSquared = simd_length_squared(toCamera)
        guard distanceSquared.isFinite, distanceSquared > 0.000001 else { return nil }
        let cosine = simd_dot(face.normal, toCamera / sqrt(distanceSquared))
        guard cosine > 0.05 else { return nil }
        let offset = faceIndex * 3
        let a = mesh.vertices[Int(mesh.triangles[offset])]
        let b = mesh.vertices[Int(mesh.triangles[offset + 1])]
        let c = mesh.vertices[Int(mesh.triangles[offset + 2])]
        guard let pa = camera.project(a), let pb = camera.project(b), let pc = camera.project(c),
              camera.contains(pa.pixel), camera.contains(pb.pixel), camera.contains(pc.pixel) else { return nil }
        let ab = pb.pixel - pa.pixel, ac = pc.pixel - pa.pixel
        let projectedArea = abs(ab.x * ac.y - ab.y * ac.x) * 0.5
        let geometricScore = projectedArea * cosine * cosine
        // Both factors below are <= 1: avoid image samples and ray tests when this
        // candidate cannot improve the result, including uniform photographic regions.
        guard geometricScore.isFinite, projectedArea > 0.00001,
              geometricScore * detail.maximumQuality >= minimumScore else { return nil }
        let photographicScore = geometricScore * detail.quality(pa.pixel, pb.pixel, pc.pixel)
        guard photographicScore >= minimumScore else { return nil }

        var residualSum: Float = 0
        // Reuse the three vertex projections; do not allocate a seven-element array
        // for every triangle/view pair in a large scan.
        for sampleIndex in 0..<7 {
            let point: SIMD3<Float>
            let projection: Projection
            switch sampleIndex {
            case 0: point = a; projection = pa
            case 1: point = b; projection = pb
            case 2: point = c; projection = pc
            default:
                switch sampleIndex {
                case 3: point = face.center
                case 4: point = (a + b) * 0.5
                case 5: point = (b + c) * 0.5
                default: point = (c + a) * 0.5
                }
                guard let projected = camera.project(point), camera.contains(projected.pixel) else { return nil }
                projection = projected
            }
            if let depth {
                guard let residual = depth.relativeResidual(for: projection, imageWidth: camera.width,
                                                            imageHeight: camera.height) else { return nil }
                residualSum += residual
            }
            // A coarse depth raster or its tolerance can miss a foreground edge
            // while the triangle center stays visible. Validate every existing
            // sample against the original mesh, even when LiDAR depth is present.
            // HiRes still uses only its own returned-frame pose/depth.
            if visibility.isOccluded(from: camera.center, to: point, excludingFace: faceIndex) { return nil }
        }
        let score = photographicScore / (1 + residualSum / 7)
        guard score.isFinite, score >= minimumScore else { return nil }
        return Observation(score: score, uv: FaceUV(a: pa.uv, b: pb.uv, c: pc.uv))
    }

    private struct FramePair: Hashable, Comparable {
        var first: Int
        var second: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.first == rhs.first ? lhs.second < rhs.second : lhs.first < rhs.first
        }
    }

    private struct SeamSegment {
        var face: Int
        var a: SIMD3<Float>
        var b: SIMD3<Float>
    }

    /// Geometry identifies correspondence: both colors come from the exact same
    /// world point. Photographs with no visible shared edge never share a gain.
    private static func harmonizeSeams(mesh: MeshSnapshot, faces: [FaceGeometry], frames: [FrameCamera],
                                       visibility: MeshVisibility?, assignments: [Int],
                                       datasetDirectory: URL) throws -> PhotometricHarmonizer.Result {
        let used = Set(assignments.filter { $0 >= 0 }).sorted()
        guard used.count > 1, let visibility else {
            return try PhotometricHarmonizer.harmonize(frameIndices: used, links: [])
        }
        let neighbors = try smoothNeighbors(mesh: mesh, faces: faces)
        var segments: [FramePair: [SeamSegment]] = [:]
        for face in faces.indices where assignments[face] >= 0 {
            if face & 1023 == 0 { try ProcessingControl.checkpoint() }
            for edge in 0..<3 {
                let other = neighbors[face][edge]
                guard other > face, assignments[other] >= 0, assignments[other] != assignments[face] else { continue }
                let first = min(assignments[face], assignments[other]), second = max(assignments[face], assignments[other])
                let a = mesh.vertices[Int(mesh.triangles[face * 3 + edge])]
                let b = mesh.vertices[Int(mesh.triangles[face * 3 + (edge + 1) % 3])]
                guard simd_length_squared(b - a) > 1e-12 else { continue }
                segments[FramePair(first: first, second: second), default: []].append(.init(face: face, a: a, b: b))
            }
        }
        let pairs = segments.keys.sorted().filter { frames[$0.first].supportsExposureDerivative && frames[$0.second].supportsExposureDerivative }
        var incident = [[Int]](repeating: [], count: frames.count)
        for (index, pair) in pairs.enumerated() {
            incident[pair.first].append(index); incident[pair.second].append(index)
        }
        // Retain only sampled colors between visits, never decoded photographs.
        // Each camera is decoded once regardless of how many neighbors it has.
        var firstColors = [[SIMD3<Float>]?](repeating: nil, count: pairs.count)
        var links: [PhotometricHarmonizer.Link] = []
        var decodes = 0
        for frameIndex in used where !incident[frameIndex].isEmpty {
            try ProcessingControl.checkpoint()
            try autoreleasepool {
                let camera = frames[frameIndex]
                var image: PhotometricRaster?
                let depth = try DepthRaster(camera.record, datasetDirectory: datasetDirectory)
                for pairIndex in incident[frameIndex] {
                    try ProcessingControl.checkpoint()
                    let pair = pairs[pairIndex], edges = segments[pair] ?? []
                    let isFirst = pair.first == frameIndex
                    var colors = isFirst ? [SIMD3<Float>](repeating: SIMD3(repeating: .nan), count: edges.count * 18) : []
                    let previous = firstColors[pairIndex]
                    var observations: [PhotometricHarmonizer.ColorPair] = []
                    for (segmentIndex, segment) in edges.enumerated() {
                        if segmentIndex & 127 == 0 { try ProcessingControl.checkpoint() }
                        for index in 0..<18 {
                            let sampleIndex = segmentIndex * 18 + index
                            if !isFirst, previous?[sampleIndex].x.isFinite != true { continue }
                            let t = (Float(index) + 0.5) / 18
                            let point = segment.a * (1 - t) + segment.b * t
                            guard let projection = visibleSeamProjection(point, face: segment.face, faces: faces,
                                                                         camera: camera, depth: depth, visibility: visibility) else { continue }
                            if image == nil { image = try PhotometricRaster(camera); decodes += 1 }
                            guard let color = image?.sample(projection.pixel) else { continue }
                            if isFirst { colors[sampleIndex] = color }
                            else if let previous {
                                observations.append(.init(first: previous[sampleIndex], second: color,
                                                          isValidation: index.isMultiple(of: 3)))
                            }
                        }
                    }
                    if isFirst { firstColors[pairIndex] = colors }
                    else {
                        firstColors[pairIndex] = nil
                        try ProcessingControl.checkpoint()
                        if let link = PhotometricHarmonizer.makeLink(first: pair.first, second: pair.second, pairs: observations) { links.append(link) }
                    }
                }
            }
        }
        var result = try PhotometricHarmonizer.harmonize(frameIndices: used, links: links)
        result.imageDecodeCount = decodes
        return result
    }

    private static func visibleSeamProjection(_ point: SIMD3<Float>, face: Int, faces: [FaceGeometry],
                                               camera: FrameCamera, depth: DepthRaster?,
                                               visibility: MeshVisibility) -> Projection? {
        let toCamera = camera.center - point, distance = simd_length(toCamera)
        guard distance > 0.001, simd_dot(faces[face].normal, toCamera / distance) > 0.05,
              let projection = camera.project(point), camera.contains(projection.pixel) else { return nil }
        if let depth, depth.relativeResidual(for: projection, imageWidth: camera.width, imageHeight: camera.height) == nil { return nil }
        guard !visibility.isOccluded(from: camera.center, to: point, excludingFace: face) else { return nil }
        return projection
    }

    private struct PhotometricRaster {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var nativeWidth: Float
        var nativeHeight: Float

        init(_ camera: FrameCamera) throws {
            guard let url = camera.imageURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary), let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw BakeError.imageEncoding }
            width = image.width; height = image.height
            nativeWidth = camera.width; nativeHeight = camera.height
            var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard rendered else { throw BakeError.imageEncoding }
            self.pixels = pixels
        }

        func sample(_ pixel: SIMD2<Float>) -> SIMD3<Float>? {
            let x = (pixel.x + 0.5) * Float(width) / nativeWidth - 0.5
            let y = (pixel.y + 0.5) * Float(height) / nativeHeight - 0.5
            guard x >= 1, y >= 1, x < Float(width - 2), y < Float(height - 2) else { return nil }
            let ix = Int(x), iy = Int(y), dx = x - Float(ix), dy = y - Float(iy)
            func color(_ px: Int, _ py: Int) -> SIMD3<Float> {
                let index = (py * width + px) * 4
                return SIMD3(PhotometricHarmonizer.linearSRGB(Float(pixels[index]) / 255),
                             PhotometricHarmonizer.linearSRGB(Float(pixels[index + 1]) / 255),
                             PhotometricHarmonizer.linearSRGB(Float(pixels[index + 2]) / 255))
            }
            return (color(ix, iy) * (1 - dx) + color(ix + 1, iy) * dx) * (1 - dy)
                + (color(ix, iy + 1) * (1 - dx) + color(ix + 1, iy + 1) * dx) * dy
        }
    }

    private static func correctedImage(_ camera: FrameCamera, gain: Double, frameIndex: Int, directory: URL) throws -> String {
        guard gain.isFinite, gain > 0, gain <= 1, let imageURL = camera.imageURL,
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == camera.record.imageWidth, image.height == camera.record.imageHeight,
              camera.supportsExposureDerivative,
              let space = image.colorSpace else { throw BakeError.imageEncoding }
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow else { throw BakeError.imageEncoding }
        var pixels = [UInt8](repeating: 255, count: byteCount)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw BakeError.imageEncoding }
        let lookup = (0..<256).map { value -> UInt8 in
            let linear = PhotometricHarmonizer.linearSRGB(Float(value) / 255) * Float(gain)
            return UInt8(min(255, max(0, (PhotometricHarmonizer.encodedSRGB(linear) * 255).rounded())))
        }
        for row in 0..<image.height {
            if row & 63 == 0 { try ProcessingControl.checkpoint() }
            for column in 0..<image.width {
                let index = (row * image.width + column) * 4
                pixels[index] = lookup[Int(pixels[index])]
                pixels[index + 1] = lookup[Int(pixels[index + 1])]
                pixels[index + 2] = lookup[Int(pixels[index + 2])]
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let corrected = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw BakeError.imageEncoding
        }
        let name = String(format: "camera_%06d_exposure.png", frameIndex)
        guard let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,
                                                               UTType.png.identifier as CFString, 1, nil) else { throw BakeError.imageEncoding }
        CGImageDestinationAddImage(destination, corrected, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BakeError.imageEncoding }
        return name
    }

    /// Image gradients influence view selection only. The original image bytes and
    /// UV calibration are always used for the exported texture. This is a bounded
    /// heuristic for local detail, not a calibrated focus or sensor-accuracy score.
    private struct PhotographicDetail {
        private let gradients: [UInt8]
        private let width: Int
        private let height: Int
        private let nativeWidth: Float
        private let nativeHeight: Float
        let maximumQuality: Float

        init(_ camera: FrameCamera) throws {
            guard let url = camera.imageURL,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: false,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                throw BakeError.invalidFrame("no se pudo analizar la fotografía \(camera.record.rgbFile).")
            }
            width = image.width
            height = image.height
            nativeWidth = camera.width
            nativeHeight = camera.height
            var luminance = [UInt8](repeating: 0, count: width * height)
            let rendered = luminance.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard rendered else { throw BakeError.imageEncoding }
            var gradients = [UInt8](repeating: 0, count: width * height)
            var maximum: UInt8 = 0
            if width > 2, height > 2 {
                for y in 1..<(height - 1) {
                    if y & 127 == 0 { try ProcessingControl.checkpoint() }
                    for x in 1..<(width - 1) {
                        let index = y * width + x
                        let horizontal = abs(Int(luminance[index + 1]) - Int(luminance[index - 1]))
                        let vertical = abs(Int(luminance[index + width]) - Int(luminance[index - width]))
                        let value = UInt8(min(255, (horizontal + vertical) / 2))
                        gradients[index] = value
                        maximum = max(maximum, value)
                    }
                }
            }
            self.gradients = gradients
            maximumQuality = Self.factor(Float(maximum))
        }

        private static func factor(_ gradient: Float) -> Float {
            // A flat surface is a legitimate observation and must never be discarded.
            0.35 + 0.65 * min(1, gradient / 24)
        }

        private func gradient(_ pixel: SIMD2<Float>) -> Float {
            let x = min(width - 1, max(0, Int(((pixel.x + 0.5) * Float(width) / nativeWidth - 0.5).rounded())))
            let y = min(height - 1, max(0, Int(((pixel.y + 0.5) * Float(height) / nativeHeight - 0.5).rounded())))
            // A 3x3 neighborhood reduces pixel-phase sensitivity of thin image detail.
            var total: Float = 0
            var count: Float = 0
            for row in max(0, y - 1)...min(height - 1, y + 1) {
                for column in max(0, x - 1)...min(width - 1, x + 1) {
                    total += Float(gradients[row * width + column])
                    count += 1
                }
            }
            return total / max(1, count)
        }

        func quality(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            // Interior samples avoid choosing a source for a sharp background along a silhouette.
            let center = (a + b + c) / 3
            let detail = gradient(center) + gradient(a * 0.6 + b * 0.2 + c * 0.2)
                + gradient(a * 0.2 + b * 0.6 + c * 0.2) + gradient(a * 0.2 + b * 0.2 + c * 0.6)
                + gradient(a * 0.45 + b * 0.45 + c * 0.1) + gradient(a * 0.1 + b * 0.45 + c * 0.45)
                + gradient(a * 0.45 + b * 0.1 + c * 0.45)
            return Self.factor(detail / 7)
        }
    }

    private struct Alternative {
        var face: Int
        var frame: Int
        var observation: Observation?
    }

    /// Local label optimization, inspired by the data/smoothness distinction in
    /// Waechter et al., ECCV 2014, https://download.hrz.tu-darmstadt.de/pub/FB20/GCC/paper/Waechter-2014-LTB.pdf
    /// It is deliberately conservative: only already-observed neighboring sources,
    /// smooth manifold edges, and >=95% of each face's best score are admissible.
    /// Neither UVs nor photographs are warped, blurred, blended or color-corrected.
    private static func makeCoherent(mesh: MeshSnapshot, faces: [FaceGeometry], frames: [FrameCamera],
                                     visibility: MeshVisibility?, datasetDirectory: URL,
                                     assignments: inout [Int], scores: [Float], uvs: inout [FaceUV],
                                     progress: (Double) -> Void) throws -> (before: Int, after: Int, changed: Int) {
        guard Set(assignments.filter { $0 >= 0 }).count > 1, let visibility else { return (0, 0, 0) }
        let neighbors = try smoothNeighbors(mesh: mesh, faces: faces)
        func boundaryCount(_ labels: [Int]) -> Int {
            var count = 0
            for face in faces.indices where labels[face] >= 0 {
                for edge in 0..<3 {
                    let other = neighbors[face][edge]
                    if other > face, labels[other] >= 0, labels[face] != labels[other] { count += 1 }
                }
            }
            return count
        }
        let before = boundaryCount(assignments)
        guard before > 0 else { return (0, 0, 0) }
        let originalAssignments = assignments
        let originalUVs = uvs
        var starts = [Int](repeating: 0, count: faces.count + 1)
        var alternatives: [Alternative] = []
        var requests = [[Int]](repeating: [], count: frames.count)
        for face in faces.indices {
            if face & 1023 == 0 { try ProcessingControl.checkpoint() }
            starts[face] = alternatives.count
            guard assignments[face] >= 0 else { continue }
            for edge in 0..<3 {
                let other = neighbors[face][edge]
                guard other >= 0, assignments[other] >= 0, assignments[other] != assignments[face] else { continue }
                let frame = assignments[other]
                guard !alternatives[starts[face]...].contains(where: { $0.frame == frame }) else { continue }
                requests[frame].append(alternatives.count)
                alternatives.append(Alternative(face: face, frame: frame))
            }
        }
        starts[faces.count] = alternatives.count
        // Load/decode at most one auxiliary raster and one depth map at a time,
        // and validate only labels present at the mesh's existing source boundaries.
        for (frameIndex, indices) in requests.enumerated() where !indices.isEmpty {
            try ProcessingControl.checkpoint()
            let camera = frames[frameIndex]
            let depth = try DepthRaster(camera.record, datasetDirectory: datasetDirectory)
            let detail = try PhotographicDetail(camera)
            for (index, candidateIndex) in indices.enumerated() {
                if index & 255 == 0 { try ProcessingControl.checkpoint() }
                let face = alternatives[candidateIndex].face
                alternatives[candidateIndex].observation = observe(face, mesh: mesh, faces: faces, camera: camera,
                    depth: depth, detail: detail, visibility: visibility, minimumScore: scores[face] * 0.95)
            }
            progress(0.85 * Double(frameIndex + 1) / Double(max(1, frames.count)))
        }
        func energy(face: Int, label: Int, score: Float) -> Float {
            var seams: Float = 0
            for edge in 0..<3 {
                let other = neighbors[face][edge]
                if other >= 0, assignments[other] >= 0 {
                    if assignments[other] != label { seams += 1 }
                }
            }
            // A constant cost per shared edge is symmetric. Starting from the
            // per-face best data score, strict energy descent cannot add net seams.
            return max(0, 1 - score / scores[face]) + 0.04 * seams
        }
        // In-place coordinate descent avoids swapping an entire checkerboard of
        // labels. Strict energy improvement and deterministic ordering break ties.
        for pass in 0..<3 {
            var changed = false
            for face in faces.indices where starts[face] < starts[face + 1] {
                if face & 255 == 0 { try ProcessingControl.checkpoint() }
                var selectedLabel = assignments[face]
                var selectedScore = scores[face]
                var selectedUV = uvs[face]
                if selectedLabel != originalAssignments[face],
                   let current = alternatives[starts[face]..<starts[face + 1]].first(where: { $0.frame == selectedLabel })?.observation {
                    selectedScore = current.score
                }
                var selectedEnergy = energy(face: face, label: selectedLabel, score: selectedScore)
                let originalEnergy = energy(face: face, label: originalAssignments[face], score: scores[face])
                if originalEnergy < selectedEnergy - 0.000001 {
                    selectedLabel = originalAssignments[face]
                    selectedScore = scores[face]
                    selectedUV = originalUVs[face]
                    selectedEnergy = originalEnergy
                }
                for candidate in alternatives[starts[face]..<starts[face + 1]] {
                    guard let observation = candidate.observation else { continue }
                    let candidateEnergy = energy(face: face, label: candidate.frame, score: observation.score)
                    if candidateEnergy < selectedEnergy - 0.000001 {
                        selectedLabel = candidate.frame
                        selectedScore = observation.score
                        selectedUV = observation.uv
                        selectedEnergy = candidateEnergy
                    }
                }
                if selectedLabel != assignments[face] {
                    assignments[face] = selectedLabel
                    uvs[face] = selectedUV
                    changed = true
                }
            }
            progress(0.85 + 0.05 * Double(pass + 1))
            if !changed { break }
        }
        progress(1)
        return (before, boundaryCount(assignments), zip(assignments, originalAssignments).filter { $0 != $1 }.count)
    }

    private static func smoothNeighbors(mesh: MeshSnapshot, faces: [FaceGeometry]) throws -> [SIMD3<Int>] {
        var neighbors = [SIMD3<Int>](repeating: SIMD3(repeating: -1), count: faces.count)
        // Positive owner: first incidence. Negative owner: two incidences. Zero:
        // non-manifold, so no smoothing is allowed across this edge.
        var edges: [UInt64: Int] = [:]
        for face in faces.indices {
            if face & 1023 == 0 { try ProcessingControl.checkpoint() }
            for edge in 0..<3 {
                let a = mesh.triangles[face * 3 + edge], b = mesh.triangles[face * 3 + (edge + 1) % 3]
                if a == b { continue }
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let owner = edges[key] {
                    if owner > 0 {
                        let first = (owner - 1) / 3, firstEdge = (owner - 1) % 3
                        if simd_dot(faces[first].normal, faces[face].normal) >= 0.96 {
                            neighbors[first][firstEdge] = face
                            neighbors[face][edge] = first
                        }
                        edges[key] = -owner
                    } else if owner < 0 {
                        let first = (-owner - 1) / 3, firstEdge = (-owner - 1) % 3
                        let second = neighbors[first][firstEdge]
                        neighbors[first][firstEdge] = -1
                        if second >= 0 {
                            for slot in 0..<3 where neighbors[second][slot] == first { neighbors[second][slot] = -1 }
                        }
                        edges[key] = 0
                    }
                } else { edges[key] = face * 3 + edge + 1 }
            }
        }
        return neighbors
    }

    private struct FrameCamera {
        let record: RGBDFrameRecord
        let worldToCamera: simd_float4x4
        let intrinsics: simd_float3x3
        let center: SIMD3<Float>
        let width: Float
        let height: Float
        var imageURL: URL?
        var imageType: String?
        var supportsExposureDerivative = false

        init(_ record: RGBDFrameRecord, datasetDirectory: URL? = nil) throws {
            guard record.imageWidth > 1, record.imageHeight > 1, record.timestamp.isFinite,
                  record.intrinsics.count == 9, record.intrinsics.allSatisfy(\.isFinite),
                  record.intrinsics[0] > 0, record.intrinsics[4] > 0,
                  abs(record.intrinsics[2]) < 0.000001, abs(record.intrinsics[5]) < 0.000001,
                  abs(record.intrinsics[8] - 1) < 0.000001,
                  let transform = record.transformMatrix,
                  abs(simd_determinant(transform)) > 0.000001,
                  abs(transform.columns.0.w) < 0.000001,
                  abs(transform.columns.1.w) < 0.000001,
                  abs(transform.columns.2.w) < 0.000001,
                  abs(transform.columns.3.w - 1) < 0.000001 else {
                throw BakeError.invalidFrame("calibración o dimensiones incorrectas en \(record.id).")
            }
            self.record = record
            worldToCamera = simd_inverse(transform)
            intrinsics = simd_float3x3(columns: (
                SIMD3(record.intrinsics[0], record.intrinsics[1], record.intrinsics[2]),
                SIMD3(record.intrinsics[3], record.intrinsics[4], record.intrinsics[5]),
                SIMD3(record.intrinsics[6], record.intrinsics[7], record.intrinsics[8])))
            center = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            width = Float(record.imageWidth)
            height = Float(record.imageHeight)
            if let datasetDirectory {
                let url = try localFile(record.rgbFile, in: datasetDirectory)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let imageWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let imageHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      imageWidth.intValue == record.imageWidth, imageHeight.intValue == record.imageHeight,
                      (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1 else {
                    throw BakeError.invalidFrame("la imagen \(record.rgbFile) no coincide con el raster nativo calibrado.")
                }
                imageURL = url
                imageType = CGImageSourceGetType(source) as String?
                if let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let name = image.colorSpace?.name {
                    // Display P3 and sRGB share the transfer curve. Applying one
                    // scalar in the original primaries preserves native gamut.
                    supportsExposureDerivative = (1...8).contains(image.bitsPerComponent)
                        && (name == CGColorSpace.sRGB || name == CGColorSpace.displayP3)
                }
            }
        }

        func project(_ point: SIMD3<Float>) -> Projection? {
            let q = worldToCamera * SIMD4(point.x, point.y, point.z, 1)
            let z = -q.z
            guard z.isFinite, z > 0.001 else { return nil }
            // ARKit camera +Y is up, looks along -Z; camera image +Y is down, pinhole +Z forward.
            let homogeneous = intrinsics * SIMD3(q.x, -q.y, z)
            let pixel = SIMD2(homogeneous.x / homogeneous.z, homogeneous.y / homogeneous.z)
            guard pixel.x.isFinite, pixel.y.isFinite else { return nil }
            // Intrinsics use the center of the top-left pixel as (0,0).
            let uv = SIMD2((pixel.x + 0.5) / width, 1 - (pixel.y + 0.5) / height)
            return Projection(pixel: pixel, uv: uv, cameraDepth: z)
        }

        func contains(_ pixel: SIMD2<Float>) -> Bool {
            pixel.x >= 0 && pixel.y >= 0 && pixel.x <= width - 1 && pixel.y <= height - 1
        }
    }

    private struct DepthRaster {
        var values: [Float]
        var confidence: Data?
        var width: Int
        var height: Int

        init?(_ frame: RGBDFrameRecord, datasetDirectory: URL) throws {
            guard let name = frame.depthFile else { return nil }
            guard let width = frame.depthWidth, let height = frame.depthHeight, width > 0, height > 0 else {
                throw BakeError.invalidFrame("dimensiones de profundidad incorrectas en \(frame.id).")
            }
            let (count, overflow) = width.multipliedReportingOverflow(by: height)
            let (byteCount, byteOverflow) = count.multipliedReportingOverflow(by: 4)
            guard !overflow, !byteOverflow else { throw BakeError.invalidFrame("dimensiones de profundidad desbordadas.") }
            let data = try Data(contentsOf: localFile(name, in: datasetDirectory), options: .mappedIfSafe)
            guard data.count == byteCount else { throw BakeError.invalidFrame("longitud del mapa de profundidad de \(frame.id).") }
            self.width = width
            self.height = height
            values = data.withUnsafeBytes { buffer in
                (0..<count).map { Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
            if let name = frame.confidenceFile {
                let confidence = try Data(contentsOf: localFile(name, in: datasetDirectory), options: .mappedIfSafe)
                guard confidence.count == count else { throw BakeError.invalidFrame("longitud del mapa de confianza de \(frame.id).") }
                self.confidence = confidence
            }
        }

        func relativeResidual(for projection: Projection, imageWidth: Float, imageHeight: Float) -> Float? {
            let x = Int(((projection.pixel.x + 0.5) * Float(width) / imageWidth - 0.5).rounded())
            let y = Int(((projection.pixel.y + 0.5) * Float(height) / imageHeight - 0.5).rounded())
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let index = y * width + x
            if let confidence, !(1...2).contains(Int(confidence[index])) { return nil }
            let measured = values[index]
            guard measured.isFinite, measured > 0 else { return nil }
            // A reconstruction consistency threshold, not an advertised accuracy specification.
            let tolerance = max(0.03, measured * 0.025)
            let residual = abs(projection.cameraDepth - measured)
            guard residual <= tolerance else { return nil }
            return residual / tolerance
        }
    }

    private static func localFile(_ path: String, in root: URL) throws -> URL {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.isEmpty, !path.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else {
            throw BakeError.invalidFrame("una ruta de archivo sale del directorio de captura.")
        }
        return url
    }

    private static func preserveImage(_ camera: FrameCamera, frameIndex: Int, directory: URL) throws -> String {
        guard let imageURL = camera.imageURL else { throw BakeError.imageEncoding }
        let stem = String(format: "camera_%06d", frameIndex)
        if camera.imageType == UTType.jpeg.identifier || camera.imageType == UTType.png.identifier {
            let name = stem + (camera.imageType == UTType.jpeg.identifier ? ".jpg" : ".png")
            try FileManager.default.copyItem(at: imageURL, to: directory.appendingPathComponent(name))
            return name
        }
        // Other ImageIO formats become portable lossless PNG at exactly the
        // original dimensions. The captured source remains untouched in RGB-D.
        let name = stem + ".png"
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == camera.record.imageWidth, image.height == camera.record.imageHeight,
              let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BakeError.imageEncoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BakeError.imageEncoding }
        return name
    }

    private static func writeMaterials(_ textures: [Int: String], to url: URL) throws {
        let writer = try BufferedTextWriter(url)
        try writer.append("# Forma: real multiview photographs, unobserved surfaces remain neutral.\nnewmtl unobserved\nKa 0.1 0.1 0.1\nKd 0.55 0.55 0.55\nKs 0 0 0\nd 1\nillum 1\n\n")
        for frameIndex in textures.keys.sorted() {
            try writer.append("newmtl camera_\(frameIndex)\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd textures/\(textures[frameIndex]!)\n\n")
        }
        try writer.finish()
    }

    private static func writeOBJ(mesh: MeshSnapshot, faces: [FaceGeometry], assignments: [Int], uvs: [FaceUV], to url: URL) throws {
        let writer = try BufferedTextWriter(url)
        try writer.append("# Forma LiDAR mesh in meters. Original vertices and triangle order are preserved.\nmtllib modelo.mtl\no Forma\n")
        for (index, vertex) in mesh.vertices.enumerated() {
            if index & 1023 == 0 { try ProcessingControl.checkpoint() }
            try writer.append("v \(vertex.x) \(vertex.y) \(vertex.z)\n")
        }
        for index in faces.indices where assignments[index] >= 0 {
            let uv = uvs[index]
            for value in [uv.a, uv.b, uv.c] { try writer.append("vt \(value.x) \(value.y)\n") }
        }
        for face in faces {
            let normal = simd_length_squared(face.normal) > 0 ? face.normal : SIMD3<Float>(0, 1, 0)
            try writer.append("vn \(normal.x) \(normal.y) \(normal.z)\n")
        }
        var previousMaterial = Int.min
        var uvIndex = 1
        for index in faces.indices {
            if index & 1023 == 0 { try ProcessingControl.checkpoint() }
            let assignment = assignments[index]
            if assignment != previousMaterial {
                try writer.append("usemtl \(assignment < 0 ? "unobserved" : "camera_\(assignment)")\n")
                previousMaterial = assignment
            }
            let a = Int(mesh.triangles[index * 3]) + 1
            let b = Int(mesh.triangles[index * 3 + 1]) + 1
            let c = Int(mesh.triangles[index * 3 + 2]) + 1
            let normal = index + 1
            if assignment >= 0 {
                try writer.append("f \(a)/\(uvIndex)/\(normal) \(b)/\(uvIndex + 1)/\(normal) \(c)/\(uvIndex + 2)/\(normal)\n")
                uvIndex += 3
            } else {
                try writer.append("f \(a)//\(normal) \(b)//\(normal) \(c)//\(normal)\n")
            }
        }
        try writer.finish()
    }

    private final class BufferedTextWriter {
        private let handle: FileHandle
        private var buffer = Data()
        init(_ url: URL) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: url)
        }
        deinit { try? handle.close() }
        func append(_ text: String) throws {
            buffer.append(contentsOf: text.utf8)
            if buffer.count >= 65536 { try flush() }
        }
        private func flush() throws {
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        func finish() throws { try flush(); try handle.close() }
    }

    /// A median-split BVH of the actual mesh; visibility is two-sided even though view selection is front-facing.
    private struct MeshVisibility {
        private struct Node {
            var lower: SIMD3<Float>
            var upper: SIMD3<Float>
            var left = -1
            var right = -1
            var start = 0
            var count = 0
        }
        private let vertices: [SIMD3<Float>]
        private let triangles: [UInt32]
        private let faces: [FaceGeometry]
        private var order: [Int]
        private var nodes: [Node] = []

        init(mesh: MeshSnapshot, faces: [FaceGeometry]) throws {
            vertices = mesh.vertices
            triangles = mesh.triangles
            self.faces = faces
            order = Array(faces.indices)
            _ = try build(start: 0, end: faces.count)
        }

        private mutating func build(start: Int, end: Int) throws -> Int {
            try ProcessingControl.checkpoint()
            var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
            var centerLower = lower, centerUpper = upper
            for position in start..<end {
                let face = order[position]
                centerLower = simd_min(centerLower, faces[face].center)
                centerUpper = simd_max(centerUpper, faces[face].center)
                for corner in 0..<3 {
                    let v = vertices[Int(triangles[face * 3 + corner])]
                    lower = simd_min(lower, v)
                    upper = simd_max(upper, v)
                }
            }
            let index = nodes.count
            nodes.append(Node(lower: lower, upper: upper, start: start, count: end - start))
            if end - start <= 8 { return index }
            let extent = centerUpper - centerLower
            let axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
            let middle = (start + end) / 2
            partition(start: start, end: end, middle: middle, axis: axis)
            let left = try build(start: start, end: middle)
            let right = try build(start: middle, end: end)
            nodes[index].left = left
            nodes[index].right = right
            nodes[index].count = 0
            return index
        }

        private func precedes(_ left: Int, _ right: Int, axis: Int) -> Bool {
            let a = faces[left].center[axis], b = faces[right].center[axis]
            return a == b ? left < right : a < b
        }

        private mutating func partition(start: Int, end: Int, middle: Int, axis: Int) {
            var left = start, right = end - 1
            while left < right {
                let pivot = order[(left + right) / 2]
                var i = left, j = right
                while i <= j {
                    while i <= right && precedes(order[i], pivot, axis: axis) { i += 1 }
                    while j >= left && precedes(pivot, order[j], axis: axis) { j -= 1 }
                    if i <= j { order.swapAt(i, j); i += 1; j -= 1 }
                }
                if middle <= j { right = j }
                else if middle >= i { left = i }
                else { return }
            }
        }

        func isOccluded(from origin: SIMD3<Float>, to point: SIMD3<Float>, excludingFace: Int) -> Bool {
            let offset = point - origin
            let distance = simd_length(offset)
            guard distance.isFinite, distance > 0.001 else { return true }
            // Only excludes the endpoint neighborhood, not a second reconstructed surface in front of it.
            let endpointTolerance = max(0.0001, distance * 0.001)
            return intersects(nodeIndex: 0, origin: origin, direction: offset / distance,
                              maximumDistance: distance - endpointTolerance, excludingFace: excludingFace)
        }

        private func intersects(nodeIndex: Int, origin: SIMD3<Float>, direction: SIMD3<Float>, maximumDistance: Float, excludingFace: Int) -> Bool {
            let node = nodes[nodeIndex]
            var near: Float = 0.0001, far = maximumDistance
            for axis in 0..<3 {
                if abs(direction[axis]) < 0.0000001 {
                    if origin[axis] < node.lower[axis] || origin[axis] > node.upper[axis] { return false }
                } else {
                    let a = (node.lower[axis] - origin[axis]) / direction[axis]
                    let b = (node.upper[axis] - origin[axis]) / direction[axis]
                    near = max(near, min(a, b))
                    far = min(far, max(a, b))
                    if far < near { return false }
                }
            }
            if node.count > 0 {
                for position in node.start..<(node.start + node.count) {
                    let face = order[position]
                    if face == excludingFace { continue }
                    let a = vertices[Int(triangles[face * 3])]
                    let b = vertices[Int(triangles[face * 3 + 1])]
                    let c = vertices[Int(triangles[face * 3 + 2])]
                    if rayTriangle(origin: origin, direction: direction, a: a, b: b, c: c, maximumDistance: maximumDistance) { return true }
                }
                return false
            }
            return intersects(nodeIndex: node.left, origin: origin, direction: direction, maximumDistance: maximumDistance, excludingFace: excludingFace)
                || intersects(nodeIndex: node.right, origin: origin, direction: direction, maximumDistance: maximumDistance, excludingFace: excludingFace)
        }

        private func rayTriangle(origin: SIMD3<Float>, direction: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, maximumDistance: Float) -> Bool {
            let edge1 = b - a, edge2 = c - a
            let p = simd_cross(direction, edge2)
            let determinant = simd_dot(edge1, p)
            guard abs(determinant) > 0.00000001 else { return false }
            let inverse = 1 / determinant
            let offset = origin - a
            let u = simd_dot(offset, p) * inverse
            guard u >= -0.00001, u <= 1.00001 else { return false }
            let q = simd_cross(offset, edge1)
            let v = simd_dot(direction, q) * inverse
            guard v >= -0.00001, u + v <= 1.00001 else { return false }
            let distance = simd_dot(edge2, q) * inverse
            return distance > 0.0001 && distance < maximumDistance
        }
    }
}
