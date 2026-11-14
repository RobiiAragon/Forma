import Foundation
import CryptoKit
import Darwin

/// App-owned snapshots, not a sandbox against another process with the same user.
/// Only prepare() admits a runtime, from explicitly selected app-bundle artifacts.
/// A job configuration can reconnect to a verified snapshot; it cannot install one.
struct DesktopGaussianRuntimeVault {
    struct Snapshot {
        var helperURL: URL
        var shadersURL: URL
    }
    private struct Artifacts: Codable {
        var schemaVersion = 1
        var platform = "macOS"
        var runtimeABI = 2
        var helperSHA256: String
        var metallibSHA256: String
        var manifestSHA256: String
        var infoSHA256: String
    }
    private struct Receipt: Codable {
        var artifacts: Artifacts
        var authenticationCode: String
    }
    private struct Manifest: Decodable {
        var schemaVersion: Int
        var platform: String
        var runtimeABI: Int
        var sha256: [String: String]
    }
    struct InvalidRuntime: LocalizedError {
        var errorDescription: String? {
            "El motor privado no pudo verificarse. Se conservan el entrenamiento y sus archivos; no se ejecutó otra copia."
        }
    }
    private let root: URL
    private var sourceVerifier = DesktopGaussianLegacyRuntime()
    private var snapshotVerifier = DesktopGaussianLegacyRuntime()

    init(root: URL) {
        self.root = URL(fileURLWithPath: root.standardizedFileURL.path, isDirectory: true)
    }

    /// No eviction or replacement: a published content-addressed entry is reused
    /// only after verification, and a damaged entry is preserved for inspection.
    mutating func prepare(helperURL: URL, shadersURL: URL) throws -> Snapshot {
        let verifiedHelper = try sourceVerifier.verifiedHelper(metallibPath: shadersURL.path, forceHashVerification: true)
        guard verifiedHelper.standardizedFileURL == helperURL.standardizedFileURL else { throw InvalidRuntime() }
        let resources = shadersURL.standardizedFileURL.deletingLastPathComponent()
        let info = resources.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let manifest = resources.appendingPathComponent("worker-artifacts.json")
        let manifestData = try Data(contentsOf: manifest)
        let decoded = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard decoded.schemaVersion == 1, decoded.platform == "macOS", decoded.runtimeABI == 2,
              let helperSHA = decoded.sha256["FormaGaussianWorker"], Self.validSHA(helperSHA),
              let metalSHA = decoded.sha256["msplat-macos.metallib"], Self.validSHA(metalSHA) else { throw InvalidRuntime() }
        let artifacts = Artifacts(helperSHA256: helperSHA, metallibSHA256: metalSHA,
            manifestSHA256: Self.hex(SHA256.hash(data: manifestData)), infoSHA256: try Self.digest(info))
        let payload = try Self.encode(artifacts), identifier = Self.hex(SHA256.hash(data: payload))
        try ensureRoot(create: true)
        let key = try authenticationKey(create: true)
        let final = root.appendingPathComponent(identifier, isDirectory: true)
        let snapshot = Self.snapshot(in: final)
        if Self.exists(final) { return try verifiedSnapshot(metallibPath: snapshot.shadersURL.path, forceHashVerification: true) }
        let stage = root.appendingPathComponent(".runtime-stage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { Self.removeOwnedStage(stage) }
        let staged = Self.snapshot(in: stage)
        try FileManager.default.createDirectory(at: staged.helperURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: staged.shadersURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let stagedResources = staged.shadersURL.deletingLastPathComponent()
        let stagedInfo = stagedResources.deletingLastPathComponent().appendingPathComponent("Info.plist")
        let stagedManifest = stagedResources.appendingPathComponent("worker-artifacts.json")
        for (source, destination) in [(verifiedHelper, staged.helperURL), (shadersURL, staged.shadersURL), (info, stagedInfo), (manifest, stagedManifest)] {
            try FileManager.default.copyItem(at: source, to: destination)
            var copied = stat()
            guard lstat(destination.path, &copied) == 0, copied.st_mode & S_IFMT == S_IFREG,
                  copied.st_uid == geteuid(), copied.st_nlink == 1 else { throw InvalidRuntime() }
            try Self.changeMode(destination, destination == staged.helperURL ? 0o700 : 0o600)
            try Self.requireRegular(destination)
            try Self.sync(destination)
        }
        // Verify the copied bytes, not just the source before a potentially racing copy.
        try Self.verifyFiles(artifacts, snapshot: staged)
        var stagedVerifier = DesktopGaussianLegacyRuntime()
        guard try stagedVerifier.verifiedHelper(metallibPath: staged.shadersURL.path, forceHashVerification: true) == staged.helperURL else { throw InvalidRuntime() }
        let receipt = Receipt(artifacts: artifacts, authenticationCode:
            Self.hex(HMAC<SHA256>.authenticationCode(for: payload, using: key)))
        let receiptURL = stage.appendingPathComponent("runtime-receipt.json")
        try Self.writeFile(try Self.encode(receipt), to: receiptURL, permissions: 0o400)
        for file in [stagedInfo, stagedManifest, staged.shadersURL] { try Self.changeMode(file, 0o400); try Self.sync(file) }
        try Self.changeMode(staged.helperURL, 0o500); try Self.sync(staged.helperURL)
        let app = stage.appendingPathComponent("FormaGaussianRuntime.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        for directory in [staged.helperURL.deletingLastPathComponent(), stagedResources, contents, app, stage] {
            try Self.changeMode(directory, 0o500); try Self.sync(directory)
        }
        // Exclusive same-volume rename publishes all artifacts and provenance together.
        if renamex_np(stage.path, final.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw InvalidRuntime() }
        }
        try Self.sync(root)
        return try verifiedSnapshot(metallibPath: snapshot.shadersURL.path, forceHashVerification: true)
    }

    /// This recognizer never creates a directory, key, receipt, or executable.
    mutating func verifiedSnapshot(metallibPath: String, forceHashVerification: Bool = false) throws -> Snapshot {
        let metal = URL(fileURLWithPath: metallibPath).standardizedFileURL
        let app = metal.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let entry = app.deletingLastPathComponent()
        guard (metallibPath as NSString).isAbsolutePath,
              entry.deletingLastPathComponent() == root, Self.validSHA(entry.lastPathComponent),
              app.lastPathComponent == "FormaGaussianRuntime.app" else { throw InvalidRuntime() }
        let snapshot = Self.snapshot(in: entry)
        guard metal == snapshot.shadersURL else { throw InvalidRuntime() }
        try ensureRoot(create: false)
        try Self.requireDirectory(entry, readOnly: true)
        let receiptURL = entry.appendingPathComponent("runtime-receipt.json")
        try Self.requireRegular(receiptURL, readOnly: true)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        let artifacts = receipt.artifacts, payload = try Self.encode(artifacts)
        guard artifacts.schemaVersion == 1, artifacts.platform == "macOS", artifacts.runtimeABI == 2,
              [artifacts.helperSHA256, artifacts.metallibSHA256, artifacts.manifestSHA256, artifacts.infoSHA256].allSatisfy(Self.validSHA),
              Self.hex(SHA256.hash(data: payload)) == entry.lastPathComponent,
              Self.validSHA(receipt.authenticationCode),
              HMAC<SHA256>.isValidAuthenticationCode(Self.bytes(receipt.authenticationCode), authenticating: payload,
                                                    using: try authenticationKey(create: false)) else { throw InvalidRuntime() }
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = snapshot.shadersURL.deletingLastPathComponent()
        for directory in [app, contents, resources, snapshot.helperURL.deletingLastPathComponent()] { try Self.requireDirectory(directory, readOnly: true) }
        for file in [snapshot.helperURL, snapshot.shadersURL, resources.appendingPathComponent("worker-artifacts.json"), contents.appendingPathComponent("Info.plist")] {
            try Self.requireRegular(file, readOnly: true)
        }
        // The legacy verifier caches positive SHA checks using file identity,
        // size, mtime and ctime. Controls explicitly request fresh SHA checks.
        guard try snapshotVerifier.verifiedHelper(metallibPath: metal.path, forceHashVerification: forceHashVerification) == snapshot.helperURL else { throw InvalidRuntime() }
        // Manifest/Info are small; authenticate their exact bytes on each query.
        guard try Self.digest(resources.appendingPathComponent("worker-artifacts.json")) == artifacts.manifestSHA256,
              try Self.digest(contents.appendingPathComponent("Info.plist")) == artifacts.infoSHA256 else { throw InvalidRuntime() }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resources.appendingPathComponent("worker-artifacts.json")))
        guard manifest.sha256["FormaGaussianWorker"] == artifacts.helperSHA256,
              manifest.sha256["msplat-macos.metallib"] == artifacts.metallibSHA256 else { throw InvalidRuntime() }
        return snapshot
    }

    func contains(metallibPath: String) -> Bool {
        URL(fileURLWithPath: metallibPath).standardizedFileURL.path.hasPrefix(root.path + "/")
    }

    private static func snapshot(in directory: URL) -> Snapshot {
        let contents = directory.appendingPathComponent("FormaGaussianRuntime.app/Contents", isDirectory: true)
        return Snapshot(helperURL: contents.appendingPathComponent("Helpers/FormaGaussianWorker"),
                        shadersURL: contents.appendingPathComponent("Resources/msplat-macos.metallib"))
    }
    private func ensureRoot(create: Bool) throws {
        let parent = root.deletingLastPathComponent()
        if create {
            if !Self.exists(parent) { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            try Self.requireDirectory(parent)
            if !Self.exists(root) { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        }
        try Self.requireDirectory(parent); try Self.requireDirectory(root)
    }
    private func authenticationKey(create: Bool) throws -> SymmetricKey {
        let keyURL = root.appendingPathComponent(".provenance-key")
        if !Self.exists(keyURL), create {
            let temporary = root.appendingPathComponent(".key-stage-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let key = SymmetricKey(size: .bits256)
            try Self.writeFile(key.withUnsafeBytes { Data($0) }, to: temporary, permissions: 0o400)
            if renamex_np(temporary.path, keyURL.path, UInt32(RENAME_EXCL)) != 0, errno != EEXIST { throw InvalidRuntime() }
            try Self.sync(root)
        }
        try Self.requireRegular(keyURL, readOnly: true)
        let bytes = try Data(contentsOf: keyURL)
        guard bytes.count == 32 else { throw InvalidRuntime() }
        return SymmetricKey(data: bytes)
    }
    private static func verifyFiles(_ artifacts: Artifacts, snapshot: Snapshot) throws {
        let resources = snapshot.shadersURL.deletingLastPathComponent()
        guard try digest(snapshot.helperURL) == artifacts.helperSHA256, try digest(snapshot.shadersURL) == artifacts.metallibSHA256,
              try digest(resources.appendingPathComponent("worker-artifacts.json")) == artifacts.manifestSHA256,
              try digest(resources.deletingLastPathComponent().appendingPathComponent("Info.plist")) == artifacts.infoSHA256 else { throw InvalidRuntime() }
    }
    private static func attributes(_ url: URL, kind: mode_t) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == kind, value.st_uid == geteuid(),
              value.st_mode & 0o077 == 0, kind != S_IFREG || value.st_nlink == 1 else { throw InvalidRuntime() }
        return value
    }
    private static func requireDirectory(_ url: URL, readOnly: Bool = false) throws {
        let value = try attributes(url, kind: S_IFDIR)
        guard !readOnly || value.st_mode & 0o222 == 0 else { throw InvalidRuntime() }
    }
    private static func requireRegular(_ url: URL, readOnly: Bool = false) throws {
        let value = try attributes(url, kind: S_IFREG)
        guard !readOnly || value.st_mode & 0o222 == 0 else { throw InvalidRuntime() }
    }
    private static func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
    private static func changeMode(_ url: URL, _ permissions: mode_t) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw InvalidRuntime() }
        defer { close(descriptor) }
        guard fchmod(descriptor, permissions) == 0 else { throw InvalidRuntime() }
    }
    private static func writeFile(_ bytes: Data, to url: URL, permissions: mode_t) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw InvalidRuntime() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: bytes)
        guard fchmod(descriptor, permissions) == 0 else { throw InvalidRuntime() }
        try file.synchronize()
    }
    private static func sync(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw InvalidRuntime() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw InvalidRuntime() }
    }
    private static func digest(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw InvalidRuntime() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hex(hash.finalize())
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func hex<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func bytes(_ value: String) -> [UInt8] {
        let characters = Array(value.utf8)
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 87 }
        return stride(from: 0, to: characters.count, by: 2).map { nibble(characters[$0]) * 16 + nibble(characters[$0 + 1]) }
    }
    private static func validSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func removeOwnedStage(_ stage: URL) {
        // This cleanup is called only with our fresh UUID staging directory, never
        // a published entry or a path received from a configuration.
        guard stage.lastPathComponent.hasPrefix(".runtime-stage-"), exists(stage) else { return }
        let files = FileManager.default.enumerator(at: stage, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let url = files?.nextObject() as? URL {
            if let value = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), value.isDirectory == true, value.isSymbolicLink != true {
                _ = chmod(url.path, 0o700)
            }
        }
        _ = chmod(stage.path, 0o700)
        try? FileManager.default.removeItem(at: stage)
    }
}
