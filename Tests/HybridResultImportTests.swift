import XCTest
import Network
@testable import Forma

/// Loopback TCP and a private ScanStore only: no camera, GPU, installed app or user scan.
final class HybridResultImportTests: XCTestCase {
    private let mesh = MeshSnapshot(vertices: [.init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0)], triangles: [0, 1, 2])

    @MainActor private struct Fixture {
        let root: URL
        let store: ScanStore
        let original: ScanRecord
        let published: HybridTransfer.ResultSource
        let originalHashes: [String: String]
        let publishedHashes: [String: String]
        var metadata: URL { root.appendingPathComponent("import-metadata") }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HybridResultImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func hashes(in directory: URL) throws -> [String: String] {
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: directory.path))
        var result: [String: String] = [:]
        while let name = files.nextObject() as? String {
            let file = directory.appendingPathComponent(name)
            if try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular {
                result[name] = try IntegrityManifest.digest(file)
            }
        }
        return result
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    /// One complete SH3 Gaussian, authored locally. Transport tests never invoke inference.
    private func gaussianPLY() -> Data {
        let names = ["x", "y", "z", "nx", "ny", "nz"] + (0..<3).map { "f_dc_\($0)" }
            + (0..<45).map { "f_rest_\($0)" } + ["opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        var data = Data(("ply\nformat binary_little_endian 1.0\nelement vertex 1\n" + names.map { "property float \($0)\n" }.joined() + "end_header\n").utf8)
        let values: [Float] = [0, 0, -1, 0, 0, 0, 0.2, 0.1, 0] + Array(repeating: 0, count: 45)
            + [0, -4.6, -4.6, -4.6, 1, 0, 0, 0]
        for value in values { append(value.bitPattern, to: &data) }
        return data
    }

    /// Checkpoint-v1 header, six parameter tensors and twelve finite zero Adam tensors.
    private func gaussianCheckpoint() -> Data {
        var data = Data()
        for value: UInt32 in [1_280_332_621, 1, 7, 1, 3, 7] { append(value, to: &data) }
        let rates: [Float] = [0.00016, 0.005, 0.001, 0.0025, 0.000125, 0.05, 0.00016, 0.0000016]
        for value in rates { append(value.bitPattern, to: &data) }
        let shapes: [[Int64]] = [[1, 3], [1, 3], [1, 4], [1, 3], [1, 15, 3], [1, 1]]
        let parameters: [[Float]] = [[0, 0, -1], [-4.6, -4.6, -4.6], [1, 0, 0, 0], [0.2, 0.1, 0], Array(repeating: 0, count: 45), [0]]
        for group in 0..<3 {
            for index in shapes.indices {
                let shape = shapes[index], count = shape.reduce(1, *)
                append(UInt32(shape.count), to: &data)
                for size in shape { append(size, to: &data) }
                append(UInt64(count * 4), to: &data)
                for value in group == 0 ? parameters[index] : Array(repeating: Float.zero, count: Int(count)) {
                    append(value.bitPattern, to: &data)
                }
            }
        }
        return data
    }

    @MainActor private func fixture(gaussian: Bool) async throws -> Fixture {
        let root = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let sourceDataset = root.appendingPathComponent("source-dataset")
        try FileManager.default.createDirectory(at: sourceDataset.appendingPathComponent("images"), withIntermediateDirectories: true)
        // A tiny authored PNG; there are no photographs from the user in this fixture.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: sourceDataset.appendingPathComponent("images/authored.png"))
        let frame = RGBDFrameRecord(id: "authored", timestamp: 1, rgbFile: "images/authored.png", imageWidth: 1, imageHeight: 1,
            cameraToWorld: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1], intrinsics: [1,0,0, 0,1,0, 0,0,1],
            depthFile: nil, confidenceFile: nil, depthWidth: nil, depthHeight: nil, source: "fixture", exposureDuration: nil, exposureOffset: nil)
        try RGBDDatasetManifest(createdAt: Date(timeIntervalSince1970: 100), frames: [frame]).write(to: sourceDataset)
        let store = ScanStore(baseURL: root.appendingPathComponent("library"))
        var originalResult = CaptureResult(mesh: mesh, mode: .lidar, duration: 1)
        originalResult.captureDatasetURL = sourceDataset
        let savedOriginal = await store.save(originalResult)
        let original = try XCTUnwrap(savedOriginal, store.error ?? "Original fixture did not commit")

        let published = root.appendingPathComponent("published"), package = published.appendingPathComponent("modelo")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let meshFile = published.appendingPathComponent("malla.json")
        try JSONEncoder().encode(mesh).write(to: meshFile)
        let name: String
        if gaussian {
            name = "gaussianas.ply"
            try gaussianPLY().write(to: package.appendingPathComponent(name))
            try gaussianCheckpoint().write(to: package.appendingPathComponent("entrenamiento.ckpt"))
        } else {
            name = "modelo.obj"
            try Data("mtllib material.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl photo\nf 1/1 2/2 3/3\n".utf8).write(to: package.appendingPathComponent(name))
            try Data("newmtl photo\nmap_Kd textura.png\n".utf8).write(to: package.appendingPathComponent("material.mtl"))
            try png.write(to: package.appendingPathComponent("textura.png"))
        }
        // This file is deliberately beside, rather than inside, the published derivative.
        try FileManager.default.createDirectory(at: published.appendingPathComponent("originales"), withIntermediateDirectories: false)
        try png.write(to: published.appendingPathComponent("originales/not-for-transfer.png"))
        let descriptor = HybridTransfer.ResultDescriptor(jobID: UUID(), resultID: UUID(), name: "Authored result", mode: "lidar", duration: 2,
            note: "Private loopback fixture", statistics: ["fixture": 1], modelRelativePath: "modelo/" + name,
            packageRelativePath: "modelo", meshRelativePath: "malla.json", gaussianModelRelativePath: gaussian ? name : nil)
        return Fixture(root: root, store: store, original: original,
            published: .init(descriptor: descriptor, directory: published),
            originalHashes: try hashes(in: store.directory(for: original)), publishedHashes: try hashes(in: published))
    }

    @MainActor private func download(_ fixture: Fixture, suffix: String = "download") async throws -> HybridTransfer.DownloadedResult {
        let receiver = HybridTransferReceiver(), value = fixture.published
        try receiver.start(directory: fixture.root.appendingPathComponent("incoming-" + UUID().uuidString), name: "Forma import fixture " + UUID().uuidString,
            onResult: { id in
                guard id == value.descriptor.jobID else { throw HybridTransfer.TransferError.failed("Unknown fixture job") }
                return value
            }) { _ in XCTFail("A result request must not create an incoming source job") }
        defer { receiver.stop() }
        var peer: HybridTransfer.Peer?
        let deadline = Date().addingTimeInterval(5)
        while peer == nil, Date() < deadline {
            if let raw = receiver.listeningPort, let port = NWEndpoint.Port(rawValue: raw) {
                peer = .init(id: "loopback", displayName: "Loopback fixture", endpoint: .hostPort(host: "127.0.0.1", port: port))
            } else { try await Task.sleep(for: .milliseconds(20)) }
        }
        let endpoint = try XCTUnwrap(peer, "Loopback listener did not become ready")
        return try await HybridTransfer.downloadResult(jobID: value.descriptor.jobID, to: endpoint, pairingCode: receiver.pairingCode,
            directory: fixture.root.appendingPathComponent(suffix))
    }

    @MainActor private func assertSourcesUnchanged(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try hashes(in: fixture.store.directory(for: fixture.original)), fixture.originalHashes, file: file, line: line)
        XCTAssertEqual(try hashes(in: fixture.published.directory), fixture.publishedHashes, file: file, line: line)
    }

    @MainActor
    func testRealTCPDownloadImportsCompleteTexturedGeometryAndInheritsOriginalDataset() async throws {
        let fixture = try await fixture(gaussian: false), bundle = try await download(fixture)
        XCTAssertEqual(bundle.descriptor, fixture.published.descriptor)
        try HybridTransfer.verifyDownloadedResult(bundle)
        let record = try await HybridResultImport(metadataDirectory: fixture.metadata).save(bundle, sourceScanID: fixture.original.id, library: fixture.store)
        XCTAssertEqual(fixture.store.scans.count, 2)
        XCTAssertEqual(record.sourceScanID, fixture.original.id)
        XCTAssertEqual(record.hybridResultProvenance?.manifestSHA256, bundle.manifestSHA256)
        XCTAssertNil(record.datasetDirectory)
        XCTAssertEqual(fixture.store.datasetURL(for: record), fixture.store.datasetURL(for: fixture.original))
        XCTAssertEqual(fixture.store.datasetSource(for: record)?.id, fixture.original.id)
        let savedMesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: fixture.store.directory(for: record).appendingPathComponent("malla.json")))
        XCTAssertEqual(savedMesh.vertices, mesh.vertices); XCTAssertEqual(savedMesh.triangles, mesh.triangles)
        for name in ["modelo.obj", "material.mtl", "textura.png"] {
            XCTAssertEqual(try Data(contentsOf: fixture.store.directory(for: record).appendingPathComponent("modelo/" + name)),
                           try Data(contentsOf: fixture.published.directory.appendingPathComponent("modelo/" + name)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.directory(for: record).appendingPathComponent("fuentes").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.directory.appendingPathComponent("originales").path))
        XCTAssertFalse(try hashes(in: fixture.store.directory(for: record)).keys.contains { $0.hasSuffix("authored.png") })
        try assertSourcesUnchanged(fixture)
    }

    @MainActor
    func testMeshOnlyDescriptorProducesUsableModelAndDeduplicatesAfterReload() async throws {
        let fixture = try await fixture(gaussian: false)
        var source = fixture.published
        source.descriptor.modelRelativePath = nil
        source.descriptor.packageRelativePath = nil
        let receiver = HybridTransferReceiver(), publishedSource = source
        try receiver.start(directory: fixture.root.appendingPathComponent("mesh-only-incoming"), name: "Forma mesh-only fixture " + UUID().uuidString,
            onResult: { _ in publishedSource }) { _ in XCTFail("A mesh result must not publish a source job") }
        defer { receiver.stop() }
        let deadline = Date().addingTimeInterval(5)
        while receiver.listeningPort == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let raw = try XCTUnwrap(receiver.listeningPort), port = try XCTUnwrap(NWEndpoint.Port(rawValue: raw))
        let peer = HybridTransfer.Peer(id: "mesh-only-loopback", displayName: "Mesh-only loopback", endpoint: .hostPort(host: "127.0.0.1", port: port))
        let bundle = try await HybridTransfer.downloadResult(jobID: source.descriptor.jobID, to: peer, pairingCode: receiver.pairingCode,
            directory: fixture.root.appendingPathComponent("mesh-only-download"))
        let saved = try await HybridResultImport(metadataDirectory: fixture.metadata).save(bundle, sourceScanID: fixture.original.id, library: fixture.store)
        let model = try XCTUnwrap(fixture.store.modelURL(for: saved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
        XCTAssertEqual(saved.vertexCount, 3); XCTAssertEqual(saved.faceCount, 1)
        let reloaded = ScanStore(baseURL: fixture.store.baseURL)
        let replay = try await HybridResultImport(metadataDirectory: fixture.metadata).save(bundle, sourceScanID: fixture.original.id, library: reloaded)
        XCTAssertEqual(replay.id, saved.id); XCTAssertEqual(reloaded.scans.count, 2)
        try assertSourcesUnchanged(fixture)
    }

    @MainActor
    func testRealTCPGaussianPreservesCheckpointAndDeduplicatesAfterCommitWithoutImportLedger() async throws {
        let fixture = try await fixture(gaussian: true), bundle = try await download(fixture)
        var importer: HybridResultImport? = HybridResultImport(metadataDirectory: fixture.metadata)
        let saved = try await importer!.save(bundle, sourceScanID: fixture.original.id, library: fixture.store)
        let model = try XCTUnwrap(fixture.store.gaussianURL(for: saved))
        XCTAssertEqual(try Data(contentsOf: model), gaussianPLY())
        XCTAssertEqual(try Data(contentsOf: model.deletingLastPathComponent().appendingPathComponent("entrenamiento.ckpt")), gaussianCheckpoint())
        XCTAssertEqual(saved.hybridResultProvenance?.jobID, bundle.descriptor.jobID)
        XCTAssertEqual(saved.hybridResultProvenance?.resultID, bundle.descriptor.resultID)
        // Recreate both owners with no external import ledger: only the committed capture remains.
        importer = nil
        try? FileManager.default.removeItem(at: fixture.metadata)
        let recreatedStore = ScanStore(baseURL: fixture.store.baseURL)
        let replay = try await HybridResultImport(metadataDirectory: fixture.metadata).save(bundle, sourceScanID: fixture.original.id, library: recreatedStore)
        XCTAssertEqual(replay.id, saved.id)
        XCTAssertEqual(recreatedStore.scans.count, 2)
        XCTAssertEqual(recreatedStore.datasetURL(for: replay), fixture.store.datasetURL(for: fixture.original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.metadata.path), "Committed provenance must deduplicate before preparing another sidecar")
        try assertSourcesUnchanged(fixture)
    }

    @MainActor
    func testVerifiedDownloadCanRetryAfterAnotherPendingCaptureIsSuccessfullyResolved() async throws {
        let fixture = try await fixture(gaussian: false), bundle = try await download(fixture)
        var pending = CaptureResult(mesh: MeshSnapshot(vertices: [], triangles: []), mode: .lidar, duration: 1)
        let failed = await fixture.store.save(pending)
        XCTAssertNil(failed); XCTAssertEqual(fixture.store.pendingCapture?.id, pending.id)
        let importer = HybridResultImport(metadataDirectory: fixture.metadata)
        do {
            _ = try await importer.save(bundle, sourceScanID: fixture.original.id, library: fixture.store)
            XCTFail("An unrelated pending capture must remain owned by its save operation")
        } catch { }
        XCTAssertEqual(fixture.store.pendingCapture?.id, pending.id)
        XCTAssertEqual(fixture.store.scans.count, 1)
        try HybridTransfer.verifyDownloadedResult(bundle)
        pending.mesh = mesh
        let resolved = await fixture.store.save(pending)
        XCTAssertNotNil(resolved)
        let saved = try await importer.save(bundle, sourceScanID: fixture.original.id, library: fixture.store)
        XCTAssertEqual(fixture.store.scans.count, 3)
        XCTAssertNil(fixture.store.pendingCapture)
        XCTAssertEqual(saved.sourceScanID, fixture.original.id)
        XCTAssertEqual(fixture.store.datasetURL(for: saved), fixture.store.datasetURL(for: fixture.original))
        try assertSourcesUnchanged(fixture)
    }

    @MainActor
    func testTamperedOrSymlinkedDownloadCannotPublishOrModifyOriginals() async throws {
        let fixture = try await fixture(gaussian: true)
        for attack in ["tamper", "symlink"] {
            let bundle = try await download(fixture, suffix: attack)
            let model = bundle.directory.appendingPathComponent("modelo/gaussianas.ply")
            if attack == "tamper" { try Data("changed after download".utf8).write(to: model) }
            else {
                try FileManager.default.removeItem(at: model)
                let original = try XCTUnwrap(fixture.store.datasetURL(for: fixture.original)).appendingPathComponent("images/authored.png")
                try FileManager.default.createSymbolicLink(at: model, withDestinationURL: original)
            }
            do {
                _ = try await HybridResultImport(metadataDirectory: fixture.metadata).save(bundle, sourceScanID: fixture.original.id, library: fixture.store)
                XCTFail("A modified downloaded bundle must be revalidated before publication: " + attack)
            } catch { }
            XCTAssertEqual(fixture.store.scans.count, 1)
            XCTAssertNil(fixture.store.pendingCapture)
            try assertSourcesUnchanged(fixture)
        }
    }

    private func record(id: UUID = UUID(), parent: UUID? = nil, dataset: String? = nil) -> ScanRecord {
        ScanRecord(id: id, name: "Legacy fixture", mode: .lidar, createdAt: Date(timeIntervalSince1970: 100), vertexCount: 3, faceCount: 1,
            duration: 1, isDemo: false, note: "", modelFile: "modelo.obj", exports: [], datasetDirectory: dataset, sourceScanID: parent)
    }
    private func writeRecord(_ record: ScanRecord, in base: URL, legacy: Bool = false) throws {
        let folder = base.appendingPathComponent(record.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = try JSONEncoder().encode(record)
        if legacy {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: "hybridResultProvenance")
            object.removeValue(forKey: "gaussianModelFile")
            object.removeValue(forKey: "statistics")
            data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        }
        try data.write(to: folder.appendingPathComponent("captura.json"), options: .atomic)
    }

    @MainActor
    func testLegacyDatasetIsInheritedAcrossLongDerivationWithoutArbitraryRecursionCutoff() async throws {
        let fixture = try await fixture(gaussian: false)
        var parent = fixture.original
        // A bounded fixture, not a production quota: cross common historical 32/64/128-depth cutoffs.
        for _ in 0..<257 {
            let child = record(parent: parent.id)
            try writeRecord(child, in: fixture.store.baseURL, legacy: true)
            parent = child
        }
        let recreated = ScanStore(baseURL: fixture.store.baseURL)
        XCTAssertEqual(recreated.scans.count, 258)
        XCTAssertEqual(recreated.datasetSource(for: parent)?.id, fixture.original.id)
        let source = try XCTUnwrap(recreated.datasetURL(for: parent))
        XCTAssertEqual(source, fixture.store.datasetURL(for: fixture.original))
        let manifest = try RGBDDatasetManifest.load(from: source)
        XCTAssertEqual(manifest.frames.count, 1)
        XCTAssertNil(manifest.frames[0].sensorMetadata)
        try assertSourcesUnchanged(fixture)
    }

    @MainActor
    func testDatasetInheritanceTerminatesOnCycleOrMissingLegacyParent() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID()
        let cycleA = record(id: a, parent: b), cycleB = record(id: b, parent: a), missing = record(parent: UUID())
        for value in [cycleA, cycleB, missing] { try writeRecord(value, in: root, legacy: true) }
        let store = ScanStore(baseURL: root)
        for value in [cycleA, cycleB, missing] {
            XCTAssertNil(store.datasetSource(for: value)); XCTAssertNil(store.datasetURL(for: value))
        }
    }
}
