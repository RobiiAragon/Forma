import Foundation
import zlib

/// Bounded file operations whose checkpoints are between 1 MiB chunks. JPEG,
/// PNG and already-compressed payloads are stored in ZIP64 without recompression.
enum CooperativeFileIO {
    struct Progress: Sendable { var completedBytes: Int64; var totalBytes: Int64 }
    enum FileError: LocalizedError {
        case invalidPath, unsupportedFile, occupiedOutput, tooLongName
        var errorDescription: String? {
            switch self {
            case .invalidPath: "La carpeta contiene una ruta que no es segura para exportar."
            case .unsupportedFile: "La exportación solo admite archivos regulares y carpetas, sin enlaces simbólicos."
            case .occupiedOutput: "El archivo de salida ya existe."
            case .tooLongName: "El nombre de archivo excede el tamaño permitido por el formato ZIP."
            }
        }
    }
    struct Item { var name: String; var url: URL; var bytes: Int64; var directory: Bool }

    static func inventory(_ source: URL) throws -> [Item] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: source.path) else { throw FileError.invalidPath }
        var items: [Item] = []
        while let name = enumerator.nextObject() as? String {
            try ProcessingControl.checkpoint()
            guard safeRelativePath(name) else { throw FileError.invalidPath }
            let url = source.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw FileError.unsupportedFile }
            items.append(.init(name: name, url: url, bytes: Int64(values.fileSize ?? 0), directory: values.isDirectory == true))
        }
        return items.sorted { $0.name < $1.name }
    }

    static func safeRelativePath(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\")
            && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func copyDirectory(_ source: URL, to destination: URL,
                              progress: (Progress) -> Void = { _ in }) throws {
        let items = try inventory(source), total = items.filter { !$0.directory }.reduce(Int64(0)) { $0 + $1.bytes }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw FileError.occupiedOutput }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for item in items {
            try ProcessingControl.checkpoint()
            let output = destination.appendingPathComponent(item.name)
            if item.directory { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyFile(item.url, to: output) { value in progress(.init(completedBytes: completed + value.completedBytes, totalBytes: total)) }
                completed += item.bytes
            }
        }
        progress(.init(completedBytes: completed, totalBytes: total))
    }

    static func copyFile(_ source: URL, to destination: URL, progress: (Progress) -> Void = { _ in }) throws {
        try ProcessingControl.checkpoint()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw FileError.occupiedOutput }
        let size = (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        try readChunks(source) { data in
            try output.write(contentsOf: data); copied += Int64(data.count)
            progress(.init(completedBytes: copied, totalBytes: Int64(size)))
        }
    }

    /// The per-chunk pool also releases Foundation's autoreleased read buffers.
    static func readChunks(_ source: URL, body: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while true {
            try ProcessingControl.checkpoint()
            let count = try autoreleasepool { () throws -> Int in
                let data = try input.read(upToCount: 1_048_576) ?? Data()
                if !data.isEmpty { try body(data) }
                return data.count
            }
            if count == 0 { break }
        }
    }

    private struct Entry { var name: Data; var crc: UInt32; var bytes: UInt64; var offset: UInt64; var directory: Bool }
    private struct Bytes {
        var data = Data()
        mutating func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        mutating func append(_ value: Data) { data.append(value) }
    }

    /// Exposed internally for format tests, including offsets beyond 4 GiB.
    static func zip64EndRecord(entryCount: UInt64, directorySize: UInt64, directoryOffset: UInt64, endOffset: UInt64) -> Data {
        var b = Bytes()
        b.put(UInt32(0x06064b50)); b.put(UInt64(44)); b.put(UInt16(45)); b.put(UInt16(45))
        b.put(UInt32(0)); b.put(UInt32(0)); b.put(entryCount); b.put(entryCount); b.put(directorySize); b.put(directoryOffset)
        b.put(UInt32(0x07064b50)); b.put(UInt32(0)); b.put(endOffset); b.put(UInt32(1))
        b.put(UInt32(0x06054b50)); b.put(UInt16(0)); b.put(UInt16(0)); b.put(UInt16.max); b.put(UInt16.max)
        b.put(UInt32.max); b.put(UInt32.max); b.put(UInt16(0))
        return b.data
    }

    static func archiveDirectory(_ source: URL, to destination: URL,
                                 progress: (Progress) -> Void = { _ in }) throws {
        let items = try inventory(source), total = items.filter { !$0.directory }.reduce(Int64(0)) { $0 + $1.bytes }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw FileError.occupiedOutput }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".zip-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fm.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var offset: UInt64 = 0, completed: Int64 = 0, entries: [Entry] = []
        func write(_ data: Data) throws { try output.write(contentsOf: data); offset += UInt64(data.count) }
        for item in items {
            try ProcessingControl.checkpoint()
            let name = Data((item.name + (item.directory ? "/" : "")).utf8)
            guard name.count <= Int(UInt16.max) else { throw FileError.tooLongName }
            let start = offset
            var local = Bytes()
            local.put(UInt32(0x04034b50)); local.put(UInt16(45)); local.put(UInt16(0x0808)); local.put(UInt16(0))
            local.put(UInt16(0)); local.put(UInt16(33)); local.put(UInt32(0)); local.put(UInt32.max); local.put(UInt32.max)
            local.put(UInt16(name.count)); local.put(UInt16(20)); local.append(name)
            local.put(UInt16(1)); local.put(UInt16(16)); local.put(UInt64(0)); local.put(UInt64(0))
            try write(local.data)
            var crc = UInt32(0), size: UInt64 = 0
            if !item.directory {
                try readChunks(item.url) { data in
                    crc = data.withUnsafeBytes { raw in UInt32(truncatingIfNeeded: crc32(uLong(crc), raw.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
                    try write(data); size += UInt64(data.count); completed += Int64(data.count)
                    progress(.init(completedBytes: completed, totalBytes: total))
                }
            }
            var descriptor = Bytes()
            descriptor.put(UInt32(0x08074b50)); descriptor.put(crc); descriptor.put(size); descriptor.put(size)
            try write(descriptor.data)
            entries.append(.init(name: name, crc: crc, bytes: size, offset: start, directory: item.directory))
        }
        let directoryOffset = offset
        for entry in entries {
            try ProcessingControl.checkpoint()
            var central = Bytes()
            central.put(UInt32(0x02014b50)); central.put(UInt16(45)); central.put(UInt16(45)); central.put(UInt16(0x0808)); central.put(UInt16(0))
            central.put(UInt16(0)); central.put(UInt16(33)); central.put(entry.crc); central.put(UInt32.max); central.put(UInt32.max)
            central.put(UInt16(entry.name.count)); central.put(UInt16(28)); central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0))
            central.put(UInt32(entry.directory ? 0x10 : 0)); central.put(UInt32.max); central.append(entry.name)
            central.put(UInt16(1)); central.put(UInt16(24)); central.put(entry.bytes); central.put(entry.bytes); central.put(entry.offset)
            try write(central.data)
        }
        try write(zip64EndRecord(entryCount: UInt64(entries.count), directorySize: offset - directoryOffset,
                                 directoryOffset: directoryOffset, endOffset: offset))
        try ProcessingControl.checkpoint()
        try output.synchronize()
        try output.close()
        try ProcessingControl.checkpoint()
        try fm.moveItem(at: temporary, to: destination)
        progress(.init(completedBytes: completed, totalBytes: total))
    }
}
