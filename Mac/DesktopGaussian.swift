import AppKit
import CryptoKit
import Darwin
import SwiftUI

/// Verifies only the legacy app named by an existing job's Metal library. It does
/// not select runtimes for new work or compare an old build with the new build's fingerprint.
struct DesktopGaussianLegacyRuntime {
    private struct Manifest: Decodable {
        var schemaVersion: Int
        var platform: String
        var runtimeABI: Int
        var sha256: [String: String]
    }
    private struct FileIdentity: Equatable {
        var device: Int32
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
        var changedSeconds: Int
        var changedNanoseconds: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }
    private struct Verified {
        var metallibPath: String
        var helper: URL
        var identities: [FileIdentity]
    }
    struct InvalidRuntime: LocalizedError {
        var errorDescription: String? { "No se pudo verificar la instalación que mantiene este entrenamiento. Sus archivos se conservan sin modificar." }
    }
    private var cached: Verified?

    mutating func verifiedHelper(metallibPath: String, forceHashVerification: Bool = false) throws -> URL {
        let metal = URL(fileURLWithPath: metallibPath).standardizedFileURL
        let resources = metal.deletingLastPathComponent(), contents = resources.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard (metallibPath as NSString).isAbsolutePath, metal.lastPathComponent == "msplat-macos.metallib",
              resources.lastPathComponent == "Resources", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { throw InvalidRuntime() }
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let helper = helpers.appendingPathComponent("FormaGaussianWorker")
        let manifestURL = resources.appendingPathComponent("worker-artifacts.json")
        let infoURL = contents.appendingPathComponent("Info.plist")
        // Every component inside the app is checked with lstat, so a symlink
        // cannot redirect a manifest, binary, library or their parent directory.
        for directory in [app, contents, helpers, resources] { _ = try Self.identity(directory, directory: true) }
        let files = [infoURL, manifestURL, helper, metal]
        let identities = try files.map { try Self.identity($0, directory: false) }
        if !forceHashVerification, let cached, cached.metallibPath == metal.path, cached.identities == identities {
            return cached.helper
        }
        cached = nil
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.robii.forma.desktop" else { throw InvalidRuntime() }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, manifest.platform == "macOS", manifest.runtimeABI == 2,
              let helperSHA = manifest.sha256["FormaGaussianWorker"], Self.validSHA(helperSHA),
              let metalSHA = manifest.sha256["msplat-macos.metallib"], Self.validSHA(metalSHA),
              try Self.digest(helper) == helperSHA, try Self.digest(metal) == metalSHA,
              try files.map({ try Self.identity($0, directory: false) }) == identities else { throw InvalidRuntime() }
        cached = Verified(metallibPath: metal.path, helper: helper, identities: identities)
        return helper
    }

    private static func identity(_ url: URL, directory: Bool) throws -> FileIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw InvalidRuntime() }
        return FileIdentity(value)
    }
    private static func validSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ url: URL) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw InvalidRuntime() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw InvalidRuntime() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        guard fstat(descriptor, &after) == 0, FileIdentity(before) == FileIdentity(after) else { throw InvalidRuntime() }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The helper owns the job. Closing a window or quitting the UI does not pause it.
@MainActor
final class DesktopGaussian: ObservableObject {
    struct Configuration: Codable {
        var schemaVersion = 1
        var jobID: String
        var datasetPath: String
        var workspacePath: String
        var metallibPath: String
        var targetIterations: Int
        var downscale: Float
        var checkpointIntervalSeconds = 30.0
        var progressIntervalSeconds = 0.5
        var initiallyPaused = false
        var resumeOnLaunch = false
        var resumePath: String?
        var datasetIndexSHA256: String
        // Optional for compatibility with existing native configurations. The helper
        // ignores these UI-owned fields; its updatedAt identifies current snapshots.
        var executionID: UUID? = nil
        var executionStartedAt: Double? = nil
    }
    struct Status: Decodable {
        var schemaVersion: Int
        var jobID: String
        var pid: Int32
        var phase: String
        var message: String
        var iteration: Int
        var targetIterations: Int
        var splats: Int
        var progress: Double
        var downscale: Float
        var updatedAt: Double
        var checkpointPath: String?
        var resultPath: String?
        var error: String?
    }
    private struct Publication: Codable {
        var jobID: UUID
        var runID: String
        var resultPath: String
        var captureID: UUID
        var resultID: UUID?
        var iteration: Int
        var executionID: UUID? = nil
    }
    @Published private(set) var busy = false
    @Published private(set) var saving = false
    @Published private(set) var state = "Gaussian Splatting local en Mac"
    @Published private(set) var notice = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var iteration = 0
    @Published private(set) var splats = 0
    @Published private(set) var phase = "settings"
    @Published private(set) var saved: ScanRecord?
    @Published var iterations = "3000"
    @Published var downscale = "1"
    private let job: DesktopJob
    private let library: ScanStore
    private let base: URL
    private let helperURL: URL
    private let shadersURL: URL
    private let canStart: () -> Bool
    private let setBusy: (Bool) -> Void
    private let onSave: (ScanRecord) -> Void
    private let onControl: ((String) throws -> Void)?
    private var configuration: Configuration?
    private var status: Status?
    private var process: Process?
    private var polling: Task<Void, Never>?
    private var pendingResult: CaptureResult?
    private var publishingPath: String?
    private var publicationAttempt: String?
    private var legacyRuntime = DesktopGaussianLegacyRuntime()
    private var adoptedLegacyPID: Int32?
    private var runtimeVault: DesktopGaussianRuntimeVault
    var isPaused: Bool { phase == "paused" || phase == "pausing" }
    var hasWorkspace: Bool { configuration != nil }
    var pendingCaptureID: UUID? { pendingResult?.id }
    var hasLiveWorker: Bool { workerIsAlive }
    var currentTargetIterations: Int? { configuration?.targetIterations }
    var currentExecutionID: UUID? {
        configuration?.executionID ?? configuration.flatMap { UUID(uuidString: URL(fileURLWithPath: $0.workspacePath).lastPathComponent) }
    }
    /// A complete library record tied to this execution's own export. A source
    /// job's historical result is deliberately not a fallback for a current run.
    var publishedCurrentResult: ScanRecord? {
        guard !saving, let configuration, let latest = readCurrentStatus(), latest.phase == "completed" else { return nil }
        return publishedRecord(latest, configuration: configuration)
    }

    init(job: DesktopJob, library: ScanStore, root: URL, canStart: @escaping () -> Bool,
         setBusy: @escaping (Bool) -> Void, onSave: @escaping (ScanRecord) -> Void,
         helperURL: URL? = nil, shadersURL: URL? = nil, onControl: ((String) throws -> Void)? = nil) {
        self.job = job; self.library = library
        base = root.appendingPathComponent("Work/Gaussian-\(job.id.uuidString)", isDirectory: true)
        runtimeVault = DesktopGaussianRuntimeVault(root: root.appendingPathComponent("Runtimes/Gaussian", isDirectory: true))
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FormaGaussianWorker")
        self.shadersURL = shadersURL ?? Bundle.main.resourceURL!.appendingPathComponent("msplat-macos.metallib")
        self.canStart = canStart; self.setBusy = setBusy; self.onSave = onSave; self.onControl = onControl
        if let data = try? Data(contentsOf: base.appendingPathComponent("config.json")),
           let existing = try? JSONDecoder().decode(Configuration.self, from: data),
           existing.schemaVersion == 1, existing.jobID == job.id.uuidString,
           existing.targetIterations > 0, Int32(exactly: existing.targetIterations) != nil,
           existing.downscale.isFinite, existing.downscale >= 1,
           Self.isInside(URL(fileURLWithPath: existing.workspacePath), base) {
            configuration = existing; iterations = String(existing.targetIterations); downscale = String(existing.downscale)
            phase = "preparing"; state = "Esperando el estado de la ejecución actual"
            inspectCurrentExecution()
        }
    }
    deinit { polling?.cancel() }

    func resumeExisting() {
        guard configuration != nil else { return }
        refresh()
        if workerIsAlive { beginPolling(); return }
        guard !workspaceIsLocked else { reportUnverifiedWorker(); return }
        if let status {
            guard !["paused", "pausing", "completed", "cancelled", "failed"].contains(status.phase) else { return }
        } else if let configuration {
            let statusFile = URL(fileURLWithPath: configuration.workspacePath).appendingPathComponent("status.json")
            if FileManager.default.fileExists(atPath: statusFile.path) {
                notice = "No se puede leer el estado del motor. Sus archivos y fuentes se conservan para revisión."; return
            }
            guard !configuration.initiallyPaused else { return }
        }
        guard canStart(), !library.isSaving else { return }
        launch(explicit: false)
    }

    func start(isUserInitiated: Bool = true) {
        refresh()
        if workerIsAlive {
            if isPaused { command("resume", isUserInitiated: isUserInitiated) }
            beginPolling(); return
        }
        guard !workspaceIsLocked else { reportUnverifiedWorker(); return }
        guard !saving, canStart(), !library.isSaving, library.pendingCapture == nil else {
            notice = "El trabajo queda disponible cuando se resuelva el procesamiento o guardado activo."; return
        }
        guard let count = Int(iterations), count > 0, Int32(exactly: count) != nil,
              let reduction = Float(downscale.replacingOccurrences(of: ",", with: ".")),
              reduction.isFinite, reduction >= 1 else {
            notice = "Introduce iteraciones enteras positivas y un factor de resolución ≥ 1."; return
        }
        do {
            if isUserInitiated { try onControl?("resume") }
            let dataset = URL(fileURLWithPath: job.sourcePath).appendingPathComponent("dataset")
            _ = try RGBDDatasetManifest.load(from: dataset)
            let indexHash = try Self.indexDigest(dataset)
            let sameInput = configuration?.datasetPath == dataset.path && configuration?.downscale == reduction &&
                configuration?.datasetIndexSHA256 == indexHash
            if sameInput, let status, count <= status.iteration {
                notice = "El checkpoint alcanzó \(status.iteration) pasos. Elige un objetivo superior o guarda su resultado."; return
            }
            let workspace = sameInput ? URL(fileURLWithPath: configuration!.workspacePath) :
                base.appendingPathComponent("runs/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let resume = sameInput ? status?.checkpointPath : nil
            configuration = Configuration(jobID: job.id.uuidString, datasetPath: dataset.path,
                workspacePath: workspace.path, metallibPath: shadersURL.path,
                targetIterations: count, downscale: reduction, resumePath: resume,
                datasetIndexSHA256: indexHash, executionID: UUID(), executionStartedAt: Date().timeIntervalSince1970)
            status = nil; saved = nil; pendingResult = nil; publishingPath = nil; publicationAttempt = nil
            phase = "preparing"; state = "Preparando la nueva ejecución Gaussian"; progress = 0; iteration = 0; splats = 0
            try writeConfiguration()
            launch(explicit: true)
        } catch {
            notice = error.localizedDescription
            if configuration?.executionStartedAt != nil, status == nil {
                phase = "failed"; state = "No se pudo iniciar la ejecución actual"; setRunning(false)
            }
        }
    }

    func command(_ action: String, isUserInitiated: Bool = true) {
        guard let configuration, ["pause", "resume", "checkpoint", "export", "cancel"].contains(action) else { return }
        if action == "resume", !canStart() {
            notice = "El entrenamiento conserva su estado mientras termina el otro trabajo activo."; return
        }
        guard isWorkerAlive(revalidateLegacy: true) else {
            if workspaceIsLocked { reportUnverifiedWorker(); return }
            if action == "resume" { start(isUserInitiated: isUserInitiated) }
            else { notice = "El proceso ya terminó. Se conserva el último checkpoint disponible." }
            return
        }
        do {
            if isUserInitiated { try onControl?(action) }
            let url = URL(fileURLWithPath: configuration.workspacePath).appendingPathComponent("control.ndjson")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            var bytes = try JSONSerialization.data(withJSONObject: ["jobID": job.id.uuidString,
                "commandID": UUID().uuidString, "command": action], options: [.sortedKeys])
            bytes.append(10); try file.write(contentsOf: bytes); try file.synchronize()
            notice = ""; beginPolling()
        } catch { notice = "No se pudo enviar el control: \(error.localizedDescription)" }
    }

    func showWorkspace() { NSWorkspace.shared.open(base) }
    func retrySave() { publicationAttempt = nil; if let status { publish(status) } }

    private func launch(explicit: Bool) {
        guard var config = configuration else { return }
        guard !workspaceIsLocked else { reportUnverifiedWorker(); return }
        guard #available(macOS 15, *), FileManager.default.isExecutableFile(atPath: helperURL.path),
              FileManager.default.fileExists(atPath: shadersURL.path) else {
            notice = "Esta instalación necesita el motor Gaussian para Apple Silicon y macOS 15 o posterior."
            phase = "failed"; state = "No se pudo iniciar la ejecución actual"; setRunning(false); return
        }
        do {
            guard try Self.indexDigest(URL(fileURLWithPath: config.datasetPath)) == config.datasetIndexSHA256 else {
                notice = "Las fuentes cambiaron. Crea otro entrenamiento para conservar su calibración."
                phase = "failed"; state = "La ejecución actual no pudo verificar sus fuentes"; setRunning(false); return
            }
            let runtime = try runtimeVault.prepare(helperURL: helperURL, shadersURL: shadersURL)
            config.metallibPath = runtime.shadersURL.path; config.resumeOnLaunch = explicit
            configuration = config; try writeConfiguration()
            let log = URL(fileURLWithPath: config.workspacePath).appendingPathComponent("worker.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let file = try FileHandle(forWritingTo: log); try file.seekToEnd()
            defer { try? file.close() }
            let worker = Process(); worker.executableURL = runtime.helperURL
            worker.arguments = ["--config", base.appendingPathComponent("config.json").path]
            worker.standardInput = FileHandle.nullDevice
            worker.standardOutput = file; worker.standardError = file
            try worker.run(); process = worker
            phase = "preparing"; state = "Preparando Gaussian en un proceso independiente…"; notice = ""
            setRunning(true); beginPolling()
        } catch {
            notice = error.localizedDescription; phase = "failed"; state = "No se pudo iniciar la ejecución actual"; setRunning(false)
        }
    }

    private func writeConfiguration() throws {
        guard let configuration else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(configuration)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try bytes.write(to: base.appendingPathComponent("config.json"), options: .atomic)
        try bytes.write(to: URL(fileURLWithPath: configuration.workspacePath).appendingPathComponent("config.json"), options: .atomic)
    }

    private var workerIsAlive: Bool { isWorkerAlive(revalidateLegacy: false) }

    private func isWorkerAlive(revalidateLegacy: Bool) -> Bool {
        // A just-launched worker may not have emitted its first status yet.
        // Keep polling it, but controls still require the verified PID/lock below.
        if process?.isRunning == true, !revalidateLegacy { return true }
        guard let status, let configuration, status.pid > 0, kill(status.pid, 0) == 0,
              status.jobID == configuration.jobID, status.targetIterations == configuration.targetIterations,
              status.downscale == configuration.downscale, workspaceIsLocked else { return false }
        // libproc.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN;
        // that function-like macro is not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(status.pid, $0.baseAddress!, UInt32($0.count)) }
        guard count > 0 else { return false }
        let actual = URL(fileURLWithPath: String(cString: path)).standardizedFileURL.resolvingSymlinksInPath()
        if runtimeVault.contains(metallibPath: configuration.metallibPath) {
            guard let runtime = try? runtimeVault.verifiedSnapshot(metallibPath: configuration.metallibPath,
                forceHashVerification: revalidateLegacy || adoptedLegacyPID != status.pid),
                  actual == runtime.helperURL.standardizedFileURL.resolvingSymlinksInPath() else { return false }
            adoptedLegacyPID = status.pid
            return true
        }
        guard let legacyHelper = try? legacyRuntime.verifiedHelper(metallibPath: configuration.metallibPath,
            forceHashVerification: revalidateLegacy || adoptedLegacyPID != status.pid),
              actual == legacyHelper.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        adoptedLegacyPID = status.pid
        return true
    }

    private var workspaceIsLocked: Bool {
        guard let configuration, Self.isInside(URL(fileURLWithPath: configuration.workspacePath), base) else { return false }
        let lock = URL(fileURLWithPath: configuration.workspacePath).appendingPathComponent("worker.lock")
        let descriptor = open(lock.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return false }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN); return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func reportUnverifiedWorker() {
        notice = "Hay un motor activo en esta carpeta cuya identidad no se pudo verificar. Se conservan su proceso, configuración y fuentes sin iniciar otro motor."
    }

    private func beginPolling() {
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                if !self.workerIsAlive && !self.saving { self.polling = nil; return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Inspection reads state only: no process launch, control command, publication,
    /// or library mutation. It also covers queries before recovery polling starts.
    func inspectCurrentExecution() {
        guard let latest = readCurrentStatus() else { return }
        applyStatus(latest)
    }

    private func readCurrentStatus() -> Status? {
        guard let configuration else { return nil }
        let workspace = URL(fileURLWithPath: configuration.workspacePath)
        guard let bytes = try? Data(contentsOf: workspace.appendingPathComponent("status.json")),
              let latest = try? JSONDecoder().decode(Status.self, from: bytes), latest.schemaVersion == 1,
              latest.jobID == job.id.uuidString, latest.iteration >= 0, latest.splats >= 0,
              latest.progress.isFinite, latest.downscale == configuration.downscale,
              latest.targetIterations == configuration.targetIterations,
              configuration.executionStartedAt.map({ latest.updatedAt >= $0 }) ?? true else { return nil }
        return latest
    }

    private func applyStatus(_ latest: Status) {
        status = latest
        if phase != latest.phase { phase = latest.phase }
        if state != latest.message { state = latest.message }
        if iteration != latest.iteration { iteration = latest.iteration }
        if splats != latest.splats { splats = latest.splats }
        let fraction = min(1, max(0, latest.progress))
        if progress != fraction { progress = fraction }
        if let error = latest.error, notice != error { notice = error }
    }

    private func refresh() {
        guard let latest = readCurrentStatus() else { return }
        if let process, latest.pid != process.processIdentifier {
            if !process.isRunning {
                phase = "failed"; state = "El motor no pudo iniciar este intento"
                notice = "Se conserva el resultado anterior. Revisa worker.log en la carpeta de entrenamiento."
                setRunning(false)
            }
            return
        }
        applyStatus(latest)
        let running = workerIsAlive && !["completed", "cancelled", "failed"].contains(latest.phase)
        if latest.phase == "completed" {
            if publicationAttempt != latest.resultPath { publish(latest) }
            setRunning(saving)
        } else {
            setRunning(running || saving)
            if !running && !["cancelled", "failed", "paused", "pausing"].contains(latest.phase) {
                state = "Trabajo interrumpido; checkpoint conservado"
            }
        }
    }

    private func setRunning(_ value: Bool) {
        guard busy != value else { return }
        busy = value; setBusy(value)
    }

    private func publishedRecord(_ status: Status, configuration: Configuration) -> ScanRecord? {
        guard status.phase == "completed", let resultPath = status.resultPath,
              Self.isInside(URL(fileURLWithPath: resultPath), URL(fileURLWithPath: configuration.workspacePath).appendingPathComponent("exports")) else { return nil }
        let workspace = URL(fileURLWithPath: configuration.workspacePath)
        let publicationURL = workspace.appendingPathComponent("publication.json")
        let previous = (try? Data(contentsOf: publicationURL)).flatMap { try? JSONDecoder().decode(Publication.self, from: $0) }
        return library.scans.first { record in
            if previous?.jobID == job.id, previous?.runID == workspace.lastPathComponent,
               configuration.executionID.map({ previous?.executionID == $0 }) ?? true,
               previous?.iteration == status.iteration, previous?.resultPath == resultPath,
               record.id == previous?.resultID, record.gaussianModelFile != nil,
               record.sourceScanID == job.resultID { return true }
            guard record.gaussianModelFile != nil, record.sourceScanID == job.resultID,
                  let name = record.exports.first(where: { $0.hasSuffix("-gaussian-job.json") }), ScanStore.safeRelativePath(name),
                  let bytes = try? Data(contentsOf: library.directory(for: record).appendingPathComponent(name)),
                  let marker = try? JSONDecoder().decode(Publication.self, from: bytes) else { return false }
            return marker.jobID == job.id && marker.runID == workspace.lastPathComponent && marker.iteration == status.iteration &&
                marker.resultPath == resultPath && (configuration.executionID.map { marker.executionID == $0 } ?? true)
        }
    }

    private func publish(_ status: Status) {
        guard let configuration, let resultPath = status.resultPath,
              Self.isInside(URL(fileURLWithPath: resultPath), URL(fileURLWithPath: configuration.workspacePath).appendingPathComponent("exports")) else { return }
        let workspace = URL(fileURLWithPath: configuration.workspacePath)
        let publicationURL = workspace.appendingPathComponent("publication.json")
        let previous = (try? Data(contentsOf: publicationURL)).flatMap { try? JSONDecoder().decode(Publication.self, from: $0) }
        let existing = publishedRecord(status, configuration: configuration)
        if let existing {
            publicationAttempt = resultPath
            if saved?.id != existing.id { saved = existing; onSave(existing) }
            state = "Gaussian guardado en la biblioteca"; return
        }
        guard !saving, publishingPath != resultPath else { return }
        guard !library.isSaving, library.pendingCapture == nil || library.pendingCapture?.id == previous?.captureID else {
            notice = "Gaussian terminó. Su resultado se conserva mientras se resuelve el otro guardado."; return
        }
        let package = URL(fileURLWithPath: resultPath), model = package.appendingPathComponent("gaussianas.ply")
        guard FileManager.default.fileExists(atPath: model.path) else {
            notice = "El motor informó un resultado, pero falta su PLY. El entrenamiento se conserva."; return
        }
        var result = pendingResult ?? library.pendingCapture ?? CaptureResult(mesh: nil, modelURL: model, mode: .lidar,
            duration: job.duration, note: "Gaussian Splatting local en Mac. \(status.iteration) pasos; \(status.splats) gaussianas. PLY SH3 y complemento SPLAT SH0; fuentes originales conservadas.")
        result.modelPackageURL = package; result.gaussianModelRelativePath = "gaussianas.ply"
        result.sourceScanID = job.resultID
        result.statistics = ["splats": Double(status.splats), "steps": Double(status.iteration), "downscaleFactor": Double(status.downscale)]
        let publication = Publication(jobID: job.id, runID: workspace.lastPathComponent, resultPath: resultPath,
            captureID: result.id, resultID: nil, iteration: status.iteration, executionID: configuration.executionID)
        let markerURL = workspace.appendingPathComponent("gaussian-job.json")
        result.auxiliaryURLs = [markerURL]
        do {
            let bytes = try JSONEncoder().encode(publication)
            try bytes.write(to: publicationURL, options: .atomic)
            try bytes.write(to: markerURL, options: .atomic)
        } catch { notice = error.localizedDescription; return }
        pendingResult = result; publishingPath = resultPath; publicationAttempt = resultPath; saving = true; setRunning(true)
        let finalResult = result
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let record = await self.library.save(finalResult) {
                var committed = publication; committed.resultID = record.id
                self.notice = ""
                do { try JSONEncoder().encode(committed).write(to: publicationURL, options: .atomic) }
                catch { self.notice = "El modelo está guardado; su marcador de publicación permitirá recuperarlo." }
                self.saved = record; self.pendingResult = nil; self.onSave(record)
                self.state = "Gaussian guardado en la biblioteca"
            } else { self.notice = self.library.error ?? "Resultado conservado; puedes reintentar su guardado." }
            self.saving = false; self.publishingPath = nil; self.setRunning(false)
        }
    }

    private static func indexDigest(_ dataset: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: dataset.appendingPathComponent(RGBDDatasetManifest.filename)))
            .map { String(format: "%02x", $0) }.joined()
    }
    private static func isInside(_ child: URL, _ parent: URL) -> Bool {
        child.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(parent.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }
}

struct DesktopGaussianView: View {
    @ObservedObject var controller: DesktopGaussian
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Gaussian Splatting en Mac").font(.title)
            Text("Entrena con Metal en un proceso independiente. Cerrar esta ventana o usar otra app no detiene el trabajo; puedes volver a conectarte a su estado.")
                .foregroundStyle(.secondary)
            Menu("Aplicar ajuste rápido") {
                ForEach(GaussianTrainingPreset.allCases) { preset in
                    Button(preset.title) {
                        preset.apply(iterations: &controller.iterations, downscale: &controller.downscale,
                                     preservingScale: controller.hasWorkspace)
                    }
                }
            }.disabled(controller.busy || controller.saving)
                .accessibilityIdentifier("desktopGaussianQualityPresets")
            Text(GaussianTrainingPreset.explanation).font(.caption).foregroundStyle(.secondary)
            if controller.hasWorkspace {
                Text("Los ajustes rápidos conservan el factor de resolución de esta ejecución; solo cambian el objetivo de pasos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Objetivo de iteraciones", text: $controller.iterations)
                TextField("Factor de resolución", text: $controller.downscale)
            }.disabled(controller.busy || controller.saving)
            Text("Factor 1 conserva la resolución capturada. Iteraciones editables, sin cuotas de gaussianas, fotografías o avisos de memoria.")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.state).font(.headline)
            ProgressView(value: controller.progress)
            Text("\(controller.iteration.formatted()) pasos · \(controller.splats.formatted()) gaussianas")
                .font(.system(.body, design: .monospaced))
            if !controller.notice.isEmpty { Text(controller.notice).textSelection(.enabled) }
            HStack {
                if controller.busy && !controller.saving {
                    Button(controller.isPaused ? "Continuar" : "Pausar y guardar") {
                        controller.command(controller.isPaused ? "resume" : "pause")
                    }
                    Button("Guardar checkpoint") { controller.command("checkpoint") }
                    Button("Terminar y exportar") { controller.command("export") }
                    Button("Detener y conservar estado") { controller.command("cancel") }
                } else if !controller.saving {
                    Button("Entrenar / continuar") { controller.start() }.buttonStyle(.borderedProminent)
                    if controller.phase == "completed", controller.saved == nil { Button("Guardar resultado") { controller.retrySave() } }
                }
            }
            HStack {
                Button("Mostrar carpeta de entrenamiento") { controller.showWorkspace() }.disabled(!controller.hasWorkspace)
                Spacer(); Button("Cerrar ventana") { dismiss() }
            }
        }.padding(28).frame(minWidth: 720, minHeight: 420)
            .onAppear { controller.resumeExisting() }
    }
}
