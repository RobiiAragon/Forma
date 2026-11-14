import SwiftUI

/// Cached by the desktop store so closing the view does not discard a running copy.
@MainActor
final class DesktopGeometryRefinement: ObservableObject {
    @Published var settings = LiDARQualitySettings()
    @Published private(set) var busy = false
    @Published private(set) var status = "Lista"
    @Published private(set) var progress = 0.0
    @Published private(set) var saved: ScanRecord?
    @Published private(set) var error: String?
    @Published private(set) var phase: ProcessingControl.Phase = .running
    @Published private(set) var hasPendingSave = false
    let record: ScanRecord
    private let library: ScanStore
    private let canStart: () -> Bool
    private let setBusy: (Bool) -> Void
    private let onSave: (ScanRecord) -> Void
    private var gate: ProcessingControl?
    private var task: Task<Void, Never>?
    private var saving = false
    private var pendingResult: CaptureResult?
    var pendingCaptureID: UUID? { pendingResult?.id }

    init(record: ScanRecord, library: ScanStore, canStart: @escaping () -> Bool,
         setBusy: @escaping (Bool) -> Void, onSave: @escaping (ScanRecord) -> Void) {
        self.record = record; self.library = library; self.canStart = canStart
        self.setBusy = setBusy; self.onSave = onSave
    }

    func start() {
        guard !busy, canStart(), !library.isSaving, library.pendingCapture == nil else {
            error = "Termina el proceso activo y guarda cualquier resultado pendiente antes de iniciar otra copia."; return
        }
        do { try settings.validate() } catch { self.error = error.localizedDescription; return }
        guard SavedScanRefinement.canRefine(scan: record, directory: library.directory(for: record)) else {
            error = "Esta captura no conserva una malla LiDAR reutilizable."; return
        }
        beginWork()
        let selected = settings
        let control = ProcessingControl { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.busy, !self.saving else { return }
                self.phase = snapshot.phase
            }
        }
        gate = control
        task = Task {
            defer { finishWork() }
            do {
                let result = try await SavedScanRefinement.process(scan: record,
                    directory: library.directory(for: record), quality: selected, control: control) { [weak self] title, fraction in
                    Task { @MainActor in
                        guard let self, self.busy, !self.saving else { return }
                        self.status = title; self.progress = fraction
                    }
                }
                do {
                    try await Task.detached(priority: .utility) { try control.checkpoint() }.value
                    try Task.checkCancellation()
                } catch {
                    if let owned = result.cleanupDirectory { try? FileManager.default.removeItem(at: owned) }
                    throw error
                }
                pendingResult = result
                await save(result)
            } catch {
                status = error is CancellationError ? "Cancelada; original conservado" : "Error"
                self.error = error is CancellationError ? nil : error.localizedDescription
            }
        }
    }

    func retrySave() {
        guard !busy, canStart(), !library.isSaving, let result = pendingResult,
              library.pendingCapture?.id == result.id else { return }
        beginWork()
        task = Task { defer { finishWork() }; await save(result) }
    }

    func pause() {
        guard busy, phase == .running else { return }
        if saving { library.pauseSaving(); phase = library.savingState.phase }
        else if let gate { phase = gate.requestPause().phase }
    }
    func resume() {
        guard busy, phase == .paused || phase == .pauseRequested else { return }
        if saving { library.toggleSavingPause(); phase = library.savingState.phase }
        else if let gate { phase = gate.resume().phase }
    }
    func cancel() {
        guard busy else { return }
        phase = .cancelled; status = "Cancelando; original conservado"
        if saving { library.cancelSaving() }
        else { gate?.cancel(); task?.cancel() }
    }

    private func beginWork() {
        busy = true; setBusy(true); error = nil; saved = nil; progress = 0; phase = .running
        status = "Preparando una copia del original"
    }
    private func finishWork() {
        busy = false; saving = false; gate = nil; task = nil; setBusy(false)
    }
    private func save(_ result: CaptureResult) async {
        saving = true; phase = .running; status = "Guardando una captura nueva"
        if let output = await library.save(result, controlObserver: { [weak self] snapshot in
            Task { @MainActor in
                guard let self, self.busy, self.saving else { return }
                self.phase = snapshot.phase
            }
        }) {
            saved = output; pendingResult = nil; hasPendingSave = false
            progress = 1; status = "Copia guardada"; onSave(output)
        } else {
            hasPendingSave = true; status = "Guardado pendiente"
            error = library.error ?? "El resultado pendiente y el original se conservan. Reintenta el guardado."
        }
    }
}

struct DesktopGeometryRefinementView: View {
    @ObservedObject var controller: DesktopGeometryRefinement
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reprocesar geometría LiDAR").font(.title2)
            Text("Se guarda otra captura y se conserva el original. La corrección de planos limita cuánto se desplaza cada vértice y conserva bordes y escala; no calibra medidas ni garantiza una escala exacta. El relieve menor que la tolerancia puede confundirse con ruido.")
                .font(.callout).foregroundStyle(.secondary)
            LiDARQualityControls(settings: $controller.settings, includeCaptureSettings: false).disabled(controller.busy)
            Text(controller.status).font(.headline)
                .accessibilityIdentifier("geometryRefinementStatus")
            if controller.busy {
                ProgressView(value: controller.progress)
                    .accessibilityLabel("Progreso del reprocesamiento")
                    .accessibilityValue(controller.progress.formatted(.percent.precision(.fractionLength(0))))
                if controller.phase == .pauseRequested { Text("Pausa solicitada; esperando un punto de control.").font(.caption) }
                if controller.phase == .paused { Text("En pausa. Continúa manualmente cuando decidas.").font(.caption) }
            }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let saved = controller.saved {
                Text("\(saved.vertexCount.formatted()) vértices · \(saved.faceCount.formatted()) triángulos")
                if let stats = saved.statistics {
                    Text("Regiones aceptadas: \(Int(stats["planarAcceptedRegions"] ?? 0)) · vértices desplazados: \(Int(stats["planarMovedVertices"] ?? 0))")
                    Text("Desplazamiento máximo: \(((stats["planarMaxDisplacementMeters"] ?? 0) * 1000).formatted()) mm")
                }
            }
            HStack {
                if controller.busy {
                    Button(controller.phase == .running ? "Pausar" : "Continuar") {
                        if controller.phase == .running { controller.pause() } else { controller.resume() }
                    }.disabled(controller.phase == .cancelled)
                    Button("Cancelar y conservar original", role: .destructive) { controller.cancel() }
                } else if controller.hasPendingSave {
                    Button("Reintentar guardado") { controller.retrySave() }
                } else {
                    Button("Crear copia con estos ajustes") { controller.start() }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if controller.busy {
                Text("Cerrar este panel no cancela el trabajo. Mantén Forma abierta; puedes volver a estos controles desde la captura.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(minWidth: 570, idealWidth: 640)
        }.frame(maxHeight: 720)
    }
}
