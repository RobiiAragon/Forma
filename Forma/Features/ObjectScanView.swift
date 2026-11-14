import SwiftUI
import RealityKit
import AVFoundation
import Observation
import UIKit

/// Object Capture acquires the photographs; PhotogrammetrySession reconstructs them on this device.
@MainActor
struct ObjectScanView: View {
    var onComplete: (CaptureResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var scanner = ObjectScanner()
    @State private var showsFlipInstructions = false

    private let accent = Color(red: 1, green: 0.36, blue: 0.18)

    var body: some View {
        ZStack {
            Color(red: 0.063, green: 0.067, blue: 0.075).ignoresSafeArea()
            if let session = scanner.captureSession, scanner.phase == .capture {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            } else {
                statusIllustration
            }

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                controls
            }
        }
        .preferredColorScheme(.dark)
        .task { await scanner.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { scanner.enteredBackground() }
            if phase == .active { scanner.becameActive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            scanner.thermalStateChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            scanner.receivedMemoryWarning()
        }
        .onDisappear { scanner.stop() }
        .alert("Capturar la otra cara", isPresented: $showsFlipInstructions) {
            Button("Ya está volteado") { scanner.beginFlippedPass() }
            Button("Cancelar", role: .cancel) { scanner.cancelFlip() }
        } message: {
            Text("La captura está en pausa. Voltea el objeto con cuidado y vuelve a apuntarlo. Hazlo solo si es rígido y puede mantenerse estable.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .foregroundStyle(accent)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Objetos").font(.headline)
                Text("Fotogrametría en tu iPhone")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button {
                scanner.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Cerrar captura de objetos")
            .accessibilityIdentifier("closeCapture")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.72))
    }

    private var statusIllustration: some View {
        VStack(spacing: 22) {
            Image(systemName: scanner.phase == .ready ? "checkmark.seal" : "cube.transparent")
                .font(.system(size: 88, weight: .ultraLight))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            if scanner.phase == .processing {
                ProgressView(value: scanner.progress)
                    .tint(accent)
                    .frame(maxWidth: 240)
                Text(scanner.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(.title2, design: .monospaced))
                    .monospacedDigit()
                Text(scanner.processingStage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if scanner.phase == .preparing {
                ProgressView().tint(accent)
            }
        }
        .padding(.bottom, 190)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(scanner.title)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 8)
                if scanner.phase == .capture {
                    Text("\(scanner.captureSession?.numberOfShotsTaken ?? 0) fotos")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(accent)
                }
            }
            Text(scanner.instructions)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            if let feedback = scanner.captureFeedback {
                Label(feedback, systemImage: "viewfinder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = scanner.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if scanner.phase == .capture || scanner.phase == .processingPaused {
                DisclosureGroup("Ajustes de reconstrucción local") {
                    Toggle("Sensibilidad alta", isOn: $scanner.qualityOptions.highSensitivity)
                    Toggle("Aislar objeto mediante máscara", isOn: $scanner.qualityOptions.objectMasking)
                    Toggle("Fotos en secuencia de captura", isOn: $scanner.qualityOptions.sequentialOrdering)
                    Text("iPhone solo ofrece el detalle Reduced del motor Apple. Full, Raw y presupuestos personalizados están disponibles en Mac. Sensibilidad alta busca más correspondencias y puede necesitar más recursos; no garantiza mayor precisión. La máscara excluye el fondo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(scanner.isCancelling)
            }
            actionButtons
        }
        .padding(20)
        .background(.black.opacity(0.83), in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.1), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch scanner.phase {
        case .capture:
            captureButtons
        case .ready:
            Button {
                guard let result = scanner.takeResult() else { return }
                onComplete(result)
                dismiss()
            } label: {
                Label("Guardar modelo", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
        case .processing:
            Button("Pausar reconstrucción") { scanner.pauseProcessing(reason: "El proceso está en pausa. Las fotografías se conservan para continuar.") }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        case .processingPaused:
            Button(scanner.isCancelling ? "Terminando de pausar…" : "Continuar reconstrucción") { scanner.resumeProcessing() }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(scanner.isCancelling)
                .frame(maxWidth: .infinity)
        case .failure:
            if scanner.permissionDenied {
                Button("Abrir ajustes de cámara") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            Button("Volver a intentar") { Task { await scanner.restart() } }
                .buttonStyle(.bordered)
        case .unsupported, .preparing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var captureButtons: some View {
        if let session = scanner.captureSession {
            switch session.state {
            case .ready:
                primaryButton("Detectar objeto", symbol: "viewfinder") { scanner.detectObject() }
            case .detecting:
                primaryButton("Comenzar captura", symbol: "record.circle") { scanner.startCapturing() }
                Button("Volver a encuadrar") { scanner.resetDetection() }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            case .capturing:
                primaryButton("Crear modelo", symbol: "cube") { scanner.finishCapturing() }
                    .disabled(session.numberOfShotsTaken == 0)
                HStack(spacing: 8) {
                    Button {
                        scanner.toggleCapturePause()
                    } label: {
                        Label(session.isPaused ? "Continuar" : "Pausar", systemImage: session.isPaused ? "play" : "pause")
                    }
                    Spacer(minLength: 0)
                    Button {
                        session.requestImageCapture()
                    } label: {
                        Label("Foto", systemImage: "camera")
                    }
                    .disabled(!session.canRequestImageCapture || session.isPaused)
                    Spacer(minLength: 0)
                    Button {
                        if scanner.prepareFlip() { showsFlipInstructions = true }
                    } label: {
                        Label("Otra cara", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!session.userCompletedScanPass || session.feedback.contains(.objectNotFlippable))
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                if session.userCompletedScanPass {
                    Button("Añadir otra vuelta a distinta altura") { scanner.beginAnotherPass() }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
            case .initializing, .finishing:
                HStack {
                    Spacer()
                    ProgressView().tint(accent)
                    Spacer()
                }
            case .completed, .failed:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
        .controlSize(.large)
    }
}

@MainActor
@Observable
private final class ObjectScanner {
    enum Phase { case preparing, capture, processing, processingPaused, ready, unsupported, failure }

    var phase: Phase = .preparing
    var captureSession: ObjectCaptureSession?
    var progress = 0.0
    var processingStage = "Preparando imágenes"
    var notice: String?
    var permissionDenied = false
    private(set) var memoryWarningCount = 0
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    var isCancelling = false
    var qualityOptions = PhotogrammetryQualityOptions()
    private var effectiveQualityOptions = PhotogrammetryQualityOptions()
    private var automaticDownsampling = false
    private var modelGeometryCounts: ModelGeometryCounts?

    @ObservationIgnored private var workspace: URL?
    @ObservationIgnored private var imagesDirectory: URL?
    @ObservationIgnored private var checkpointDirectory: URL?
    @ObservationIgnored private var reconstructedURL: URL?
    @ObservationIgnored private var reconstruction: PhotogrammetrySession?
    @ObservationIgnored private var captureMonitor: Task<Void, Never>?
    @ObservationIgnored private var processingMonitor: Task<Void, Never>?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var handedOff = false
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var pendingFlip = false
    @ObservationIgnored private var backgroundPausedCapture = false
    @ObservationIgnored private var manuallyPausedCapture = false
    @ObservationIgnored private var resumeProcessingWhenActive = false
    @ObservationIgnored private var capturedShots = 0
    @ObservationIgnored private var skippedShots = 0
    @ObservationIgnored private var failureMessage = ""

    var title: String {
        switch phase {
        case .preparing: return "Preparando cámara"
        case .capture:
            guard let session = captureSession else { return "Captura de objeto" }
            if session.isPaused { return "Captura en pausa" }
            switch session.state {
            case .initializing: return "Iniciando cámara"
            case .ready: return "Encuadra tu objeto"
            case .detecting: return "Ajusta el recuadro"
            case .capturing: return session.userCompletedScanPass ? "Vuelta completada" : "Rodea el objeto"
            case .finishing: return "Guardando fotografías"
            default: return "Captura de objeto"
            }
        case .processing: return "Construyendo tu modelo"
        case .processingPaused: return "Reconstrucción en pausa"
        case .ready: return "Tu objeto, en 3D"
        case .unsupported: return "Dispositivo no compatible"
        case .failure: return "No se pudo completar"
        }
    }

    var instructions: String {
        switch phase {
        case .preparing: return "Se comprobará el acceso a la cámara y la compatibilidad con captura y reconstrucción local."
        case .capture:
            guard let session = captureSession else { return "Preparando la captura." }
            if session.isPaused { return "Mantén el objeto estable. Continúa cuando el teléfono esté listo y vuelvas a encuadrarlo." }
            switch session.state {
            case .ready: return "Elige un objeto inmóvil, con buena luz y detalles visibles. Colócalo en el centro de la cámara."
            case .detecting: return "Ajusta la caja para que abarque el objeto completo. Deja libre espacio para caminar alrededor."
            case .capturing: return "Muévete despacio y mantén el objeto completo a la vista. Completa varias alturas para captar sus detalles."
            case .finishing: return "Espera mientras se terminan de escribir las imágenes."
            default: return "Mueve el iPhone suavemente para iniciar el seguimiento."
            }
        case .processing: return "\(capturedShots) fotografías se procesan en este iPhone. Mantén la app abierta; no se envía nada a la nube."
        case .processingPaused: return "Las fotografías originales siguen en el dispositivo. Puedes continuar la reconstrucción mientras esta pantalla esté abierta."
        case .ready: return "USDZ con textura generado localmente. Guarda el modelo y sus fotografías originales en tu biblioteca."
        case .unsupported:
            #if targetEnvironment(simulator)
            return "El simulador no tiene cámara ni LiDAR. Abre Objetos en un iPhone o iPad compatible para capturar y reconstruir."
            #else
            return "Este dispositivo no admite el flujo de Object Capture y reconstrucción local de Apple. Se requiere hardware compatible con LiDAR."
            #endif
        case .failure: return failureMessage
        }
    }

    var captureFeedback: String? {
        guard phase == .capture, let session = captureSession else { return nil }
        let feedback = session.feedback
        if feedback.contains(.environmentTooDark) { return "Necesitas más iluminación para continuar." }
        if feedback.contains(.environmentLowLight) { return "Añade luz difusa para conseguir fotos más nítidas." }
        if feedback.contains(.movingTooFast) { return "Más despacio: el movimiento está reduciendo la calidad." }
        if feedback.contains(.objectTooClose) { return "Aléjate un poco del objeto." }
        if feedback.contains(.objectTooFar) { return "Acércate sin recortar el objeto." }
        if feedback.contains(.outOfFieldOfView) { return "Vuelve a incluir el objeto completo en el encuadre." }
        if case .limited = session.cameraTracking { return "Seguimiento limitado. Muévete despacio hacia una zona con más detalles." }
        if session.numberOfShotsTaken > session.maximumNumberOfInputImages {
            return "iOS usará hasta \(session.maximumNumberOfInputImages) fotos para este modelo. Se conservarán también las originales adicionales."
        }
        return nil
    }

    func start() async {
        guard !started, !stopped else { return }
        started = true
        guard ObjectCaptureSession.isSupported, PhotogrammetrySession.isSupported else {
            phase = .unsupported
            return
        }

        let permission: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permission = true
        case .notDetermined: permission = await AVCaptureDevice.requestAccess(for: .video)
        default: permission = false
        }
        guard !stopped else { return }
        guard permission else {
            permissionDenied = true
            fail("Activa el permiso de cámara en Ajustes para capturar objetos.")
            return
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FormaObject-\(UUID().uuidString)", isDirectory: true)
            workspace = directory
            let images = directory.appendingPathComponent("Originales", isDirectory: true)
            let checkpoints = directory.appendingPathComponent("Checkpoints", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
            imagesDirectory = images
            checkpointDirectory = checkpoints
            startedAt = Date()
            let session = ObjectCaptureSession()
            var configuration = ObjectCaptureSession.Configuration()
            configuration.checkpointDirectory = checkpoints
            // Capture has no app quota. Apple may skip excess images during local reconstruction.
            configuration.isOverCaptureEnabled = true
            captureSession = session
            phase = .capture
            captureMonitor = Task { [weak self] in
                for await state in session.stateUpdates {
                    guard let self, !Task.isCancelled, !self.stopped else { return }
                    switch state {
                    case .completed:
                        self.capturedShots = session.numberOfShotsTaken
                        self.captureSession = nil
                        self.beginProcessing()
                        return
                    case .failed(let error):
                        self.fail("La captura no pudo terminar: \(error.localizedDescription)")
                        return
                    default: break
                    }
                }
            }
            session.start(imagesDirectory: images, configuration: configuration)
            if case .failed(let error) = session.state {
                fail("La captura no pudo iniciarse: \(error.localizedDescription)")
                return
            }
            thermalStateChanged()
            if !isActive { session.pause(); backgroundPausedCapture = true }
        } catch {
            fail("No se pudo preparar el almacenamiento: \(error.localizedDescription)")
        }
    }

    func detectObject() {
        if captureSession?.startDetecting() != true { notice = "No se detectó el objeto. Mejora el encuadre y vuelve a intentar." }
        else { notice = nil }
    }

    func resetDetection() {
        _ = captureSession?.resetDetection()
        notice = nil
    }

    func startCapturing() {
        notice = nil
        captureSession?.startCapturing()
    }

    func finishCapturing() {
        guard let session = captureSession, session.numberOfShotsTaken > 0 else { return }
        notice = nil
        session.finish()
    }

    func toggleCapturePause() {
        guard let session = captureSession, isActive else { return }
        if session.isPaused { manuallyPausedCapture = false; session.resume(); notice = nil }
        else { manuallyPausedCapture = true; session.pause() }
    }

    func beginAnotherPass() {
        guard let session = captureSession, session.userCompletedScanPass else { return }
        manuallyPausedCapture = false
        session.beginNewScanPass()
        if session.isPaused { session.resume() }
    }

    func prepareFlip() -> Bool {
        guard let session = captureSession, session.userCompletedScanPass else { return false }
        pendingFlip = true
        session.pause()
        return true
    }

    func beginFlippedPass() {
        guard pendingFlip, let session = captureSession else { return }
        pendingFlip = false
        manuallyPausedCapture = false
        session.beginNewScanPassAfterFlip()
        if isActive { session.resume() }
    }

    func cancelFlip() {
        pendingFlip = false
        manuallyPausedCapture = false
        if isActive { captureSession?.resume() }
    }

    private func beginProcessing() {
        guard !stopped, reconstruction == nil, let images = imagesDirectory, let workspace else { return }
        if !isActive {
            phase = .processingPaused
            resumeProcessingWhenActive = true
            notice = "Vuelve a la app para iniciar la reconstrucción con Metal."
            return
        }

        phase = .processing
        progress = 0
        skippedShots = 0
        automaticDownsampling = false
        modelGeometryCounts = nil
        effectiveQualityOptions = qualityOptions
        processingStage = "Preparando imágenes"
        notice = nil
        reconstructedURL = nil
        let outputURL = workspace.appendingPathComponent("Objeto.usdz")
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) { try FileManager.default.removeItem(at: outputURL) }
            var configuration = PhotogrammetrySession.Configuration()
            // A reconstruction checkpoint may contain a previous configuration.
            // Reuse capture checkpoints only with the original capture defaults;
            // isolate each other combination so changes take effect on retry.
            if effectiveQualityOptions == PhotogrammetryQualityOptions() {
                configuration.checkpointDirectory = checkpointDirectory
            } else {
                let selectedCheckpoints = workspace.appendingPathComponent("Reconstruction-" + effectiveQualityOptions.checkpointKey)
                try FileManager.default.createDirectory(at: selectedCheckpoints, withIntermediateDirectories: true)
                configuration.checkpointDirectory = selectedCheckpoints
            }
            effectiveQualityOptions.apply(to: &configuration)
            let session = try PhotogrammetrySession(input: images, configuration: configuration)
            reconstruction = session
            let request = PhotogrammetrySession.Request.modelFile(url: outputURL, detail: .reduced)
            processingMonitor = Task { [weak self] in
                do {
                    try session.process(requests: [request])
                    for try await output in session.outputs {
                        guard let self, !Task.isCancelled, !self.stopped else { return }
                        if await self.receive(output) { return }
                    }
                    guard let self, !Task.isCancelled, !self.stopped else { return }
                    if self.phase == .processingPaused { self.finishedCancelling(); return }
                    guard self.phase == .processing else { return }
                    self.fail("La reconstrucción terminó sin entregar un modelo. Conserva buena luz y rodea el objeto con más solapamiento.")
                } catch {
                    guard let self, !Task.isCancelled, !self.stopped else { return }
                    if self.phase == .processingPaused { self.finishedCancelling(); return }
                    guard self.phase == .processing else { return }
                    self.fail("No se pudo reconstruir el objeto: \(error.localizedDescription)")
                }
            }
        } catch {
            fail("No se pudo iniciar la reconstrucción local: \(error.localizedDescription)")
        }
    }

    /// Returns true when this output ends the single-model request.
    private func receive(_ output: PhotogrammetrySession.Output) async -> Bool {
        switch output {
        case .requestProgress(_, let fraction):
            progress = min(1, max(progress, fraction.isFinite ? fraction : 0))
        case .requestProgressInfo(_, let info):
            if let stage = info.processingStage { processingStage = stageTitle(stage) }
        case .inputComplete:
            processingStage = "Alineando fotografías"
        case .requestComplete(_, let result):
            if case .modelFile(let url) = result {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                        fail("El sistema produjo un archivo vacío. Vuelve a capturar el objeto con buena iluminación.")
                        return true
                    }
                    reconstructedURL = url
                } catch {
                    fail("No se pudo leer el modelo creado: \(error.localizedDescription)")
                    return true
                }
            }
        case .processingComplete:
            guard let reconstructedURL else {
                fail("La reconstrucción no produjo un archivo USDZ utilizable.")
                return true
            }
            processingStage = "Leyendo geometría exportada"
            let counts = await Task.detached(priority: .utility) {
                PhotogrammetryQualityOptions.geometryCounts(at: reconstructedURL)
            }.value
            guard !stopped else { return true }
            if phase == .processingPaused { finishedCancelling(); return true }
            guard phase == .processing else { return true }
            modelGeometryCounts = counts
            progress = 1
            phase = .ready
            isCancelling = false
            reconstruction = nil
            processingMonitor = nil
            processingStage = "Completado"
            return true
        case .requestError(_, let error):
            if phase == .processingPaused { finishedCancelling(); return true }
            fail("La reconstrucción falló: \(error.localizedDescription)")
            return true
        case .processingCancelled:
            if phase == .processing {
                phase = .processingPaused
                notice = "El sistema canceló el proceso. Puedes volver a iniciarlo con las fotografías guardadas."
            }
            finishedCancelling()
            return true
        case .automaticDownsampling:
            automaticDownsampling = true
            notice = "iOS redujo imágenes para ajustarse a los recursos disponibles. Se conservan las fotografías originales."
        case .invalidSample, .skippedSample:
            skippedShots += 1
            notice = "iOS omitió \(skippedShots) fotografías durante el proceso. Las originales se conservan."
        case .stitchingIncomplete:
            notice = "Algunas vistas no se pudieron unir completamente. Revisa el modelo antes de usarlo."
        @unknown default: break
        }
        return false
    }

    private func stageTitle(_ stage: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch stage {
        case .preProcessing: return "Preparando imágenes"
        case .imageAlignment: return "Alineando fotografías"
        case .pointCloudGeneration: return "Calculando puntos 3D"
        case .meshGeneration: return "Construyendo geometría"
        case .textureMapping: return "Aplicando texturas"
        case .optimization: return "Optimizando modelo"
        @unknown default: return "Procesando modelo"
        }
    }

    func pauseProcessing(reason: String, bySystem: Bool = false) {
        guard phase == .processing else { return }
        resumeProcessingWhenActive = bySystem
        phase = .processingPaused
        notice = reason
        isCancelling = true
        reconstruction?.cancel()
        // Wait for processingCancelled before reusing the same checkpoint directory.
    }

    private func finishedCancelling() {
        isCancelling = false
        reconstruction = nil
        processingMonitor = nil
        if resumeProcessingWhenActive, isActive, !stopped {
            resumeProcessingWhenActive = false
            beginProcessing()
        }
    }

    func resumeProcessing() {
        guard phase == .processingPaused, !isCancelling, isActive else { return }
        resumeProcessingWhenActive = false
        beginProcessing()
    }

    func enteredBackground() {
        isActive = false
        if phase == .capture {
            captureSession?.pause()
            backgroundPausedCapture = !manuallyPausedCapture && !pendingFlip
            notice = "iOS necesita la cámara en primer plano. La captura continuará al volver a Forma."
        }
        if phase == .processing {
            pauseProcessing(reason: "Metal no está autorizado en segundo plano; la reconstrucción continuará al volver a Forma.", bySystem: true)
        }
    }

    func becameActive() {
        isActive = true
        thermalStateChanged()
        if backgroundPausedCapture, !pendingFlip {
            backgroundPausedCapture = false
            // Resuming ARKit tracking can fail; stateUpdates will expose that error to the user.
            captureSession?.resume()
        }
        if resumeProcessingWhenActive, phase == .processingPaused, !isCancelling {
            resumeProcessingWhenActive = false
            beginProcessing()
        }
    }

    func thermalStateChanged() {
        thermalState = ProcessInfo.processInfo.thermalState
    }

    func receivedMemoryWarning() {
        memoryWarningCount += 1
    }

    func takeResult() -> CaptureResult? {
        guard phase == .ready, let url = reconstructedURL else { return nil }
        handedOff = true
        return CaptureResult(
            mesh: nil,
            modelURL: url,
            auxiliaryURLs: imagesDirectory.map { [$0] } ?? [],
            mode: .object,
            duration: Date().timeIntervalSince(startedAt),
            note: "Fotogrametría local · \(capturedShots) fotos · detalle Reduced (único nivel nativo en iPhone), \(effectiveQualityOptions.summary) · USDZ con textura. El detalle no certifica precisión. \(notice ?? "")",
            cleanupDirectory: workspace,
            statistics: effectiveQualityOptions.statistics.merging([
                "photogrammetryDetailLevel": Double(PhotogrammetrySession.Request.Detail.reduced.rawValue),
                "photogrammetryCapturedPhotos": Double(capturedShots),
                "appleSkippedPhotos": Double(skippedShots),
                "appleAutomaticDownsampling": automaticDownsampling ? 1 : 0
            ].merging(modelGeometryCounts.map { [
                "photogrammetryEffectiveVertexCount": Double($0.vertexCount),
                "photogrammetryEffectiveTriangleCount": Double($0.faceCount)
            ] } ?? [:], uniquingKeysWith: { _, new in new }), uniquingKeysWith: { _, new in new }),
            modelGeometryCounts: modelGeometryCounts
        )
    }

    private func fail(_ message: String) {
        failureMessage = message
        phase = .failure
        captureMonitor?.cancel()
        captureMonitor = nil
        captureSession?.cancel()
        captureSession = nil
        reconstruction?.cancel()
        reconstruction = nil
        processingMonitor?.cancel()
        processingMonitor = nil
        isCancelling = false
    }

    func restart() async {
        stop()
        stopped = false
        started = false
        handedOff = false
        permissionDenied = false
        pendingFlip = false
        backgroundPausedCapture = false
        manuallyPausedCapture = false
        resumeProcessingWhenActive = false
        memoryWarningCount = 0
        capturedShots = 0
        skippedShots = 0
        notice = nil
        phase = .preparing
        await start()
    }

    func stop() {
        stopped = true
        captureMonitor?.cancel()
        captureMonitor = nil
        captureSession?.cancel()
        captureSession = nil
        processingMonitor?.cancel()
        processingMonitor = nil
        reconstruction?.cancel()
        reconstruction = nil
        isCancelling = false
        // The library owns cleanup after handoff; its copy may outlive the callback.
        if !handedOff, let workspace { try? FileManager.default.removeItem(at: workspace) }
    }
}
