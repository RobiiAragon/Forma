import SwiftUI
import RoomPlan
import AVFoundation
import UIKit
import simd
import SceneKit

struct RoomScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: RoomScanController
    private let accent = Color(red: 1, green: 0.36, blue: 0.18)

    init(onComplete: @escaping (CaptureResult) -> Void) {
        _controller = StateObject(wrappedValue: RoomScanController(onComplete: onComplete))
    }

    var body: some View {
        ZStack {
            Color(red: 0.063, green: 0.067, blue: 0.075).ignoresSafeArea()
            if controller.cameraAvailable {
                RoomCaptureSurface(controller: controller).ignoresSafeArea()
            }
            if controller.phase == .review, let scene = controller.reviewScene {
                SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                HStack {
                    Button { controller.teardown(); dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Cerrar captura de habitación")
                    .accessibilityIdentifier("closeCapture")
                    Spacer()
                    Text("PLANO DE HABITACIÓN").font(.caption.bold()).tracking(1.8)
                    Spacer()
                    Image(systemName: "square.split.bottomrightquarter")
                        .frame(width: 44, height: 44).foregroundStyle(accent)
                }
                .padding()
                Spacer()
                statusPanel
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { await controller.prepare() }
        .onDisappear { controller.teardown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.background() }
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: controller.phase.symbol).foregroundStyle(accent).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.phase.title).font(.title3.bold())
                    Text(controller.message).font(.subheadline).foregroundStyle(.white.opacity(0.72))
                }
            }
            if controller.phase == .scanning || controller.phase == .review {
                HStack(spacing: 24) {
                    metric("Muros", value: controller.wallCount)
                    metric("Puertas", value: controller.doorCount)
                    metric("Ventanas", value: controller.windowCount)
                    Spacer(minLength: 0)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(controller.elapsedText).font(.system(.headline, design: .monospaced))
                    }
                }
            }
            switch controller.phase {
            case .preparing, .processing, .saving:
                ProgressView().tint(accent).frame(maxWidth: .infinity)
            case .scanning:
                Toggle("Refinar aspecto de objetos", isOn: $controller.beautifyObjects)
                    .accessibilityIdentifier("roomBeautifyObjects")
                Text("RoomPlan ajusta la forma de los objetos detectados. No aumenta la resolución de muros ni garantiza medidas más exactas. Desactívalo para conservar la reconstrucción sin este ajuste.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                Button { controller.finishCapture() } label: {
                    Label("Terminar y revisar", systemImage: "stop.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                }.buttonStyle(.borderedProminent).tint(accent)
            case .review:
                HStack {
                    Button("Repetir") { controller.restart() }
                        .buttonStyle(.bordered).tint(.white)
                    Button { controller.save() } label: {
                        Label("Guardar plano", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(accent)
                }
                Text("USDZ + datos RoomPlan + fuente original + informe JSON + proyección SVG. Las medidas son estimaciones del dispositivo.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            case .failed:
                if controller.permissionDenied {
                    Button("Abrir ajustes de cámara") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.borderedProminent).tint(accent)
                } else if controller.cameraAvailable {
                    Button("Volver a escanear") { controller.restart() }
                        .buttonStyle(.borderedProminent).tint(accent)
                }
            }
            Text("Procesamiento local · Sin cuenta ni límite de capturas")
                .font(.caption2).foregroundStyle(.white.opacity(0.48))
        }
        .padding(22)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 26))
        .padding()
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)").font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct RoomCaptureSurface: UIViewRepresentable {
    let controller: RoomScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.isModelEnabled = true
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    static func dismantleUIView(_ uiView: RoomCaptureView, coordinator: ()) {
        uiView.delegate = nil
        uiView.captureSession.delegate = nil
        uiView.captureSession.stop(pauseARSession: true)
        uiView.captureSession.arSession.pause()
    }
}

@MainActor
private final class RoomScanController: ObservableObject {
    enum Phase {
        case preparing, scanning, processing, review, saving, failed
        var title: String {
            switch self {
            case .preparing: return "Preparando RoomPlan"
            case .scanning: return "Recorre la habitación"
            case .processing: return "Procesando tu habitación"
            case .review: return "Revisa el plano"
            case .saving: return "Guardando archivos"
            case .failed: return "No se pudo crear el plano"
            }
        }
        var symbol: String {
            switch self {
            case .scanning: return "viewfinder"
            case .review: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            default: return "square.split.bottomrightquarter"
            }
        }
    }

    @Published var phase: Phase = .preparing
    @Published var message = "Comprobando el dispositivo y el permiso de cámara."
    @Published var cameraAvailable = false
    @Published var permissionDenied = false
    @Published var wallCount = 0
    @Published var doorCount = 0
    @Published var windowCount = 0
    @Published var beautifyObjects = true
    @Published private(set) var reviewScene: SCNScene?
    private var sourceData: CapturedRoomData?
    private var appliedBeautifyObjects = true
    private var previewDirectory: URL?
    private var buildTask: Task<Void, Never>?
    private weak var captureView: RoomCaptureView?
    private var delegate: RoomScanDelegate?
    private var room: CapturedRoom?
    private var startedAt: Date?
    private var duration: TimeInterval = 0
    private var isVisible = true
    private var didPrepare = false
    private var onComplete: (CaptureResult) -> Void

    init(onComplete: @escaping (CaptureResult) -> Void) { self.onComplete = onComplete }

    var elapsedText: String {
        let elapsed = phase == .scanning ? Date().timeIntervalSince(startedAt ?? .now) : duration
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        #if targetEnvironment(simulator)
        fail("RoomPlan necesita un iPhone o iPad físico con LiDAR. El simulador no captura habitaciones.")
        return
        #else
        guard RoomCaptureSession.isSupported else {
            fail("Este dispositivo no admite RoomPlan. Se necesita un iPhone o iPad compatible con LiDAR.")
            return
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard isVisible else { return }
        guard authorized else {
            permissionDenied = true
            fail("Activa el acceso a la cámara en Ajustes para capturar la habitación.")
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            didPrepare = false
            fail("Abre de nuevo la captura con la app en primer plano.")
            return
        }
        cameraAvailable = true
        #endif
    }

    func attach(_ view: RoomCaptureView) {
        captureView = view
        // Defer state changes until SwiftUI has installed the UIKit view.
        Task { @MainActor [weak self] in self?.restart() }
    }

    func restart() {
        guard isVisible, let captureView,
              UIApplication.shared.applicationState != .background else { return }
        delegate?.setProcessingEnabled(false)
        captureView.delegate = nil
        captureView.captureSession.delegate = nil
        captureView.captureSession.stop(pauseARSession: true)
        let bridge = RoomScanDelegate(owner: self)
        delegate = bridge
        captureView.delegate = bridge
        captureView.captureSession.delegate = bridge
        buildTask?.cancel(); buildTask = nil
        clearPreview()
        room = nil; sourceData = nil
        wallCount = 0; doorCount = 0; windowCount = 0
        startedAt = .now
        duration = 0
        phase = .scanning
        message = "Mueve el iPhone despacio y cubre muros, puertas y ventanas."
        delegate?.setProcessingEnabled(true)
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
    }

    func finishCapture() {
        guard phase == .scanning, let captureView else { return }
        duration = Date().timeIntervalSince(startedAt ?? .now)
        phase = .processing
        message = "RoomPlan está calculando la estructura. No cierres esta pantalla."
        captureView.captureSession.stop(pauseARSession: true)
        captureView.captureSession.arSession.pause()
    }

    func background() {
        if phase == .scanning {
            finishCapture()
            message = "La captura se detuvo al salir de la app. Revisa el resultado al volver."
        }
        captureView?.captureSession.arSession.pause()
    }

    func teardown() {
        isVisible = false
        buildTask?.cancel(); buildTask = nil
        clearPreview()
        delegate?.setProcessingEnabled(false)
        captureView?.delegate = nil
        captureView?.captureSession.delegate = nil
        captureView?.captureSession.stop(pauseARSession: true)
        captureView?.captureSession.arSession.pause()
    }

    func update(_ room: CapturedRoom) {
        guard isVisible, phase == .scanning else { return }
        wallCount = room.walls.count
        doorCount = room.doors.count
        windowCount = room.windows.count
    }

    func instruction(_ instruction: RoomCaptureSession.Instruction) {
        guard isVisible, phase == .scanning else { return }
        switch instruction {
        case .moveCloseToWall: message = "Acércate al muro para captar sus detalles."
        case .moveAwayFromWall: message = "Aléjate un poco del muro."
        case .slowDown: message = "Muévete más despacio para mantener el seguimiento."
        case .turnOnLight: message = "Hace falta más luz para seguir la habitación."
        case .lowTexture: message = "Busca zonas con textura y evita superficies completamente lisas."
        case .normal: message = "Continúa por los muros y vuelve sobre las zonas pendientes."
        @unknown default: message = "Sigue las indicaciones de captura."
        }
    }

    func sessionEnded(data: CapturedRoomData, errorDescription: String?) {
        guard isVisible, phase == .scanning || phase == .processing else { return }
        if let errorDescription { fail(errorDescription); return }
        guard sourceData == nil else { return }
        sourceData = data
        captureView?.captureSession.arSession.pause()
        duration = duration > 0 ? duration : Date().timeIntervalSince(startedAt ?? .now)
        phase = .processing
        appliedBeautifyObjects = beautifyObjects
        let refine = appliedBeautifyObjects
        message = refine ? "RoomPlan está refinando los objetos detectados." : "RoomPlan está reconstruyendo sin refinar objetos."
        buildTask = Task { [weak self] in
            do {
                let builder = RoomBuilder(options: refine ? [.beautifyObjects] : [])
                let room = try await builder.capturedRoom(from: data)
                try Task.checkCancellation()
                guard let self, self.isVisible else { return }
                guard !room.walls.isEmpty else {
                    self.fail("No se detectaron muros suficientes. Repite el recorrido con más luz y movimiento lento.")
                    return
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-Room-Review-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                self.previewDirectory = folder
                let model = folder.appendingPathComponent("review.usdz")
                try room.export(to: model, exportOptions: .parametric)
                self.reviewScene = try SCNScene(url: model)
                self.room = room
                self.wallCount = room.walls.count
                self.doorCount = room.doors.count
                self.windowCount = room.windows.count
                self.phase = .review
                self.message = refine ? "Revisa el resultado con objetos refinados. Esta versión se exportará." : "Revisa el resultado sin refinado de objetos. Esta versión se exportará."
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isVisible else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func clearPreview() {
        reviewScene = nil
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
    }

    func save() {
        guard phase == .review, let room, let sourceData else { return }
        phase = .saving
        message = "Creando el modelo y los archivos portables en este dispositivo."
        let duration = self.duration
        let refined = appliedBeautifyObjects
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try RoomScanFiles.export(room, sourceData: sourceData, beautifyObjects: refined, duration: duration)
                }.value
                guard let self, self.isVisible else { return }
                self.onComplete(result)
            } catch {
                guard let self, self.isVisible else { return }
                self.phase = .review
                self.message = "No se guardó: \(error.localizedDescription). Puedes volver a intentarlo."
            }
        }
    }

    private func fail(_ description: String) {
        delegate?.setProcessingEnabled(false)
        phase = .failed
        message = description
        captureView?.captureSession.arSession.pause()
    }
}

/// RoomPlan can deliver delegate callbacks outside the UI actor. Only its synchronous
/// decision uses a lock; every UI mutation is explicitly delivered to the main actor.
@objc(FormaRoomScanDelegate)
private final class RoomScanDelegate: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    private weak var owner: RoomScanController?
    private let lock = NSLock()
    private var processingEnabled = false

    init(owner: RoomScanController) { self.owner = owner; super.init() }
    required init?(coder: NSCoder) { return nil }
    func encode(with coder: NSCoder) {}

    func setProcessingEnabled(_ enabled: Bool) {
        lock.lock(); processingEnabled = enabled; lock.unlock()
    }

    private var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return processingEnabled
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        // The app builds and previews the chosen refinement itself from didEnd's source.
        false
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {}

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor [weak self, weak owner] in
            guard self?.isEnabled == true else { return }
            owner?.update(room)
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor [weak self, weak owner] in
            guard self?.isEnabled == true else { return }
            owner?.instruction(instruction)
        }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        let description = error?.localizedDescription
        Task { @MainActor [weak self, weak owner] in
            guard self?.isEnabled == true else { return }
            owner?.sessionEnded(data: data, errorDescription: description)
        }
    }
}

private enum RoomScanFiles {
    struct Report: Encodable {
        let schemaVersion = 2
        let capturedAt: Date
        let source = "Apple RoomPlan"
        let units = "meters"
        let objectRefinement: String
        let sourceDataFile = "roomplan-source.json"
        let resolutionControl = "RoomPlan exposes parametric surfaces, not voxel or triangle resolution."
        let durationSeconds: TimeInterval
        let wallCount: Int
        let doorCount: Int
        let windowCount: Int
        let openingCount: Int
        let objectCount: Int
        let curvedWallsOmittedFromSVG: Int
        let floorAreaSquareMeters: Double? = nil
        let note = "Estructura estimada por RoomPlan. La proyección SVG muestra segmentos de muros planos detectados sobre X/Z, con longitud declarada por RoomPlan. No calcula área habitable ni certifica precisión."
    }

    static func export(_ room: CapturedRoom, sourceData: CapturedRoomData, beautifyObjects: Bool, duration: TimeInterval) throws -> CaptureResult {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Forma-Room-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let modelURL = folder.appendingPathComponent("habitacion.usdz")
            try room.export(to: modelURL, exportOptions: .parametric)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let dataURL = folder.appendingPathComponent("roomplan.json")
            try encoder.encode(room).write(to: dataURL, options: .atomic)
            let reportURL = folder.appendingPathComponent("informe.json")
            let sourceURL = folder.appendingPathComponent("roomplan-source.json")
            try encoder.encode(sourceData).write(to: sourceURL, options: .atomic)
            let report = Report(capturedAt: .now, objectRefinement: beautifyObjects ? "beautifyObjects" : "none", durationSeconds: duration,
                                wallCount: room.walls.count, doorCount: room.doors.count,
                                windowCount: room.windows.count, openingCount: room.openings.count,
                                objectCount: room.objects.count,
                                curvedWallsOmittedFromSVG: room.walls.filter { $0.curve != nil }.count)
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            var auxiliaryURLs = [dataURL, sourceURL, reportURL]
            if let svg = projectionSVG(room) {
                let svgURL = folder.appendingPathComponent("proyeccion-muros.svg")
                try svg.write(to: svgURL, atomically: true, encoding: .utf8)
                auxiliaryURLs.append(svgURL)
            }
            var result = CaptureResult(mesh: nil, modelURL: modelURL, auxiliaryURLs: auxiliaryURLs,
                                       mode: .room, duration: duration,
                                       note: "RoomPlan local. Muros: \(room.walls.count), puertas: \(room.doors.count), ventanas: \(room.windows.count). USDZ paramétrico y JSON de la versión elegida; datos fuente RoomPlan conservados. Refinado de objetos: \(beautifyObjects ? "sí" : "no"). Dimensiones estimadas; SVG de muros planos sin cálculo de área.")
            result.cleanupDirectory = folder
            return result
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func projectionSVG(_ room: CapturedRoom) -> String? {
        struct Segment { let a: SIMD2<Float>; let b: SIMD2<Float>; let length: Float }
        let segments: [Segment] = room.walls.compactMap { wall in
            guard wall.curve == nil, wall.dimensions.x.isFinite, wall.dimensions.x > 0 else { return nil }
            let a = wall.transform * SIMD4<Float>(-wall.dimensions.x / 2, 0, 0, 1)
            let b = wall.transform * SIMD4<Float>(wall.dimensions.x / 2, 0, 0, 1)
            guard a.x.isFinite, a.z.isFinite, b.x.isFinite, b.z.isFinite else { return nil }
            return Segment(a: SIMD2(a.x, -a.z), b: SIMD2(b.x, -b.z), length: wall.dimensions.x)
        }
        guard let first = segments.first else { return nil }
        var low = first.a, high = first.a
        for segment in segments {
            low = simd_min(low, simd_min(segment.a, segment.b))
            high = simd_max(high, simd_max(segment.a, segment.b))
        }
        let margin: Float = 0.8
        let width = max(high.x - low.x, 0.1) + margin * 2
        let height = max(high.y - low.y, 0.1) + margin * 2
        func number(_ value: Float) -> String {
            String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let lines = segments.map { segment in
            let mid = (segment.a + segment.b) * 0.5
            return """
            <line x1="\(number(segment.a.x))" y1="\(number(segment.a.y))" x2="\(number(segment.b.x))" y2="\(number(segment.b.y))" stroke="#151719" stroke-width="0.055" stroke-linecap="round"/>
            <text x="\(number(mid.x))" y="\(number(mid.y - 0.09))" text-anchor="middle" font-family="sans-serif" font-size="0.14" fill="#b33d19">\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), segment.length)) m</text>
            """
        }.joined(separator: "\n")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="\(number(low.x - margin)) \(number(low.y - margin)) \(number(width)) \(number(height))">
        <title>Forma · Proyección de muros detectados</title>
        <desc>Coordenadas X/Z de RoomPlan en metros; Z invertida para visualización. Solo muros planos. Muros curvos omitidos. Las cotas son estimaciones. No representa un polígono cerrado ni un área certificada.</desc>
        <rect x="\(number(low.x - margin))" y="\(number(low.y - margin))" width="\(number(width))" height="\(number(height))" fill="#fffdf7"/>
        \(lines)
        <text x="\(number(low.x - margin + 0.1))" y="\(number(high.y + margin - 0.12))" font-family="sans-serif" font-size="0.12" fill="#666">RoomPlan · proyección de muros · medidas estimadas</text>
        </svg>
        """
    }
}
