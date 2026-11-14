import XCTest
@testable import Forma

final class PendingRecoveryIntegrityTests: XCTestCase {
    @MainActor
    func testCompleteRestorePublishesWithoutChangingAnyFileBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makePendingFixture(in: root, prefix: ".restore-")
        let original = try fileBytes(in: fixture.pending)
        let report = try await Task.detached { try PendingScanRecovery.recover(in: fixture.base) }.value
        XCTAssertEqual(report.recoveredCount, 1)
        XCTAssertEqual(report.remainingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.path))
        XCTAssertEqual(try fileBytes(in: fixture.final), original)
    }

    @MainActor
    func testIncompleteRestoreRemainsHiddenAndPreservesAvailableFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makePendingFixture(in: root, prefix: ".restore-")
        try FileManager.default.removeItem(at: fixture.pending.appendingPathComponent("modelo.obj"))
        try FileManager.default.removeItem(at: fixture.pending.appendingPathComponent("integridad.json"))
        let incomplete = try fileBytes(in: fixture.pending)
        let report = try await Task.detached { try PendingScanRecovery.recover(in: fixture.base) }.value
        XCTAssertEqual(report.recoveredCount, 0)
        XCTAssertEqual(report.remainingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        XCTAssertEqual(try fileBytes(in: fixture.pending), incomplete)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: fixture.base,
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles).isEmpty)
    }

    @MainActor
    func testRestoreDirectoryWhoseUUIDDisagreesWithRecordNeverPublishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makePendingFixture(in: root, prefix: ".restore-")
        let wrongID = UUID()
        let renamed = fixture.base.appendingPathComponent(".restore-" + wrongID.uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: fixture.pending, to: renamed)
        let original = try fileBytes(in: renamed)
        let report = try await Task.detached { try PendingScanRecovery.recover(in: fixture.base) }.value
        XCTAssertEqual(report.recoveredCount, 0)
        XCTAssertEqual(report.remainingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent(wrongID.uuidString).path))
        XCTAssertEqual(try fileBytes(in: renamed), original)
    }

    @MainActor
    func testValidButPartialIntegrityManifestDoesNotPublishPendingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makePendingFixture(in: root)
        let capture = fixture.pending.appendingPathComponent("captura.json")
        let captureBytes = try Data(contentsOf: capture)
        let modelBytes = try Data(contentsOf: fixture.pending.appendingPathComponent("modelo.obj"))
        let partial = IntegrityManifest(createdAt: Date(), files: [
            .init(name: "captura.json", sha256: try IntegrityManifest.digest(capture), bytes: captureBytes.count)
        ])
        // Every declared hash is valid; the missing inventory entries are the defect.
        XCTAssertEqual(partial.files[0].sha256, try IntegrityManifest.digest(capture))
        try JSONEncoder().encode(partial).write(to: fixture.pending.appendingPathComponent("integridad.json"), options: .atomic)
        let report = try await Task.detached { try PendingScanRecovery.recover(in: fixture.base) }.value
        XCTAssertEqual(report.recoveredCount, 0)
        XCTAssertEqual(report.remainingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        XCTAssertEqual(try Data(contentsOf: capture), captureBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.pending.appendingPathComponent("modelo.obj")), modelBytes)
    }

    @MainActor
    func testSymlinkPayloadWithMatchingHashDoesNotPublishOrAlterItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makePendingFixture(in: root)
        let model = fixture.pending.appendingPathComponent("modelo.obj")
        let bytes = try Data(contentsOf: model)
        let external = root.appendingPathComponent("external-model.obj")
        try bytes.write(to: external)
        try FileManager.default.removeItem(at: model)
        try FileManager.default.createSymbolicLink(at: model, withDestinationURL: external)
        // The original complete manifest still matches the target bytes.
        let manifest = try JSONDecoder().decode(IntegrityManifest.self,
            from: Data(contentsOf: fixture.pending.appendingPathComponent("integridad.json")))
        XCTAssertEqual(try XCTUnwrap(manifest.files.first { $0.name == "modelo.obj" }).sha256,
                       try IntegrityManifest.digest(external))
        let report = try await Task.detached { try PendingScanRecovery.recover(in: fixture.base) }.value
        XCTAssertEqual(report.recoveredCount, 0)
        XCTAssertEqual(report.remainingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        XCTAssertEqual(try model.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }

    @MainActor
    func testSymlinkPendingDirectoryIsPreservedAndNeverRenamedIntoLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await makePendingFixture(in: root)
        let external = root.appendingPathComponent("external-capture", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.pending, to: external)
        let captureBytes = try Data(contentsOf: external.appendingPathComponent("captura.json"))
        try FileManager.default.createSymbolicLink(at: fixture.pending, withDestinationURL: external)
        let report = try await Task.detached { try PendingScanRecovery.recover(in: fixture.base) }.value
        XCTAssertEqual(report.recoveredCount, 0)
        XCTAssertEqual(report.remainingCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        XCTAssertEqual(try fixture.pending.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: external.appendingPathComponent("captura.json")), captureBytes)
    }

    @MainActor
    private func makePendingFixture(in root: URL, prefix: String = ".pending-") async throws -> (base: URL, pending: URL, final: URL) {
        let base = root.appendingPathComponent("library", isDirectory: true)
        let store = ScanStore(baseURL: base)
        let mesh = MeshSnapshot(vertices: [.init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0)], triangles: [0, 1, 2])
        let saved = await store.save(CaptureResult(mesh: mesh, mode: .lidar, duration: 1))
        let record = try XCTUnwrap(saved)
        let final = store.directory(for: record)
        let pending = base.appendingPathComponent(prefix + record.id.uuidString, isDirectory: true)
        try FileManager.default.moveItem(at: final, to: pending)
        return (base, pending, final)
    }

    private func fileBytes(in directory: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: directory.path))
        var files: [String: Data] = [:]
        while let name = enumerator.nextObject() as? String {
            let file = directory.appendingPathComponent(name)
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[name] = try Data(contentsOf: file)
            }
        }
        return files
    }
}
