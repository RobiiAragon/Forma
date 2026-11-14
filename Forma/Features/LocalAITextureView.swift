import SwiftUI
import UIKit

/// Human intent is independent of an OS execution grant. It survives worker
/// replacement within the living controller; relaunch recovery remains explicit.
struct LocalAIJobControlState: Equatable, Sendable {
    enum Intent: String, Sendable { case running, paused, cancelled }
    enum RecoveryAction: Equatable { case none, resumeInference, retrySave }
    private(set) var intent: Intent = .running
    private(set) var foreground = true
    private(set) var cpuBackgroundGranted = false
    private(set) var needsSystemRecovery = false
    private(set) var memoryWarningCount: UInt64 = 0

    var isManuallyPaused: Bool { intent == .paused }
    var waitsForForeground: Bool { !foreground && !cpuBackgroundGranted && intent != .cancelled }
    var shouldHoldWorker: Bool { isManuallyPaused || waitsForForeground }
    var shouldRecoverAutomatically: Bool { needsSystemRecovery && foreground && intent == .running }
    func recoveryAction(hasPendingResult: Bool) -> RecoveryAction {
        guard shouldRecoverAutomatically else { return .none }
        return hasPendingResult ? .retrySave : .resumeInference
    }

    mutating func begin(explicitUserAction: Bool) {
        if explicitUserAction { intent = .running; memoryWarningCount = 0 }
        needsSystemRecovery = false; cpuBackgroundGranted = false
    }
    mutating func setForeground(_ value: Bool) { foreground = value }
    mutating func setCPUBackgroundGrant(_ value: Bool) { cpuBackgroundGranted = value }
    mutating func pauseByUser() { if intent != .cancelled { intent = .paused } }
    mutating func resumeByUser() { if intent != .cancelled { intent = .running } }
    mutating func cancelByUser() { intent = .cancelled; needsSystemRecovery = false }
    mutating func receiveMemoryWarning() { memoryWarningCount &+= 1 }
    /// Only actual grant expiration in background interrupts a worker. A foreground
    /// CPU worker does not need the expired background grant to keep processing.
    @discardableResult mutating func executionExpired() -> Bool {
        cpuBackgroundGranted = false
        guard !foreground, intent != .cancelled else { return false }
        needsSystemRecovery = true
        return true
    }
}

struct LocalAITextureWorkConfiguration: Codable, Equatable, Sendable {
    var sourceID: UUID
    var strength: Double
    var isValid: Bool { strength.isFinite && (0...1).contains(strength) }
    func matches(sourceID: UUID, strength: Double) -> Bool {
        isValid && self.sourceID == sourceID && self.strength == strength
    }
}

@MainActor
struct LocalAITextureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var library: ScanStore
    @StateObject private var controller: LocalAITextureController
    private let onUseMac: (() -> Void)?

    init(record: ScanRecord, library: ScanStore,
         onSaved: @escaping (ScanRecord) -> Void, onUseMac: (() -> Void)? = nil) {
        _library = ObservedObject(wrappedValue: library)
        _controller = StateObject(wrappedValue: LocalAITextureController(
            record: record, library: library, onSaved: onSaved))
        self.onUseMac = onUseMac
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(FormaStyle.accent)
                    Text("Restaurar textura").font(.largeTitle.bold())
                    Text("IA local con Core ML. Crea una versión nueva de las texturas y conserva la geometría, las UV y la resolución nativa.")
                        .foregroundStyle(.secondary)
                    settings
                    Label(controller.energyStatus, systemImage: "leaf.fill").font(.subheadline).foregroundStyle(FormaStyle.accent)
                    if !controller.backgroundStatus.isEmpty { Text(controller.backgroundStatus).font(.caption).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 12) {
                        Label(controller.state, systemImage: controller.saved == nil ? "cpu" : "checkmark.circle")
                            .font(.headline).accessibilityIdentifier("localAIState")
                        if controller.isChecking {
                            ProgressView().tint(FormaStyle.accent)
                        } else if controller.busy {
                            if controller.isSavingOwnResult {
                                savingProgress
                            } else {
                                ProgressView(value: controller.progress).tint(FormaStyle.accent)
                                    .accessibilityIdentifier("localAIProgress")
                                Text(controller.progress, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            pauseStatus
                        }
                        if !controller.notice.isEmpty {
                            Text(controller.notice).font(.subheadline).textSelection(.enabled)
                        }
                        actions
                    }.padding(20).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Procesamiento en este iPhone", systemImage: "iphone")
                            .font(.headline)
                        Text("Procesamiento continuo, sin descansos ni pausas por avisos de memoria añadidos por Forma. Usa CPU para continuar en segundo plano cuando iOS lo autorice. Si iOS suspende la ejecución, continúa al volver a Forma; tu pausa manual se conserva.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let onUseMac {
                            Button(action: onUseMac) {
                                Label("Procesar en tu Mac", systemImage: "desktopcomputer")
                            }.foregroundStyle(FormaStyle.accent).disabled(controller.busy)
                                .accessibilityIdentifier("localAIUseMac")
                        } else {
                            Text("También puedes usar «Procesar en tu Mac» desde la ficha de una captura con fuentes guardadas.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Real-ESRGAN viene incluido en Forma. Sin Comfy, conexión a internet ni descargas durante el procesamiento. La IA puede suavizar o inferir apariencia; no convierte ese detalle en una medición 3D.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(FormaStyle.background)
                .navigationTitle("IA local").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") { dismiss() }.disabled(controller.busy)
                    }
                }
        }.preferredColorScheme(.dark)
            .interactiveDismissDisabled(controller.busy)
            .task { await controller.prepare() }
            .onAppear { controller.applicationPhaseChanged(scenePhase) }
            .onChange(of: scenePhase) { _, phase in controller.applicationPhaseChanged(phase) }
            .onChange(of: library.isSaving) { _, _ in controller.savingStateChanged() }
            .onChange(of: library.savingState) { _, _ in controller.savingStateChanged() }
            .onChange(of: library.savingCompletedBytes) { _, _ in controller.savingStateChanged() }
            .onChange(of: library.savingStage) { _, _ in controller.savingStateChanged() }
            .onChange(of: library.pendingCapture?.id) { _, _ in controller.savingStateChanged() }
            .onDisappear { controller.leave() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Intensidad").font(.headline)
                Spacer()
                Text(controller.strength, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(FormaStyle.accent)
            }
            Slider(value: $controller.strength, in: 0.05...1)
                .tint(FormaStyle.accent).accessibilityIdentifier("localAIStrength")
            Text("Se protegen los márgenes y las costuras UV. Las fotografías y la captura original permanecen en su lugar; la versión nueva mantiene el enlace a su origen.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
            .disabled(controller.busy || controller.saved != nil || controller.hasPendingResult || controller.hasRecoverableWork)
    }

    private var savingProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(library.savingStage).font(.subheadline)
            if library.savingTotalBytes > 0 {
                ProgressView(value: Double(library.savingCompletedBytes), total: Double(library.savingTotalBytes))
                    .tint(FormaStyle.accent)
                Text("\(library.savingCompletedBytes.formatted()) de \(library.savingTotalBytes.formatted()) bytes de esta etapa")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else { ProgressView().tint(FormaStyle.accent) }
        }
    }

    @ViewBuilder private var pauseStatus: some View {
        let phase = controller.isSavingOwnResult ? library.savingState.phase : controller.pauseState.phase
        if controller.cancelling {
            Text("Cancelando al terminar el bloque actual…").font(.subheadline).foregroundStyle(.secondary)
        } else if phase == .pauseRequested {
            Text("Pausando al terminar el bloque actual…").font(.subheadline).foregroundStyle(FormaStyle.accent)
        } else if phase == .paused {
            Text(controller.waitingForForeground ? "Esperando ejecución de iOS · continúa al volver a Forma" : "Pausado · no se inician más bloques")
                .font(.subheadline).foregroundStyle(FormaStyle.accent)
        }
        if !controller.pauseReason.isEmpty {
            Text(controller.pauseReason).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        if controller.busy {
            HStack {
                let pause = controller.isManuallyPaused
                Button(pause ? "Reanudar" : "Pausar") { controller.togglePause() }
                    .buttonStyle(.bordered).disabled(controller.cancelling)
                    .accessibilityIdentifier("localAIPause")
                Button("Cancelar", role: .destructive) { controller.cancel() }
                    .buttonStyle(.bordered).disabled(controller.cancelling)
                    .accessibilityIdentifier("localAICancel")
            }
        } else if controller.hasPendingResult {
            Button("Reintentar guardado") { controller.retrySave() }
                .buttonStyle(.borderedProminent).tint(FormaStyle.accent)
                .disabled(library.isSaving).accessibilityIdentifier("localAIRetrySave")
        } else if controller.saved == nil {
            PrimaryButton(title: controller.hasRecoverableWork ? "Reanudar trabajo con IA" : "Crear copia con IA", symbol: "sparkles") { controller.start() }
                .disabled(!controller.canStart).opacity(controller.canStart ? 1 : 0.45)
                .accessibilityIdentifier("localAIStart")
            if controller.hasRecoverableWork {
                Text("Se conserva el avance entre texturas completas. Reiniciar descarta sólo este trabajo pendiente; el escaneo original permanece intacto.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reiniciar desde el original", role: .destructive) { controller.restartWork() }
                    .disabled(!controller.canRestartWork)
            }
        }
    }
}

@MainActor
private final class LocalAITextureController: ObservableObject {
    @Published var strength = 0.35
    @Published private(set) var busy = false
    @Published private(set) var isChecking = true
    @Published private(set) var isSavingOwnResult = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress = 0.0
    @Published private(set) var state = "Comprobando texturas y modelo local…"
    @Published private(set) var notice = ""
    @Published private(set) var pauseReason = ""
    @Published private(set) var pauseState = ProcessingControl.Snapshot(phase: .running, revision: 0)
    @Published private(set) var saved: ScanRecord?
    @Published private(set) var hasPendingResult = false
    @Published private(set) var hasRecoverableWork = false
    private let record: ScanRecord
    private let library: ScanStore
    private let onSaved: (ScanRecord) -> Void
    private let modelURL = Bundle.main.url(forResource: "RealESRGAN_general_522_fp16", withExtension: "mlmodelc")
    private var sourceURL: URL?
    private var pendingResult: CaptureResult?
    private var task: Task<Void, Never>?
    private var control: ProcessingControl?
    private var generation = UUID()
    private var applicationActive = true
    private var previousIdleTimer: Bool?
    @Published private(set) var energyStatus = "Procesamiento continuo · sin descansos añadidos"
    @Published private(set) var backgroundStatus = ""
    @Published private(set) var jobControl = LocalAIJobControlState()
    private var energyPolicy: MobileProcessingPolicy?
    private var executionLease: ProcessingExecutionLease?
    private var expiredBySystem = false
    private var fallbackBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastActivityProgress = 0.0
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var workspaceURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FormaAIWork", isDirectory: true)
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
    }

    init(record: ScanRecord, library: ScanStore, onSaved: @escaping (ScanRecord) -> Void) {
        self.record = record; self.library = library; self.onSaved = onSaved
        applicationActive = UIApplication.shared.applicationState != .background
        jobControl.setForeground(applicationActive)
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setApplicationActive(true) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setApplicationActive(false) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.receiveMemoryWarning() }
            }
        ]
    }
    deinit { lifecycleObservers.forEach(NotificationCenter.default.removeObserver) }

    var isManuallyPaused: Bool { jobControl.isManuallyPaused }
    var waitingForForeground: Bool { jobControl.waitsForForeground && !jobControl.isManuallyPaused }

    var canStart: Bool {
        !busy && !isChecking && !hasPendingResult && saved == nil && sourceURL != nil && modelURL != nil &&
            !library.isSaving && library.pendingCapture == nil && applicationActive
    }

    var canRestartWork: Bool {
        !busy && pendingResult == nil && !library.isSaving &&
            !(library.pendingCapture.map(referencesWorkspace) ?? false)
    }

    func prepare() async {
        guard isChecking else { return }
        defer { isChecking = false }
        guard modelURL != nil else {
            state = "Modelo local no disponible"
            notice = "Esta instalación no incluye el restaurador Core ML compilado. No se descargará un modelo desde el iPhone."
            return
        }
        guard let source = library.modelURL(for: record), LocalAIModelRestoration.supports(source) else {
            state = "Esta captura no tiene un OBJ o USDZ compatible"
            notice = "La restauración necesita texturas existentes. Crea otra copia y conserva la geometría original."
            return
        }
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let count = try LocalAIModelRestoration.textureCount(model: source)
            try Task.checkCancellation()
            return count
        }
        do {
            let count = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            guard count > 0 else {
                state = "La captura no tiene texturas fotográficas"
                notice = "El original se conserva. Esta función restaura imágenes existentes, no crea textura donde no la hay."
                return
            }
            sourceURL = source
            if let data = try? Data(contentsOf: workspaceURL.appendingPathComponent("trabajo.json")),
               let existing = try? JSONDecoder().decode(LocalAITextureWorkConfiguration.self, from: data),
               existing.sourceID == record.id, existing.isValid {
                strength = existing.strength; hasRecoverableWork = true
                state = "\(count.formatted()) texturas · trabajo local pendiente de reanudar"
            } else { state = "\(count.formatted()) texturas · listo para crear una copia" }
            if let pending = library.pendingCapture, ownsPendingCapture(pending) {
                pendingResult = pending
                hasPendingResult = true
                hasRecoverableWork = true
                state = library.isSaving ? "Guardando copia pendiente en la biblioteca…" : "Copia con IA lista · guardado pendiente"
                notice = "Se conserva la copia ya procesada. Reintenta su guardado sin repetir la restauración."
            }
        } catch is CancellationError { }
        catch { state = "No se pudieron preparar las texturas"; notice = error.localizedDescription }
    }

    func start(automaticallyRecovering: Bool = false) {
        guard canStart, let source = sourceURL, let model = modelURL else { return }
        if automaticallyRecovering && !jobControl.shouldRecoverAutomatically { return }
        jobControl.begin(explicitUserAction: !automaticallyRecovering)
        busy = true; cancelling = false; progress = 0; notice = ""; pauseReason = ""
        state = "Preparando restaurador Core ML local…"
        pauseState = .init(phase: .running, revision: 0)
        let run = UUID(); generation = run
        expiredBySystem = false; lastActivityProgress = 0
        let policy = MobileProcessingPolicy(mode: .continuous) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.busy, self.generation == run else { return }
                self.energyStatus = "Procesamiento continuo · sin descansos añadidos"
            }
        }
        energyPolicy = policy
        let gate = ProcessingControl { [weak self] snapshot in
            policy.observeControlState(snapshot)
            Task { @MainActor [weak self] in
                guard let self, self.busy, self.generation == run, snapshot.revision >= self.pauseState.revision else { return }
                self.pauseState = snapshot
                self.updateIdleTimer(); self.publishActivity()
                if snapshot.phase == .paused { self.endFallbackBackgroundTime() }
            }
        }
        control = gate
        updateIdleTimer()
        let workspace = workspaceURL
        let package = workspace.appendingPathComponent("modelo", isDirectory: true)
        let meshURL = library.directory(for: record).appendingPathComponent("malla.json")
        let amount = strength, recordID = record.id
        let updateProgress: @Sendable (String, Double) -> Void = { [weak self] _, fraction in
            guard let self else { return }
            Task { @MainActor in
                guard self.busy, self.generation == run, !self.isSavingOwnResult,
                      self.pendingResult == nil, self.saved == nil, !self.cancelling,
                      fraction.isFinite else { return }
                self.state = "Restaurando texturas…"
                self.progress = max(self.progress, min(1, max(0, fraction))); self.publishActivity()
            }
        }
        task = Task { [self] in
            defer {
                if saved != nil || !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("trabajo.json").path) {
                    try? FileManager.default.removeItem(at: workspace)
                }
                hasRecoverableWork = saved == nil && FileManager.default.fileExists(atPath: workspace.appendingPathComponent("trabajo.json").path)
                busy = false; cancelling = false; isSavingOwnResult = false
                ProcessingActivityCoordinator.shared.finish(id: run, success: saved != nil,
                    status: saved != nil ? "Copia guardada" : (expiredBySystem ? "iOS terminó la ejecución; avance conservado" : state))
                executionLease = nil; energyPolicy = nil; endFallbackBackgroundTime()
                control = nil; task = nil; updateIdleTimer()
                scheduleAutomaticRecoveryIfNeeded()
            }
            do {
                let lease = await ProcessingActivityCoordinator.shared.begin(id: run, title: "Forma · Texturas IA", onAction: { [weak self] action in
                    guard let self, self.busy, self.generation == run else { return }
                    if action == "pause" { self.requestPause(reason: "Pausa desde la actividad de Forma.") }
                    else if action == "resume" { self.resumeByUser() }
                    else if action == "cancel" { self.cancel() }
                }, onExpiration: { [weak self] in
                    guard let self, self.generation == run else { return }
                    self.handleExecutionExpiration()
                })
                executionLease = lease; lease.setApplicationActive(applicationActive)
                jobControl.setCPUBackgroundGrant(lease.canContinueInBackground)
                backgroundStatus = lease.backgroundReason
                updateIdleTimer()
                try Task.checkCancellation()
                synchronizeExecutionGate()
                policy.resetWorkClock()
                let worker = Task.detached(priority: .utility) {
                    try gate.checkpoint()
                    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    // Keep only the referenced model package accessible after a normal lock.
                    // It remains encrypted and inaccessible before the first unlock after reboot.
                    try Self.prepareLockedAccess(source.deletingLastPathComponent(), control: gate)
                    let metadata = workspace.appendingPathComponent("trabajo.json")
                    if FileManager.default.fileExists(atPath: metadata.path) {
                        let configuration = try JSONDecoder().decode(LocalAITextureWorkConfiguration.self, from: Data(contentsOf: metadata))
                        guard configuration.matches(sourceID: recordID, strength: amount) else {
                            throw RGBDDatasetError.invalid("El trabajo pendiente pertenece a otra configuración. Reinicia desde el original para cambiarla.")
                        }
                    } else {
                        let configuration = LocalAITextureWorkConfiguration(sourceID: recordID, strength: amount)
                        try JSONEncoder().encode(configuration).write(to: metadata, options: .atomic)
                    }
                    let report: LocalAITextureEnhancer.Report
                    if FileManager.default.fileExists(atPath: package.appendingPathComponent("ia-local.json").path) {
                        let restored = try LocalAIModelRestoration.restoredReport(package: package, sourceModel: source)
                        guard restored.changedPixels > 0 else {
                            throw RGBDDatasetError.invalid("El resultado pendiente no coincide con la geometría original. Reinicia este trabajo para crear una copia nueva.")
                        }
                        report = restored
                    } else {
                    report = try LocalAIModelRestoration.run(model: source, output: package,
                        restorer: model, strength: amount, control: gate,
                        // CPU for the entire mobile job avoids an in-flight GPU/ANE
                        // prediction becoming unauthorized during a background transition.
                        pacing: { try policy.checkpoint(control: gate) }, cpuOnly: true,
                        checkpointDirectory: workspace.appendingPathComponent("checkpoint", isDirectory: true), progress: updateProgress)
                    }
                    try gate.checkpoint()
                    let reportURL = workspace.appendingPathComponent("informe-ia.json")
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(report).write(to: reportURL, options: .atomic)
                    let mesh = FileManager.default.fileExists(atPath: meshURL.path)
                        ? try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: meshURL)) : nil
                    try gate.checkpoint()
                    return (report, reportURL, mesh)
                }
                let (report, reportURL, mesh) = try await withTaskCancellationHandler(
                    operation: { try await worker.value }, onCancel: { gate.cancel(); worker.cancel() })
                try Task.checkCancellation()
                guard report.changedPixels > 0 else {
                    state = "No se creó una copia sin cambios"
                    notice = "No hubo píxeles modificados dentro de las zonas seguras. Las costuras, los formatos no compatibles y el original se conservan."
                    return
                }
                let coverage = report.totalTexturePixels > 0 ? Double(report.eligiblePixels) / Double(report.totalTexturePixels) : 0
                let observedCoverage = report.observedUVPixels > 0 ? Double(report.eligiblePixels) / Double(report.observedUVPixels) : 0
                var statistics = record.statistics ?? [:]
                statistics.merge([
                    "localAITextureRestoration": 1, "localAIStrength": amount,
                    "localAIEligibleCoverage": coverage, "localAIChangedPixels": Double(report.changedPixels),
                    "localAITiles": Double(report.inferenceTileCount), "localAISeconds": report.totalSeconds,
                    "localAIProcessedTextures": Double(report.processedTextureCount),
                    "localAISkippedTextures": Double(report.skippedTextureCount),
                    "localAIObservedCoverage": observedCoverage, "localAIObservedUVPixels": Double(report.observedUVPixels),
                    "localAIIslands": Double(report.islandCount),
                    "mobileTargetActivityFraction": 1,
                    "mobileMeasuredWorkSeconds": policy.snapshot.measuredWorkSeconds,
                    "mobileRestSeconds": policy.snapshot.restSeconds,
                    "mobileBackgroundCPU": 1,
                    "localAIMemoryWarnings": Double(jobControl.memoryWarningCount)
                ]) { _, new in new }
                pendingResult = CaptureResult(mesh: mesh, modelURL: report.modelURL, auxiliaryURLs: [reportURL],
                    mode: record.mode, duration: record.duration, isDemo: record.isDemo,
                    note: "Restauración local de texturas con Real-ESRGAN y Core ML. Intensidad \(Int(amount * 100)) %. Conserva geometría, UV y resolución nativa; la IA infiere apariencia, no añade mediciones. Márgenes y costuras protegidos. Fotografías y calibración originales conservadas en la captura de origen \(record.id).",
                    cleanupDirectory: workspace, modelPackageURL: report.packageURL,
                    statistics: statistics, sourceScanID: record.id,
                    modelGeometryCounts: ModelGeometryCounts(vertexCount: record.vertexCount, faceCount: record.faceCount))
                hasPendingResult = true
                notice = String(format: "%d texturas procesadas · %.1f %% de la zona UV observada procesable. Original conservado.", report.processedTextureCount, observedCoverage * 100)
                await savePending()
            } catch {
                state = error is CancellationError ? "Cancelado · original conservado" : "No se completó la restauración"
                if expiredBySystem && jobControl.intent != .cancelled {
                    state = "Avance conservado · continuará al volver a Forma"
                    notice = "iOS terminó la ejecución en segundo plano. Las texturas completas no se vuelven a calcular; una pausa manual se mantiene."
                }
                else if !(error is CancellationError) { notice = error.localizedDescription }
            }
        }
    }

    private func savePending() async {
        guard let result = pendingResult else { return }
        guard !library.isSaving, library.pendingCapture == nil || library.pendingCapture?.id == result.id else {
            state = "Guardado pendiente"
            notice = "Hay otro guardado pendiente en la biblioteca. La copia con IA y el original se conservan; resuelve ese guardado antes de reintentar."
            return
        }
        state = "Guardando copia de textura restaurada…"; isSavingOwnResult = true
        // ScanStore owns the idle timer during saving. Release our lease before
        // it snapshots the previous value, avoiding nested restoration races.
        updateIdleTimer()
        let run = generation
        let savePolicy = MobileProcessingPolicy(mode: .continuous) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.busy, self.isSavingOwnResult, self.generation == run else { return }
                self.energyStatus = "Guardado continuo · sin descansos añadidos"
                self.publishActivity()
            }
        }
        energyPolicy = savePolicy
        if let saved = await library.save(result, pacing: {
            try savePolicy.checkpoint(control: ProcessingControl.current)
        }, initiallyPaused: jobControl.shouldHoldWorker, controlObserver: { savePolicy.observeControlState($0) }) {
            self.saved = saved; pendingResult = nil; hasPendingResult = false
            state = "Copia con IA guardada"; progress = 1
            onSaved(saved)
        } else {
            state = "Guardado pendiente"
            notice = library.error ?? "Los archivos de la copia se conservan para reintentar el guardado."
        }
        isSavingOwnResult = false
    }

    func retrySave(automaticallyRecovering: Bool = false) {
        guard !busy, pendingResult != nil, !library.isSaving else { return }
        if automaticallyRecovering && !jobControl.shouldRecoverAutomatically { return }
        jobControl.begin(explicitUserAction: !automaticallyRecovering)
        busy = true; cancelling = false; expiredBySystem = false; generation = UUID()
        pauseState = .init(phase: .running, revision: 0); lastActivityProgress = 0.9
        let run = generation
        updateIdleTimer()
        task = Task { [self] in
            defer {
                ProcessingActivityCoordinator.shared.finish(id: run, success: saved != nil, status: state)
                busy = false; cancelling = false; task = nil; executionLease = nil; energyPolicy = nil
                endFallbackBackgroundTime(); updateIdleTimer()
                scheduleAutomaticRecoveryIfNeeded()
            }
            let lease = await ProcessingActivityCoordinator.shared.begin(id: run, title: "Forma · Guardar texturas", onAction: { [weak self] action in
                guard let self, self.busy, self.generation == run else { return }
                if action == "pause" { self.requestPause(reason: "Pausa desde la actividad de Forma.") }
                else if action == "resume" { self.resumeByUser() }
                else if action == "cancel" { self.cancel() }
            }, onExpiration: { [weak self] in
                guard let self, self.generation == run else { return }
                self.handleExecutionExpiration()
            })
            executionLease = lease; lease.setApplicationActive(applicationActive)
            jobControl.setCPUBackgroundGrant(lease.canContinueInBackground)
            backgroundStatus = lease.backgroundReason
            guard !Task.isCancelled else { return }
            synchronizeExecutionGate()
            await savePending()
        }
    }

    func togglePause() {
        guard busy, !cancelling else { return }
        if jobControl.isManuallyPaused { resumeByUser() }
        else { requestPause(reason: "Pausa solicitada por ti.") }
    }

    func requestPause(reason: String) {
        guard busy, !cancelling else { return }
        jobControl.pauseByUser(); pauseReason = reason
        synchronizeExecutionGate()
    }

    private func resumeByUser() {
        guard busy, !cancelling else { return }
        jobControl.resumeByUser()
        synchronizeExecutionGate()
    }

    func receiveMemoryWarning() {
        guard busy else { return }
        jobControl.receiveMemoryWarning()
        if !cancelling && !expiredBySystem {
            notice = "Avisos de memoria de iOS: \(jobControl.memoryWarningCount.formatted()). Forma continúa sin detener el trabajo por este aviso."
        }
        publishActivity()
    }

    func applicationPhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: setApplicationActive(true)
        case .background: setApplicationActive(false)
        case .inactive: break // Control Center, Dynamic Island, and system UI do not revoke foreground execution.
        @unknown default: break
        }
    }

    func setApplicationActive(_ active: Bool) {
        applicationActive = active; executionLease?.setApplicationActive(active)
        jobControl.setForeground(active)
        jobControl.setCPUBackgroundGrant(executionLease?.canContinueInBackground == true && !expiredBySystem)
        if active { energyPolicy?.resetWorkClock() }
        synchronizeExecutionGate()
        if !active && jobControl.waitsForForeground { beginFallbackBackgroundTime() }
        if active { endFallbackBackgroundTime(); scheduleAutomaticRecoveryIfNeeded() }
        updateIdleTimer(); publishActivity()
    }

    func savingStateChanged() {
        if !busy, let local = pendingResult, library.pendingCapture?.id != local.id {
            // Another library view may have saved or discarded the adopted result.
            // Release only our reference; never alter a different pending capture.
            pendingResult = nil; hasPendingResult = false
            jobControl.cancelByUser() // Another view resolved this result; do not recreate it automatically.
            hasRecoverableWork = FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("trabajo.json").path)
            state = hasRecoverableWork ? "Trabajo local pendiente de reanudar" : "La biblioteca ya resolvió este guardado pendiente"
            notice = "Revisa la biblioteca para ver el resultado del guardado."
        }
        synchronizeExecutionGate()
        if library.savingState.phase == .paused { endFallbackBackgroundTime() }
        scheduleAutomaticRecoveryIfNeeded()
        updateIdleTimer(); publishActivity()
    }

    func cancel() {
        guard busy else { return }
        jobControl.cancelByUser()
        cancelling = true
        if executionLease == nil {
            ProcessingActivityCoordinator.shared.finish(id: generation, success: false, status: "Cancelado; original conservado")
        }
        if isSavingOwnResult { library.cancelSaving() }
        control?.cancel(); task?.cancel()
    }

    func leave() {
        // A view disappearing is not a user cancellation or an app lifecycle event.
        // The living job retains its controller; a relaunch registry is a separate layer.
        updateIdleTimer()
    }

    private func synchronizeExecutionGate() {
        guard busy, !cancelling, !expiredBySystem, jobControl.intent != .cancelled else { return }
        if jobControl.waitsForForeground && !jobControl.isManuallyPaused {
            pauseReason = "iOS no concedió ejecución en segundo plano. El trabajo continúa automáticamente al volver a Forma."
        } else if !jobControl.isManuallyPaused { pauseReason = "" }
        if pendingResult != nil && !isSavingOwnResult {
            pauseState = .init(phase: jobControl.shouldHoldWorker ? .pauseRequested : .running,
                               revision: pauseState.revision &+ 1)
        } else if isSavingOwnResult {
            if jobControl.shouldHoldWorker && !library.savingState.isPauseActive { library.pauseSaving() }
            else if !jobControl.shouldHoldWorker && library.savingState.isPauseActive { library.toggleSavingPause() }
        } else if let control {
            pauseState = jobControl.shouldHoldWorker ? control.requestPause() : control.resume()
        }
        updateIdleTimer(); publishActivity()
    }

    private func handleExecutionExpiration() {
        guard busy, !cancelling else { return }
        if jobControl.executionExpired() {
            expiredBySystem = true
            pauseReason = "iOS terminó la ejecución en segundo plano. El avance completo está guardado; continuará al volver a Forma."
            backgroundStatus = pauseReason
            // Expiration is not user cancellation. Release the model/worker and
            // recover through the enhancer's existing durable per-atlas checkpoint.
            if isSavingOwnResult { library.cancelSaving() }
            control?.cancel(); task?.cancel()
            beginFallbackBackgroundTime()
        } else {
            backgroundStatus = "iOS terminó la concesión de segundo plano. El trabajo CPU continúa mientras Forma está abierta."
            synchronizeExecutionGate()
        }
    }

    private func scheduleAutomaticRecoveryIfNeeded() {
        guard !busy, !isChecking, saved == nil, !library.isSaving,
              jobControl.shouldRecoverAutomatically else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.busy, self.saved == nil, !self.library.isSaving else { return }
            switch self.jobControl.recoveryAction(hasPendingResult: self.pendingResult != nil) {
            case .retrySave: self.retrySave(automaticallyRecovering: true)
            case .resumeInference: self.start(automaticallyRecovering: true)
            case .none: break
            }
        }
    }

    func restartWork() {
        guard canRestartWork else { return }
        do {
            if FileManager.default.fileExists(atPath: workspaceURL.path) { try FileManager.default.removeItem(at: workspaceURL) }
            hasRecoverableWork = false; notice = "Avance pendiente reiniciado; original conservado."
            state = "Listo para crear otra copia"
        } catch { notice = error.localizedDescription }
    }

    private func ownsPendingCapture(_ pending: CaptureResult) -> Bool {
        guard pending.sourceScanID == record.id,
              let cleanup = pending.cleanupDirectory,
              cleanup.standardizedFileURL.resolvingSymlinksInPath() == workspaceURL.standardizedFileURL.resolvingSymlinksInPath(),
              let package = pending.modelPackageURL, let model = pending.modelURL else { return false }
        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let packagePath = package.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return packagePath.hasPrefix(root) && model.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(packagePath)
    }

    private func referencesWorkspace(_ pending: CaptureResult) -> Bool {
        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let urls = [pending.cleanupDirectory, pending.modelPackageURL, pending.modelURL, pending.captureDatasetURL]
            .compactMap { $0 } + pending.auxiliaryURLs
        return urls.contains { url in
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    nonisolated private static func prepareLockedAccess(_ directory: URL, control: ProcessingControl) throws {
        let fm = FileManager.default
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for case let file as URL in enumerator {
            try control.checkpoint()
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw RGBDDatasetError.invalid("El paquete contiene un enlace simbólico no admitido.")
            }
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
    }

    private func publishActivity() {
        guard busy else { return }
        let phase = isSavingOwnResult ? library.savingState.phase : pauseState.phase
        let pausedPhase = executionLease?.canContinueInBackground == true ? "paused" : "pausedForeground"
        let label: String = phase == .paused ? pausedPhase : (phase == .pauseRequested ? "pausing" : (isSavingOwnResult ? "saving" : "running"))
        let fraction: Double
        if isSavingOwnResult {
            let saving = library.savingTotalBytes > 0 ? Double(library.savingCompletedBytes) / Double(library.savingTotalBytes) : 0
            fraction = 0.9 + 0.1 * min(1, max(0, saving))
        } else { fraction = progress * 0.9 }
        lastActivityProgress = max(lastActivityProgress, fraction)
        let status = phase == .paused ? "Pausado" : (phase == .pauseRequested ? "Pausando…" : (isSavingOwnResult ? library.savingStage : state))
        ProcessingActivityCoordinator.shared.update(id: generation, progress: lastActivityProgress,
            status: status, phase: label, energyLabel: energyStatus)
    }

    private func beginFallbackBackgroundTime() {
        guard busy, fallbackBackgroundTask == .invalid else { return }
        fallbackBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Pausar IA de Forma") { [weak self] in
            Task { @MainActor in self?.endFallbackBackgroundTime() }
        }
    }
    private func endFallbackBackgroundTime() {
        guard fallbackBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(fallbackBackgroundTask); fallbackBackgroundTask = .invalid
    }

    private func updateIdleTimer() {
        let phase = isSavingOwnResult ? library.savingState.phase : pauseState.phase
        let working = busy && !isSavingOwnResult && applicationActive && executionLease?.canContinueInBackground != true &&
            (phase == .running || phase == .pauseRequested)
        if working {
            if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            self.previousIdleTimer = nil
        }
    }
}
