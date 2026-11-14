import XCTest
import Foundation
@testable import Forma

final class CooperativeFileIOTests: XCTestCase {
    func testArchivePreservesUTF8NestedEmptyAndPayloadBytes() throws {
        let root = try directory(), input = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: input.appendingPathComponent("habitación/vacía"), withIntermediateDirectories: true)
        let payload = Data((0..<70000).map { UInt8($0 % 251) })
        try payload.write(to: input.appendingPathComponent("habitación/foto.bin"))
        try Data().write(to: input.appendingPathComponent("vacío.txt"))
        let zip = root.appendingPathComponent("result.zip")
        var last = CooperativeFileIO.Progress(completedBytes: 0, totalBytes: 0)
        try CooperativeFileIO.archiveDirectory(input, to: zip) { last = $0 }
        XCTAssertEqual(last.completedBytes, Int64(payload.count)); XCTAssertEqual(last.totalBytes, Int64(payload.count))
        let archived = try readStoredEntries(zip)
        XCTAssertEqual(archived["habitación/foto.bin"], payload)
        XCTAssertEqual(archived["vacío.txt"], Data())
        XCTAssertEqual(archived["habitación/vacía/"], Data())
    }

    func testCancelledPausedArchiveNeverPublishesAndKeepsSource() throws {
        let root = try directory(), input = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let payload = Data(repeating: 17, count: 3 * 1_048_576)
        let source = input.appendingPathComponent("photo.bin")
        try payload.write(to: source)
        let output = root.appendingPathComponent("cancelled.zip")
        let paused = expectation(description: "ZIP paused at chunk"), ended = expectation(description: "ZIP cancelled")
        let done = ProcessingTestBox<Int64>(0), cancellation = ProcessingTestBox(false)
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        DispatchQueue.global().async {
            do {
                try ProcessingControl.withControl(control) {
                    try CooperativeFileIO.archiveDirectory(input, to: output) { progress in
                        done.value = progress.completedBytes
                        if progress.completedBytes == 1_048_576 { control.requestPause() }
                    }
                }
                XCTFail("Cancelled archive published")
            } catch is CancellationError { cancellation.value = true }
            catch { XCTFail("Unexpected ZIP error: \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        XCTAssertEqual(done.value, 1_048_576)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        control.cancel()
        wait(for: [ended], timeout: 2)
        XCTAssertTrue(cancellation.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".zip-") })
    }

    func testHashPauseResumeUsesRealByteProgressAndCorrectSHA256() throws {
        let root = try directory(), file = root.appendingPathComponent("source.bin")
        let payload = Data(repeating: 41, count: 2 * 1_048_576 + 19)
        try payload.write(to: file)
        let expected = try IntegrityManifest.digest(file)
        let paused = expectation(description: "hash paused"), ended = expectation(description: "hash resumed")
        let count = ProcessingTestBox<Int64>(0), digest = ProcessingTestBox("")
        let control = ProcessingControl { if $0.phase == .paused { paused.fulfill() } }
        DispatchQueue.global().async {
            do {
                digest.value = try ProcessingControl.withControl(control) {
                    try IntegrityManifest.digest(file) { bytes in
                        count.value = bytes
                        if bytes == 1_048_576 { control.requestPause() }
                    }
                }
            } catch { XCTFail("Unexpected hash failure: \(error)") }
            ended.fulfill()
        }
        wait(for: [paused], timeout: 2)
        XCTAssertEqual(count.value, 1_048_576)
        control.resume()
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(count.value, Int64(payload.count)); XCTAssertEqual(digest.value, expected)
    }

    func testZip64EndRecordRetainsOffsetsAndCountsBeyondClassicZIPLimits() {
        let offset = UInt64(UInt32.max) + 12345, size = UInt64(UInt32.max) + 42
        let data = CooperativeFileIO.zip64EndRecord(entryCount: 100_000, directorySize: size,
                                                   directoryOffset: offset, endOffset: offset + size)
        XCTAssertEqual(u64(data, 32), 100_000)
        XCTAssertEqual(u64(data, 40), size)
        XCTAssertEqual(u64(data, 48), offset)
        XCTAssertEqual(u64(data, 64), offset + size)
    }

    func testSymlinksCannotEscapeArchiveRoot() throws {
        let root = try directory(), input = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: input.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try CooperativeFileIO.archiveDirectory(input, to: root.appendingPathComponent("bad.zip")))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-FileIO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func u16(_ d: Data, _ p: Int) -> UInt16 { d.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt16.self)) } }
    private func u32(_ d: Data, _ p: Int) -> UInt32 { d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt32.self)) } }
    private func u64(_ d: Data, _ p: Int) -> UInt64 { d.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt64.self)) } }
    /// A tiny independent reader uses ZIP64 central-directory offsets, not the writer's local descriptors.
    private func readStoredEntries(_ url: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: url)
        let end = data.count - 98
        XCTAssertEqual(u32(data, end), 0x06064b50)
        var p = Int(u64(data, end + 48)), result: [String: Data] = [:]
        for _ in 0..<Int(u64(data, end + 32)) {
            XCTAssertEqual(u32(data, p), 0x02014b50)
            XCTAssertEqual(u16(data, p + 10), 0)
            let nameLength = Int(u16(data, p + 28)), extraLength = Int(u16(data, p + 30))
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            let extra = p + 46 + nameLength
            let count = Int(u64(data, extra + 4)), local = Int(u64(data, extra + 20))
            let start = local + 30 + Int(u16(data, local + 26)) + Int(u16(data, local + 28))
            result[name] = Data(data[start..<(start + count)])
            p += 46 + nameLength + extraLength
        }
        return result
    }
}
