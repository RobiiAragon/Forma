import AppKit
import SwiftUI

@MainActor
final class DesktopLocalAI: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var state = "Listo para crear una copia con textura restaurada"
    @Published private(set) var notice = ""
    @Published private(set) var pauseState: ProcessingControl.Phase = .running
    @Published private(set) var saved: ScanRecord?
    @Published private(set) var isSavingOwnResult = false
    @Published private(set) var hasRecoverableWork = false
    @Published var strength = 0.35
    let models: LocalAIModelStore
    let library: ScanStore
    private let record: ScanRecord
    private let root: URL
    private let setBusy: (Bool) -> Void
    private let setWorking: (Bool) -> Void
    private let canStart: () -> Bool
    private let onSave: (ScanRecord) -> Void
    private let onIssue: (String) -> Void
    private var task: Task<Void, Never>?
    private var control: ProcessingControl?
    private var revision: UInt64 = 0
    private var pendingResult: CaptureResult?
    private var generation = UUID()
    private var recoveryJob: DesktopLocalAIRecovery.Job?
    private var recoveryLoadFailed = false
    private var lastProgressPersist = 0.0
    private var savingRevision: UInt64 = 0
    var canRetrySave: Bool { pendingResult != nil }
    var pendingCaptureID: UUID? { pendingResult?.id }
    var shouldResumeAutomatically: Bool { !recoveryLoadFailed && recoveryJob?.shouldResumeAutomatically == true }
    private var workspace: URL { DesktopLocalAIRecovery.workspace(root: root, sourceID: record.id) }

    init(record: ScanRecord, library: ScanStore, root: URL, models: LocalAIModelStore,
         canStart: @escaping () -> Bool, setBusy: @escaping (Bool) -> Void,
         setWorking: @escaping (Bool) -> Void, onSave: @escaping (ScanRecord) -> Void,
         onIssue: @escaping (String) -> Void = { _ in }) {
        self.record = record; self.library = library; self.root = root; self.models = models
        self.setBusy = setBusy; self.onSave = onSave; self.onIssue = onIssue
        self.canStart = canStart; self.setWorking = setWorking
        do {
            if let job = try DesktopLocalAIRecovery.load(root: root, sourceID: record.id) {
                recoveryJob = job; strength = job.strength; progress = job.progress; hasRecoverableWork = true
                state = job.state == .manualPaused ? "Pausa manual conservada" : "Trabajo IA conservado en esta Mac"
                if job.state == .manualPaused { pauseState = .paused }
                notice = job.error ?? "Se conserva la intensidad y el avance de las texturas completas."
            }
        } catch {
            recoveryLoadFailed = true; notice = error.localizedDescription
            state = "El trabajo conservado necesita revisión; sus archivos no se han borrado"
            onIssue(notice)
        }
    }

    func start() {
        guard !busy, !recoveryLoadFailed, saved == nil, pendingResult == nil else { return }
        guard let model = models.modelURL else { notice = "Falta el modelo local; instala los mismos pesos antes de continuar."; return }
        guard let source = library.modelURL(for: record), LocalAIModelRestoration.supports(source) else {
            notice = "No se encuentra un OBJ o USDZ de la captura de origen. El trabajo se conserva."; return
        }
        guard canStart() else { notice = "Espera a que termine el trabajo activo o resuelve su guardado pendiente antes de iniciar la IA."; return }
        var job = recoveryJob ?? .init(id: UUID(), sourceID: record.id, strength: strength)
        strength = job.strength; job.state = .running; job.error = nil; job.updatedAt = Date()
        do { try DesktopLocalAIRecovery.save(job, root: root) }
        catch { notice = error.localizedDescription; return }
        recoveryJob = job; hasRecoverableWork = true
        busy = true; setBusy(true); progress = job.progress; notice = ""; revision = 0
        pauseState = .running; state = "Preparando restaurador Core ML local…"
        let run = UUID(); generation = run
        let gate = ProcessingControl { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.busy, self.generation == run, !self.isSavingOwnResult,
                      snapshot.revision >= self.revision else { return }
                self.revision = snapshot.revision; self.pauseState = snapshot.phase
                self.setWorking(snapshot.phase == .running || snapshot.phase == .pauseRequested)
                if snapshot.phase == .paused { self.persistState(.manualPaused) }
            }
        }
        control = gate
        let work = workspace, amount = strength
        let package = work.appendingPathComponent("modelo", isDirectory: true)
        let meshURL = library.directory(for: record).appendingPathComponent("malla.json")
        task = Task {
            defer {
                busy = false; isSavingOwnResult = false; task = nil; control = nil
                setWorking(false); setBusy(false)
            }
            do {
                let worker = Task.detached(priority: .userInitiated) { [weak self] in
                  try ProcessingControl.withControl(gate) {
                    try DesktopLocalAIRecovery.bindInputs(work: work, source: source.deletingLastPathComponent(), model: model)
                    let report: LocalAITextureEnhancer.Report
                    if let ready = try DesktopLocalAIRecovery.restoredReport(work: work, package: package, sourceModel: source) {
                        report = ready
                    } else {
                        report = try LocalAIModelRestoration.run(model: source, output: package,
                            restorer: model, strength: amount, control: gate,
                            checkpointDirectory: work.appendingPathComponent("checkpoint", isDirectory: true)) { label, fraction in
                            Task { @MainActor in
                                guard let self, self.busy, self.generation == run,
                                      self.pendingResult == nil, self.saved == nil, !self.isSavingOwnResult,
                                      fraction.isFinite else { return }
                                self.state = label; self.progress = max(self.progress, fraction)
                                if ProcessInfo.processInfo.systemUptime - self.lastProgressPersist > 1 {
                                    self.lastProgressPersist = ProcessInfo.processInfo.systemUptime
                                    self.persistProgress()
                                }
                            }
                        }
                        try DesktopLocalAIRecovery.commitResult(work: work, package: package)
                    }
                    try gate.checkpoint()
                    let reportURL = work.appendingPathComponent("informe-ia.json")
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(report).write(to: reportURL, options: .atomic)
                    let mesh = FileManager.default.fileExists(atPath: meshURL.path)
                        ? try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: meshURL)) : nil
                    try gate.checkpoint()
                    return (report, reportURL, mesh)
                  }
                }
                let (report, reportURL, mesh) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { gate.cancel(); worker.cancel() })
                try Task.checkCancellation()
                guard report.changedPixels > 0 else {
                    state = "No se creó una copia sin cambios"
                    notice = "Esta captura no tiene suficientes interiores de textura para aplicar el modelo sin cruzar sus costuras. El original se conserva."
                    persistState(.stopped); return
                }
                let coverage = report.totalTexturePixels > 0 ? Double(report.eligiblePixels) / Double(report.totalTexturePixels) : 0
                let observedCoverage = report.observedUVPixels > 0 ? Double(report.eligiblePixels) / Double(report.observedUVPixels) : 0
                var statistics = record.statistics ?? [:]
                statistics.merge(["localAITextureRestoration": 1, "localAIStrength": amount,
                    "localAIEligibleCoverage": coverage, "localAIChangedPixels": Double(report.changedPixels),
                    "localAITiles": Double(report.inferenceTileCount), "localAISeconds": report.totalSeconds,
                    "localAIObservedCoverage": observedCoverage, "localAIObservedUVPixels": Double(report.observedUVPixels),
                    "localAIIslands": Double(report.islandCount)]) { _, new in new }
                pendingResult = CaptureResult(mesh: mesh, modelURL: report.modelURL,
                    auxiliaryURLs: [reportURL, work.appendingPathComponent(DesktopLocalAIRecovery.metadataName)], mode: record.mode,
                    duration: record.duration, note: "Restauración local de texturas con Real-ESRGAN y Core ML. Intensidad \(Int(amount*100)) %. Conserva geometría, UV y resolución nativa; la IA infiere apariencia, no añade mediciones. Bordes y costuras protegidos. Fotografías y captura de origen conservadas en \(record.id).",
                    cleanupDirectory: work, modelPackageURL: report.packageURL,
                    statistics: statistics, sourceScanID: record.id,
                    modelGeometryCounts: ModelGeometryCounts(vertexCount: record.vertexCount, faceCount: record.faceCount))
                await savePending()
            } catch {
                state = error is CancellationError ? "Detenido; texturas completas y original conservados" : "No se completó la restauración"
                if !(error is CancellationError) { notice = error.localizedDescription }
                persistState(error is CancellationError ? .stopped : .failed, error: error is CancellationError ? nil : error.localizedDescription)
                if !(error is CancellationError) { onIssue(notice) }
            }
        }
    }

    func togglePause() {
        if isSavingOwnResult, library.isSaving {
            library.toggleSavingPause()
            persistState(library.savingState.isPauseActive ? .manualPaused : .saving)
            return
        }
        guard let control else { return }
        let next: ProcessingControl.Snapshot
        if control.snapshot.isPauseActive { persistState(.running); next = control.resume() }
        else { persistState(.manualPaused); next = control.requestPause() }
        revision = next.revision; pauseState = next.phase
    }
    func cancel() {
        guard busy else { return }
        persistState(.stopped)
        if library.isSaving, let own = pendingResult, library.pendingCapture?.id == own.id { library.cancelSaving() }
        if let next = control?.cancel() { revision = next.revision; pauseState = next.phase }
        task?.cancel()
    }
    func retrySave() {
        guard pendingResult != nil, !busy else { return }
        generation = UUID(); busy = true; setBusy(true)
        task = Task {
            defer { busy = false; isSavingOwnResult = false; task = nil; setWorking(false); setBusy(false) }
            await savePending()
        }
    }

    private func savePending() async {
        guard let result = pendingResult else { return }
        guard !library.isSaving, library.pendingCapture == nil || library.pendingCapture?.id == result.id else {
            state = "Guardado pendiente"; persistState(.savePending)
            notice = "Hay otro guardado pendiente. Esta copia con IA se conserva para reintentar después."; return
        }
        state = "Guardando copia de textura restaurada…"; isSavingOwnResult = true
        savingRevision = 0
        let run = generation
        persistState(.saving)
        if let saved = await library.save(result, controlObserver: { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.busy, self.isSavingOwnResult, self.generation == run,
                      self.recoveryJob?.state != .completed, snapshot.revision >= self.savingRevision else { return }
                self.savingRevision = snapshot.revision
                if snapshot.isPauseActive { self.persistState(.manualPaused) }
                else if snapshot.phase == .running { self.persistState(.saving) }
            }
        }) {
            pendingResult = nil; self.saved = saved; onSave(saved)
            state = "Copia con IA guardada"; progress = 1
            completeRecovery(saved)
        } else {
            state = "Guardado pendiente"; notice = library.error ?? "El resultado sigue en la Mac y puede reintentarse."
            persistState(Task.isCancelled ? .stopped : .savePending)
        }
    }
    private func persistProgress() {
        guard var job = recoveryJob else { return }
        job.progress = min(1, max(job.progress, progress)); job.updatedAt = Date(); recoveryJob = job
        do { try DesktopLocalAIRecovery.save(job, root: root) }
        catch { notice = "No se pudo actualizar el índice de avance: " + error.localizedDescription }
    }
    private func persistState(_ state: DesktopLocalAIRecovery.State, error: String? = nil) {
        guard var job = recoveryJob else { return }
        job.state = state; job.progress = min(1, max(job.progress, progress)); job.error = error; job.updatedAt = Date(); recoveryJob = job
        do { try DesktopLocalAIRecovery.save(job, root: root) }
        catch { notice = "Se conserva el workspace, pero no se pudo actualizar su índice: " + error.localizedDescription }
    }
    private func completeRecovery(_ saved: ScanRecord) {
        guard var job = recoveryJob else { return }
        job.state = .completed; job.resultID = saved.id; job.progress = 1; job.updatedAt = Date(); recoveryJob = job
        do {
            try DesktopLocalAIRecovery.save(job, root: root)
            try DesktopLocalAIRecovery.removeCompleted(job, root: root)
            hasRecoverableWork = false
        } catch { notice = "La copia está guardada; el índice recuperable se conserva: " + error.localizedDescription }
    }
}

struct DesktopLocalAIView: View {
    @StateObject var controller: DesktopLocalAI
    @ObservedObject private var models: LocalAIModelStore
    @Environment(\.dismiss) private var dismiss
    init(controller: DesktopLocalAI) {
        _controller = StateObject(wrappedValue: controller)
        _models = ObservedObject(wrappedValue: controller.models)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restaurar textura con IA local").font(.title)
            Text("Real-ESRGAN se ejecuta dentro de Forma con Core ML. Reduce ruido y restaura apariencia en los interiores de la textura; conserva las costuras, la forma y la resolución nativa. Guarda una copia para compararla con el original.")
                .foregroundStyle(.secondary)
            LocalAIModelPanel(models: models)
            HStack {
                Text("Intensidad \(Int(controller.strength*100)) %")
                Slider(value: $controller.strength, in: 0.05...1).disabled(controller.busy || controller.hasRecoverableWork)
            }
            Text("La IA puede suavizar o inferir detalles fotográficos. No convierte esos detalles en geometría medida.").font(.caption).foregroundStyle(.secondary)
            Text(controller.state).font(.headline)
            if controller.pauseState == .pauseRequested { Text("Pausando al terminar el bloque actual…") }
            if controller.pauseState == .paused { Text("Pausado · no se procesan más bloques") }
            ProgressView(value: controller.progress)
            if !controller.notice.isEmpty { Text(controller.notice).textSelection(.enabled) }
            if controller.isSavingOwnResult {
                DesktopLocalAISavingPanel(library: controller.library, togglePause: controller.togglePause, cancel: controller.cancel)
            }
            HStack {
                if controller.busy, !controller.library.isSaving {
                    Button(controller.pauseState == .paused || controller.pauseState == .pauseRequested ? "Reanudar" : "Pausar") { controller.togglePause() }
                    Button("Cancelar", role: .destructive) { controller.cancel() }
                } else if controller.canRetrySave { Button("Reintentar guardado") { controller.retrySave() } }
                else if controller.saved == nil { Button(controller.hasRecoverableWork ? "Reanudar trabajo conservado" : "Crear copia con IA") { controller.start() }.disabled(models.modelURL == nil || models.isInstalling) }
                Spacer()
                Button("Cerrar") { dismiss() }.disabled(controller.busy)
            }
        }.padding(28).frame(width: 680).interactiveDismissDisabled(controller.busy)
    }
}

private struct LocalAIModelPanel: View {
    @ObservedObject var models: LocalAIModelStore
    var body: some View {
        GroupBox("Modelo en esta Mac") {
            VStack(alignment: .leading, spacing: 8) {
                Text(models.status)
                if models.isInstalling { ProgressView() }
                else if models.modelURL == nil { Button("Descargar modelo gratuito") { models.install() } }
                Text("La descarga inicial necesita internet. El procesamiento posterior es local, sin Comfy, cuentas ni cuotas.").font(.caption).foregroundStyle(.secondary)
                Link("Modelo y licencia BSD-3-Clause", destination: URL(string: "https://github.com/xinntao/Real-ESRGAN")!)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DesktopLocalAISavingPanel: View {
    @ObservedObject var library: ScanStore
    var togglePause: () -> Void
    var cancel: () -> Void
    var body: some View {
        if library.isSaving {
            Text(library.savingStage)
            HStack {
                Button(library.savingState.isPauseActive ? "Reanudar guardado" : "Pausar guardado", action: togglePause)
                Button("Cancelar guardado", role: .destructive, action: cancel)
            }
        }
    }
}
