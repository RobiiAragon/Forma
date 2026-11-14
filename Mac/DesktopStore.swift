import Foundation
import SwiftUI
import AppKit
import Combine

struct DesktopJob: Identifiable, Codable {
    var id: UUID
    var sourcePath: String
    var duration: TimeInterval
    var title: String
    var state = "En cola"
    var progress = 0.0
    var status = "Fuentes originales conservadas"
    var resultID: UUID?
    var processingRequest: HybridTransfer.ProcessingRequest?
}

@MainActor
final class DesktopStore: ObservableObject {
    @Published var jobs: [DesktopJob] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published var isImporting = false
    @Published private(set) var photogrammetryBusy = false
    @Published private(set) var localAIBusy = false
    @Published private(set) var gaussianBusy = false
    let receiver = HybridTransferReceiver()
    let library: ScanStore
    let root: URL
    let localAIModels: LocalAIModelStore
    private var active: Task<Void, Never>?
    private var activeID: UUID?
    private var gate: ProcessingControl?
    private var stateRevision: UInt64 = 0
    private var usbProxy: Process?
    private var savingObservation: AnyCancellable?
    private var activity: NSObjectProtocol?
    private var localAIControllers: [UUID: DesktopLocalAI] = [:]
    private var geometryControllers: [UUID: DesktopGeometryRefinement] = [:]
    private var recoveringLocalAI: [UUID] = []
    private var gaussianControllers: [UUID: DesktopGaussian] = [:]
    private var recoveringGaussian: [UUID] = []
    private var gaussianObservations: [UUID: AnyCancellable] = [:]
    private let gaussianHelperURL: URL?
    private let gaussianShadersURL: URL?
    private var savingPauseIntents: [UUID: Bool] = [:]
    private var remoteResultPreparations: [UUID: Task<HybridTransfer.ResultSource, Error>] = [:]
    private lazy var remoteControlLedger = DesktopRemoteControlLedger(root: root.appendingPathComponent("RemoteControl", isDirectory: true))

    init(baseURL: URL? = nil, gaussianHelperURL: URL? = nil, gaussianShadersURL: URL? = nil) {
        self.gaussianHelperURL = gaussianHelperURL; self.gaussianShadersURL = gaussianShadersURL
        root = baseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FormaDesktop", isDirectory: true)
        localAIModels = LocalAIModelStore(root: root)
        library = ScanStore(baseURL: root.appendingPathComponent("Library", isDirectory: true))
        if let bytes = try? Data(contentsOf: root.appendingPathComponent("jobs.json")), let saved = try? JSONDecoder().decode([DesktopJob].self, from: bytes) {
            jobs = saved.map { job in
                var job = job
                if ["Procesando", "Pausando", "Pausado", "Guardado pendiente"].contains(job.state) {
                    if job.processingRequest?.kind == .gaussian {
                        // The independent worker owns its persisted pause/run intent.
                        // A CPU input preparation interrupted before worker creation can restart.
                        let config = root.appendingPathComponent("Work/Gaussian-\(job.id.uuidString)/config.json")
                        if !FileManager.default.fileExists(atPath: config.path) {
                            if job.state == "Pausando" || job.state == "Pausado" {
                                job.state = "Pausado"; job.status = "Pausa manual conservada; continúa cuando lo indiques"
                            } else {
                                job.state = "En cola"; job.status = "Preparación Gaussian conservada para continuar"
                            }
                        }
                    } else {
                        job.state = "Interrumpido"; job.status = "Fuentes conservadas. Reanudar inicia un nuevo proceso desde ellas."
                    }
                }
                return job
            }
        }
        selectedID = jobs.last?.id
        savingObservation = library.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.synchronizeSavingState() }
        }
        recoveringGaussian = jobs.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("Work/Gaussian-\($0.id.uuidString)/config.json").path)
        }.map(\.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // ScanStore may first finish publishing a recovered final save.
            if self.library.pendingSaveCount > 0 { await self.library.recoverPendingSaves() }
            while self.library.isSaving { try? await Task.sleep(for: .milliseconds(100)) }
            self.restoreLocalAIJobs()
            self.next()
        }
    }

    var selected: DesktopJob? { jobs.first { $0.id == selectedID } }
    var activeGaussianJob: DesktopJob? {
        jobs.first { gaussianControllers[$0.id]?.busy == true }
    }
    var canStartPhotogrammetry: Bool { active == nil && !library.isSaving && library.pendingCapture == nil && !photogrammetryBusy && !localAIBusy && !gaussianBusy }
    func gaussianController(for job: DesktopJob) -> DesktopGaussian {
        if let existing = gaussianControllers[job.id] { return existing }
        var controllerJob = job
        if job.processingRequest?.kind == .gaussian {
            controllerJob.sourcePath = gaussianInputSource(for: job).path
            // This controller publishes the original remote request. The result
            // assigned to its queue row must not become a different source ID on relaunch.
            controllerJob.resultID = nil
        }
        let controller = DesktopGaussian(job: controllerJob, library: library, root: root,
            canStart: { [weak self] in
                guard let self else { return false }
                return self.active == nil && !self.library.isSaving && self.library.pendingCapture == nil &&
                    !self.photogrammetryBusy && !self.localAIBusy &&
                    !self.gaussianControllers.contains(where: { $0.key != job.id && $0.value.busy })
            },
            setBusy: { [weak self] _ in
                guard let self else { return }
                self.gaussianBusy = self.gaussianControllers.values.contains(where: \.busy)
                self.updateActivity(working: self.gaussianBusy)
                if !self.gaussianBusy {
                    if self.active == nil, self.activeID == job.id { self.activeID = nil }
                    self.next()
                }
            }, onSave: { [weak self] record in
                guard let self else { return }
                self.registerGaussianResult(record, sourceJob: job)
            }, helperURL: gaussianHelperURL, shadersURL: gaussianShadersURL, onControl: { [weak self] _ in
                guard let self else { throw RGBDDatasetError.invalid("Forma Desktop no está disponible.") }
                try self.remoteControlLedger.noteHumanIntent(for: job.id)
            })
        if job.processingRequest?.kind == .gaussian, !controller.hasWorkspace {
            if let iterations = job.processingRequest?.iterations { controller.iterations = String(iterations) }
            if let downscale = job.processingRequest?.downscale { controller.downscale = String(downscale) }
        }
        gaussianControllers[job.id] = controller
        gaussianObservations[job.id] = controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeGaussianState(for: job.id) }
        }
        return controller
    }
    func localAIController(for job: DesktopJob) -> DesktopLocalAI? {
        guard let record = record(job) else { return nil }
        if let existing = localAIControllers[record.id], existing.saved == nil { return existing }
        let controller = DesktopLocalAI(record: record, library: library, root: root, models: localAIModels,
            canStart: { [weak self] in self?.canStartPhotogrammetry == true }, setBusy: { [weak self] busy in
            self?.localAIBusy = busy; self?.updateActivity(working: busy); if !busy { self?.next() }
        }, setWorking: { [weak self] in self?.updateActivity(working: $0) }, onSave: { [weak self] record in
            guard let self else { return }
            self.registerAIResult(record, sourceJob: job)
        }, onIssue: { [weak self] message in self?.error = "El trabajo IA se conserva. " + message })
        localAIControllers[record.id] = controller
        return controller
    }
    func isRefiningGeometry(_ job: DesktopJob) -> Bool {
        guard let id = job.resultID else { return false }
        return geometryControllers[id]?.busy == true
    }
    func geometryController(for job: DesktopJob) -> DesktopGeometryRefinement? {
        guard let record = record(job), SavedScanRefinement.canRefine(scan: record, directory: library.directory(for: record)) else { return nil }
        if let existing = geometryControllers[record.id] { return existing }
        let controller = DesktopGeometryRefinement(record: record, library: library,
            canStart: { [weak self] in
                guard let self else { return false }
                // A retry owns an existing pending result; start() separately
                // rejects unrelated pending captures before beginning a new run.
                return self.active == nil && !self.library.isSaving &&
                    !self.photogrammetryBusy && !self.localAIBusy && !self.gaussianBusy
            },
            setBusy: { [weak self] busy in
                self?.photogrammetryBusy = busy; self?.updateActivity(working: busy)
                if !busy { self?.next() }
            }, onSave: { [weak self] result in
                guard let self else { return }
                let derived = DesktopJob(id: UUID(), sourcePath: job.sourcePath, duration: job.duration,
                    title: "Geometría refinada · " + job.title, state: "Completado", progress: 1,
                    status: "Copia independiente; geometría y fuentes originales conservadas", resultID: result.id)
                self.jobs.append(derived); self.selectedID = derived.id; self.persist()
            })
        geometryControllers[record.id] = controller
        return controller
    }
    func photogrammetryController(for job: DesktopJob) -> DesktopPhotogrammetry {
        DesktopPhotogrammetry(job: job, library: library, root: root, setBusy: { [weak self] busy in
            self?.photogrammetryBusy = busy; self?.updateActivity(working: busy); if !busy { self?.next() }
        }, onSave: { [weak self] record in
            guard let self else { return }
            let derived = DesktopJob(id: UUID(), sourcePath: job.sourcePath, duration: job.duration,
                title: "Fotogrametría · " + job.title, state: "Completado", progress: 1, status: "Modelo fotográfico independiente; fuentes conservadas", resultID: record.id)
            self.jobs.append(derived); self.selectedID = derived.id; self.persist()
        })
    }
    func record(_ job: DesktopJob) -> ScanRecord? { library.scans.first { $0.id == job.resultID } }
    func receive() {
        do {
            try receiver.start(directory: root.appendingPathComponent("Incoming"), onStatus: remoteStatusProvider, onCommand: remoteCommandProvider, onResult: remoteResultProvider) { [weak self] received in
                Task { @MainActor in self?.enqueue(received, title: "iPhone · \(Date().formatted(date: .abbreviated, time: .shortened))") }
            }
        } catch { self.error = error.localizedDescription }
    }
    func enqueue(_ received: HybridTransfer.ReceivedJob, title: String) {
        guard !jobs.contains(where: { $0.id == received.id }) else { return }
        do {
            let request = try readProcessingRequest(in: received.directory)
            jobs.append(.init(id: received.id, sourcePath: received.directory.path, duration: received.duration,
                              title: title, processingRequest: request))
            selectedID = received.id; persist(); next()
        } catch {
            self.error = "La solicitud recibida no se inició; sus fuentes se conservan. " + error.localizedDescription
        }
    }
    func receiveUSB() {
        guard receiver.isListening else { error = "Activa primero Recibir desde iPhone y copia la clave de sesión."; return }
        guard !receiver.isUSBContinuousEnabled else { return }
        do {
            if usbProxy?.isRunning != true {
                let candidates = ["/opt/homebrew/bin/iproxy", "/usr/local/bin/iproxy"]
                guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                    error = "USB-C necesita iproxy de libusbmuxd. Instálalo con Homebrew: brew install libusbmuxd. Wi-Fi sigue disponible."; return
                }
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = ["-l", "-s", "127.0.0.1", "49232:49231"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); usbProxy = process
            }
            // The reconnect loop also covers the bridge's startup delay. No delayed
            // task may accidentally enable USB again after closing a reception.
            try receiver.startContinuousUSB(directory: root.appendingPathComponent("Incoming"), pairingCode: receiver.pairingCode,
                onStatus: remoteStatusProvider, onCommand: remoteCommandProvider, onResult: remoteResultProvider) { [weak self] received in
                    Task { @MainActor in self?.enqueue(received, title: "USB-C · \(Date().formatted(date: .abbreviated, time: .shortened))") }
                }
        } catch { stopUSBReception(); self.error = error.localizedDescription }
    }
    func stopUSBReception() {
        receiver.stopContinuousUSB()
        if usbProxy?.isRunning == true { usbProxy?.terminate() }
        usbProxy = nil
    }
    func stopReception() { stopUSBReception(); receiver.stop() }
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Elige una carpeta de captura de Forma o su carpeta fuentes (dataset.json y malla original)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importDirectory(url)
    }
    func importDirectory(_ source: URL) {
        guard !isImporting else { return }
        isImporting = true
        let incoming = root.appendingPathComponent("Incoming")
        let access = source.startAccessingSecurityScopedResource()
        Task {
            defer { isImporting = false; if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let received = try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let candidates = [source, source.appendingPathComponent("fuentes"), source.appendingPathComponent("dataset")]
                    guard let dataset = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("dataset.json").path) }) else {
                        throw RGBDDatasetError.invalid("No se encontró dataset.json. Importa la carpeta de fuentes RGB-D completa.")
                    }
                    let meshes = [dataset.appendingPathComponent("malla-original.json"), source.appendingPathComponent("malla-original.json"),
                                  source.appendingPathComponent("datos-1-malla-original.json"), source.appendingPathComponent("malla.json")]
                    guard let mesh = meshes.first(where: { fm.fileExists(atPath: $0.path) }) else {
                        throw RGBDDatasetError.invalid("Falta malla-original.json o malla.json junto a las fuentes.")
                    }
                    _ = try RGBDDatasetManifest.load(from: dataset)
                    let raw = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: mesh))
                    try MeshExporter.validate(raw)
                    let id = UUID(), stage = incoming.appendingPathComponent(".import-\(UUID().uuidString)")
                    let final = incoming.appendingPathComponent(id.uuidString)
                    try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
                    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                    defer { try? fm.removeItem(at: stage) }
                    try fm.copyItem(at: dataset, to: stage.appendingPathComponent("dataset"))
                    try fm.copyItem(at: mesh, to: stage.appendingPathComponent("malla-original.json"))
                    try fm.moveItem(at: stage, to: final)
                    return HybridTransfer.ReceivedJob(id: id, directory: final, duration: 0)
                }.value
                enqueue(received, title: "Importada · \(source.lastPathComponent)")
            } catch { self.error = error.localizedDescription }
        }
    }

    func pause() {
        let id = activeID ?? gaussianControllers.first(where: { $0.value.busy })?.key
        guard let id else { return }
        do {
            if library.isSaving {
                try remoteControlLedger.noteHumanIntent(for: id); library.pauseSaving()
            } else if active == nil, let controller = gaussianControllers[id], controller.busy {
                controller.command("pause")
            } else {
                try remoteControlLedger.noteHumanIntent(for: id)
                update(id) { $0.state = "Pausando" }; try persistDurably(); _ = gate?.requestPause()
            }
        } catch { self.error = "No se pudo registrar la pausa; no se cambió el control. " + error.localizedDescription }
    }
    func resume(_ id: UUID) {
        if let controller = gaussianControllers[id], controller.hasWorkspace,
           jobs.first(where: { $0.id == id })?.resultID == nil, !library.isSaving, gate == nil {
            controller.start(); synchronizeGaussianState(for: id); return
        }
        do {
            if library.isSaving, activeID == id {
                try remoteControlLedger.noteHumanIntent(for: id)
                if library.savingState.isPauseActive { library.toggleSavingPause() }; return
            }
            if activeID == id, let gate {
                try remoteControlLedger.noteHumanIntent(for: id); _ = gate.resume(); return
            }
            guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].resultID == nil else { return }
            try remoteControlLedger.noteHumanIntent(for: id)
            jobs[index].state = "En cola"
            jobs[index].status = "Esperando turno de procesamiento; fuentes originales conservadas"
            try persistDurably(); next()
        } catch { self.error = "No se pudo registrar la continuación; el estado se conserva. " + error.localizedDescription }
    }
    func cancel() {
        let id = activeID ?? gaussianControllers.first(where: { $0.value.busy })?.key
        guard let id else { return }
        do {
            if library.isSaving {
                try remoteControlLedger.noteHumanIntent(for: id); library.cancelSaving()
            } else if active == nil, let controller = gaussianControllers[id], controller.busy {
                controller.command("cancel")
            } else {
                try remoteControlLedger.noteHumanIntent(for: id); gate?.cancel(); active?.cancel()
            }
        } catch { self.error = "No se pudo registrar la cancelación; no se cambió el control. " + error.localizedDescription }
    }
    func retrySave() {
        if let pending = library.pendingCapture,
           let owner = geometryControllers.values.first(where: { $0.pendingCaptureID == pending.id }) {
            owner.retrySave(); return
        }
        guard let pending = library.pendingCapture else { return }
        if let owner = localAIControllers.values.first(where: { $0.pendingCaptureID == pending.id }) {
            owner.retrySave()
            return
        }
        if let owner = gaussianControllers.values.first(where: { $0.pendingCaptureID == pending.id }) {
            owner.retrySave()
            return
        }
        let id = activeID
        Task {
            if let saved = await library.save(pending) {
                if let id { update(id) { $0.resultID = saved.id; $0.state = "Completado"; $0.progress = 1; $0.status = "Modelo y originales guardados" } }
                else if let original = pending.sourceScanID, let source = jobs.first(where: { $0.resultID == original }) {
                    let derived = DesktopJob(id: UUID(), sourcePath: source.sourcePath, duration: source.duration,
                        title: "Textura IA · " + source.title, state: "Completado", progress: 1,
                        status: "Restauración Core ML local; original conservado", resultID: saved.id)
                    jobs.append(derived); selectedID = derived.id
                }
                else if let source = jobs.first(where: { URL(fileURLWithPath: $0.sourcePath).appendingPathComponent("dataset").standardizedFileURL == pending.captureDatasetURL?.standardizedFileURL }) {
                    let derived = DesktopJob(id: UUID(), sourcePath: source.sourcePath, duration: source.duration,
                        title: "Fotogrametría · " + source.title, state: "Completado", progress: 1, status: "Modelo fotográfico guardado", resultID: saved.id)
                    jobs.append(derived); selectedID = derived.id
                }
                if let work = pending.cleanupDirectory, work.standardizedFileURL.path.hasPrefix(root.appendingPathComponent("Work").standardizedFileURL.path + "/") {
                    try? FileManager.default.removeItem(at: work)
                }
                activeID = nil; persist(); next()
            } else { error = library.error }
        }
    }
    private func updateActivity(working: Bool) {
        if working, activity == nil { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Procesamiento local de Forma") }
        else if !working, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func synchronizeSavingState() {
        objectWillChange.send()
        guard library.isSaving else {
            savingPauseIntents.removeAll()
            if active == nil && !photogrammetryBusy && !localAIBusy && !gaussianBusy { updateActivity(working: false) }
            return
        }
        for (id, controller) in gaussianControllers where controller.saving && ownsCurrentSaving(id) {
            do { try synchronizeRemoteSavingRevision(for: id) }
            catch { self.error = "No se pudo registrar el control del guardado Gaussian actual." }
        }
        let state = library.savingState
        updateActivity(working: state.phase == .running || state.phase == .pauseRequested)
        if let id = activeID {
            do { try synchronizeRemoteSavingRevision(for: id) }
            catch { self.error = "No se pudo registrar el cambio manual del guardado; los controles remotos necesitan revisión." }
            update(id) {
                $0.status = library.savingStage
                if library.savingTotalBytes > 0 { $0.progress = Double(library.savingCompletedBytes)/Double(library.savingTotalBytes) }
                if state.phase == .paused { $0.state = "Pausado" }
                else if state.phase == .pauseRequested { $0.state = "Pausando" }
                else { $0.state = "Procesando" }
            }
        }
    }
    private func next() {
        guard active == nil, !photogrammetryBusy, !localAIBusy, !gaussianBusy, !library.isSaving, library.pendingCapture == nil else { return }
        // Reconnect existing independent workers before starting recovered IA.
        while !recoveringGaussian.isEmpty {
            let id = recoveringGaussian.removeFirst()
            guard let job = jobs.first(where: { $0.id == id }) else { continue }
            let controller = gaussianController(for: job)
            controller.resumeExisting()
            synchronizeGaussianState(for: id)
            if controller.busy { activeID = id; return }
            if !controller.notice.isEmpty { error = "El trabajo Gaussian se conserva. " + controller.notice }
        }
        while !recoveringLocalAI.isEmpty {
            let sourceID = recoveringLocalAI.removeFirst()
            guard let sourceJob = jobs.first(where: { $0.resultID == sourceID }),
                  let controller = localAIController(for: sourceJob), controller.shouldResumeAutomatically else { continue }
            controller.start()
            if controller.busy { return }
            error = "El trabajo IA se conserva, pero no pudo reanudarse: " + controller.notice
        }
        guard let job = jobs.first(where: { $0.state == "En cola" }) else { return }
        if job.processingRequest?.kind == .gaussian {
            startQueuedGaussian(job)
            return
        }
        activeID = job.id; stateRevision = 0
        let id = job.id
        gate = ProcessingControl { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.activeID == id, snapshot.revision >= self.stateRevision else { return }
                self.stateRevision = snapshot.revision
                self.updateActivity(working: snapshot.phase == .running || snapshot.phase == .pauseRequested)
                self.update(id) {
                    switch snapshot.phase {
                    case .pauseRequested: $0.state = "Pausando"; $0.status = "Esperando un punto seguro del procesamiento"
                    case .paused: $0.state = "Pausado"; $0.status = "Pausa confirmada; fuentes y trabajo en memoria conservados"
                    case .running: $0.state = "Procesando"
                    case .cancelled: $0.status = "Cancelando y limpiando la versión de trabajo"
                    }
                }
            }
        }
        let control = gate!
        updateActivity(working: true)
        update(id) { $0.state = "Procesando"; $0.progress = 0; $0.status = "Preparando una copia de trabajo" }
        let work = root.appendingPathComponent("Work/\(id.uuidString)-\(UUID().uuidString)")
        active = Task { [self] in
            var preserveWork = false
            defer {
                if !preserveWork { try? FileManager.default.removeItem(at: work) }
                active = nil; gate = nil
                updateActivity(working: false)
                if library.pendingCapture == nil { activeID = nil }
                persist(); next()
            }
            do {
                let source = URL(fileURLWithPath: job.sourcePath, isDirectory: true)
                let copy = Task.detached(priority: .userInitiated) {
                    try control.checkpoint()
                    try FileManager.default.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ProcessingControl.withControl(control) { try CooperativeFileIO.copyDirectory(source, to: work) }
                    try control.checkpoint()
                    return try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: work.appendingPathComponent("malla-original.json")))
                }
                let mesh = try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel(); control.cancel() })
                let result = try await LiDARProcessingPipeline.process(mesh: mesh, datasetDirectory: work.appendingPathComponent("dataset"),
                    duration: job.duration, mode: .lidar, control: control) { [weak self] title, progress in
                    Task { @MainActor in self?.update(id) { $0.progress = progress; if $0.state == "Procesando" { $0.status = title } } }
                }
                try Task.checkCancellation()
                update(id) { $0.status = "Guardando paquete, fuentes y huellas de integridad" }
                if let saved = await library.save(result) {
                    update(id) { $0.resultID = saved.id; $0.state = "Completado"; $0.progress = 1; $0.status = "Modelo y originales guardados" }
                } else {
                    preserveWork = true
                    update(id) { $0.state = "Guardado pendiente"; $0.status = library.error ?? "Conservado para reintentar" }
                }
            } catch is CancellationError { update(id) { $0.state = "Cancelado"; $0.status = "Las fuentes originales siguen disponibles; puedes reiniciar" } }
            catch { update(id) { $0.state = "Error"; $0.status = error.localizedDescription } }
        }
    }

    private var remoteStatusProvider: @Sendable (UUID) async throws -> HybridTransfer.RemoteJobStatus {
        { [weak self] id in
            guard let self else { throw RGBDDatasetError.invalid("Forma Desktop no está disponible.") }
            return await self.remoteStatus(for: id)
        }
    }

    private var remoteCommandProvider: HybridTransfer.CommandProvider {
        { [weak self] command in
            guard let self else { throw RGBDDatasetError.invalid("Forma Desktop no está disponible.") }
            return try await self.remoteCommand(command)
        }
    }
    private var remoteResultProvider: HybridTransfer.ResultProvider {
        { [weak self] id in
            guard let self else { throw RGBDDatasetError.invalid("Forma Desktop no está disponible.") }
            return try await self.remoteResult(for: id)
        }
    }

    func remoteStatus(for id: UUID) -> HybridTransfer.RemoteJobStatus {
        var status = remoteStatusSnapshot(for: id)
        guard jobs.contains(where: { $0.id == id }) else { status.supportedCommands = []; return status }
        do {
            try synchronizeRemoteSavingRevision(for: id)
            status.controlRevision = try remoteControlLedger.revision(for: id)
            status.supportedCommands = supportedRemoteCommands(for: id)
            if try remoteControlLedger.hasUncertainCommand(for: id) {
                status.error = "Un control remoto quedó incierto al interrumpirse la Mac; no se repetirá automáticamente. Consulta su recibo antes de enviar una nueva acción."
            }
        } catch {
            status.supportedCommands = []
            status.error = "El registro de controles necesita revisión en la Mac; no se admiten acciones hasta resolverlo."
        }
        return status
    }

    private func hasConfiguredGaussianExecution(for job: DesktopJob) -> Bool {
        gaussianControllers[job.id]?.hasWorkspace == true || FileManager.default.fileExists(atPath:
            root.appendingPathComponent("Work/Gaussian-\(job.id.uuidString)/config.json").path)
    }

    private func currentGaussianExecution(for job: DesktopJob) -> DesktopGaussian? {
        guard hasConfiguredGaussianExecution(for: job) else { return nil }
        // Constructing/inspecting a controller reads metadata only. Recovery polling
        // owns process launch and publication; a status request never starts either.
        let controller = gaussianController(for: job)
        guard controller.hasWorkspace else { return nil }
        controller.inspectCurrentExecution()
        return controller
    }

    private func ownsCurrentSaving(_ id: UUID) -> Bool {
        guard library.isSaving else { return false }
        if activeID == id { return true }
        guard let controller = gaussianControllers[id], controller.saving,
              let capture = controller.pendingCaptureID else { return false }
        return capture == library.pendingCapture?.id
    }

    private func synchronizeRemoteSavingRevision(for id: UUID) throws {
        guard ownsCurrentSaving(id) else { savingPauseIntents[id] = nil; return }
        let paused = library.savingState.isPauseActive
        if paused != (savingPauseIntents[id] ?? false) {
            try remoteControlLedger.noteHumanIntent(for: id)
        }
        savingPauseIntents[id] = paused
    }

    private func supportedRemoteCommands(for id: UUID) -> [HybridTransfer.RemoteJobCommand.Action] {
        guard let job = jobs.first(where: { $0.id == id }) else { return [] }
        let controller = currentGaussianExecution(for: job)
        if controller?.publishedCurrentResult != nil { return [] }
        if controller == nil, job.resultID != nil { return [] }
        if hasConfiguredGaussianExecution(for: job), controller == nil { return [] }
        if library.isSaving {
            guard ownsCurrentSaving(id) else { return [] }
            return library.savingState.isPauseActive ? [.resume, .cancel] : [.pause, .cancel]
        }
        if activeID == id, gate != nil {
            return ["Pausado", "Pausando"].contains(job.state) ? [.resume, .cancel] : [.pause, .cancel]
        }
        if let controller {
            if controller.saving { return [] }
            if controller.busy || controller.hasLiveWorker {
                return controller.isPaused ? [.resume, .cancel, .export] : [.pause, .cancel, .export]
            }
            if controller.phase == "completed" { return [.export] }
            return [.resume]
        }
        if ["En cola", "Procesando"].contains(job.state) { return [.pause, .cancel] }
        return [.resume, .cancel]
    }

    func remoteCommand(_ command: HybridTransfer.RemoteJobCommand) throws -> HybridTransfer.RemoteCommandReply {
        // Saving controls also exist outside Store (the library's global panel).
        // Read that intent synchronously before a remote claim, so an observer task
        // queued behind this command cannot let a stale resume win a human pause.
        try synchronizeRemoteSavingRevision(for: command.jobID)
        let job = jobs.first { $0.id == command.jobID }
        let rejection = job == nil ? "No se encontró ese trabajo en Forma Desktop." :
            (supportedRemoteCommands(for: command.jobID).contains(command.action) ? nil :
                "Esa acción no está disponible para el estado actual de este trabajo.")
        let claim = try remoteControlLedger.claim(command, rejection: rejection)
        switch claim {
        case .recorded(let outcome):
            return .init(commandID: command.id, jobID: command.jobID, state: outcome.state,
                         status: remoteStatus(for: command.jobID), error: outcome.error)
        case .dispatch:
            let outcome: DesktopRemoteControlLedger.Outcome
            do {
                try dispatchRemoteCommand(command)
                outcome = .init(state: "accepted", error: nil)
            } catch {
                // Effects may have reached the worker before an I/O error. A retry must
                // never repeat this command, particularly resume after a later pause.
                outcome = .init(state: "uncertain", error: "No se pudo confirmar el control. Consulta el estado en la Mac antes de enviar una nueva acción.")
            }
            do { try remoteControlLedger.finish(command, outcome: outcome) }
            catch {
                return .init(commandID: command.id, jobID: command.jobID, state: "uncertain",
                             status: remoteStatus(for: command.jobID), error: "El registro final del comando no pudo confirmarse. No se repetirá automáticamente.")
            }
            return .init(commandID: command.id, jobID: command.jobID, state: outcome.state,
                         status: remoteStatus(for: command.jobID), error: outcome.error)
        }
    }

    private func dispatchRemoteCommand(_ command: HybridTransfer.RemoteJobCommand) throws {
        guard let index = jobs.firstIndex(where: { $0.id == command.jobID }) else {
            throw RGBDDatasetError.invalid("El trabajo ya no está disponible para control.")
        }
        let id = command.jobID
        let current = currentGaussianExecution(for: jobs[index])
        guard current?.publishedCurrentResult == nil, current != nil || jobs[index].resultID == nil else {
            throw RGBDDatasetError.invalid("La ejecución ya terminó; su resultado se conserva.")
        }
        if library.isSaving {
            guard ownsCurrentSaving(id) else { throw RGBDDatasetError.invalid("El guardado pertenece a otro trabajo.") }
            switch command.action {
            case .pause: library.pauseSaving()
            case .resume: if library.savingState.isPauseActive { library.toggleSavingPause() }
            case .cancel: library.cancelSaving()
            case .export: throw RGBDDatasetError.invalid("El resultado ya se está guardando.")
            }
            return
        }
        if activeID == id, let gate {
            switch command.action {
            case .pause:
                jobs[index].state = "Pausando"; try persistDurably(); _ = gate.requestPause()
            case .resume: _ = gate.resume()
            case .cancel: gate.cancel(); active?.cancel()
            case .export: throw RGBDDatasetError.invalid("La preparación todavía no produjo un entrenamiento.")
            }
            return
        }
        if let controller = current {
            switch command.action {
            case .resume: controller.start(isUserInitiated: false)
            case .export:
                if controller.phase == "completed" { controller.retrySave() }
                else { controller.command("export", isUserInitiated: false) }
            case .pause: controller.command("pause", isUserInitiated: false)
            case .cancel: controller.command("cancel", isUserInitiated: false)
            }
            // DesktopGaussian exposes synchronous submission failures as notice.
            // Never acknowledge a failed append/launch as an accepted dispatch.
            if !controller.notice.isEmpty, !(command.action == .export && controller.phase == "completed") {
                throw RGBDDatasetError.invalid("El motor no confirmó el envío del control; su estado se conserva.")
            }
            synchronizeGaussianState(for: id); return
        }
        switch command.action {
        case .pause: jobs[index].state = "Pausado"; jobs[index].status = "Pausa remota conservada; fuentes originales disponibles"
        case .resume:
            jobs[index].state = "En cola"
            jobs[index].status = "Esperando turno de procesamiento; fuentes originales conservadas"
        case .cancel: jobs[index].state = "Cancelado"; jobs[index].status = "Cancelado desde el iPhone; fuentes originales conservadas"
        case .export: throw RGBDDatasetError.invalid("Este trabajo no tiene un entrenamiento Gaussian exportable.")
        }
        try persistDurably(); next()
    }

    func remoteResult(for id: UUID) async throws -> HybridTransfer.ResultSource {
        guard let job = jobs.first(where: { $0.id == id }) else {
            throw HybridTransfer.TransferError.failed("No se encontró ese trabajo en Forma Desktop.")
        }
        let current = currentGaussianExecution(for: job)
        let record: ScanRecord
        if hasConfiguredGaussianExecution(for: job) {
            guard let published = current?.publishedCurrentResult,
                  library.scans.contains(where: { $0.id == published.id }) else {
                throw HybridTransfer.TransferError.failed("La ejecución Gaussian actual todavía no tiene un resultado completo publicado. El resultado anterior se conserva en la biblioteca.")
            }
            record = published
        } else {
            guard let published = self.record(job), job.state == "Completado", job.progress == 1 else {
                throw HybridTransfer.TransferError.failed("Este trabajo todavía no tiene un resultado completo publicado.")
            }
            record = published
        }
        let expectedExecution = current?.currentExecutionID
        let folder = library.directory(for: record)
        let libraryRoot = root.appendingPathComponent("Library")
        let cache = root.appendingPathComponent("RemoteResults")
        let existing = remoteResultPreparations[record.id]
        let task = existing ?? Task.detached(priority: .userInitiated) {
            try DesktopHybridResultPackage.prepare(jobID: id, record: record,
                libraryDirectory: folder, libraryRoot: libraryRoot, cacheRoot: cache)
        }
        if existing == nil { remoteResultPreparations[record.id] = task }
        defer { if existing == nil { remoteResultPreparations[record.id] = nil } }
        do {
            let result = try await task.value
            let latest = currentGaussianExecution(for: job)
            let samePublication: Bool
            if let expectedExecution {
                samePublication = latest?.currentExecutionID == expectedExecution && latest?.publishedCurrentResult?.id == record.id
            } else {
                samePublication = !hasConfiguredGaussianExecution(for: job) && self.record(job)?.id == record.id
            }
            guard samePublication else {
                throw HybridTransfer.TransferError.failed("La ejecución cambió mientras se preparaba el paquete. Actualiza el estado antes de descargar su resultado.")
            }
            return result
        } catch {
            self.error = "No se pudo preparar el resultado remoto; el original se conserva. " + error.localizedDescription
            throw HybridTransfer.TransferError.failed("No se pudo preparar un resultado completo de la ejecución actual. Revisa Forma Desktop; las publicaciones anteriores se conservan.")
        }
    }

    private func persistDurably() throws {
        try DesktopRemoteControlLedger.writeDurably(JSONEncoder().encode(jobs), to: root.appendingPathComponent("jobs.json"))
    }

    private func remoteStatusSnapshot(for id: UUID) -> HybridTransfer.RemoteJobStatus {
        guard let job = jobs.first(where: { $0.id == id }) else {
            return .init(id: id, state: "unknown", progress: 0, resultAvailable: false,
                         error: "El trabajo todavía no figura en la cola de Forma Desktop.")
        }
        let controller = currentGaussianExecution(for: job)
        if hasConfiguredGaussianExecution(for: job), controller == nil {
            return .init(id: id, state: "interrupted", progress: 0, resultAvailable: false,
                         error: "La configuración de la ejecución actual necesita revisión; las publicaciones anteriores se conservan.")
        }
        if let current = controller?.publishedCurrentResult {
            return .init(id: id, state: "completed", progress: 1,
                         iteration: current.statistics?["steps"].flatMap { Int(exactly: $0) },
                         targetIterations: controller?.currentTargetIterations,
                         splats: current.statistics?["splats"].flatMap { Int(exactly: $0) }, resultAvailable: true)
        }
        if ownsCurrentSaving(id) {
            let phase = library.savingState.phase
            let state = phase == .paused ? "paused" : phase == .pauseRequested ? "pausing" : "saving"
            let progress = library.savingTotalBytes > 0 ? Double(library.savingCompletedBytes) / Double(library.savingTotalBytes) : 0
            return .init(id: id, state: state, progress: min(1, max(0, progress)),
                         iteration: controller?.iteration, targetIterations: controller?.currentTargetIterations ?? job.processingRequest?.iterations,
                         splats: controller?.splats, resultAvailable: false)
        }
        if let controller {
            let state: String
            if controller.saving { state = "saving" }
            else if controller.phase == "completed" { state = "awaiting-save" }
            else if controller.phase == "settings" { state = "interrupted" }
            else if !controller.busy, !controller.hasLiveWorker, ["preparing", "running", "checkpointing", "exporting"].contains(controller.phase) { state = "interrupted" }
            else { state = controller.phase }
            return .init(id: id, state: state, progress: controller.progress,
                         iteration: controller.iteration, targetIterations: controller.currentTargetIterations, splats: controller.splats,
                         resultAvailable: false, error: ["failed", "interrupted", "awaiting-save"].contains(state)
                            ? "La ejecución actual necesita revisión; sus checkpoints y las publicaciones anteriores se conservan." : nil)
        }
        if let record = record(job) {
            return .init(id: id, state: "completed", progress: 1,
                         iteration: record.statistics?["steps"].flatMap { Int(exactly: $0) },
                         targetIterations: job.processingRequest?.iterations,
                         splats: record.statistics?["splats"].flatMap { Int(exactly: $0) }, resultAvailable: true)
        }
        let states = ["En cola": "queued", "Procesando": "running", "Pausando": "pausing", "Pausado": "paused",
                      "Guardado pendiente": "awaiting-save", "Interrumpido": "interrupted", "Cancelado": "cancelled", "Error": "failed"]
        return .init(id: id, state: states[job.state] ?? "interrupted", progress: job.progress,
                     targetIterations: job.processingRequest?.iterations, resultAvailable: false,
                     error: ["Error", "Interrumpido", "Guardado pendiente"].contains(job.state)
                        ? "El trabajo necesita revisión en Forma Desktop; sus fuentes se conservan." : nil)
    }

    private func readProcessingRequest(in directory: URL) throws -> HybridTransfer.ProcessingRequest? {
        let url = directory.appendingPathComponent("procesamiento.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RGBDDatasetError.invalid("La solicitud de procesamiento no es un archivo regular.")
        }
        let request = try JSONDecoder().decode(HybridTransfer.ProcessingRequest.self, from: Data(contentsOf: url))
        try request.validate()
        return request
    }

    private func gaussianInputSource(for job: DesktopJob) -> URL {
        root.appendingPathComponent("Work/HybridGaussian-\(job.id.uuidString)/source")
    }
    private func preparedGaussianSource(for job: DesktopJob) -> URL? {
        let source = gaussianInputSource(for: job)
        let marker = source.appendingPathComponent(".gaussian-input.json")
        guard let bytes = try? Data(contentsOf: marker),
              let value = try? JSONDecoder().decode(GaussianInputMarker.self, from: bytes),
              value.jobID == job.id, value.schemaVersion == 1 else { return nil }
        return source
    }
    private struct GaussianInputMarker: Codable { var schemaVersion = 1; var jobID: UUID }

    private func startQueuedGaussian(_ job: DesktopJob) {
        if preparedGaussianSource(for: job) != nil { launchQueuedGaussian(job); return }
        activeID = job.id; stateRevision = 0
        let id = job.id
        let control = ProcessingControl { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.activeID == id, snapshot.revision >= self.stateRevision else { return }
                self.stateRevision = snapshot.revision
                self.updateActivity(working: snapshot.phase == .running || snapshot.phase == .pauseRequested)
                self.update(id) {
                    if snapshot.phase == .paused { $0.state = "Pausado" }
                    else if snapshot.phase == .pauseRequested { $0.state = "Pausando" }
                    else if snapshot.phase == .running { $0.state = "Procesando" }
                }
                self.persist()
            }
        }
        gate = control
        update(id) { $0.state = "Procesando"; $0.status = "Preparando cámaras y semillas Gaussian en una copia local"; $0.progress = 0 }
        persist(); updateActivity(working: true)
        let source = URL(fileURLWithPath: job.sourcePath, isDirectory: true)
        let parent = root.appendingPathComponent("Work/HybridGaussian-\(id.uuidString)")
        active = Task { [self] in
            var prepared = false
            do {
                let copy = Task.detached(priority: .userInitiated) {
                    try ProcessingControl.withControl(control) {
                        let fm = FileManager.default
                        let destination = parent.appendingPathComponent("source")
                        guard !fm.fileExists(atPath: destination.path) else {
                            throw RGBDDatasetError.invalid("La copia Gaussian existente necesita revisión; se conservó sin sobrescribir.")
                        }
                        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                        let stage = parent.appendingPathComponent(".preparing-\(UUID().uuidString)")
                        defer { try? fm.removeItem(at: stage) }
                        try CooperativeFileIO.copyDirectory(source, to: stage)
                        let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: stage.appendingPathComponent("malla-original.json")))
                        try COLMAPDatasetExporter.prepare(datasetDirectory: stage.appendingPathComponent("dataset"), mesh: mesh)
                        try control.checkpoint()
                        try JSONEncoder().encode(GaussianInputMarker(jobID: id)).write(to: stage.appendingPathComponent(".gaussian-input.json"), options: .atomic)
                        try fm.moveItem(at: stage, to: destination)
                    }
                }
                try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel(); control.cancel() })
                // Copy completion and its final CPU checkpoint can race a human
                // pause queued on the main actor. Confirm that pause before the
                // synchronous handoff; resuming this gate never starts a second job.
                while control.snapshot.isPauseActive {
                    let waiting = Task.detached(priority: .utility) { try control.checkpoint() }
                    try await withTaskCancellationHandler(operation: { try await waiting.value }, onCancel: { waiting.cancel(); control.cancel() })
                }
                try Task.checkCancellation()
                if control.snapshot.phase == .cancelled { throw CancellationError() }
                prepared = true
            } catch is CancellationError {
                update(id) { $0.state = "Cancelado"; $0.status = "Fuentes conservadas; puedes volver a iniciar Gaussian" }
            } catch {
                update(id) { $0.state = "Error"; $0.status = error.localizedDescription }
            }
            active = nil; gate = nil; updateActivity(working: false)
            if prepared { launchQueuedGaussian(job) } else { activeID = nil; persist(); next() }
        }
    }

    private func launchQueuedGaussian(_ job: DesktopJob) {
        activeID = job.id
        let controller = gaussianController(for: job)
        controller.start(isUserInitiated: false)
        synchronizeGaussianState(for: job.id)
        if !controller.busy {
            update(job.id) { $0.state = "Error"; $0.status = controller.notice.isEmpty ? "El motor Gaussian no pudo iniciar; fuentes conservadas" : controller.notice }
            activeID = nil; persist(); next()
        }
    }

    private func synchronizeGaussianState(for id: UUID) {
        guard let controller = gaussianControllers[id], let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].processingRequest?.kind == .gaussian, jobs[index].resultID == nil else { return }
        let state: String
        if controller.saving { state = "Procesando" }
        else if !controller.busy, ["preparing", "running", "checkpointing"].contains(controller.phase) { state = "Interrumpido" }
        else {
            switch controller.phase {
            case "paused": state = "Pausado"
            case "pausing": state = "Pausando"
            case "cancelled", "cancelling": state = "Cancelado"
            case "failed": state = "Error"
            case "completed": state = "Guardado pendiente"
            case "settings": return
            default: state = "Procesando"
            }
        }
        let status = controller.notice.isEmpty ? controller.state : controller.notice
        guard jobs[index].state != state || jobs[index].progress != controller.progress || jobs[index].status != status else { return }
        jobs[index].state = state; jobs[index].progress = controller.progress; jobs[index].status = status
        persist()
    }

    private func registerGaussianResult(_ record: ScanRecord, sourceJob: DesktopJob) {
        if let existing = jobs.first(where: { $0.resultID == record.id }) { selectedID = existing.id; return }
        if let index = jobs.firstIndex(where: { $0.id == sourceJob.id }),
           jobs[index].processingRequest?.kind == .gaussian, jobs[index].resultID == nil {
            jobs[index].resultID = record.id; jobs[index].state = "Completado"; jobs[index].progress = 1
            jobs[index].status = "Gaussian Splatting guardado; fuentes originales conservadas"
            selectedID = sourceJob.id; persist(); return
        }
        let derived = DesktopJob(id: UUID(), sourcePath: sourceJob.sourcePath, duration: sourceJob.duration,
            title: "Gaussian · " + sourceJob.title, state: "Completado", progress: 1,
            status: "Gaussian Splatting local; fuentes originales conservadas", resultID: record.id)
        jobs.append(derived); selectedID = derived.id; persist()
    }

    private func update(_ id: UUID, _ change: (inout DesktopJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; change(&jobs[index])
    }
    private func registerAIResult(_ record: ScanRecord, sourceJob: DesktopJob) {
        if let existing = jobs.first(where: { $0.resultID == record.id }) { selectedID = existing.id; return }
        let derived = DesktopJob(id: UUID(), sourcePath: sourceJob.sourcePath, duration: sourceJob.duration,
            title: "Textura IA · " + sourceJob.title, state: "Completado", progress: 1,
            status: "Restauración Core ML local; original conservado", resultID: record.id)
        jobs.append(derived); selectedID = derived.id; persist()
    }

    private func restoreLocalAIJobs() {
        // Close the crash window between library publication and jobs.json.
        for record in library.scans where !jobs.contains(where: { $0.resultID == record.id }) {
            guard let owner = DesktopLocalAIRecovery.publishedJob(in: library.directory(for: record), record: record),
                  let source = jobs.first(where: { $0.resultID == owner.sourceID }) else { continue }
            registerAIResult(record, sourceJob: source)
        }
        let discovered = DesktopLocalAIRecovery.discover(root: root)
        var failures = discovered.failures
        for var job in discovered.jobs {
            if let published = library.scans.first(where: { record in
                DesktopLocalAIRecovery.publishedJob(in: library.directory(for: record), record: record)?.id == job.id
            }) {
                job.state = .completed; job.resultID = published.id
                do { try DesktopLocalAIRecovery.save(job, root: root); try DesktopLocalAIRecovery.removeCompleted(job, root: root) }
                catch { failures.append(error.localizedDescription) }
                continue
            }
            guard library.scans.contains(where: { $0.id == job.sourceID }), jobs.contains(where: { $0.resultID == job.sourceID }) else {
                failures.append("Falta la captura original del trabajo IA \(job.id.uuidString). Se conserva su workspace.")
                continue
            }
            if job.shouldResumeAutomatically { recoveringLocalAI.append(job.sourceID) }
            else if job.state == .failed { failures.append(job.error ?? "Un trabajo IA conservado necesita revisión.") }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(jobs).write(to: root.appendingPathComponent("jobs.json"), options: .atomic)
        } catch { self.error = "No se pudo guardar la cola: \(error.localizedDescription)" }
    }
}
