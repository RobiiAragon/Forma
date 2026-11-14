import Foundation
import zlib

/// The stored, unencrypted ZIP subset used by USDZ; not a general ZIP extractor.
/// USDZ payloads are 64-byte aligned (openusd.org/release/spec_usdz.html).
/// ZIP64 fields follow PKWARE APPNOTE 4.3/4.5.3, without a 4-GiB app quota.
struct StoredUSDZArchive {
    struct Entry: Equatable, Sendable {
        let name: String
        let size: UInt64
        let crc: UInt32
        let offset: UInt64
        let isDirectory: Bool
    }
    struct Progress: Sendable {
        let completedBytes: UInt64
        let totalBytes: UInt64
        var fraction: Double { totalBytes == 0 ? 1 : Double(completedBytes) / Double(totalBytes) }
    }
    enum ArchiveError: LocalizedError {
        case invalidArchive, unsupportedFeature(String), unsafePath, duplicatePath, occupiedOutput, invalidReplacement, checksumMismatch(String), sourceChanged
        var errorDescription: String? {
            switch self {
            case .invalidArchive: "El USDZ está incompleto o su estructura ZIP no es válida. El original se conserva."
            case .unsupportedFeature(let feature): "Este USDZ utiliza una función no compatible: \(feature). El original se conserva."
            case .unsafePath: "El USDZ contiene una ruta o un enlace que no se puede extraer con seguridad."
            case .duplicatePath: "El USDZ contiene nombres duplicados o rutas que se superponen."
            case .occupiedOutput: "El destino ya existe; no se reemplazó ningún archivo."
            case .invalidReplacement: "Una textura de reemplazo no corresponde a un archivo regular del USDZ."
            case .checksumMismatch(let name): "La comprobación CRC del archivo \(name) falló. El original se conserva."
            case .sourceChanged: "Un archivo cambió durante el procesamiento; el resultado no se publicó."
            }
        }
    }
    private struct Record {
        var entry: Entry
        var name: Data
        var flags: UInt16
        var time: UInt16
        var date: UInt16
        var madeBy: UInt16
        var attributes: UInt32
        var comment: Data
        var localOffset: UInt64
    }
    private struct Identity: Equatable {
        var bytes: UInt64
        var modified: Date?
        var number: UInt64?
        var volume: UInt64?
    }
    private struct Bytes {
        var data = Data()
        mutating func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        mutating func append(_ value: Data) { data.append(value) }
    }
    let url: URL
    let entries: [Entry]
    private let records: [Record]
    private let identity: Identity
    private let archiveComment: Data

    /// Reads bounded headers and the central directory; payload CRC is streamed
    /// by validateCRC/extract/rewrite rather than buffering large texture files.
    init(url: URL) throws {
        self.url = url.standardizedFileURL
        identity = try Self.regularIdentity(self.url)
        let input = try FileHandle(forReadingFrom: self.url)
        defer { try? input.close() }
        let parsed = try Self.parse(input, bytes: identity.bytes)
        records = parsed.records; archiveComment = parsed.comment
        entries = records.map(\.entry)
        try assertSourceUnchanged()
    }

    func validateCRC() throws {
        try assertSourceUnchanged()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        for entry in entries {
            let crc = try Self.stream(input, offset: entry.offset, bytes: entry.size) { _ in }
            guard crc == entry.crc else { throw ArchiveError.checksumMismatch(entry.name) }
        }
        try assertSourceUnchanged()
    }

    /// Publishes a fresh private directory only after every member passes CRC.
    @discardableResult
    func extract(toPrivateDirectory destination: URL, progress: (Progress) -> Void = { _ in }) throws -> [String: URL] {
        try assertSourceUnchanged()
        try Self.requireAbsent(destination)
        let stage = try Self.stagingDirectory(beside: destination)
        defer { try? FileManager.default.removeItem(at: stage) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let total = try entries.reduce(UInt64(0)) { try Self.add($0, $1.size) }
        var completed: UInt64 = 0
        for entry in entries {
            try ProcessingControl.checkpoint()
            let outputURL = stage.appendingPathComponent(Self.filePath(entry.name))
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard entry.crc == 0 else { throw ArchiveError.checksumMismatch(entry.name) }
            } else {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Self.requireAbsent(outputURL)
                guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: outputURL)
                do {
                    let crc = try Self.stream(input, offset: entry.offset, bytes: entry.size) { data in
                        try output.write(contentsOf: data); completed = try Self.add(completed, UInt64(data.count))
                        progress(.init(completedBytes: completed, totalBytes: total))
                    }
                    guard crc == entry.crc else { throw ArchiveError.checksumMismatch(entry.name) }
                    try output.synchronize(); try output.close()
                } catch { try? output.close(); throw error }
            }
        }
        try assertSourceUnchanged(); try ProcessingControl.checkpoint()
        try Self.requireAbsent(destination)
        try FileManager.default.moveItem(at: stage, to: destination)
        progress(.init(completedBytes: total, totalBytes: total))
        return Dictionary(uniqueKeysWithValues: entries.filter { !$0.isDirectory }.map { ($0.name, destination.appendingPathComponent($0.name)) })
    }

    static func rewrite(original: URL, toNew destination: URL, replacements: [String: URL],
                        progress: (Progress) -> Void = { _ in }) throws {
        try Self(url: original).rewrite(to: destination, replacements: replacements, progress: progress)
    }

    /// Member order/names and untouched payloads remain exact, including USDC.
    /// Headers are rebuilt with known CRCs, no data descriptors, and 64-B padding.
    func rewrite(to destination: URL, replacements: [String: URL], progress: (Progress) -> Void = { _ in }) throws {
        try assertSourceUnchanged(); try Self.requireAbsent(destination)
        let names = Set(entries.filter { !$0.isDirectory }.map(\.name))
        guard replacements.keys.allSatisfy({ names.contains($0) }) else { throw ArchiveError.invalidReplacement }
        var replacementInfo: [String: (identity: Identity, crc: UInt32)] = [:]
        for (name, source) in replacements {
            try ProcessingControl.checkpoint()
            let identity = try Self.regularIdentity(source)
            let input = try FileHandle(forReadingFrom: source)
            let crc: UInt32
            do { crc = try Self.stream(input, offset: 0, bytes: identity.bytes) { _ in }; try input.close() }
            catch { try? input.close(); throw error }
            guard try Self.regularIdentity(source) == identity else { throw ArchiveError.sourceChanged }
            replacementInfo[name] = (identity, crc)
        }
        let total = try entries.reduce(UInt64(0)) { try Self.add($0, replacementInfo[$1.name]?.identity.bytes ?? $1.size) }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".usdz-rewrite-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary), original = try FileHandle(forReadingFrom: url)
        defer { try? output.close(); try? original.close() }
        var offset: UInt64 = 0, completed: UInt64 = 0, written: [Record] = []
        func write(_ data: Data) throws { try output.write(contentsOf: data); offset = try Self.add(offset, UInt64(data.count)) }
        for record in records {
            try ProcessingControl.checkpoint()
            let replacement = replacementInfo[record.entry.name]
            let size = replacement?.identity.bytes ?? record.entry.size
            let crc = replacement?.crc ?? record.entry.crc
            if replacement != nil {
                guard try Self.stream(original, offset: record.entry.offset, bytes: record.entry.size, body: { _ in }) == record.entry.crc else {
                    throw ArchiveError.checksumMismatch(record.entry.name)
                }
            }
            let start = offset, large = size >= UInt64(UInt32.max)
            var extra = Bytes()
            if large { extra.put(UInt16(1)); extra.put(UInt16(16)); extra.put(size); extra.put(size) }
            let base = try Self.add(start, UInt64(30 + record.name.count + extra.data.count))
            var padding = Int((64 - base % 64) % 64)
            if padding > 0 && padding < 4 { padding += 64 }
            if padding > 0 { extra.put(UInt16(0x1986)); extra.put(UInt16(padding - 4)); extra.append(Data(repeating: 0, count: padding - 4)) }
            var local = Bytes()
            local.put(UInt32(0x04034b50)); local.put(UInt16(large ? 45 : 20)); local.put(UInt16(0x0800)); local.put(UInt16(0))
            local.put(record.time); local.put(record.date); local.put(crc)
            local.put(large ? UInt32.max : UInt32(size)); local.put(large ? UInt32.max : UInt32(size))
            local.put(UInt16(record.name.count)); local.put(UInt16(extra.data.count)); local.append(record.name); local.append(extra.data)
            try write(local.data)
            let payloadOffset = offset
            if let replacement, let source = replacements[record.entry.name] {
                guard try Self.regularIdentity(source) == replacement.identity else { throw ArchiveError.sourceChanged }
                let input = try FileHandle(forReadingFrom: source)
                let actual: UInt32
                do {
                    actual = try Self.stream(input, offset: 0, bytes: size) { data in
                        try write(data); completed = try Self.add(completed, UInt64(data.count)); progress(.init(completedBytes: completed, totalBytes: total))
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
                guard actual == crc, try Self.regularIdentity(source) == replacement.identity else { throw ArchiveError.sourceChanged }
            } else {
                let actual = try Self.stream(original, offset: record.entry.offset, bytes: size) { data in
                    try write(data); completed = try Self.add(completed, UInt64(data.count)); progress(.init(completedBytes: completed, totalBytes: total))
                }
                guard actual == crc else { throw ArchiveError.checksumMismatch(record.entry.name) }
            }
            var next = record
            next.entry = Entry(name: record.entry.name, size: size, crc: crc, offset: payloadOffset, isDirectory: record.entry.isDirectory)
            next.localOffset = start; next.flags = 0x0800; written.append(next)
        }
        let directoryOffset = offset
        for record in written {
            try ProcessingControl.checkpoint()
            let size64 = record.entry.size >= UInt64(UInt32.max), offset64 = record.localOffset >= UInt64(UInt32.max)
            var values = Bytes()
            if size64 { values.put(record.entry.size); values.put(record.entry.size) }
            if offset64 { values.put(record.localOffset) }
            var extra = Bytes()
            if !values.data.isEmpty { extra.put(UInt16(1)); extra.put(UInt16(values.data.count)); extra.append(values.data) }
            var central = Bytes()
            central.put(UInt32(0x02014b50)); central.put(record.madeBy); central.put(UInt16(size64 || offset64 ? 45 : 20))
            central.put(UInt16(0x0800)); central.put(UInt16(0)); central.put(record.time); central.put(record.date); central.put(record.entry.crc)
            central.put(size64 ? UInt32.max : UInt32(record.entry.size)); central.put(size64 ? UInt32.max : UInt32(record.entry.size))
            central.put(UInt16(record.name.count)); central.put(UInt16(extra.data.count)); central.put(UInt16(record.comment.count))
            central.put(UInt16(0)); central.put(UInt16(0)); central.put(record.attributes)
            central.put(offset64 ? UInt32.max : UInt32(record.localOffset)); central.append(record.name); central.append(extra.data); central.append(record.comment)
            try write(central.data)
        }
        let directorySize = offset - directoryOffset, count = UInt64(written.count)
        if count >= UInt64(UInt16.max) || directoryOffset >= UInt64(UInt32.max) || directorySize >= UInt64(UInt32.max) {
            var end = CooperativeFileIO.zip64EndRecord(entryCount: count, directorySize: directorySize, directoryOffset: directoryOffset, endOffset: offset)
            end.removeLast(2)
            var comment = Bytes(); comment.put(UInt16(archiveComment.count)); comment.append(archiveComment); end.append(comment.data)
            try write(end)
        } else {
            var end = Bytes(); end.put(UInt32(0x06054b50)); end.put(UInt16(0)); end.put(UInt16(0)); end.put(UInt16(count)); end.put(UInt16(count))
            end.put(UInt32(directorySize)); end.put(UInt32(directoryOffset)); end.put(UInt16(archiveComment.count)); end.append(archiveComment)
            try write(end.data)
        }
        try output.synchronize(); try output.close(); try assertSourceUnchanged()
        let rebuilt = try Self(url: temporary)
        guard rebuilt.entries.map(\.name) == entries.map(\.name) else { throw ArchiveError.invalidArchive }
        try rebuilt.validateCRC(); try ProcessingControl.checkpoint(); try Self.requireAbsent(destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(.init(completedBytes: total, totalBytes: total))
    }

    private static func parse(_ input: FileHandle, bytes: UInt64) throws -> (records: [Record], comment: Data) {
        guard bytes >= 22 else { throw ArchiveError.invalidArchive }
        let tailSize = Int(min(bytes, 22 + UInt64(UInt16.max)))
        let tail = try read(input, at: bytes - UInt64(tailSize), count: tailSize)
        var endIndex: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if try u32(tail, index) == 0x06054b50, index + 22 + Int(try u16(tail, index + 20)) == tail.count { endIndex = index; break }
        }
        guard let endIndex else { throw ArchiveError.invalidArchive }
        let end = tail.subdata(in: endIndex..<tail.count), endOffset = bytes - UInt64(tailSize) + UInt64(endIndex)
        guard try u16(end, 4) == 0, try u16(end, 6) == 0, try u16(end, 8) == u16(end, 10) else { throw ArchiveError.unsupportedFeature("ZIP dividido en varios discos") }
        var count = UInt64(try u16(end, 10)), directorySize = UInt64(try u32(end, 12)), directoryOffset = UInt64(try u32(end, 16))
        var directoryEnd = endOffset
        if count == UInt64(UInt16.max) || directorySize == UInt64(UInt32.max) || directoryOffset == UInt64(UInt32.max) {
            guard endOffset >= 20 else { throw ArchiveError.invalidArchive }
            let locator = try read(input, at: endOffset - 20, count: 20)
            guard try u32(locator, 0) == 0x07064b50, try u32(locator, 4) == 0, try u32(locator, 16) == 1 else { throw ArchiveError.invalidArchive }
            let zip64Offset = try u64(locator, 8), zip64 = try read(input, at: zip64Offset, count: 56)
            guard try u32(zip64, 0) == 0x06064b50, try u64(zip64, 4) >= 44,
                  try add(zip64Offset, add(12, u64(zip64, 4))) == endOffset - 20,
                  try u16(zip64, 14) <= 45, try u32(zip64, 16) == 0, try u32(zip64, 20) == 0,
                  try u64(zip64, 24) == u64(zip64, 32) else { throw ArchiveError.invalidArchive }
            count = try u64(zip64, 32); directorySize = try u64(zip64, 40); directoryOffset = try u64(zip64, 48); directoryEnd = zip64Offset
        }
        guard count > 0, count <= directorySize / 46, try add(directoryOffset, directorySize) == directoryEnd, directoryEnd <= bytes else { throw ArchiveError.invalidArchive }
        var cursor = directoryOffset, records: [Record] = [], names = Set<String>()
        while cursor < directoryEnd {
            try ProcessingControl.checkpoint()
            let central = try read(input, at: cursor, count: 46)
            guard try u32(central, 0) == 0x02014b50, try u16(central, 6) <= 45 else { throw ArchiveError.invalidArchive }
            let flags = try u16(central, 8); try validateFlags(flags, method: u16(central, 10))
            let nameLength = Int(try u16(central, 28)), extraLength = Int(try u16(central, 30)), commentLength = Int(try u16(central, 32))
            let variable = try read(input, at: add(cursor, 46), count: nameLength + extraLength + commentLength)
            cursor = try add(cursor, UInt64(46 + variable.count))
            guard cursor <= directoryEnd else { throw ArchiveError.invalidArchive }
            let name = variable.subdata(in: 0..<nameLength)
            guard let text = String(data: name, encoding: .utf8), safePath(text) else { throw ArchiveError.unsafePath }
            guard names.insert(filePath(text)).inserted else { throw ArchiveError.duplicatePath }
            let extra = variable.subdata(in: nameLength..<(nameLength + extraLength))
            let rawSize = try u32(central, 24), rawCompressed = try u32(central, 20), rawOffset = try u32(central, 42), disk = try u16(central, 34)
            var extended = try zip64Values(extra, needed: rawSize == .max || rawCompressed == .max || rawOffset == .max || disk == .max)
            let size = rawSize == .max ? try take64(&extended) : UInt64(rawSize)
            let compressed = rawCompressed == .max ? try take64(&extended) : UInt64(rawCompressed)
            let local = rawOffset == .max ? try take64(&extended) : UInt64(rawOffset)
            let diskNumber = disk == .max ? UInt64(try take32(&extended)) : UInt64(disk)
            guard size == compressed, diskNumber == 0, local < directoryOffset else { throw ArchiveError.invalidArchive }
            let attributes = try u32(central, 38), type = (attributes >> 16) & 0xf000
            guard type == 0 || type == 0x8000 || type == 0x4000 else { throw ArchiveError.unsafePath }
            let directory = text.hasSuffix("/")
            guard !directory || size == 0, directory || (attributes & 0x10 == 0 && type != 0x4000) else { throw ArchiveError.unsafePath }
            let entry = Entry(name: text, size: size, crc: try u32(central, 16), offset: 0, isDirectory: directory)
            records.append(.init(entry: entry, name: name, flags: flags, time: try u16(central, 12), date: try u16(central, 14),
                madeBy: try u16(central, 4), attributes: attributes, comment: variable.subdata(in: (nameLength + extraLength)..<variable.count), localOffset: local))
        }
        guard UInt64(records.count) == count else { throw ArchiveError.invalidArchive }
        records.sort { $0.localOffset < $1.localOffset }
        guard records.first?.localOffset == 0, let first = records.first,
              ["usd", "usda", "usdc"].contains((first.entry.name as NSString).pathExtension.lowercased()) else { throw ArchiveError.unsupportedFeature("el primer miembro no es una capa USD") }
        let files = Set(records.filter { !$0.entry.isDirectory }.map { filePath($0.entry.name) })
        for record in records {
            var parts = filePath(record.entry.name).split(separator: "/"); parts.removeLast()
            while !parts.isEmpty { if files.contains(parts.joined(separator: "/")) { throw ArchiveError.duplicatePath }; parts.removeLast() }
        }
        for index in records.indices {
            try ProcessingControl.checkpoint()
            let record = records[index], nextOffset = index + 1 < records.count ? records[index + 1].localOffset : directoryOffset
            let local = try read(input, at: record.localOffset, count: 30)
            guard try u32(local, 0) == 0x04034b50, try u16(local, 4) <= 45, try u16(local, 6) == record.flags else { throw ArchiveError.invalidArchive }
            try validateFlags(record.flags, method: u16(local, 8))
            let nameLength = Int(try u16(local, 26)), extraLength = Int(try u16(local, 28))
            let variable = try read(input, at: add(record.localOffset, 30), count: nameLength + extraLength)
            guard variable.subdata(in: 0..<nameLength) == record.name else { throw ArchiveError.invalidArchive }
            let payload = try add(record.localOffset, UInt64(30 + variable.count)), payloadEnd = try add(payload, record.entry.size)
            guard payload % 64 == 0, payloadEnd <= nextOffset else { throw ArchiveError.invalidArchive }
            let extra = variable.subdata(in: nameLength..<variable.count), rawSize = try u32(local, 22), rawCompressed = try u32(local, 18)
            var extended = try zip64Values(extra, needed: rawSize == .max || rawCompressed == .max)
            let localSize = rawSize == .max ? try take64(&extended) : UInt64(rawSize)
            let localCompressed = rawCompressed == .max ? try take64(&extended) : UInt64(rawCompressed)
            let localCRC = try u32(local, 14)
            if record.flags & 8 == 0 {
                guard localSize == record.entry.size, localCompressed == record.entry.size, localCRC == record.entry.crc, payloadEnd == nextOffset else { throw ArchiveError.invalidArchive }
            } else {
                guard (localSize == 0 || localSize == record.entry.size), (localCompressed == 0 || localCompressed == record.entry.size),
                      localCRC == 0 || localCRC == record.entry.crc else { throw ArchiveError.invalidArchive }
                try validateDescriptor(input, at: payloadEnd, bytes: nextOffset - payloadEnd, entry: record.entry)
            }
            records[index].entry = Entry(name: record.entry.name, size: record.entry.size, crc: record.entry.crc, offset: payload, isDirectory: record.entry.isDirectory)
        }
        return (records, end.subdata(in: 22..<end.count))
    }

    private static func validateDescriptor(_ input: FileHandle, at offset: UInt64, bytes: UInt64, entry: Entry) throws {
        guard [UInt64(12), 16, 20, 24].contains(bytes) else { throw ArchiveError.invalidArchive }
        let data = try read(input, at: offset, count: Int(bytes)), signature = bytes == 16 || bytes == 24
        var cursor = 0
        if signature { guard try u32(data, 0) == 0x08074b50 else { throw ArchiveError.invalidArchive }; cursor = 4 }
        guard try u32(data, cursor) == entry.crc else { throw ArchiveError.invalidArchive }; cursor += 4
        if bytes >= 20 { guard try u64(data, cursor) == entry.size, try u64(data, cursor + 8) == entry.size else { throw ArchiveError.invalidArchive } }
        else { guard entry.size < UInt64(UInt32.max), try UInt64(u32(data, cursor)) == entry.size, try UInt64(u32(data, cursor + 4)) == entry.size else { throw ArchiveError.invalidArchive } }
    }
    private static func zip64Values(_ data: Data, needed: Bool) throws -> Data {
        var cursor = 0, result: Data?
        while cursor < data.count {
            guard cursor + 4 <= data.count else { throw ArchiveError.invalidArchive }
            let tag = try u16(data, cursor), size = Int(try u16(data, cursor + 2)); cursor += 4
            guard cursor + size <= data.count else { throw ArchiveError.invalidArchive }
            if tag == 1 { guard result == nil else { throw ArchiveError.invalidArchive }; result = data.subdata(in: cursor..<(cursor + size)) }
            cursor += size
        }
        if needed, result == nil { throw ArchiveError.invalidArchive }
        return result ?? Data()
    }
    private static func take64(_ data: inout Data) throws -> UInt64 { let value = try u64(data, 0); data = data.subdata(in: 8..<data.count); return value }
    private static func take32(_ data: inout Data) throws -> UInt32 { let value = try u32(data, 0); data = data.subdata(in: 4..<data.count); return value }
    private static func validateFlags(_ flags: UInt16, method: UInt16) throws {
        guard method == 0 else { throw ArchiveError.unsupportedFeature("compresión ZIP (método \(method))") }
        guard flags & 0x0041 == 0 else { throw ArchiveError.unsupportedFeature("cifrado ZIP") }
        guard flags & ~UInt16(0x0808) == 0 else { throw ArchiveError.unsupportedFeature("opciones ZIP no admitidas") }
    }
    private func assertSourceUnchanged() throws { guard try Self.regularIdentity(url) == identity else { throw ArchiveError.sourceChanged } }
    private static func regularIdentity(_ url: URL) throws -> Identity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ArchiveError.unsafePath }
        guard let size = attributes[.size] as? NSNumber else { throw ArchiveError.invalidArchive }
        return Identity(bytes: size.uint64Value, modified: attributes[.modificationDate] as? Date,
                        number: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value, volume: (attributes[.systemNumber] as? NSNumber)?.uint64Value)
    }
    private static func stream(_ input: FileHandle, offset: UInt64, bytes: UInt64, body: (Data) throws -> Void) throws -> UInt32 {
        try input.seek(toOffset: offset)
        var remaining = bytes, checksum: UInt32 = 0
        while remaining > 0 {
            try ProcessingControl.checkpoint()
            try autoreleasepool {
                let request = Int(min(remaining, 1_048_576))
                let data = try input.read(upToCount: request) ?? Data()
                guard !data.isEmpty else { throw ArchiveError.invalidArchive }
                checksum = data.withUnsafeBytes { raw in UInt32(truncatingIfNeeded: crc32(uLong(checksum), raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
                try body(data); remaining -= UInt64(data.count)
            }
        }
        try ProcessingControl.checkpoint()
        return checksum
    }
    private static func read(_ input: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try input.seek(toOffset: offset)
        var result = Data()
        while result.count < count {
            let data = try input.read(upToCount: count - result.count) ?? Data()
            guard !data.isEmpty else { throw ArchiveError.invalidArchive }; result.append(data)
        }
        return result
    }
    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 { UInt16(try integer(data, offset, count: 2)) }
    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 { UInt32(try integer(data, offset, count: 4)) }
    private static func u64(_ data: Data, _ offset: Int) throws -> UInt64 { try integer(data, offset, count: 8) }
    private static func integer(_ data: Data, _ offset: Int, count: Int) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - count else { throw ArchiveError.invalidArchive }
        var result: UInt64 = 0
        for index in 0..<count { result |= UInt64(data[data.startIndex + offset + index]) << (8 * index) }
        return result
    }
    private static func add(_ first: UInt64, _ second: UInt64) throws -> UInt64 {
        let (value, overflow) = first.addingReportingOverflow(second)
        guard !overflow else { throw ArchiveError.invalidArchive }; return value
    }
    private static func filePath(_ name: String) -> String { name.hasSuffix("/") ? String(name.dropLast()) : name }
    private static func safePath(_ name: String) -> Bool {
        let path = filePath(name)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && !(path.count >= 2 && path[path.index(after: path.startIndex)] == ":")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func requireAbsent(_ url: URL) throws {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else { throw ArchiveError.occupiedOutput }
    }
    private static func stagingDirectory(beside destination: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = parent.appendingPathComponent(".usdz-extract-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return stage
    }
}
