import Foundation
import CryptoKit
import zlib
#if !STORED_USDZ_FIXTURES_ONLY
import XCTest
@testable import Forma
#endif

/// Independently authored ZIP records, including sparse ZIP64 metadata. Payloads
/// are synthetic bytes; no ModelIO, ML model, original scan or GPU is involved.
enum StoredUSDZFixture {
    struct Member {
        var name: String
        var data: Data
        var declaredSize: UInt64? = nil
        var attributes: UInt32 = 0
    }
    struct Bytes {
        var data = Data()
        mutating func put<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        mutating func append(_ value: Data) { data.append(value) }
    }
    static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(truncatingIfNeeded: crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
    static func write(_ url: URL, members: [Member], zip64: Bool = false, descriptor: Bool = false,
                      method: UInt16 = 0, extraFlags: UInt16 = 0) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var cursor: UInt64 = 0
        var records: [(Member, UInt32, UInt64)] = []
        func write(_ data: Data) throws { try output.write(contentsOf: data); cursor += UInt64(data.count) }
        for member in members {
            let size = member.declaredSize ?? UInt64(member.data.count), checksum = crc(member.data)
            let start = cursor, name = Data(member.name.utf8)
            var extra = Bytes()
            if zip64 { extra.put(UInt16(1)); extra.put(UInt16(16)); extra.put(descriptor ? UInt64(0) : size); extra.put(descriptor ? UInt64(0) : size) }
            let base = cursor + UInt64(30 + name.count + extra.data.count)
            var padding = Int((64 - base % 64) % 64)
            if padding > 0 && padding < 4 { padding += 64 }
            if padding > 0 { extra.put(UInt16(0x1986)); extra.put(UInt16(padding - 4)); extra.append(Data(repeating: 0, count: padding - 4)) }
            var local = Bytes()
            local.put(UInt32(0x04034b50)); local.put(UInt16(zip64 ? 45 : 20)); local.put(extraFlags | (descriptor ? 8 : 0)); local.put(method)
            local.put(UInt16(0)); local.put(UInt16(33)); local.put(descriptor ? UInt32(0) : checksum)
            local.put(zip64 ? UInt32.max : descriptor ? 0 : UInt32(size)); local.put(zip64 ? UInt32.max : descriptor ? 0 : UInt32(size))
            local.put(UInt16(name.count)); local.put(UInt16(extra.data.count)); local.append(name); local.append(extra.data)
            try write(local.data); try write(member.data)
            if size > UInt64(member.data.count) {
                cursor += size - UInt64(member.data.count)
                try output.truncate(atOffset: cursor); try output.seek(toOffset: cursor)
            }
            if descriptor {
                var value = Bytes(); value.put(UInt32(0x08074b50)); value.put(checksum)
                if zip64 { value.put(size); value.put(size) } else { value.put(UInt32(size)); value.put(UInt32(size)) }
                try write(value.data)
            }
            records.append((member, checksum, start))
        }
        let directory = cursor
        for (member, checksum, start) in records {
            let size = member.declaredSize ?? UInt64(member.data.count), name = Data(member.name.utf8)
            var extra = Bytes()
            if zip64 { extra.put(UInt16(1)); extra.put(UInt16(24)); extra.put(size); extra.put(size); extra.put(start) }
            var central = Bytes()
            central.put(UInt32(0x02014b50)); central.put(UInt16(0x031e)); central.put(UInt16(zip64 ? 45 : 20))
            central.put(extraFlags | (descriptor ? 8 : 0)); central.put(method); central.put(UInt16(0)); central.put(UInt16(33)); central.put(checksum)
            central.put(zip64 ? UInt32.max : UInt32(size)); central.put(zip64 ? UInt32.max : UInt32(size))
            central.put(UInt16(name.count)); central.put(UInt16(extra.data.count)); central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0))
            central.put(member.attributes); central.put(zip64 ? UInt32.max : UInt32(start)); central.append(name); central.append(extra.data)
            try write(central.data)
        }
        let directorySize = cursor - directory
        if zip64 {
            try write(CooperativeFileIO.zip64EndRecord(entryCount: UInt64(records.count), directorySize: directorySize, directoryOffset: directory, endOffset: cursor))
        } else {
            var end = Bytes(); end.put(UInt32(0x06054b50)); end.put(UInt16(0)); end.put(UInt16(0)); end.put(UInt16(records.count)); end.put(UInt16(records.count))
            end.put(UInt32(directorySize)); end.put(UInt32(directory)); end.put(UInt16(0)); try write(end.data)
        }
        try output.synchronize()
    }
    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StoredUSDZTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    static func digest(_ url: URL) throws -> String {
        var hash = SHA256()
        try CooperativeFileIO.readChunks(url) { hash.update(data: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func set<T: FixedWidthInteger>(_ value: T, in data: inout Data, at offset: Int) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
}

#if !STORED_USDZ_FIXTURES_ONLY
final class StoredUSDZArchiveTests: XCTestCase {
    func testReplacementKeepsUSDCBytesOrderNamesAndAlignment() throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.usdz"), output = root.appendingPathComponent("derived.usdz")
        let usdc = Data([0x50, 0x58, 0x52, 0x2d, 0, 255, 17]), texture = Data(repeating: 97, count: 130)
        try StoredUSDZFixture.write(original, members: [.init(name: "scene.usdc", data: usdc), .init(name: "textures/atlas.png", data: texture)])
        let before = try StoredUSDZFixture.digest(original), archive = try StoredUSDZArchive(url: original)
        let replacement = root.appendingPathComponent("restored.png"), bytes = Data(repeating: 123, count: 523)
        try bytes.write(to: replacement)
        try archive.rewrite(to: output, replacements: ["textures/atlas.png": replacement])
        let rebuilt = try StoredUSDZArchive(url: output)
        try rebuilt.validateCRC()
        XCTAssertEqual(rebuilt.entries.map(\.name), archive.entries.map(\.name))
        XCTAssertTrue(rebuilt.entries.allSatisfy { $0.offset % 64 == 0 })
        let files = try rebuilt.extract(toPrivateDirectory: root.appendingPathComponent("extracted"))
        XCTAssertEqual(try Data(contentsOf: files["scene.usdc"]!), usdc)
        XCTAssertEqual(try Data(contentsOf: files["textures/atlas.png"]!), bytes)
        XCTAssertEqual(try StoredUSDZFixture.digest(original), before)
    }

    func testZIP64AndStreamingDescriptorAreAcceptedThenRewrittenWithoutDescriptor() throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        for descriptor in [false, true] {
            let original = root.appendingPathComponent("zip64-\(descriptor).usdz"), output = root.appendingPathComponent("rewritten-\(descriptor).usdz")
            try StoredUSDZFixture.write(original, members: [.init(name: "scene.usdc", data: Data(repeating: 19, count: 89)),
                .init(name: "a.png", data: Data(repeating: 23, count: 134))], zip64: true, descriptor: descriptor)
            let archive = try StoredUSDZArchive(url: original); try archive.validateCRC()
            try archive.rewrite(to: output, replacements: [:])
            let rebuilt = try StoredUSDZArchive(url: output); try rebuilt.validateCRC()
            XCTAssertEqual(rebuilt.entries.map(\.name), archive.entries.map(\.name))
            XCTAssertEqual(rebuilt.entries.map(\.crc), archive.entries.map(\.crc))
            XCTAssertTrue(rebuilt.entries.allSatisfy { $0.offset % 64 == 0 })
        }
    }

    func testZIP64IndexesSparseMemberBeyondFourGiBWithoutLoadingItsPayload() throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sparse-metadata.usdz"), size = UInt64(UInt32.max) + 257
        // CRC is deliberately not asserted for the sparse synthetic payload. This
        // tests metadata arithmetic only; every publishing API validates payload CRC.
        try StoredUSDZFixture.write(file, members: [.init(name: "scene.usdc", data: Data(), declaredSize: size)], zip64: true)
        let archive = try StoredUSDZArchive(url: file)
        XCTAssertEqual(archive.entries.first?.size, size)
        XCTAssertEqual(archive.entries.first?.offset, 64)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).uint64Value, UInt64(UInt32.max))
    }

    func testBadCRCDoesNotPublishExtractionOrRewriteAndPreservesOriginal() throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("corrupt.usdz")
        try StoredUSDZFixture.write(file, members: [.init(name: "scene.usdc", data: Data(repeating: 7, count: 100))])
        let metadata = try StoredUSDZArchive(url: file)
        let handle = try FileHandle(forWritingTo: file); try handle.seek(toOffset: metadata.entries[0].offset)
        try handle.write(contentsOf: Data([99])); try handle.close()
        let before = try StoredUSDZFixture.digest(file), archive = try StoredUSDZArchive(url: file)
        let extracted = root.appendingPathComponent("extracted"), rewritten = root.appendingPathComponent("rewritten.usdz")
        XCTAssertThrowsError(try archive.extract(toPrivateDirectory: extracted))
        XCTAssertThrowsError(try archive.rewrite(to: rewritten, replacements: [:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: rewritten.path))
        XCTAssertEqual(try StoredUSDZFixture.digest(file), before)
    }

    func testUnsafeDuplicateSymlinkAndUnsupportedArchivesAreRejected() throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let cases: [[StoredUSDZFixture.Member]] = [
            [.init(name: "scene.usdc", data: Data()), .init(name: "../escape.png", data: Data())],
            [.init(name: "scene.usdc", data: Data()), .init(name: "scene.usdc", data: Data())],
            [.init(name: "scene.usdc", data: Data()), .init(name: "scene.usdc/a.png", data: Data())],
            [.init(name: "scene.usdc", data: Data()), .init(name: "a.png", data: Data(), attributes: 0xa1ff0000)]
        ]
        for (index, members) in cases.enumerated() {
            let file = root.appendingPathComponent("unsafe-\(index).usdz")
            try StoredUSDZFixture.write(file, members: members)
            XCTAssertThrowsError(try StoredUSDZArchive(url: file))
        }
        for (method, flags) in [(UInt16(8), UInt16(0)), (0, 1)] {
            let file = root.appendingPathComponent("unsupported-\(method)-\(flags).usdz")
            try StoredUSDZFixture.write(file, members: [.init(name: "scene.usdc", data: Data())], method: method, extraFlags: flags)
            let before = try StoredUSDZFixture.digest(file)
            XCTAssertThrowsError(try StoredUSDZArchive(url: file))
            XCTAssertEqual(try StoredUSDZFixture.digest(file), before)
        }
    }

    func testSymlinkReplacementUnknownNameAndOccupiedDestinationAreNotOverwritten() throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.usdz"), texture = root.appendingPathComponent("texture.png"), alias = root.appendingPathComponent("alias.png")
        try StoredUSDZFixture.write(file, members: [.init(name: "scene.usdc", data: Data()), .init(name: "a.png", data: Data([9]))])
        try Data([11]).write(to: texture); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: texture)
        let archive = try StoredUSDZArchive(url: file), output = root.appendingPathComponent("output.usdz")
        XCTAssertThrowsError(try archive.rewrite(to: output, replacements: ["a.png": alias]))
        XCTAssertThrowsError(try archive.rewrite(to: output, replacements: ["missing.png": texture]))
        try Data("KEEP".utf8).write(to: output)
        XCTAssertThrowsError(try archive.rewrite(to: output, replacements: [:]))
        XCTAssertEqual(try Data(contentsOf: output), Data("KEEP".utf8)); XCTAssertEqual(try Data(contentsOf: texture), Data([11]))
    }

    func testTruncationLocalMismatchMisalignmentAndZIP64OverflowFailSafely() throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.usdz")
        try StoredUSDZFixture.write(source, members: [.init(name: "scene.usdc", data: Data([1,2,3]))])
        let original = try Data(contentsOf: source)
        var variants = [Data(original.dropLast())]
        var localMismatch = original; localMismatch[30] = 65; variants.append(localMismatch)
        var misaligned = original; StoredUSDZFixture.set(UInt16(0), in: &misaligned, at: 28); variants.append(misaligned)
        for (index, bytes) in variants.enumerated() {
            let file = root.appendingPathComponent("malformed-\(index).usdz"); try bytes.write(to: file)
            XCTAssertThrowsError(try StoredUSDZArchive(url: file))
        }
        let zip64 = root.appendingPathComponent("zip64.usdz")
        try StoredUSDZFixture.write(zip64, members: [.init(name: "scene.usdc", data: Data([1,2,3]))], zip64: true)
        var bytes = try Data(contentsOf: zip64)
        let locator = bytes.count - 42
        StoredUSDZFixture.set(UInt64.max - 1, in: &bytes, at: locator + 8)
        let invalidLocator = root.appendingPathComponent("overflow-locator.usdz"); try bytes.write(to: invalidLocator)
        XCTAssertThrowsError(try StoredUSDZArchive(url: invalidLocator))
        bytes = try Data(contentsOf: zip64)
        // Both ZIP64 sizes claim UInt64.max. Adding the aligned data offset must
        // throw rather than wrap or allocate the declared payload.
        StoredUSDZFixture.set(UInt64.max, in: &bytes, at: 44)
        StoredUSDZFixture.set(UInt64.max, in: &bytes, at: 52)
        let central = bytes.range(of: Data([0x50,0x4b,0x01,0x02]))!.lowerBound
        StoredUSDZFixture.set(UInt64.max, in: &bytes, at: central + 60)
        StoredUSDZFixture.set(UInt64.max, in: &bytes, at: central + 68)
        let overflow = root.appendingPathComponent("overflow-size.usdz"); try bytes.write(to: overflow)
        XCTAssertThrowsError(try StoredUSDZArchive(url: overflow))
    }

    func testCancellationAndAcknowledgedPauseDoNotPublishPartialArchive() async throws {
        let root = try StoredUSDZFixture.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.usdz"), output = root.appendingPathComponent("output.usdz")
        try StoredUSDZFixture.write(file, members: [.init(name: "scene.usdc", data: Data(repeating: 42, count: 2_200_000))])
        let archive = try StoredUSDZArchive(url: file), before = try StoredUSDZFixture.digest(file), gate = ProcessingControl()
        gate.requestPause()
        let operation = Task.detached { try ProcessingControl.withControl(gate) { try archive.rewrite(to: output, replacements: [:]) } }
        for _ in 0..<100 { if gate.snapshot.phase == .paused { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(gate.snapshot.phase, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        gate.resume(); try await operation.value
        try StoredUSDZArchive(url: output).validateCRC()
        let cancelled = ProcessingControl(); cancelled.cancel()
        XCTAssertThrowsError(try ProcessingControl.withControl(cancelled) { try archive.rewrite(to: root.appendingPathComponent("cancelled.usdz"), replacements: [:]) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.usdz").path))
        XCTAssertEqual(try StoredUSDZFixture.digest(file), before)
    }
}
#endif
