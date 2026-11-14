import XCTest
import UIKit
import Metal
import simd
import FormaGaussianCore
@testable import Forma

/// Authored synthetic integration fixture. This validates actual Metal optimization,
/// dense tile sorting, exports and checkpoint safety; it measures no real-world quality.
final class GaussianEngineTests: XCTestCase {
    @MainActor
    func testSyntheticDenseMetalTrainingExportAndCheckpointResume() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Este test del entrenador se valida en iPhone físico; Metal del simulador no valida estos kernels.")
        #else
        setenv("MSPLAT_MEM_LOG_EVERY", "5", 1)
        guard #available(iOS 18, *) else { throw XCTSkip("El motor requiere iOS 18 o posterior.") }
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "El iPhone de prueba debe proporcionar una GPU Metal")
        let metallib = try XCTUnwrap(Bundle.main.url(forResource: "msplat-ios", withExtension: "metallib"), "Falta el metallib de dispositivo en los recursos de Forma")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-GaussianTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dataset = folder.appendingPathComponent("dataset", isDirectory: true)
        try makeSyntheticDataset(at: dataset)
        let output = folder.appendingPathComponent("output", isDirectory: true)
        var error = [CChar](repeating: 0, count: 2048)
        let unrelatedLibrary = try XCTUnwrap(Bundle.main.url(forResource: "default", withExtension: "metallib"))
        let incompatible = dataset.path.withCString { path in
            unrelatedLibrary.path.withCString { library in forma_gaussian_create(path, library, 5, 1, &error, error.count) }
        }
        XCTAssertNil(incompatible, "A renderer's Metal library cannot be used by the native training engine")
        if let incompatible { forma_gaussian_destroy(incompatible) }
        XCTAssertTrue(String(cString: error).contains("ABI"), "Incompatible shaders must fail before touching training buffers: \(String(cString: error))")
        var handle = dataset.path.withCString { path in
            metallib.path.withCString { library in
                forma_gaussian_create(path, library, 5, 1, &error, error.count)
            }
        }
        defer { if let handle { forma_gaussian_destroy(handle) } }
        let trainer = try XCTUnwrap(handle, String(cString: error))
        let concurrent = dataset.path.withCString { path in
            metallib.path.withCString { library in forma_gaussian_create(path, library, 5, 1, &error, error.count) }
        }
        XCTAssertNil(concurrent, "The engine has one global Metal context; a second live trainer must fail without touching it")
        var stats = FormaGaussianStats(iteration: 0, splats: 0, milliseconds: 0)
        for _ in 0..<5 {
            XCTAssertTrue(forma_gaussian_step(trainer, &stats, &error, error.count), String(cString: error))
        }
        XCTAssertEqual(stats.iteration, 5)
        XCTAssertEqual(stats.splats, 2200, "Five steps precede densification; no initial Gaussian may be dropped")
        var intersections: Int64 = 0, densestTile: Int64 = 0
        forma_gaussian_sort_diagnostics(&intersections, &densestTile)
        XCTAssertGreaterThan(densestTile, 2048, "Fixture must exercise the exact path beyond upstream's tile limit")
        XCTAssertGreaterThanOrEqual(intersections, densestTile)
        XCTAssertTrue(output.path.withCString { forma_gaussian_export(trainer, $0, &error, error.count) }, String(cString: error))
        let splat = try Data(contentsOf: output.appendingPathComponent("gaussianas.splat"))
        XCTAssertEqual(splat.count, 2200 * 32)
        let ply = try Data(contentsOf: output.appendingPathComponent("gaussianas.ply"))
        try assertFiniteOptimizedPLY(ply)
        let previewAsset = try GaussianAsset.load(url: output.appendingPathComponent("gaussianas.ply"))
        XCTAssertEqual(previewAsset.points.count, 2200)
        XCTAssertEqual(previewAsset.harmonicDegree, 3)
        XCTAssertEqual(previewAsset.harmonics.count, 2200 * 16,
                       "The native viewer must retain every SH3 band exported by the trainer")
        let splatAsset = try GaussianAsset.load(url: output.appendingPathComponent("gaussianas.splat"))
        // .splat sorts records by size/opacity, so match original coordinates
        // instead of assuming its vertex order is the same as binary PLY.
        let plyByPosition = Dictionary(uniqueKeysWithValues: previewAsset.points.map {
            (SIMD3($0.positionOpacity.x,$0.positionOpacity.y,$0.positionOpacity.z),$0.rotation)
        })
        for gaussian in splatAsset.points {
            let position = SIMD3(gaussian.positionOpacity.x,gaussian.positionOpacity.y,gaussian.positionOpacity.z)
            let expectedRotation = try XCTUnwrap(plyByPosition[position], "SPLAT and PLY must retain identical authored positions")
            XCTAssertGreaterThan(abs(simd_dot(expectedRotation,gaussian.rotation)),0.9995,
                                 "Quantized SPLAT must preserve normalized PLY orientation; raw optimizer quaternions must not be clamped")
        }
        forma_gaussian_destroy(trainer)
        handle = nil

        // A new trainer must recover full optimizer state and advance from 5 to 6.
        handle = dataset.path.withCString { path in
            metallib.path.withCString { library in forma_gaussian_create(path, library, 10, 1, &error, error.count) }
        }
        let resumedTrainer = try XCTUnwrap(handle, String(cString: error))
        var resumedStep: Int32 = 0
        let checkpoint = output.appendingPathComponent("entrenamiento.ckpt")
        XCTAssertTrue(checkpoint.path.withCString { forma_gaussian_resume(resumedTrainer, $0, &resumedStep, &error, error.count) }, String(cString: error))
        XCTAssertEqual(resumedStep, 5)
        XCTAssertTrue(forma_gaussian_step(resumedTrainer, &stats, &error, error.count), String(cString: error))
        XCTAssertEqual(stats.iteration, 6)
        let malformed = folder.appendingPathComponent("malformed.ckpt")
        try Data("MSPL".utf8).write(to: malformed)
        XCTAssertFalse(malformed.path.withCString { forma_gaussian_resume(resumedTrainer, $0, &resumedStep, &error, error.count) }, "Truncated checkpoint must return an error rather than reach unsafe memory copies")
        XCTAssertFalse(String(cString: error).isEmpty)
        #endif
    }

    @MainActor
    private func makeSyntheticDataset(at folder: URL) throws {
        let images = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try "1 PINHOLE 32 32 28 28 16 16\n".write(to: folder.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        var records = ""
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        for index in 1...3 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { renderer in
                for y in 0..<32 {
                    for x in 0..<32 {
                        renderer.cgContext.setFillColor(UIColor(red: CGFloat((x * 8 + index * 5) % 256) / 255,
                                                               green: CGFloat(y * 8) / 255, blue: 128.0 / 255, alpha: 1).cgColor)
                        renderer.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            let name = "frame-\(index).png"
            try XCTUnwrap(image.pngData()).write(to: images.appendingPathComponent(name))
            let offset = Float(index - 2) * 0.08
            records += "\(index) 1 0 0 0 \(offset) 0 2 1 \(name)\n\n"
        }
        try records.write(to: folder.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        var seed: UInt64 = 42
        func coordinate() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53) * 0.2 - 0.1
        }
        var points = ""
        for index in 1...2200 {
            points += "\(index) \(coordinate()) \(coordinate()) \(coordinate()) 128 128 128 0\n"
        }
        try points.write(to: folder.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
    }

    private func assertFiniteOptimizedPLY(_ data: Data) throws {
        let marker = Data("end_header\n".utf8)
        let range = try XCTUnwrap(data.range(of: marker))
        let header = try XCTUnwrap(String(data: data[..<range.upperBound], encoding: .utf8))
        XCTAssertTrue(header.contains("element vertex 2200\n"))
        let properties = header.components(separatedBy: "\n").filter { $0.hasPrefix("property float ") }.map { String($0.dropFirst("property float ".count)) }
        XCTAssertEqual(properties.count, 62, "SH3 PLY must retain all 45 non-DC SH coefficients")
        let dcIndex = try XCTUnwrap(properties.firstIndex(of: "f_dc_0"))
        let payload = data[range.upperBound...]
        XCTAssertEqual(payload.count, 2200 * properties.count * 4)
        let initialDC = Float((128.0 / 255.0 - 0.5) / 0.28209479177387814)
        var changedDC = 0
        for index in 0..<(2200 * properties.count) {
            let bytes = payload.startIndex + index * 4
            let low = UInt32(payload[bytes]) | (UInt32(payload[bytes + 1]) << 8)
            let high = (UInt32(payload[bytes + 2]) << 16) | (UInt32(payload[bytes + 3]) << 24)
            let bits = low | high
            let value = Float(bitPattern: bits)
            XCTAssertTrue(value.isFinite, "Trained Gaussian parameters must remain finite")
            if index % properties.count == dcIndex, abs(value - initialDC) > 0.000001 { changedDC += 1 }
        }
        XCTAssertGreaterThan(changedDC, 0, "Optimization must actually change the initialized colors; exporting seed points is insufficient")
    }
}
