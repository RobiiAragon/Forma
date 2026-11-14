import Foundation
import simd
import Darwin
import os

/// Runtime allocation checks, not a limit on model size. Existing allocations are
/// already reflected in each fresh OS snapshot; callers pass the additional peak.
enum GaussianMemoryGuard {
    static func bytes(_ count: Int, stride: Int) throws -> Int {
        let result = count.multipliedReportingOverflow(by: stride)
        guard count >= 0, stride >= 0, !result.overflow else { throw invalidSize() }
        return result.partialValue
    }

    static func sum(_ values: Int...) throws -> Int {
        var result = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard value >= 0, !next.overflow else { throw invalidSize() }
            result = next.partialValue
        }
        return result
    }

    static func require(_ additionalBytes: Int, phase: String) throws {
        guard additionalBytes >= 0 else { throw invalidSize() }
        if additionalBytes == 0 { return }
        let available = try availableBytes()
        guard UInt64(additionalBytes) <= available else {
            let required = ByteCountFormatter.string(fromByteCount: Int64(additionalBytes), countStyle: .memory)
            let current = ByteCountFormatter.string(fromByteCount: Int64(min(available, UInt64(Int64.max))), countStyle: .memory)
            throw RGBDDatasetError.invalid("No hay memoria disponible para \(phase): se necesitan aproximadamente \(required) adicionales y el sistema informa \(current) disponibles. Cierra otras vistas o libera memoria y vuelve a abrir. Los archivos completos siguen disponibles para exportar; no se ha reducido el modelo.")
        }
    }

    private static func availableBytes() throws -> UInt64 {
        #if os(iOS) && !targetEnvironment(simulator)
        return UInt64(max(0, os_proc_available_memory()))
        #else
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let pageResult = host_page_size(host, &pageSize)
        let statsResult = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard pageResult == KERN_SUCCESS, statsResult == KERN_SUCCESS, pageSize > 0 else {
            throw RGBDDatasetError.invalid("El sistema no pudo consultar la memoria disponible del visor. Vuelve a abrirlo; los archivos siguen disponibles para exportar.")
        }
        let pages = try sum(Int(statistics.free_count), Int(statistics.inactive_count))
        return UInt64(try bytes(pages, stride: Int(pageSize)))
        #endif
    }

    private static func invalidSize() -> RGBDDatasetError {
        .invalid("El tamaño del modelo excede el espacio de direcciones de este dispositivo. Los archivos completos siguen disponibles para exportar.")
    }
}

/// One CPU parse/sort at a time avoids overlapping temporary peaks when a viewer
/// is closed and immediately reopened. Cancellation is checked inside long loops.
enum GaussianWorkQueue {
    static let queue = DispatchQueue(label: "com.forma.gaussian-viewer", qos: .userInitiated)
}

final class GaussianWorkControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Anisotropic Gaussian parameters shared by .splat and trained SH0–SH3 PLY.
/// Higher spherical-harmonic bands live in GaussianAsset.harmonics for the Metal viewer.
struct GaussianPoint: Sendable {
    var positionOpacity: SIMD4<Float>
    var scale: SIMD4<Float>
    var rotation: SIMD4<Float> // x,y,z,w
    var color: SIMD4<Float>
}

struct GaussianAsset: Sendable {
    var points: [GaussianPoint]
    var center: SIMD3<Float>
    var radius: Float
    var harmonics: [SIMD4<Float>] = []
    var harmonicDegree: Int = -1

    static func load(url: URL, checkCancellation: () throws -> Void = {}) throws -> Self {
        try checkCancellation()
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            try GaussianMemoryGuard.require(fileSize, phase: "leer el archivo Gaussian")
        }
        if url.pathExtension.lowercased() == "ply" { return try loadPLY(url: url, checkCancellation: checkCancellation) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count.isMultiple(of: 32) else {
            throw RGBDDatasetError.invalid("El archivo .splat está vacío o incompleto.")
        }
        try checkCancellation()
        let pointBytes = try GaussianMemoryGuard.bytes(data.count / 32, stride: MemoryLayout<GaussianPoint>.stride)
        // Mapped input pages may still fault in while decoded storage is filled.
        try GaussianMemoryGuard.require(try GaussianMemoryGuard.sum(pointBytes, data.count), phase: "decodificar el modelo Gaussian")
        var points: [GaussianPoint] = []
        points.reserveCapacity(data.count / 32)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        try data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 32) {
                if offset.isMultiple(of: 8192) { try checkCancellation() }
                func f(_ byte: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + byte, as: UInt32.self)))
                }
                let p = SIMD3(f(0), f(4), f(8)), s = SIMD3(f(12), f(16), f(20))
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
                      s.x.isFinite, s.y.isFinite, s.z.isFinite, s.x > 0, s.y > 0, s.z > 0 else {
                    throw RGBDDatasetError.invalid("El archivo Gaussian contiene coordenadas o escalas no válidas.")
                }
                var q = SIMD4<Float>(Float(raw[offset+29])/128-1, Float(raw[offset+30])/128-1,
                                     Float(raw[offset+31])/128-1, Float(raw[offset+28])/128-1)
                guard simd_length_squared(q) > 0.00001 else { throw RGBDDatasetError.invalid("Rotación Gaussian no válida.") }
                q = simd_normalize(q)
                let color = SIMD4<Float>(Float(raw[offset+24])/255, Float(raw[offset+25])/255, Float(raw[offset+26])/255, 1)
                points.append(.init(positionOpacity: SIMD4(p, Float(raw[offset+27])/255), scale: SIMD4(s, 0), rotation: q, color: color))
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        let bounds = try validatedBounds(lo: lo, hi: hi)
        return Self(points: points, center: bounds.center, radius: bounds.radius)
    }

    /// Standard trained 3DGS binary PLY. Every SH coefficient is retained through degree 3.
    private static func loadPLY(url: URL, checkCancellation: () throws -> Void) throws -> Self {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let end = data.range(of: Data("end_header\n".utf8)) ?? data.range(of: Data("end_header\r\n".utf8)) else {
            throw RGBDDatasetError.invalid("El archivo PLY no contiene una cabecera completa.")
        }
        try checkCancellation()
        try GaussianMemoryGuard.require(try GaussianMemoryGuard.bytes(end.lowerBound, stride: 4), phase: "leer la cabecera PLY")
        guard let header = String(data: data[..<end.lowerBound], encoding: .utf8),
              header.hasPrefix("ply"), header.contains("format binary_little_endian 1.0") else {
            throw RGBDDatasetError.invalid("El visor necesita un PLY Gaussian binario little-endian válido.")
        }
        var count = 0, names: [String] = [], inVertices = false
        for line in header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            try checkCancellation()
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.first == "element" {
                inVertices = tokens.count == 3 && tokens[1] == "vertex"
                if inVertices { count = Int(tokens[2]) ?? 0 }
            } else if inVertices, tokens.first == "property" {
                guard tokens.count == 3, ["float", "float32"].contains(String(tokens[1])) else {
                    throw RGBDDatasetError.invalid("El PLY Gaussian contiene un tipo de propiedad no compatible.")
                }
                names.append(String(tokens[2]))
            }
        }
        let required = ["x","y","z","f_dc_0","f_dc_1","f_dc_2","opacity","scale_0","scale_1","scale_2","rot_0","rot_1","rot_2","rot_3"]
        guard Set(names).count == names.count else { throw RGBDDatasetError.invalid("El PLY repite nombres de propiedades.") }
        let offsets = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element,$0.offset) })
        let rowBytes = try GaussianMemoryGuard.bytes(names.count, stride: 4)
        guard count > 0, !names.isEmpty, required.allSatisfy({ offsets[$0] != nil }),
              count <= Int.max/rowBytes, data.count-end.upperBound >= count*rowBytes else {
            throw RGBDDatasetError.invalid("El PLY Gaussian está incompleto o no incluye escalas, opacidad y rotaciones.")
        }
        let restCount = names.filter { $0.hasPrefix("f_rest_") }.count
        guard restCount.isMultiple(of: 3), [0,3,8,15].contains(restCount/3),
              (0..<restCount).allSatisfy({ offsets["f_rest_\($0)"] != nil }) else {
            throw RGBDDatasetError.invalid("Los armónicos del PLY Gaussian no tienen un formato SH0–SH3 válido.")
        }
        let bases = restCount/3
        let degree = bases == 15 ? 3 : bases == 8 ? 2 : bases == 3 ? 1 : 0
        let harmonicCount = try GaussianMemoryGuard.bytes(count, stride: 16)
        let decodedBytes = try GaussianMemoryGuard.sum(GaussianMemoryGuard.bytes(count, stride: MemoryLayout<GaussianPoint>.stride), GaussianMemoryGuard.bytes(harmonicCount, stride: MemoryLayout<SIMD4<Float>>.stride))
        try GaussianMemoryGuard.require(try GaussianMemoryGuard.sum(decodedBytes, data.count), phase: "decodificar los parámetros y armónicos Gaussian")
        var points: [GaussianPoint] = [], harmonics: [SIMD4<Float>] = []
        points.reserveCapacity(count); harmonics.reserveCapacity(harmonicCount)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        try data.withUnsafeBytes { raw in
            for i in 0..<count {
                if i.isMultiple(of: 256) { try checkCancellation() }
                let row = end.upperBound + i*rowBytes
                func field(_ name: String) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: row+offsets[name]!*4, as: UInt32.self)))
                }
                let p = SIMD3(field("x"),field("y"),field("z"))
                let scale = SIMD3(exp(field("scale_0")),exp(field("scale_1")),exp(field("scale_2")))
                var q = SIMD4(field("rot_1"),field("rot_2"),field("rot_3"),field("rot_0"))
                let opacity = 1/(1+exp(-field("opacity")))
                let dc = SIMD4(field("f_dc_0"),field("f_dc_1"),field("f_dc_2"),Float(0))
                guard [p.x,p.y,p.z,scale.x,scale.y,scale.z,q.x,q.y,q.z,q.w,opacity,dc.x,dc.y,dc.z].allSatisfy(\.isFinite),
                      scale.x > 0, scale.y > 0, scale.z > 0, simd_length_squared(q) > 0.00001 else {
                    throw RGBDDatasetError.invalid("El PLY Gaussian contiene parámetros no válidos.")
                }
                // Scaling first avoids overflow in the norm of finite large values.
                q /= max(max(abs(q.x),abs(q.y)),max(abs(q.z),abs(q.w)))
                q = simd_normalize(q)
                let color = simd_clamp(dc * 0.2820948 + SIMD4<Float>(repeating: 0.5), .zero, SIMD4<Float>(repeating: 1))
                points.append(.init(positionOpacity: SIMD4(p,opacity),scale: SIMD4(scale,0),rotation: q,color: color))
                harmonics.append(dc)
                for b in 0..<15 {
                    let coefficient: SIMD4<Float>
                    if b < bases {
                        coefficient = SIMD4(field("f_rest_\(b)"),field("f_rest_\(bases+b)"),field("f_rest_\(2*bases+b)"),0)
                        guard coefficient.x.isFinite, coefficient.y.isFinite, coefficient.z.isFinite else {
                            throw RGBDDatasetError.invalid("El PLY contiene armónicos no finitos.")
                        }
                    } else { coefficient = .zero }
                    harmonics.append(coefficient)
                }
                lo = simd_min(lo,p); hi = simd_max(hi,p)
            }
        }
        let bounds = try validatedBounds(lo: lo, hi: hi)
        return Self(points: points, center: bounds.center, radius: bounds.radius, harmonics: harmonics, harmonicDegree: degree)
    }

    private static func validatedBounds(lo: SIMD3<Float>, hi: SIMD3<Float>) throws -> (center: SIMD3<Float>, radius: Float) {
        let center = lo * 0.5 + hi * 0.5
        let extent = SIMD3<Double>(Double(hi.x)-Double(lo.x), Double(hi.y)-Double(lo.y), Double(hi.z)-Double(lo.z))
        let radius = Float(max(simd_length(extent)*0.5,0.01))
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite, radius.isFinite,
              (radius*100).isFinite else {
            throw RGBDDatasetError.invalid("La extensión del modelo excede la precisión numérica del visor. Los archivos siguen disponibles para exportar.")
        }
        return (center,radius)
    }
}
