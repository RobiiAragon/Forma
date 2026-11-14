import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import simd

/// Camera ownership and a CPU execution grant are separate from human intent.
/// Temporary system interruptions never manufacture a manual pause or undo one.
struct LiDARExecutionState: Equatable, Sendable {
    enum CameraIntent: Equatable { case capturing, manuallyPaused, failed, processing, closed }
    private(set) var cameraIntent: CameraIntent = .capturing
    private(set) var foreground = true
    private(set) var visible = true
    private(set) var cameraInterrupted = false
    private(set) var processingManuallyPaused = false
    private(set) var processingCancelled = false
    private(set) var cpuBackgroundGranted = false
    private var cpuGrantExpired = false
    var shouldRunCamera: Bool { cameraIntent == .capturing && foreground && visible && !cameraInterrupted }
    var processingWaitsForForeground: Bool { !foreground && !cpuBackgroundGranted && !processingCancelled }
    var shouldHoldProcessing: Bool { processingManuallyPaused || processingWaitsForForeground }

    mutating func setForeground(_ value: Bool) {
        if value && !foreground { cameraInterrupted = false }
        foreground = value
    }
    mutating func setVisible(_ value: Bool) { visible = value }
    mutating func pauseCameraByUser() { if cameraIntent != .closed { cameraIntent = .manuallyPaused } }
    mutating func resumeCameraByUser() { if cameraIntent != .closed { cameraIntent = .capturing } }
    mutating func cameraFailed() { if cameraIntent != .closed { cameraIntent = .failed } }
    mutating func cameraWasInterrupted() { cameraInterrupted = true }
    mutating func cameraInterruptionEnded() { cameraInterrupted = false }
    mutating func close() { cameraIntent = .closed; processingCancelled = true }
    mutating func beginProcessing() {
        cameraIntent = .processing; processingManuallyPaused = false; processingCancelled = false
        cpuBackgroundGranted = false; cpuGrantExpired = false
    }
    mutating func updateCPUGrant(_ value: Bool) { cpuBackgroundGranted = value && !cpuGrantExpired }
    mutating func expireCPUGrant() { cpuGrantExpired = true; cpuBackgroundGranted = false }
    mutating func pauseProcessingByUser() { if !processingCancelled { processingManuallyPaused = true } }
    mutating func resumeProcessingByUser() { if !processingCancelled { processingManuallyPaused = false } }
    mutating func cancelProcessingByUser() { processingCancelled = true }
}

/// Live, local ARKit reconstruction. The camera only runs while this screen is active.
struct LiDARCaptureView: View {
    let onComplete: (CaptureResult) -> Void
    var offloadProcessing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = LiDARCaptureController()
    @State private var confirmingDiscard = false
    private let accent = Color(red: 1, green: 0.36, blue: 0.18)

    var body: some View {
        ZStack {
            Color(red: 0.063, green: 0.067, blue: 0.075).ignoresSafeArea()
            if capture.isSupported {
                LiDARCameraPreview(controller: capture).ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.8), .clear, .black.opacity(0.9)],
                               startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
            VStack(spacing: 20) {
                HStack {
                    Button {
                        if capture.hasCapturedData { confirmingDiscard = true }
                        else { close() }
                    } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }.accessibilityLabel("Cerrar captura").accessibilityIdentifier("closeCapture")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("ESCANEO LIDAR").font(.caption.weight(.bold)).tracking(2)
                        Text(capture.elapsed.formatted(.number.precision(.fractionLength(0))) + (offloadProcessing ? " s · Híbrido" : " s · iPhone"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                    }
                }
                if capture.isSupported {
                    HStack(spacing: 24) {
                        metric("VÉRTICES", value: capture.vertexCount.formatted())
                        metric("TRIÁNGULOS", value: capture.faceCount.formatted())
                        Spacer(minLength: 0)
                        Image(systemName: capture.isRunning ? "record.circle" : "pause.circle")
                            .foregroundStyle(capture.isRunning ? accent : .white)
                    }
                    .padding(16).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                    ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Máxima calidad de imagen", isOn: Binding(get: { capture.maximumQuality }, set: { capture.setMaximumQuality($0) }))
                            .font(.subheadline).tint(accent)
                            .disabled(capture.isSaving || capture.isWritingKeyframe)
                        LiDARQualityControls(settings: $capture.qualitySettings, captureSettingsLocked: capture.captureSettingsLocked)
                            .disabled(capture.isSaving)
                            .onChange(of: capture.qualitySettings.nativePlaneAssistance) { _, _ in capture.applyPlaneAssistance() }
                        Text(capture.cameraResolution + " · \(capture.savedPhotos) fotos · \(capture.savedDepthFrames) RGB-D")
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                        Text(capture.arCallbackFPS > 0 ? String(format: "AR %.0f fps · Vista %.0f fps · Escritura %.0f ms", capture.arCallbackFPS,
                                    capture.previewCallbackFPS, capture.lastWriteMilliseconds) : "AR — fps · Vista — fps · Escritura — ms")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.65))
                        if capture.savedHighResolutionPhotos > 0 {
                            Text("\(capture.savedHighResolutionPhotos) fotos HiRes · última: \(capture.lastSavedResolution)")
                                .font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                        Label("Guardando fotograma a resolución nativa…", systemImage: "externaldrive.badge.timemachine")
                            .font(.caption2).foregroundStyle(.orange).opacity(capture.isWritingKeyframe ? 1 : 0)
                            .accessibilityHidden(!capture.isWritingKeyframe)
                        Button { capture.captureHighResolutionPhoto(manual: true) } label: {
                            Label("Foto HiRes", systemImage: "camera.aperture").font(.subheadline.weight(.semibold))
                        }.disabled(!capture.isRunning || capture.isSaving || capture.isWritingKeyframe)
                        Text("Fotos automáticas según movimiento y nitidez. Una escritura simultánea para proteger memoria y seguimiento; sin cuota.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                        Text(capture.sensorPacingNotice)
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                    }.padding(14)
                    }.frame(maxHeight: 270).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                }
                Spacer()
                if !capture.isSupported {
                    Image(systemName: "sensor.fill").font(.system(size: 48)).foregroundStyle(accent)
                    Text("LiDAR no disponible").font(.title2.bold())
                    Text("Este dispositivo no admite reconstrucción de mallas de ARKit. En el simulador no se puede capturar geometría real.")
                        .font(.body).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label(capture.status, systemImage: capture.statusSymbol)
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(capture.guidance).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    if let depth = capture.depthQuality {
                        Label(depth, systemImage: "square.3.layers.3d").font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    if let warning = capture.thermalWarning {
                        Label(warning, systemImage: "thermometer.high").font(.caption).foregroundStyle(.orange)
                    }
                    if let notice = capture.recordingNotice {
                        Text(notice).font(.caption).foregroundStyle(.orange)
                    }
                    if capture.isSaving {
                        ProgressView(value: capture.processingProgress).tint(accent)
                        if capture.processingState.isPauseActive {
                            Label(capture.processingWaitingForForeground ? "Esperando ejecución de iOS" : (capture.processingState.phase == .paused ? "Procesamiento en pausa" : "Solicitando pausa…"),
                                  systemImage: capture.processingState.phase == .paused ? "pause.circle.fill" : "hourglass")
                                .font(.subheadline.weight(.semibold)).accessibilityIdentifier("lidarProcessingPauseState")
                            Text(capture.processingWaitingForForeground
                                 ? "El progreso se conserva y continúa al volver a Forma. Una pausa manual se mantiene."
                                 : capture.processingState.phase == .paused
                                 ? "Se conservan el progreso, las fotografías y la malla. Puedes continuar desde aquí."
                                 : "Termina la operación de archivo o imagen actual antes de detener el trabajo.")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    if capture.cameraDenied {
                        Button("Abrir ajustes de cámara") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.borderedProminent).tint(accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 20))

                if capture.isSupported && !capture.cameraDenied {
                    HStack(spacing: 12) {
                        if capture.isSaving {
                            Button { capture.toggleProcessingPause() } label: {
                                Label(capture.processingManuallyPaused ? "Continuar" : "Pausar trabajo",
                                      systemImage: capture.processingManuallyPaused ? "play.fill" : "pause.fill")
                                    .frame(maxWidth: .infinity).frame(height: 54)
                            }.background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                                .accessibilityIdentifier("pauseLiDARProcessing")
                        } else {
                            Button {
                                capture.isRunning ? capture.pause(reason: "Captura en pausa") : capture.resume()
                            } label: {
                                Label(capture.isRunning ? "Pausar" : "Continuar",
                                      systemImage: capture.isRunning ? "pause.fill" : "play.fill")
                                    .frame(maxWidth: .infinity).frame(height: 54)
                            }.background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                            .disabled(!capture.canResume && !capture.isRunning)
                        }
                        Button {
                            capture.finish { result in onComplete(result); dismiss() }
                        } label: {
                            HStack {
                                if capture.isSaving { ProgressView().tint(.white) }
                                else { Image(systemName: "checkmark") }
                                Text(capture.isSaving ? "Preparando malla…" : "Guardar")
                            }.font(.headline).frame(maxWidth: .infinity).frame(height: 54)
                        }.background(accent, in: RoundedRectangle(cornerRadius: 16))
                            .disabled(capture.faceCount == 0 || capture.isSaving || capture.isRequestingHighResolution)
                            .opacity(capture.faceCount == 0 ? 0.45 : 1)
                    }
                    if capture.isSaving {
                        Button("Cancelar procesamiento y conservar captura") { capture.cancelProcessing() }
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .accessibilityIdentifier("cancelLiDARProcessing")
                    }
                }
            }.padding(20)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { capture.offloadProcessing = offloadProcessing; capture.viewAppeared() }
        .onDisappear { capture.viewDisappeared() }
        .onChange(of: scenePhase) { _, phase in capture.applicationPhaseChanged(phase) }
        .interactiveDismissDisabled(capture.isSaving)
        .confirmationDialog("¿Descartar esta captura y sus imágenes originales?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Descartar captura", role: .destructive) { close() }
            Button("Seguir escaneando", role: .cancel) {}
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.65))
        }
    }

    private func close() { capture.discard(); dismiss() }
}

private struct LiDARCameraPreview: UIViewRepresentable {
    let controller: LiDARCaptureController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.backgroundColor = .black
        view.automaticallyUpdatesLighting = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = CapturePacingPolicy.phonePreviewFPS
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
        uiView.delegate = nil
        uiView.session.delegate = nil
    }
}

/// Render callbacks run on SceneKit's render queue; this delegate never touches SwiftUI state.
private final class LiDARMeshRenderer: NSObject, ARSCNViewDelegate {
    struct Sample: Sendable {
        var callbackFPS: Double
        var meanMeshBuildMilliseconds: Double
        var totalMeshUpdates: Int
        var totalSkippedMeshUpdates: Int
    }
    private var onSample: (@Sendable (Sample) -> Void)?
    private let lock = NSLock()
    private var lastRefresh: [UUID: TimeInterval] = [:]
    private var sampleStarted: TimeInterval?
    private var sampleFrames = 0
    private var meshBuildSeconds = 0.0
    private var meshBuildCount = 0
    private var totalMeshUpdates = 0
    private var totalSkippedMeshUpdates = 0

    func setSampleHandler(_ handler: @escaping @Sendable (Sample) -> Void) {
        lock.lock(); onSample = handler; lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let mesh = anchor as? ARMeshAnchor else { return nil }
        _ = shouldRefresh(mesh.identifier)
        return SCNNode(geometry: timedGeometry(mesh.geometry))
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor, shouldRefresh(mesh.identifier) else { return }
        node.geometry = timedGeometry(mesh.geometry)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        lock.lock(); lastRefresh.removeValue(forKey: anchor.identifier); lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        lock.lock()
        guard let started = sampleStarted else {
            sampleStarted = time; sampleFrames = 1; lock.unlock(); return
        }
        sampleFrames += 1
        let interval = time - started
        guard interval >= 1 else { lock.unlock(); return }
        let sample = Sample(callbackFPS: Double(sampleFrames - 1) / interval,
                            meanMeshBuildMilliseconds: meshBuildCount > 0 ? meshBuildSeconds * 1000 / Double(meshBuildCount) : 0,
                            totalMeshUpdates: totalMeshUpdates, totalSkippedMeshUpdates: totalSkippedMeshUpdates)
        sampleStarted = time; sampleFrames = 1; meshBuildSeconds = 0; meshBuildCount = 0
        let callback = onSample
        lock.unlock()
        callback?(sample)
    }

    private func shouldRefresh(_ id: UUID) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        // Only the wireframe display is paced. ARKit reconstruction and the saved mesh remain complete.
        if !CapturePacingPolicy.hasElapsed(CapturePacingPolicy.meshPreviewInterval, since: lastRefresh[id], at: now) {
            totalSkippedMeshUpdates += 1
            return false
        }
        lastRefresh[id] = now
        return true
    }

    private func timedGeometry(_ geometry: ARMeshGeometry) -> SCNGeometry? {
        let started = ProcessInfo.processInfo.systemUptime
        let result = makeGeometry(geometry)
        lock.lock()
        meshBuildSeconds += ProcessInfo.processInfo.systemUptime - started
        meshBuildCount += 1; totalMeshUpdates += 1
        lock.unlock()
        return result
    }

    private func makeGeometry(_ mesh: ARMeshGeometry) -> SCNGeometry? {
        let faces = mesh.faces
        guard mesh.vertices.count > 0, faces.count > 0, faces.indexCountPerPrimitive == 3,
              faces.primitiveType == .triangle else { return nil }
        let vertices = mesh.vertices
        let source = SCNGeometrySource(buffer: vertices.buffer, vertexFormat: vertices.format,
                                       semantic: .vertex, vertexCount: vertices.count,
                                       dataOffset: vertices.offset, dataStride: vertices.stride)
        let data = Data(bytes: faces.buffer.contents(), count: faces.count * 3 * faces.bytesPerIndex)
        let element = SCNGeometryElement(data: data, primitiveType: .triangles,
                                        primitiveCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 1, green: 0.36, blue: 0.18, alpha: 0.8)
        material.lightingModel = .constant
        material.fillMode = .lines
        material.isDoubleSided = false
        material.cullMode = .back
        geometry.materials = [material]
        return geometry
    }
}

@MainActor
private final class LiDARCaptureController: NSObject, ObservableObject, @preconcurrency ARSessionDelegate {
    @Published var isRunning = false
    @Published var isSaving = false
    @Published var cameraDenied = false
    @Published var vertexCount = 0
    @Published var faceCount = 0
    @Published var elapsed: TimeInterval = 0
    @Published var status = "Preparando cámara"
    @Published var statusSymbol = "viewfinder"
    @Published var guidance = "Recorre despacio el espacio. Vuelve a pasar por los huecos de la malla naranja."
    @Published var depthQuality: String?
    @Published var thermalWarning: String?
    @Published var maximumQuality = true
    @Published var qualitySettings = LiDARQualitySettings()
    @Published var cameraResolution = "Resolución pendiente del sensor"
    @Published var lastSavedResolution = ""
    @Published var savedPhotos = 0
    @Published var savedDepthFrames = 0
    @Published var savedHighResolutionPhotos = 0
    @Published var isWritingKeyframe = false
    @Published var isRequestingHighResolution = false
    @Published var recordingNotice: String?
    @Published var processingProgress = 0.0
    @Published private(set) var processingState = ProcessingControl.Snapshot(phase: .running, revision: 0)
    var offloadProcessing = false
    @Published var arCallbackFPS = 0.0
    @Published var previewCallbackFPS = 0.0
    @Published var lastWriteMilliseconds = 0.0
    @Published var sensorFormatFPS = 0
    @Published var sensorPacingNotice = "Vista, malla visual y selección automática hasta 5 fps; seguimiento según los formatos reales de ARKit."

    let isSupported = ARWorldTrackingConfiguration.isSupported && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    private let session = ARSession()
    private let meshRenderer = LiDARMeshRenderer()
    private weak var preview: ARSCNView?
    private var counts: [UUID: (vertices: Int, faces: Int)] = [:]
    private var permissionGranted = false
    private var hasStarted = false
    private var isClosed = false
    private var lastSample: TimeInterval = 0
    private var accumulated: TimeInterval = 0
    private var runningSince: TimeInterval?
    private var thermalObserver: NSObjectProtocol?
    private var meshTask: Task<MeshSnapshot, Error>?
    private var preparationTask: Task<Void, Never>?
    private var recording: RGBDRecording?
    private var keyframeTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingControl: ProcessingControl?
    private var processingGeneration = UUID()
    private var previousProcessingIdleTimer: Bool?
    private var lastStreamPose: simd_float4x4?
    private var lastStreamTimestamp: TimeInterval?
    private var lastKeyframeEvaluationTimestamp: TimeInterval?
    private var lastHighResolutionPose: simd_float4x4?
    private var lastHighResolutionTimestamp: TimeInterval = -.infinity
    private var hasStreamSinceHighResolution = false
    private var recordingFailed = false
    private var latestLumaEdgeMean01: Double?
    private var arWindowStarted: TimeInterval?
    private var arWindowFrames = 0
    private var arMeasuredIntervals = 0.0
    private var arMeasuredFrames = 0
    private var arFramesObserved = 0
    private var arFramesWhileWriterBusy = 0
    private var arFramesLimitedTracking = 0
    private var finalizedMesh: MeshSnapshot?
    @Published private var executionState = LiDARExecutionState()
    private var processingExecutionLease: ProcessingExecutionLease?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var cleanupBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    var hasCapturedData: Bool { faceCount > 0 || savedPhotos > 0 || isWritingKeyframe }
    var captureSettingsLocked: Bool { finalizedMesh != nil }
    var processingManuallyPaused: Bool { executionState.processingManuallyPaused }
    var processingWaitingForForeground: Bool { executionState.processingWaitsForForeground && !executionState.processingManuallyPaused }

    var canResume: Bool { permissionGranted && !isClosed && !isSaving && finalizedMesh == nil }

    override init() {
        super.init()
        executionState.setForeground(UIApplication.shared.applicationState != .background)
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setApplicationActive(true) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setApplicationActive(false) }
            }
        ]
    }
    deinit { lifecycleObservers.forEach(NotificationCenter.default.removeObserver) }

    func viewAppeared() {
        executionState.setVisible(true)
        prepare()
        if UIApplication.shared.applicationState == .active { setApplicationActive(true) }
    }
    func viewDisappeared() {
        executionState.setVisible(false)
        pauseCameraSession(reason: "Cámara fuera de pantalla")
        // CPU preparation owns its execution lease and is not cancelled by a view transition.
    }
    func applicationPhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: setApplicationActive(true)
        case .background: setApplicationActive(false)
        case .inactive: break
        @unknown default: break
        }
    }
    private func setApplicationActive(_ active: Bool) {
        guard !isClosed else { return }
        executionState.setForeground(active)
        processingExecutionLease?.setApplicationActive(active)
        executionState.updateCPUGrant(processingExecutionLease?.canContinueInBackground == true)
        if active {
            refreshAuthorization()
            resumeCameraIfAllowed()
            endCleanupBackgroundTime()
        } else {
            pauseCameraSession(reason: "La cámara necesita Forma en primer plano")
            if isSaving && executionState.processingWaitsForForeground { beginCleanupBackgroundTime() }
        }
        synchronizeProcessingGate()
    }

    func attach(_ view: ARSCNView) {
        preview = view
        view.session = session
        view.delegate = meshRenderer
        session.delegate = self
        session.delegateQueue = .main
        meshRenderer.setSampleHandler { [weak self] sample in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.isClosed else { return }
                self.previewCallbackFPS = sample.callbackFPS
                self.recording?.setCaptureMetric("previewLastRenderCallbackFPS", value: sample.callbackFPS)
                self.recording?.setCaptureMetric("previewLastMeanMeshBuildMilliseconds", value: sample.meanMeshBuildMilliseconds)
                self.recording?.setCaptureMetric("previewMeshUpdates", value: Double(sample.totalMeshUpdates))
                self.recording?.setCaptureMetric("previewMeshUpdatesPaced", value: Double(sample.totalSkippedMeshUpdates))
            }
        }
    }

    func prepare() {
        guard isSupported, !isClosed, preparationTask == nil, !hasStarted else { return }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThermalState() }
        }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard !Task.isCancelled, !self.isClosed else { return }
            self.permissionGranted = authorized
            self.cameraDenied = !authorized
            if authorized {
                do { self.recording = try RGBDRecording() }
                catch {
                    self.status = "No se pudo preparar la captura RGB-D"
                    self.guidance = error.localizedDescription
                    self.recordingFailed = true
                    self.executionState.cameraFailed()
                    return
                }
                self.updateThermalState()
                if UIApplication.shared.applicationState == .active { self.resumeCameraIfAllowed() }
                else { self.status = "Cámara lista"; self.guidance = "Toca Continuar para iniciar el escaneo." }
            } else {
                self.status = "Se necesita acceso a la cámara"
                self.statusSymbol = "camera.fill"
                self.guidance = "Activa Cámara para Forma en Ajustes. La captura se procesa en este dispositivo."
            }
        }
    }

    func resume() {
        guard canResume else { return }
        executionState.resumeCameraByUser()
        resumeCameraIfAllowed()
    }

    private func resumeCameraIfAllowed() {
        guard canResume, !isRunning, executionState.shouldRunCamera,
              UIApplication.shared.applicationState == .active else { return }
        if recording == nil {
            do { recording = try RGBDRecording() }
            catch { recordingNotice = error.localizedDescription; executionState.cameraFailed(); return }
        }
        recordingFailed = false
        recordingNotice = nil
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.planeDetection = qualitySettings.nativePlaneAssistance ? [.horizontal, .vertical] : []
        config.environmentTexturing = .none
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let candidates = formats.map { CapturePacingPolicy.Format(framesPerSecond: $0.framesPerSecond,
            width: Int($0.imageResolution.width), height: Int($0.imageResolution.height),
            supportsHighResolution: $0.isRecommendedForHighResolutionFrameCapturing) }
        if let index = CapturePacingPolicy.preferredFormatIndex(candidates, maximumQuality: maximumQuality) {
            config.videoFormat = formats[index]
        }
        sensorFormatFPS = config.videoFormat.framesPerSecond
        sensorPacingNotice = sensorFormatFPS > CapturePacingPolicy.phonePreviewFPS
            ? "Vista, malla visual y selección automática hasta 5 fps. El formato ARKit seleccionado funciona a \(sensorFormatFPS) fps reales; el sensor conserva esa frecuencia."
            : "Vista, malla visual y selección automática hasta 5 fps · formato ARKit: \(sensorFormatFPS) fps reales."
        cameraResolution = "Solicitado \(Int(config.videoFormat.imageResolution.width)) × \(Int(config.videoFormat.imageResolution.height)) · sensor \(sensorFormatFPS) fps"
        preview?.preferredFramesPerSecond = CapturePacingPolicy.phonePreviewFPS
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        session.run(config)
        hasStarted = true
        isRunning = true
        runningSince = ProcessInfo.processInfo.systemUptime
        arWindowStarted = nil
        lastKeyframeEvaluationTimestamp = nil
        status = "Buscando superficies"
        statusSymbol = "viewfinder"
        guidance = "Muévete despacio y mantén superficies con detalle dentro de la cámara. Evita espejos y cristales."
    }

    func setMaximumQuality(_ enabled: Bool) {
        guard !isSaving, !isWritingKeyframe, finalizedMesh == nil else { return }
        maximumQuality = enabled
        if isRunning { pause(reason: "Actualizando formato de cámara"); resume() }
    }

    func applyPlaneAssistance() {
        guard !isSaving, finalizedMesh == nil else { return }
        if isRunning { pause(reason: "Actualizando detección de planos"); resume() }
    }

    func refreshAuthorization() {
        guard !isClosed, cameraDenied, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        permissionGranted = true
        cameraDenied = false
        status = "Cámara lista"
        statusSymbol = "camera.fill"
        guidance = "Toca Continuar para iniciar el escaneo."
    }

    func pause(reason: String) {
        executionState.pauseCameraByUser()
        pauseCameraSession(reason: reason)
    }

    private func pauseCameraSession(reason: String) {
        session.pause()
        if let start = runningSince { accumulated += ProcessInfo.processInfo.systemUptime - start }
        runningSince = nil
        elapsed = accumulated
        isRunning = false
        if !isSaving, hasStarted, !isClosed {
            status = reason
            statusSymbol = "pause.circle"
            guidance = "La malla capturada se conserva. Retoma desde la misma zona para mantener la orientación."
        }
    }

    func stop() {
        isClosed = true
        executionState.close()
        pauseCameraSession(reason: "")
        preparationTask?.cancel()
        meshTask?.cancel()
        keyframeTask?.cancel()
        processingTask?.cancel()
        processingControl?.cancel()
        restoreProcessingIdleTimer()
        endCleanupBackgroundTime()
        session.delegate = nil
        preview?.delegate = nil
        if let observer = thermalObserver { NotificationCenter.default.removeObserver(observer); thermalObserver = nil }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver); lifecycleObservers.removeAll()
    }

    func discard() {
        let processing = processingTask
        stop()
        let recording = recording
        Task {
            if let processing { await processing.value }
            await recording?.discard()
        }
    }

    func finish(onComplete: @escaping @MainActor (CaptureResult) -> Void) {
        guard !isSaving, !isClosed, !isRequestingHighResolution else { return }
        let anchors = session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let frozen = finalizedMesh
        guard frozen != nil || !anchors.isEmpty else { return }
        executionState.beginProcessing()
        pauseCameraSession(reason: "Preparando malla")
        isSaving = true
        let generation = UUID()
        processingGeneration = generation
        processingState = .init(phase: .running, revision: 0)
        let control = ProcessingControl { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.applyProcessingState(snapshot, generation: generation) }
        }
        processingControl = control
        previousProcessingIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        processingProgress = 0
        status = "Construyendo la malla local"
        statusSymbol = "cube.transparent"
        guidance = "Uniendo superficies en coordenadas reales, expresadas en metros."
        let duration = accumulated
        let task = Task.detached(priority: .userInitiated) {
            if let frozen { return frozen }
            return try ProcessingControl.withControl(control) { try LiDARMeshBuilder.snapshot(anchors) }
        }
        meshTask = task
        processingTask = Task { [self] in
            var completed = false
            defer {
                ProcessingActivityCoordinator.shared.finish(id: generation, success: completed, status: completed ? "Captura preparada" : status)
                processingExecutionLease = nil
                endCleanupBackgroundTime()
            }
            do {
                let lease = await ProcessingActivityCoordinator.shared.begin(id: generation, title: "Forma · Preparar captura LiDAR", onAction: { [weak self] action in
                    guard let self, self.isSaving, self.processingGeneration == generation else { return }
                    if action == "pause" { self.pauseProcessing() }
                    else if action == "resume" { self.resumeProcessingByUser() }
                    else if action == "cancel" { self.cancelProcessing() }
                }, onExpiration: { [weak self] in
                    guard let self, self.isSaving, self.processingGeneration == generation else { return }
                    self.executionState.expireCPUGrant()
                    self.synchronizeProcessingGate()
                    if self.executionState.processingWaitsForForeground { self.beginCleanupBackgroundTime() }
                })
                processingExecutionLease = lease
                lease.setApplicationActive(executionState.foreground)
                executionState.updateCPUGrant(lease.canContinueInBackground)
                synchronizeProcessingGate()
                try Task.checkCancellation()
                let mesh = try await task.value
                guard !self.isClosed else { return }
                try Task.checkCancellation()
                self.finalizedMesh = mesh
                if let keyframeTask = self.keyframeTask { await keyframeTask.value }
                try Task.checkCancellation()
                guard !self.isClosed else { return }
                guard let recording = self.recording else { throw RGBDDatasetError.invalid("Las fuentes de esta captura no están disponibles para guardar.") }
                self.updateCaptureMetrics()
                try await recording.flush()
                try await self.waitForProcessingGate(control)
                self.status = "Texturizando geometría"
                self.guidance = "Usando fotografías originales, calibración y profundidad capturadas. Las fuentes se conservan si ocurre un error."
                let result: CaptureResult
                if self.offloadProcessing {
                    self.status = "Guardando captura para procesar en Mac"
                    result = try await HybridCapturePreparation.prepare(mesh: mesh, datasetDirectory: recording.directory,
                                                                         duration: duration, mode: .lidar)
                } else {
                result = try await LiDARProcessingPipeline.process(mesh: mesh, datasetDirectory: recording.directory,
                    duration: duration, mode: .lidar, control: control, progress: { [weak self] title, fraction in
                        Task { @MainActor [weak self] in
                            guard let self, !self.isClosed, self.isSaving else { return }
                            self.status = title
                            self.processingProgress = fraction.isFinite ? min(1, max(0, fraction)) : 0
                            self.applyProcessingState(self.processingState, generation: generation)
                        }
                    })
                }
                try await self.waitForProcessingGate(control)
                try Task.checkCancellation()
                guard !self.isClosed else { return }
                self.isSaving = false
                self.restoreProcessingIdleTimer()
                self.processingTask = nil
                completed = true
                self.stop()
                onComplete(result)
            } catch {
                guard !self.isClosed else { return }
                self.isSaving = false
                self.restoreProcessingIdleTimer()
                self.processingTask = nil
                self.processingControl = nil
                if error is CancellationError {
                    self.status = "Procesamiento cancelado"
                    self.statusSymbol = "pause.circle"
                    self.guidance = "La captura y sus fuentes se conservan. Puedes volver a guardar."
                } else {
                    self.status = "No se pudo preparar la malla"
                    self.statusSymbol = "exclamationmark.triangle"
                    self.guidance = error.localizedDescription
                }
            }
        }
    }

    func toggleProcessingPause() {
        if executionState.processingManuallyPaused { resumeProcessingByUser() }
        else { pauseProcessing() }
    }

    private func waitForProcessingGate(_ control: ProcessingControl) async throws {
        let worker = Task.detached(priority: .utility) { try control.checkpoint() }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: {
            control.cancel(); worker.cancel()
        })
    }

    func pauseProcessing() {
        guard isSaving else { return }
        executionState.pauseProcessingByUser()
        synchronizeProcessingGate()
    }

    private func resumeProcessingByUser() {
        guard isSaving else { return }
        executionState.resumeProcessingByUser()
        synchronizeProcessingGate()
    }

    private func synchronizeProcessingGate() {
        guard isSaving, !executionState.processingCancelled, let processingControl else { return }
        let value = executionState.shouldHoldProcessing ? processingControl.requestPause() : processingControl.resume()
        applyProcessingState(value, generation: processingGeneration)
    }

    func cancelProcessing() {
        executionState.cancelProcessingByUser()
        processingControl?.cancel()
        meshTask?.cancel()
        processingTask?.cancel()
    }

    private func applyProcessingState(_ state: ProcessingControl.Snapshot, generation: UUID) {
        guard isSaving, generation == processingGeneration, state.revision >= processingState.revision else { return }
        processingState = state
        if state.phase == .paused || state.phase == .cancelled { restoreProcessingIdleTimer(); endCleanupBackgroundTime() }
        else if state.phase == .running {
            if previousProcessingIdleTimer == nil { previousProcessingIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        }
        let waiting = executionState.processingWaitsForForeground && !executionState.processingManuallyPaused
        let phase = state.phase == .paused ? (waiting ? "pausedForeground" : "paused") : (state.isPauseActive ? "pausing" : "running")
        ProcessingActivityCoordinator.shared.update(id: generation, progress: processingProgress,
            status: waiting ? "Continúa al volver a Forma" : status, phase: phase,
            energyLabel: "Procesamiento CPU continuo")
    }

    private func beginCleanupBackgroundTime() {
        guard isSaving, cleanupBackgroundTask == .invalid else { return }
        cleanupBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Conservar captura LiDAR") { [weak self] in
            Task { @MainActor [weak self] in self?.endCleanupBackgroundTime() }
        }
    }
    private func endCleanupBackgroundTime() {
        guard cleanupBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(cleanupBackgroundTask); cleanupBackgroundTask = .invalid
    }

    private func restoreProcessingIdleTimer() {
        if let previousProcessingIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousProcessingIdleTimer
            self.previousProcessingIdleTimer = nil
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updateCounts(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updateCounts(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors { counts.removeValue(forKey: anchor.identifier) }
    }

    private func updateCounts(_ anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors {
            counts[mesh.identifier] = (mesh.geometry.vertices.count, mesh.geometry.faces.count)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        observeCallback(frame)
        selectKeyframe(from: frame)
        guard isRunning, frame.timestamp - lastSample >= 0.5 else { return }
        lastSample = frame.timestamp
        vertexCount = counts.values.reduce(0) { $0 + $1.vertices }
        faceCount = counts.values.reduce(0) { $0 + $1.faces }
        elapsed = accumulated + (runningSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
        switch frame.camera.trackingState {
        case .normal:
            status = "Capturando superficies"; statusSymbol = "checkmark.circle"
            guidance = "Rodea las superficies y observa la malla naranja. Acércate a los huecos y evita movimientos bruscos."
        case .notAvailable:
            status = "Seguimiento no disponible"; statusSymbol = "exclamationmark.triangle"
            guidance = "Espera a que ARKit recupere la posición antes de seguir avanzando."
        case .limited(let reason):
            status = "Mejora el seguimiento"; statusSymbol = "viewfinder"
            switch reason {
            case .excessiveMotion: guidance = "Reduce la velocidad y mantén el iPhone estable."
            case .insufficientFeatures: guidance = "Apunta a superficies con textura y mejora la iluminación."
            case .relocalizing: guidance = "Regresa a una zona que ya hayas escaneado para recuperar la posición."
            case .initializing: guidance = "Mueve el iPhone suavemente para reconocer el espacio."
            @unknown default: guidance = "Mantén el iPhone estable y apunta a una superficie con detalle."
            }
        }
        depthQuality = Self.depthSummary(frame.sceneDepth)
        cameraResolution = "Vídeo \(CVPixelBufferGetWidth(frame.capturedImage)) × \(CVPixelBufferGetHeight(frame.capturedImage))"
    }

    private func selectKeyframe(from frame: ARFrame) {
        guard !isSaving, !isClosed, !isWritingKeyframe, !recordingFailed, recording != nil,
              case .normal = frame.camera.trackingState else { return }
        guard CapturePacingPolicy.hasElapsed(CapturePacingPolicy.automaticKeyframeEvaluationInterval,
                                            since: lastKeyframeEvaluationTimestamp, at: frame.timestamp) else { return }
        lastKeyframeEvaluationTimestamp = frame.timestamp
        let pose = frame.camera.transform
        // The interval prevents overlapping photo requests and allows the sensor/encoder to settle.
        // There is no photo-count or scan-duration limit.
        if maximumQuality, hasStreamSinceHighResolution,
           frame.timestamp - lastHighResolutionTimestamp >= 3,
           Self.hasMoved(from: lastHighResolutionPose, to: pose, translation: 0.15, angle: 0.15),
           frame.camera.exposureDuration <= 1.0 / 15.0,
           latestLumaEdgeMean01.map({ $0 >= 1.0 / 255.0 }) ?? true {
            captureHighResolutionPhoto(manual: false)
            return
        }
        // Match the actual encoder's sustainable cadence, preserving spatial overlap while keeping one writer.
        let writeMean = recording?.streamMeanCommitSeconds ?? 0
        let interval = CapturePacingPolicy.savedStreamInterval(meanCommitSeconds: writeMean)
        guard CapturePacingPolicy.hasElapsed(interval, since: lastStreamTimestamp, at: frame.timestamp),
              Self.hasMoved(from: lastStreamPose, to: pose, translation: qualitySettings.translationBetweenPhotos,
                            angle: qualitySettings.angleBetweenPhotos) else { return }
        let input = RGBDRecordingFrame(frame: frame, source: "streamRGBD")
        isWritingKeyframe = true
        keyframeTask = Task { [weak self] in
            guard let self, let recording = self.recording else { return }
            defer { self.isWritingKeyframe = false; self.keyframeTask = nil }
            do {
                let record = try await recording.append(input)
                guard !self.isClosed else { return }
                self.hasStreamSinceHighResolution = record.depthFile != nil
                self.didSaveFrame(record)
            } catch {
                guard !self.isClosed else { return }
                self.recordingFailed = true
                self.executionState.cameraFailed()
                self.pauseCameraSession(reason: "Escritura RGB-D detenida por un error")
                self.recordingNotice = "No se ha descartado lo guardado. \(error.localizedDescription) Libera espacio y toca Continuar o vuelve a guardar."
            }
        }
    }

    func captureHighResolutionPhoto(manual: Bool) {
        guard isRunning, !isSaving, !isClosed, !isWritingKeyframe, !recordingFailed,
              let current = session.currentFrame, case .normal = current.camera.trackingState else { return }
        lastHighResolutionTimestamp = current.timestamp
        isWritingKeyframe = true
        isRequestingHighResolution = true
        keyframeTask = Task { [weak self] in
            guard let self, let recording = self.recording else { return }
            var receivedPhoto = false
            defer {
                self.isWritingKeyframe = false
                self.isRequestingHighResolution = false
                self.keyframeTask = nil
            }
            do {
                let input: RGBDRecordingFrame = try await withCheckedThrowingContinuation { continuation in
                    let requested = ProcessInfo.processInfo.systemUptime
                    self.session.captureHighResolutionFrame { frame, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard let frame else {
                            continuation.resume(throwing: RGBDRecording.RecordingError.imageEncoding)
                            return
                        }
                        // Pose, K and optional depth come from this returned ARFrame, not the request's earlier frame.
                        var packet = RGBDRecordingFrame(frame: frame, source: "highResolution")
                        packet.record.acquisitionMetrics?["highResolutionRequestSeconds"] = ProcessInfo.processInfo.systemUptime - requested
                        continuation.resume(returning: packet)
                    }
                }
                self.isRequestingHighResolution = false
                guard !Task.isCancelled, !self.isClosed else { return }
                receivedPhoto = true
                let record = try await recording.append(input)
                guard !self.isClosed else { return }
                self.hasStreamSinceHighResolution = false
                self.didSaveFrame(record)
            } catch {
                guard !self.isClosed else { return }
                self.recordingNotice = "Foto HiRes no guardada: \(error.localizedDescription). Los fotogramas RGB-D ya guardados se conservan; puedes volver a intentarlo."
                if receivedPhoto {
                    self.recordingFailed = true
                    self.executionState.cameraFailed()
                    self.pauseCameraSession(reason: "Escritura de foto HiRes detenida por un error")
                }
            }
        }
        if manual { recordingNotice = "Solicitando foto a la resolución que ARKit ofrezca con el formato actual…" }
    }

    private func didSaveFrame(_ frame: RGBDFrameRecord) {
        guard let recording else { return }
        savedPhotos = recording.frameCount
        savedDepthFrames = recording.depthFrameCount
        savedHighResolutionPhotos = recording.highResolutionCount
        lastWriteMilliseconds = recording.lastCommitSeconds * 1000
        latestLumaEdgeMean01 = frame.acquisitionMetrics?["sampledLumaEdgeMean01"]
        if frame.source == "streamRGBD" { lastStreamPose = frame.transformMatrix; lastStreamTimestamp = frame.timestamp }
        if frame.source == "highResolution" {
            lastHighResolutionPose = frame.transformMatrix
            lastSavedResolution = "\(frame.imageWidth) × \(frame.imageHeight)"
        }
        recordingNotice = nil
    }

    private func observeCallback(_ frame: ARFrame) {
        arFramesObserved += 1
        if isWritingKeyframe { arFramesWhileWriterBusy += 1 }
        if case .normal = frame.camera.trackingState {} else { arFramesLimitedTracking += 1 }
        guard let started = arWindowStarted else { arWindowStarted = frame.timestamp; arWindowFrames = 1; return }
        arWindowFrames += 1
        let interval = frame.timestamp - started
        guard interval >= 1 else { return }
        arCallbackFPS = Double(arWindowFrames - 1) / interval
        arMeasuredFrames += arWindowFrames - 1
        arMeasuredIntervals += interval
        arWindowStarted = frame.timestamp; arWindowFrames = 1
        updateCaptureMetrics()
    }

    private func updateCaptureMetrics() {
        recording?.lidarQuality = qualitySettings
        recording?.setCaptureMetric("arFramesObserved", value: Double(arFramesObserved))
        recording?.setCaptureMetric("arFramesWhileWriterBusy", value: Double(arFramesWhileWriterBusy))
        recording?.setCaptureMetric("arFramesLimitedTracking", value: Double(arFramesLimitedTracking))
        recording?.setCaptureMetric("arLastCallbackFPS", value: arCallbackFPS)
        if arMeasuredIntervals > 0 { recording?.setCaptureMetric("arMeanCallbackFPS", value: Double(arMeasuredFrames) / arMeasuredIntervals) }
        recording?.setCaptureMetric("captureActiveSeconds", value: elapsed)
        recording?.setCaptureMetric("previewTargetFPS", value: Double(CapturePacingPolicy.phonePreviewFPS))
        recording?.setCaptureMetric("meshPreviewMaximumFPSPerAnchor", value: Double(CapturePacingPolicy.meshPreviewFPS))
        recording?.setCaptureMetric("keyframeEvaluationMaximumFPS", value: Double(CapturePacingPolicy.automaticKeyframeEvaluationFPS))
        recording?.setCaptureMetric("savedStreamMaximumFPS", value: Double(CapturePacingPolicy.maximumSavedStreamFPS))
        recording?.setCaptureMetric("sensorConfiguredFPS", value: Double(sensorFormatFPS))
    }

    private static func hasMoved(from previous: simd_float4x4?, to current: simd_float4x4,
                                 translation: Float, angle: Float) -> Bool {
        guard let previous else { return true }
        let a = SIMD3(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let b = SIMD3(current.columns.3.x, current.columns.3.y, current.columns.3.z)
        let dot = abs(simd_dot(simd_quatf(previous).vector, simd_quatf(current).vector))
        let rotation = 2 * acos(min(1, max(0, dot)))
        return simd_distance(a, b) >= translation || rotation >= angle
    }

    func sessionWasInterrupted(_ session: ARSession) {
        executionState.cameraWasInterrupted()
        if let start = runningSince { accumulated += ProcessInfo.processInfo.systemUptime - start }
        runningSince = nil; elapsed = accumulated; isRunning = false
        if !isSaving {
            status = "iOS interrumpió la cámara"
            guidance = "La captura se conserva y continúa cuando iOS devuelva la cámara, salvo que la hayas pausado."
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard !isClosed, !isSaving else { return }
        executionState.cameraInterruptionEnded()
        resumeCameraIfAllowed()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        executionState.cameraFailed()
        pauseCameraSession(reason: "Error de captura")
        statusSymbol = "exclamationmark.triangle"
        guidance = error.localizedDescription + (maximumQuality ? " Si el formato no es compatible, desactiva Máxima calidad y toca Continuar. Las imágenes guardadas se conservan." : "")
    }

    private func updateThermalState() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalWarning = nil; preview?.preferredFramesPerSecond = CapturePacingPolicy.phonePreviewFPS
        case .fair: thermalWarning = "El dispositivo está templado."; preview?.preferredFramesPerSecond = CapturePacingPolicy.phonePreviewFPS
        case .serious:
            thermalWarning = "iOS informa temperatura alta. Forma continúa sin añadir una pausa."
            preview?.preferredFramesPerSecond = CapturePacingPolicy.phonePreviewFPS
        case .critical:
            thermalWarning = "iOS informa temperatura crítica. Forma no añade una pausa; el sistema controla la disponibilidad de la cámara."
        @unknown default: thermalWarning = nil
        }
    }

    /// A sparse sample measures sensor confidence, not geometric accuracy or scan completeness.
    private static func depthSummary(_ depth: ARDepthData?) -> String? {
        guard let depth, let map = depth.confidenceMap else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map)
        var high = 0, total = 0
        for y in Swift.stride(from: 0, to: height, by: 8) {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: 8) { total += 1; if row[x] == 2 { high += 1 } }
        }
        guard total > 0 else { return nil }
        return "Confianza del sensor: \(Int(Double(high) / Double(total) * 100)) % alta · muestra de profundidad"
    }
}

private enum LiDARMeshBuilder {
    enum BuildError: LocalizedError {
        case empty, capacity
        var errorDescription: String? {
            switch self {
            case .empty: return "No hay triángulos válidos todavía. Continúa el recorrido y vuelve a guardar."
            case .capacity: return "La malla supera la capacidad de índices del formato. Guarda el espacio en varias capturas."
            }
        }
    }

    /// Copies geometry once, after pausing the session. Every returned index addresses a finite world-space vertex.
    static func snapshot(_ anchors: [ARMeshAnchor]) throws -> MeshSnapshot {
        var vertices: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        for anchor in anchors {
            try ProcessingControl.checkpoint()
            let source = anchor.geometry.vertices, faces = anchor.geometry.faces
            guard source.format == .float3, source.count > 0, source.offset >= 0, source.stride >= 12,
                  source.offset + (source.count - 1) * source.stride + 12 <= source.buffer.length,
                  faces.indexCountPerPrimitive == 3, faces.primitiveType == .triangle,
                  [1, 2, 4].contains(faces.bytesPerIndex),
                  faces.count * 3 * faces.bytesPerIndex <= faces.buffer.length else { continue }
            guard UInt64(vertices.count) + UInt64(source.count) < UInt64(UInt32.max) else { throw BuildError.capacity }
            var indices = [UInt32](repeating: .max, count: source.count)
            for index in 0..<source.count {
                if index % 4096 == 0 { try ProcessingControl.checkpoint() }
                let point = source.buffer.contents().advanced(by: source.offset + index * source.stride)
                let local = SIMD4<Float>(point.loadUnaligned(as: Float.self),
                                         point.advanced(by: 4).loadUnaligned(as: Float.self),
                                         point.advanced(by: 8).loadUnaligned(as: Float.self), 1)
                let world = anchor.transform * local
                guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { continue }
                indices[index] = UInt32(vertices.count)
                vertices.append(SIMD3(world.x, world.y, world.z))
            }
            let buffer = faces.buffer.contents()
            func index(at position: Int) -> Int {
                let pointer = buffer.advanced(by: position * faces.bytesPerIndex)
                switch faces.bytesPerIndex {
                case 1: return Int(pointer.load(as: UInt8.self))
                case 2: return Int(pointer.loadUnaligned(as: UInt16.self))
                default: return Int(pointer.loadUnaligned(as: UInt32.self))
                }
            }
            for face in 0..<faces.count {
                if face % 4096 == 0 { try ProcessingControl.checkpoint() }
                let a = index(at: face * 3), b = index(at: face * 3 + 1), c = index(at: face * 3 + 2)
                guard a < indices.count, b < indices.count, c < indices.count,
                      indices[a] != .max, indices[b] != .max, indices[c] != .max,
                      a != b, b != c, a != c else { continue }
                triangles.append(contentsOf: [indices[a], indices[b], indices[c]])
            }
        }
        guard !triangles.isEmpty else { throw BuildError.empty }
        return MeshSnapshot(vertices: vertices, triangles: triangles)
    }
}
