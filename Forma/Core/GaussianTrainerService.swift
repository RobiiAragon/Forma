import Foundation
import Combine
import Metal
import UIKit
import FormaGaussianCore

@MainActor
final class GaussianTrainerService: ObservableObject {

    enum Phase { case settings, running, paused, exporting, ready, failed }
    @Published private(set) var phase: Phase = .settings
    @Published private(set) var iteration = 0
    @Published private(set) var splatCount = 0
    @Published private(set) var milliseconds: Float = 0
    @Published private(set) var message = "Entrenamiento real de gaussianas sobre imágenes y cámaras calibradas."
    @Published private(set) var result: CaptureResult?
    @Published private(set) var checkpointURL: URL?
    @Published private(set) var pauseRequested = false
    @Published private(set) var pauseCause: GaussianSessionPauseState.Cause?
    @Published private(set) var memoryWarningCount = 0
    @Published private(set) var waitingForEngine = false
    @Published private(set) var energyLabel = "Entrenamiento continuo · sin esperas programadas"
    @Published private(set) var executionNotice = "Continúa con Forma abierta. Al volver de una suspensión de iOS se reanuda desde el checkpoint."
    private var control: GaussianTrainingControl?
    private var workspace: URL?
    private var recoverySession: GaussianRecoverySession?
    private var jobID = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var energyPolicy: MobileProcessingPolicy?
    private var executionLease: ProcessingExecutionLease?
    private var activityID: UUID?
    private var targetIterations = 0
    private var pauseSession = GaussianSessionPauseState()
    private var previousIdleTimer: Bool?
    private var memoryWarningObserver: AnyCancellable?
    private var lifecycleObservers: Set<AnyCancellable> = []
    private var desiredIntent: GaussianRunIntention.Intent = .stopped
    private var exportRequested = false
    private var systemReleaseRequested = false
    var datasetPath: String?
    var sessionID: UUID? { recoverySession?.id }
    var progressFraction: Double { targetIterations > 0 ? min(1, max(0, Double(iteration) / Double(targetIterations))) : 0 }

    init(session: GaussianRecoverySession? = nil) {
        memoryWarningObserver = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.receiveMemoryWarning() }
        recoverySession = session
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.setApplicationActive(false) }
            .store(in: &lifecycleObservers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.setApplicationActive(true)
                self?.continueAfterSystemInterruption()
            }.store(in: &lifecycleObservers)
        if let session {
            datasetPath = session.datasetURL.standardizedFileURL.path
            if let intention = try? GaussianRunIntention.load(from: session.workspaceURL) {
                desiredIntent = intention.intent; exportRequested = intention.exportRequested
            }
            targetIterations = session.targetIterations
            workspace = session.workspaceURL
            checkpointURL = session.checkpointURL
            iteration = session.step
            message = "Sesión recuperada. Conserva el mismo dataset para continuar."
            let metadataURL = session.workspaceURL.appendingPathComponent("gaussianas.json")
            if let data = try? Data(contentsOf: metadataURL),
               let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let count = GaussianRecoveryExportPolicy.splatCount(session: session, metadata: metadata),
               FileManager.default.fileExists(atPath: session.workspaceURL.appendingPathComponent("gaussianas.ply").path) {
                splatCount = count
                result = Self.packagedResult(folder: session.workspaceURL, datasetURL: session.datasetURL,
                                            steps: session.step, splats: count, downscale: session.downscale, duration: 0)
                phase = .ready
            }
        }
    }

    func start(datasetURL: URL, iterations: Int, downscale: Float, resumeURL: URL? = nil,
               continuingExport: Bool = false) {
        guard phase != .running, phase != .paused, phase != .exporting else { return }
        guard #available(iOS 18, *) else { fail("El motor necesita iOS 18 o posterior."); return }
        #if targetEnvironment(simulator)
        fail("El entrenamiento Metal debe validarse en el iPhone físico. El simulador no certifica este motor.")
        return
        #else
        guard MTLCreateSystemDefaultDevice() != nil else { fail("No hay una GPU Metal disponible."); return }
        guard iterations > 0, iterations <= Int(Int32.max), downscale.isFinite, downscale >= 1 else {
            fail("Parámetros inválidos: usa pasos positivos y un factor de reducción igual o mayor que 1."); return
        }
        guard let library = Bundle.main.url(forResource: "msplat-ios", withExtension: "metallib") else {
            fail("Falta msplat-ios.metallib en los recursos de la app."); return
        }
        let session: GaussianRecoverySession
        let folder: URL
        do {
            if let existing = recoverySession {
                let metadata = existing.workspaceURL.appendingPathComponent("session.json")
                var configured = (try? JSONDecoder().decode(GaussianRecoverySession.self, from: Data(contentsOf: metadata))) ?? existing
                configured.targetIterations = iterations; configured.downscale = downscale
                session = try GaussianRecovery.update(session: configured, workspaceURL: configured.workspaceURL, step: configured.step, state: "configured")
                folder = session.workspaceURL; recoverySession = session
            }
            else {
                let created = try GaussianRecovery.create(datasetURL: datasetURL, iterations: iterations, downscale: downscale)
                session = created.session; folder = created.workspaceURL; recoverySession = session
            }
        }
        catch { fail(error.localizedDescription); return }
        var safeResumeURL = resumeURL
        if let resumeURL {
            do {
                let owned = folder.appendingPathComponent("inicio.ckpt")
                if resumeURL.standardizedFileURL != owned.standardizedFileURL {
                    if FileManager.default.fileExists(atPath: owned.path) { try FileManager.default.removeItem(at: owned) }
                    try FileManager.default.copyItem(at: resumeURL, to: owned)
                }
                safeResumeURL = owned
            } catch { fail("No se pudo conservar el checkpoint: \(error.localizedDescription)"); return }
        }
        workspace = folder
        datasetPath = datasetURL.standardizedFileURL.path
        exportRequested = continuingExport
        do { try GaussianRunIntention.save(.running, exportRequested: exportRequested, to: folder) }
        catch { fail("No se pudo registrar la ejecución: \(error.localizedDescription)"); return }
        desiredIntent = .running; systemReleaseRequested = false
        let token = UUID(); jobID = token
        let control = GaussianTrainingControl(active: UIApplication.shared.applicationState == .active, engineJobID: token)
        control.prepareEngineRequest()
        if exportRequested { control.set(.export) }
        self.control = control
        targetIterations = iterations
        phase = .running; result = nil; pauseRequested = false
        pauseSession = GaussianSessionPauseState(); pauseCause = nil; memoryWarningCount = 0; waitingForEngine = false
        updateIdleTimer()
        message = "Optimizando posición, escala, rotación, opacidad y armónicos esféricos en Metal."
        let policy = MobileProcessingPolicy(mode: .continuous) { [weak self] snapshot in
            Task { @MainActor in self?.receiveEnergyState(snapshot, token: token) }
        }
        energyPolicy = policy
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let lease = await ProcessingActivityCoordinator.shared.begin(id: token, title: "Gaussian Splatting", requiresGPU: true,
                onAction: { [weak self] action in
                    guard let self, self.jobID == token else { return }
                    if action == "pause" { self.pause() }
                    else if action == "resume" { self.resume() }
                }, onExpiration: { [weak self] in
                    guard let self, self.jobID == token else { return }
                    // A background grant expiring cannot revoke foreground
                    // Metal execution. Only checkpoint if actually inactive.
                    if UIApplication.shared.applicationState == .background {
                        self.pause(cause: .executionExpired)
                    }
                })
            guard self.jobID == token else {
                GaussianEngineGate.shared.interrupt(jobID: token)
                ProcessingActivityCoordinator.shared.finish(id: token, success: false, status: "Sesión reemplazada")
                return
            }
            self.executionLease = lease; self.activityID = token
            self.executionNotice = lease.backgroundReason + " Al volver continúa automáticamente."
            self.setApplicationActive(UIApplication.shared.applicationState == .active)
            self.updateActivity()
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                let owner = self // Retain the coordinator until checkpoint/release completes after close.
                var error = [CChar](repeating: 0, count: 2048)
                var handle: FormaGaussianHandle?
                var engineLease: GaussianEngineGate.Lease?
                var checkpointEligible = false
                func releaseEngine() {
                    if let activeHandle = handle { forma_gaussian_destroy(activeHandle); handle = nil }
                    engineLease?.release(); engineLease = nil
                }
                defer { releaseEngine(); GaussianEngineGate.shared.interrupt(jobID: token) }
                var resumeSource = safeResumeURL
                let checkpoint = folder.appendingPathComponent("entrenamiento.ckpt")
                var checkpointSchedule = GaussianCheckpointSchedule(now: ProcessInfo.processInfo.systemUptime)
                func energyBoundary() throws -> Bool {
                    do {
                        try policy.checkpoint(control: control.energyCancellation,
                                              additionalCheck: { try control.checkPacingState() })
                        return true
                    } catch GaussianTrainingControl.PacingInterruption.stateChanged {
                        return false
                    } catch is CancellationError {
                        if control.action() == .cancel { return false }
                        throw CancellationError()
                    }
                }
                do {
                    let logURL = folder.appendingPathComponent("entrenamiento.csv")
                    if !FileManager.default.fileExists(atPath: logURL.path) {
                        try Data("iteration,splats,milliseconds\n".utf8).write(to: logURL)
                    }
                    let log = try FileHandle(forWritingTo: logURL)
                    try log.seekToEnd()
                    defer { try? log.close() }
                    var stats = FormaGaussianStats(iteration: 0, splats: 0, milliseconds: 0)
                    while true {
                        let action = control.action()
                        if action == .cancel || action == .pause || !control.isActive {
                            if let activeHandle = handle {
                                if checkpointEligible {
                                    guard checkpoint.path.withCString({ forma_gaussian_checkpoint(activeHandle, $0, &error, error.count) }) else {
                                        throw GaussianTrainingError.engine(String(cString: error))
                                    }
                                    try GaussianRecovery.update(session: session, workspaceURL: folder, step: Int(stats.iteration))
                                    resumeSource = checkpoint
                                    checkpointSchedule.didSave(now: ProcessInfo.processInfo.systemUptime)
                                }
                                releaseEngine(); checkpointEligible = false
                            }
                            if action == .cancel { await owner?.receiveCancelled(checkpoint: checkpoint, token: token); return }
                            await owner?.receivePause(checkpoint: checkpoint, token: token)
                            await control.waitUntilResumedAsync()
                            policy.resetWorkClock()
                            continue
                        }
                        if handle == nil {
                            // No Metal creation is initiated while inactive; an in-flight step
                            // finishes at the next boundary before checkpointing/releasing GPU.
                            guard try energyBoundary(), control.isActive else { continue }
                            let request = control.takeEngineRequest() ?? control.prepareAndTakeEngineRequest()
                            await owner?.receiveEngineWait(token: token)
                            guard let request, let admission = await GaussianEngineGate.shared.acquire(request) else { continue }
                            engineLease = admission
                            guard try energyBoundary(), control.isActive else { releaseEngine(); continue }
                            await owner?.receiveEngineAcquired(token: token)
                            guard try energyBoundary(), control.isActive else { releaseEngine(); continue }
                            handle = datasetURL.path.withCString { dataset in
                                library.path.withCString { metal in forma_gaussian_create(dataset, metal, Int32(iterations), downscale, &error, error.count) }
                            }
                            guard handle != nil else { throw GaussianTrainingError.engine(String(cString: error)) }
                            // An unresumed handle is never checkpointed over the last valid
                            // recovery file when pause arrives during loading/rest.
                            guard try energyBoundary(), control.isActive else { continue }
                            if let resumeSource {
                                guard try energyBoundary(), control.isActive else { continue }
                                var resumed: Int32 = 0
                                guard resumeSource.path.withCString({ forma_gaussian_resume(handle, $0, &resumed, &error, error.count) }) else {
                                    throw GaussianTrainingError.engine(String(cString: error))
                                }
                                guard try energyBoundary(), control.isActive else { continue }
                            }
                            guard forma_gaussian_stats(handle, &stats, &error, error.count) else {
                                throw GaussianTrainingError.engine(String(cString: error))
                            }
                            checkpointEligible = true
                            if Int(stats.iteration) >= iterations && control.action() != .export {
                                throw GaussianTrainingError.engine("El checkpoint ya alcanzó \(stats.iteration) pasos. Elige un objetivo superior o guarda la exportación existente.")
                            }
                            _ = try energyBoundary()
                            continue // Re-check lifecycle immediately after initialization/resume.
                        }
                        if action == .export {
                            await owner?.receiveExporting(token: token)
                            guard try energyBoundary(), control.isActive, control.action() == .export else { continue }
                            guard folder.path.withCString({ forma_gaussian_export(handle, $0, &error, error.count) }) else {
                                throw GaussianTrainingError.engine(String(cString: error))
                            }
                            guard try energyBoundary(), control.isActive else { continue }
                            break
                        }
                        guard try energyBoundary(), control.isActive, control.action() == .run else { continue }
                        guard forma_gaussian_step(handle, &stats, &error, error.count) else {
                            throw GaussianTrainingError.engine(String(cString: error))
                        }
                        try log.write(contentsOf: Data("\(stats.iteration),\(stats.splats),\(stats.milliseconds)\n".utf8))
                        if checkpointSchedule.isDue(now: ProcessInfo.processInfo.systemUptime) {
                            // Stream the current tensors to an atomic checkpoint;
                            // keep the engine resident and the session running.
                            guard checkpoint.path.withCString({ forma_gaussian_checkpoint(handle, $0, &error, error.count) }) else {
                                throw GaussianTrainingError.engine(String(cString: error))
                            }
                            try GaussianRecovery.update(session: session, workspaceURL: folder, step: Int(stats.iteration))
                            resumeSource = checkpoint
                            checkpointSchedule.didSave(now: ProcessInfo.processInfo.systemUptime)
                            await owner?.receiveCheckpoint(checkpoint, token: token)
                        }
                        if stats.iteration % 5 == 0 || Int(stats.iteration) >= iterations {
                            await owner?.receive(stats, token: token)
                        }
                        if Int(stats.iteration) >= iterations { control.requestAutomaticExport() }
                        _ = try energyBoundary()
                    }
                    let metadata: [String: Any] = [
                        "engine": "msplat-ios", "upstreamCommit": "e8611098583059b82e0b7d35259fb4e9c42df248",
                        "representation": "trained-3d-gaussian-splatting", "steps": Int(stats.iteration),
                        "requestedIterations": iterations, "splats": Int(stats.splats), "downscaleFactor": downscale,
                        "numDownscales": 0, "keepCrs": true, "sphericalHarmonicsDegree": 3,
                        "primaryViewerDegree": 3, "splatDegree": 0, "dataset": datasetURL.lastPathComponent,
                        "mobileTargetActiveFraction": 1.0,
                        "mobileResourcePausePolicy": "continuous-no-memory-or-thermal-pause",
                        "mobileMeasuredWorkSeconds": policy.snapshot.measuredWorkSeconds,
                        "mobileRestSeconds": policy.snapshot.restSeconds,
                        "note": "Entrenamiento fotométrico local. Visor PLY conserva SH3; .splat complementario conserva color base SH0. No certifica dimensiones."
                    ]
                    let metadataURL = folder.appendingPathComponent("gaussianas.json")
                    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: metadataURL, options: .atomic)
                    try GaussianRecovery.update(session: session, workspaceURL: folder, step: Int(stats.iteration), state: "exported")
                    releaseEngine()
                    let result = Self.packagedResult(folder: folder, datasetURL: datasetURL, steps: Int(stats.iteration), splats: Int(stats.splats), downscale: downscale, duration: Date().timeIntervalSince(startedAt))
                    await owner?.receiveResult(result, checkpoint: checkpoint, token: token)
                } catch {
                    // Preserve every workspace and checkpoint on failure; never destroy source images.
                    var failure = error.localizedDescription
                    if let activeHandle = handle {
                        var checkpointError = [CChar](repeating: 0, count: 2048)
                        var savedStats = FormaGaussianStats(iteration: 0, splats: 0, milliseconds: 0)
                        if checkpointEligible,
                           checkpoint.path.withCString({ forma_gaussian_checkpoint(activeHandle, $0, &checkpointError, checkpointError.count) }),
                           forma_gaussian_stats(activeHandle, &savedStats, &checkpointError, checkpointError.count) {
                            do {
                                try GaussianRecovery.update(session: session, workspaceURL: folder, step: Int(savedStats.iteration), state: "interrupted")
                                failure += " Se conservó un checkpoint recuperable."
                            } catch { failure += " El checkpoint existe, pero falló su índice: \(error.localizedDescription)." }
                        } else if checkpointEligible {
                            failure += " No se pudo guardar otro checkpoint: \(String(cString: checkpointError)). El anterior, si existía, se conserva."
                        } else {
                            failure += " Se conserva el checkpoint anterior, si existía; la inicialización no completó un estado nuevo."
                        }
                    }
                    releaseEngine()
                    GaussianEngineGate.shared.interrupt(jobID: token)
                    await owner?.receiveFailure(failure, token: token)
                }
            }
            await worker.value
        }
        #endif
    }

    func pause(cause: GaussianSessionPauseState.Cause = .manual) {
        guard phase == .running || phase == .exporting else { return }
        if cause == .manual { persistIntent(.manuallyPaused) }
        pauseSession.requestPause(cause)
        pauseCause = pauseSession.cause
        message = pauseSession.cause?.requestMessage ?? cause.requestMessage
        guard !pauseRequested else { updateActivity(); return }
        pauseRequested = true
        beginBackgroundCheckpoint()
        control?.set(.pause)
        updateActivity()
    }

    func resume() {
        guard phase == .paused, !pauseRequested else { return }
        let environment = GaussianSessionPauseState.Environment(
            applicationActive: UIApplication.shared.applicationState == .active)
        switch pauseSession.resumeDecision(environment) {
        case .requiresForeground:
            message = "Vuelve a Forma para continuar; el entrenamiento necesita GPU autorizada."
            updateActivity(); return
        case .notPaused:
            return
        case .allowed:
            break
        }
        persistIntent(.running)
        control?.prepareEngineRequest()
        guard control?.resumeIfActive(environment.applicationActive) == true else {
            phase = .settings
            continueAfterSystemInterruption()
            return
        }
        pauseSession.didResume(); pauseCause = nil
        phase = control?.action() == .export ? .exporting : .running
        pauseRequested = false; message = phase == .exporting ? "Continuando exportación local." : "Continuando optimización local."
        updateIdleTimer()
        energyPolicy?.resetWorkClock()
        updateActivity()
    }

    func stopAndExport() {
        guard (phase == .running || phase == .paused), !pauseRequested else { return }
        guard UIApplication.shared.applicationState == .active else {
            message = "Vuelve a Forma para exportar con Metal; la firma actual no autoriza GPU en segundo plano."
            updateActivity(); return
        }
        pauseSession.didResume(); pauseCause = nil
        exportRequested = true; persistIntent(.running)
        if control == nil || control?.action() == .cancel {
            phase = .settings
            continueAfterSystemInterruption()
            return
        }
        if phase == .paused { control?.prepareEngineRequest() }
        phase = .exporting; pauseRequested = false; message = "Terminando el paso actual y exportando el entrenamiento real."
        control?.setApplicationActive(true)
        updateIdleTimer()
        control?.set(.export)
        updateActivity()
    }

    func cancel() {
        guard phase == .running || phase == .paused || phase == .exporting else { return }
        persistIntent(.stopped)
        beginBackgroundCheckpoint(); control?.set(.cancel)
        pauseRequested = true; message = "Conservando el checkpoint y liberando GPU…"
        updateActivity()
    }

    func setApplicationActive(_ active: Bool) {
        executionLease?.setApplicationActive(active)
        if active { energyPolicy?.resetWorkClock() }
        // A CPU-only grant must never authorize this Metal engine. The current
        // GPU lease deliberately falls back to foreground execution.
        let backgroundGPU = executionLease.map { $0.canContinueInBackground && !$0.shouldUseCPUOnly } ?? false
        control?.setApplicationActive(active || backgroundGPU)
        if !active && !backgroundGPU {
            pause(cause: .applicationInactive)
        } else if active && phase == .paused && pauseSession.shouldResumeWhenActive {
            resume()
        }
    }

    func continueAfterSystemInterruption() {
        guard desiredIntent == .running, phase == .settings,
              UIApplication.shared.applicationState == .active,
              let session = recoverySession else { return }
        let latest = (try? JSONDecoder().decode(GaussianRecoverySession.self,
            from: Data(contentsOf: session.workspaceURL.appendingPathComponent("session.json")))) ?? session
        // An uncheckpointed initialization may safely restart from its immutable sources.
        let checkpoint = FileManager.default.fileExists(atPath: session.checkpointURL.path) ? session.checkpointURL : nil
        start(datasetURL: latest.datasetURL, iterations: latest.targetIterations,
              downscale: latest.downscale, resumeURL: checkpoint,
              continuingExport: exportRequested || latest.step >= latest.targetIterations)
    }

    private func persistIntent(_ intent: GaussianRunIntention.Intent) {
        desiredIntent = intent
        guard let workspace else { return }
        do { try GaussianRunIntention.save(intent, exportRequested: exportRequested, to: workspace) }
        catch { executionNotice = "No se pudo registrar el control para el siguiente arranque: \(error.localizedDescription)" }
    }

    func receiveMemoryWarning() {
        guard phase == .running || phase == .exporting || phase == .paused else { return }
        pauseSession.observeMemoryWarning()
        memoryWarningCount = pauseSession.memoryWarningCount
        // A warning is information, not a stop command. UIKit and the OS retain
        // their own resource enforcement; never rewrite a manual pause here.
    }

    private func updateIdleTimer() {
        if phase == .running || phase == .exporting {
            if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
            self.previousIdleTimer = nil
        }
    }

    private func beginBackgroundCheckpoint() {
        guard backgroundTask == .invalid, phase == .running || phase == .exporting else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Guardar checkpoint Gaussian") { [weak self] in
            Task { @MainActor in
                self?.checkpointAllowanceExpired()
            }
        }
    }
    func checkpointAllowanceExpired() {
        systemReleaseRequested = true
        control?.set(.cancel)
        endBackgroundCheckpoint()
    }
    private func endBackgroundCheckpoint() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    nonisolated private static func packagedResult(folder: URL, datasetURL: URL, steps: Int, splats: Int, downscale: Float, duration: TimeInterval) -> CaptureResult {
        var result = CaptureResult(mesh: nil, modelURL: folder.appendingPathComponent("gaussianas.ply"), mode: .lidar, duration: duration,
                                   note: "Gaussian Splatting local · \(steps) pasos · \(splats) gaussianas. Visor PLY SH3; complemento SPLAT SH0. No es una malla ni una medida certificada.")
        result.cleanupDirectory = folder; result.modelPackageURL = folder; result.captureDatasetURL = datasetURL
        result.gaussianModelRelativePath = "gaussianas.ply"
        result.statistics = ["splats": Double(splats), "steps": Double(steps), "downscaleFactor": Double(downscale)]
        return result
    }

    private func receive(_ stats: FormaGaussianStats, token: UUID) {
        guard jobID == token else { return }
        iteration = Int(stats.iteration); splatCount = Int(stats.splats); milliseconds = stats.milliseconds
        updateActivity()
    }
    private func receiveCheckpoint(_ checkpoint: URL, token: UUID) {
        guard jobID == token else { return }
        checkpointURL = checkpoint
    }
    private func receivePause(checkpoint: URL, token: UUID) {
        guard jobID == token else { return }
        let exists = FileManager.default.fileExists(atPath: checkpoint.path)
        checkpointURL = exists ? checkpoint : nil; phase = .paused; pauseRequested = false; waitingForEngine = false
        pauseSession.didPause(); pauseCause = pauseSession.cause
        updateIdleTimer()
        endBackgroundCheckpoint()
        message = pauseSession.confirmedMessage(hasCheckpoint: exists)
        updateActivity()
        if UIApplication.shared.applicationState == .active && pauseSession.shouldResumeWhenActive {
            resume()
        }
    }
    private func receiveExporting(token: UUID) {
        guard jobID == token else { return }
        phase = .exporting; message = "Escribiendo PLY, SPLAT y checkpoint."
        updateActivity()
    }
    private func receiveResult(_ result: CaptureResult, checkpoint: URL, token: UUID) {
        guard jobID == token else { return }
        self.result = result; checkpointURL = checkpoint; phase = .ready; waitingForEngine = false
        persistIntent(.completed)
        pauseCause = nil
        endBackgroundCheckpoint()
        message = "Entrenamiento exportado. El visor PLY conserva SH3; SPLAT complementario guarda el color base SH0."
        pauseRequested = false
        finishActivity(success: true, status: "Gaussianas exportadas; listas para guardar")
    }
    private func receiveFailure(_ message: String, token: UUID) {
        guard jobID == token else { return }
        if let saved = recoverySession?.checkpointURL, FileManager.default.fileExists(atPath: saved.path) { checkpointURL = saved }
        fail(message)
    }
    private func receiveCancelled(checkpoint: URL, token: UUID) {
        guard jobID == token else { return }
        checkpointURL = FileManager.default.fileExists(atPath: checkpoint.path) ? checkpoint : nil
        phase = .settings; pauseRequested = false; waitingForEngine = false; endBackgroundCheckpoint()
        pauseCause = nil
        message = "Estado conservado en las sesiones recuperables de la biblioteca."
        finishActivity(success: false, status: "Trabajo detenido; estado conservado")
        if systemReleaseRequested {
            systemReleaseRequested = false
            if desiredIntent == .manuallyPaused {
                pauseSession.requestPause(.manual); pauseSession.didPause()
                pauseCause = .manual; phase = .paused
                message = "Pausa solicitada. Estado conservado; pulsa Continuar cuando quieras."
            }
            else { continueAfterSystemInterruption() }
        }
    }
    private func fail(_ message: String) {
        persistIntent(.failed)
        self.message = message; phase = .failed; pauseRequested = false; pauseCause = nil; waitingForEngine = false; endBackgroundCheckpoint()
        finishActivity(success: false, status: message)
    }

    private func receiveEnergyState(_ snapshot: MobileProcessingPolicy.Snapshot, token: UUID) {
        guard token == jobID, phase == .running || phase == .exporting else { return }
        energyLabel = "Entrenamiento continuo · sin esperas programadas"
        updateActivity()
    }
    private func receiveEngineWait(token: UUID) {
        guard token == jobID, phase == .running || phase == .exporting, !pauseRequested else { return }
        waitingForEngine = true
        message = "Esperando turno del motor Gaussian. La configuración y el avance se conservan."
        updateActivity()
    }
    private func receiveEngineAcquired(token: UUID) {
        guard token == jobID, phase == .running || phase == .exporting, !pauseRequested else { return }
        waitingForEngine = false
        message = "Preparando el motor para continuar el entrenamiento local."
        updateActivity()
    }

    private func updateActivity() {
        guard let activityID, activityID == jobID else { return }
        let activityPhase: String
        if pauseRequested { activityPhase = "pausing" }
        else {
            switch phase {
            case .paused: activityPhase = executionLease?.canContinueInBackground == true ? "paused" : "pausedForeground"
            case .exporting: activityPhase = "saving"
            case .ready: activityPhase = "completed"
            case .failed, .settings: activityPhase = "failed"
            case .running: activityPhase = "running"
            }
        }
        ProcessingActivityCoordinator.shared.update(id: activityID, progress: progressFraction, status: message,
                                                     phase: activityPhase, energyLabel: energyLabel)
    }

    private func finishActivity(success: Bool, status: String) {
        updateIdleTimer()
        if let activityID { ProcessingActivityCoordinator.shared.finish(id: activityID, success: success, status: status) }
        activityID = nil; executionLease = nil; energyPolicy = nil
    }
}

/// Pause decisions shared by the real trainer and deterministic lifecycle tests.
/// Resource warnings are diagnostic only; only user/lifecycle events pause GPU.
struct GaussianSessionPauseState {
    enum Cause: String, Equatable, Sendable {
        case manual, applicationInactive, executionExpired

        fileprivate var priority: Int {
            switch self {
            case .manual: return 3
            case .applicationInactive: return 1
            case .executionExpired: return 2
            }
        }

        var requestMessage: String {
            switch self {
            case .manual: return "Pausa solicitada. Guardando checkpoint y liberando GPU…"
            case .applicationInactive: return "Forma dejó de estar activa. Guardando checkpoint y liberando GPU…"
            case .executionExpired: return "iOS terminó la autorización. Guardando checkpoint y liberando GPU…"
            }
        }
    }

    struct Environment {
        var applicationActive: Bool
    }

    enum ResumeDecision: Equatable { case allowed, requiresForeground, notPaused }
    enum Stage: Equatable { case running, pauseRequested, paused }
    private(set) var stage: Stage = .running
    private(set) var cause: Cause?
    private(set) var memoryWarningCount = 0
    var shouldResumeWhenActive: Bool { cause == .applicationInactive || cause == .executionExpired }

    mutating func observeMemoryWarning() { memoryWarningCount += 1 }

    mutating func requestPause(_ requested: Cause) {
        if cause == nil || requested.priority > cause!.priority { cause = requested }
        stage = .pauseRequested
    }

    mutating func didPause() {
        // A lifecycle boundary can pause the worker before its UI notification.
        if cause == nil { cause = .applicationInactive }
        stage = .paused
    }

    func resumeDecision(_ environment: Environment) -> ResumeDecision {
        guard stage == .paused else { return .notPaused }
        guard environment.applicationActive else { return .requiresForeground }
        return .allowed
    }

    mutating func didResume() { stage = .running; cause = nil }

    func confirmedMessage(hasCheckpoint: Bool) -> String {
        let saved = hasCheckpoint ? "Checkpoint guardado y GPU liberada." : "GPU liberada; la inicialización no completó un checkpoint nuevo."
        switch cause {
        case .applicationInactive:
            return "Forma dejó de estar activa. \(saved) Al volver a Forma continuará automáticamente."
        case .executionExpired:
            return "iOS terminó la autorización de segundo plano. \(saved) Al volver a Forma continuará automáticamente."
        case .manual, nil:
            return "Pausa solicitada. \(saved) Pulsa Continuar cuando quieras."
        }
    }
}

/// Recovery writes add no session pause and never reduce model resolution.
struct GaussianCheckpointSchedule {
    private var savedAt: TimeInterval
    init(now: TimeInterval) { savedAt = now }
    func isDue(now: TimeInterval) -> Bool { now.isFinite && now - savedAt >= 30 }
    mutating func didSave(now: TimeInterval) { savedAt = now }
}

/// Continuing a session keeps its last PLY on disk. That older export is not
/// the result of a newer checkpoint until a matching export completes.
enum GaussianRecoveryExportPolicy {
    static func splatCount(session: GaussianRecoverySession, metadata: [String: Any]) -> Int? {
        guard session.state == "exported", session.step >= 0,
              let exportedSteps = metadata["steps"] as? Int, exportedSteps == session.step,
              let count = metadata["splats"] as? Int, count >= 0 else { return nil }
        return count
    }
}

private enum GaussianTrainingError: LocalizedError {
    case engine(String)
    var errorDescription: String? { switch self { case .engine(let text): return text } }
}

final class GaussianTrainingControl: @unchecked Sendable {
    enum Action { case run, pause, export, cancel }
    enum PacingInterruption: Error { case stateChanged }
    let energyCancellation = ProcessingControl()
    private let condition = NSCondition()
    private var value: Action = .run
    private var exportRequested = false
    private var active: Bool
    private let engineJobID: UUID?
    private var engineRequest: GaussianEngineGate.Ticket?
    private var asyncWaiters: [CheckedContinuation<Void, Never>] = []
    init(active: Bool, engineJobID: UUID? = nil) {
        self.active = active; self.engineJobID = engineJobID
        if !active { value = .pause }
    }
    deinit {
        if let engineJobID {
            // A weak eligibility callback can relinquish its last control
            // reference under the gate lock. Clean up without re-entering it.
            DispatchQueue.global(qos: .utility).async { GaussianEngineGate.shared.interrupt(jobID: engineJobID) }
        }
    }
    var isActive: Bool { condition.lock(); defer { condition.unlock() }; return active }
    func prepareEngineRequest() {
        guard let engineJobID else { return }
        condition.lock(); let cancelled = value == .cancel; condition.unlock()
        guard !cancelled else { return }
        let request = GaussianEngineGate.shared.enqueue(jobID: engineJobID) { [weak self] in
            guard let self else { return false }
            self.condition.lock(); defer { self.condition.unlock() }
            return self.active && (self.value == .run || self.value == .export)
        }
        condition.lock()
        let previous = engineRequest; engineRequest = request
        let nowCancelled = value == .cancel
        condition.unlock()
        if let previous { GaussianEngineGate.shared.withdraw(previous) }
        if nowCancelled { GaussianEngineGate.shared.withdraw(request) }
    }
    func takeEngineRequest() -> GaussianEngineGate.Ticket? {
        condition.lock(); defer { condition.unlock() }
        let request = engineRequest; engineRequest = nil; return request
    }
    func prepareAndTakeEngineRequest() -> GaussianEngineGate.Ticket? {
        prepareEngineRequest(); return takeEngineRequest()
    }
    func set(_ action: Action) {
        condition.lock()
        if value != .cancel {
            value = action
            if action == .export { exportRequested = true }
            else if action == .run { exportRequested = false }
        }
        let waiting = takeReadyWaitersLocked()
        condition.broadcast(); condition.unlock()
        for continuation in waiting { continuation.resume() }
        if (action == .pause || action == .cancel), let engineJobID { GaussianEngineGate.shared.interrupt(jobID: engineJobID) }
        if action == .cancel { energyCancellation.cancel() }
    }
    func action() -> Action { condition.lock(); defer { condition.unlock() }; return value }
    /// UIKit may already be active before SwiftUI delivers its scene change.
    /// Update the lifecycle flag and requested action under the same lock.
    @discardableResult func resumeIfActive(_ active: Bool) -> Bool {
        condition.lock()
        guard value != .cancel, active else { condition.unlock(); return false }
        self.active = active; value = exportRequested ? .export : .run
        let waiting = takeReadyWaitersLocked()
        condition.broadcast(); condition.unlock()
        for continuation in waiting { continuation.resume() }
        return true
    }
    func requestAutomaticExport() {
        condition.lock()
        if value == .run { value = .export; exportRequested = true }
        condition.broadcast(); condition.unlock()
    }
    func setApplicationActive(_ active: Bool) {
        condition.lock(); self.active = active
        if !active && (value == .run || value == .export) { value = .pause }
        let waiting = takeReadyWaitersLocked()
        condition.broadcast(); condition.unlock()
        for continuation in waiting { continuation.resume() }
        if !active, let engineJobID { GaussianEngineGate.shared.interrupt(jobID: engineJobID) }
    }
    /// Interrupt energy rest before waiting on the service's pause condition, so
    /// its worker can first checkpoint and destroy the Metal handle.
    func checkPacingState() throws {
        condition.lock(); let allowed = active && (value == .run || value == .export); condition.unlock()
        if !allowed { throw PacingInterruption.stateChanged }
    }
    func waitUntilResumed() { condition.lock(); while (value == .pause || !active) && value != .cancel { condition.wait() }; condition.unlock() }
    /// A paused job must not occupy a cooperative executor thread while other
    /// admitted jobs need that executor to start or checkpoint.
    func waitUntilResumedAsync() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if (value == .pause || !active) && value != .cancel {
                asyncWaiters.append(continuation); condition.unlock()
            } else { condition.unlock(); continuation.resume() }
        }
    }
    private func takeReadyWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        guard (value != .pause && active) || value == .cancel else { return [] }
        let waiting = asyncWaiters; asyncWaiters.removeAll(); return waiting
    }
    func waitForForeground() { condition.lock(); while !active && value != .cancel { condition.wait() }; condition.unlock() }
}
