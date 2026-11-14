import SwiftUI
import RealityKit
import AppKit

/// Optional photographic reconstruction. Apple owns its stages and resource policy;
/// interruption is cancellation, not a cooperative in-memory pause.
@MainActor
final class DesktopPhotogrammetry: ObservableObject {
    @Published var detail = "raw"
    @Published var customPolygonCount = "10000000"
    @Published var customTextureDimension: Int = {
        if #available(macOS 15.0, *) { return 16384 }
        return 8192
    }()
    @Published var qualityOptions = PhotogrammetryQualityOptions(highSensitivity: true, objectMasking: false)
    @Published private(set) var state = "Lista"
    @Published private(set) var progress = 0.0
    @Published private(set) var notice = ""
    @Published private(set) var busy = false
    @Published private(set) var saved: ScanRecord?
    let job: DesktopJob
    let library: ScanStore
    private let directory: URL
    private let setBusy: (Bool) -> Void
    private let onSave: (ScanRecord) -> Void
    private var session: PhotogrammetrySession?
    private var monitor: Task<Void, Never>?
    private var interrupted = false
    private var preparationControl: ProcessingControl?

    init(job: DesktopJob, library: ScanStore, root: URL, setBusy: @escaping (Bool) -> Void, onSave: @escaping (ScanRecord) -> Void) {
        self.job = job; self.library = library; self.directory = root.appendingPathComponent("Photogrammetry/\(job.id.uuidString)")
        self.setBusy = setBusy; self.onSave = onSave
    }
    private var sessionKey: String {
        (detail == "custom" ? "custom-\(UInt(customPolygonCount) ?? 0)-t\(customTextureDimension)" : detail) + "-" + qualityOptions.checkpointKey
    }
    var checkpointDirectory: URL { directory.appendingPathComponent(sessionKey + "/checkpoints") }
    var hasCheckpointFiles: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: checkpointDirectory.path)) ?? []).isEmpty == false }
    func start() {
        guard !busy, library.pendingCapture == nil, !library.isSaving else { notice = "Guarda primero la captura pendiente."; return }
        guard PhotogrammetrySession.isSupported else { notice = "El motor de fotogrametría de Apple no admite este Mac."; return }
        let quality: PhotogrammetrySession.Request.Detail
        var polygonCount: UInt?
        switch detail {
        case "raw": quality = .raw
        case "full": quality = .full
        case "medium": quality = .medium
        case "reduced": quality = .reduced
        case "custom":
            guard let count = UInt(customPolygonCount), count > 0 else {
                notice = "Introduce un número positivo de polígonos para la reconstrucción personalizada."; return
            }
            guard [2048, 4096, 8192, 16384].contains(customTextureDimension) else { notice = "Selecciona una dimensión de textura válida."; return }
            guard #available(macOS 14.0, *) else { notice = "El detalle personalizado requiere macOS 14 o posterior."; return }
            if customTextureDimension == 16384 {
                guard #available(macOS 15.0, *) else { notice = "16K requiere macOS 15 o posterior."; return }
            }
            quality = .custom; polygonCount = count
        default: notice = "Selecciona un detalle de reconstrucción válido."; return
        }
        let selectedOptions = qualityOptions
        let selectedDetail = detail
        let selectedTextureDimension = customTextureDimension
        let selectedCheckpointDirectory = checkpointDirectory
        let dataset = URL(fileURLWithPath: job.sourcePath).appendingPathComponent("dataset")
        busy = true; setBusy(true); interrupted = false; progress = 0; state = "Preparando fotogrametría \(detail)"; notice = ""
        let sessionDirectory = directory.appendingPathComponent(sessionKey)
        let output = sessionDirectory.appendingPathComponent("Modelo-\(UUID().uuidString).usdz")
        let preparationControl = ProcessingControl(); self.preparationControl = preparationControl
        monitor = Task {
          defer { self.preparationControl = nil; self.session = nil; self.monitor = nil; busy = false; setBusy(false) }
          do {
            let prepared = try await Task.detached(priority: .userInitiated) { [weak self] in
                try ProcessingControl.withControl(preparationControl) {
                    try DesktopPhotogrammetryInput.prepare(dataset: dataset, sessionDirectory: sessionDirectory) { fraction in
                        Task { @MainActor in self?.progress = fraction; self?.state = "Preparando fotografías originales del manifiesto" }
                    }
                }
            }.value
            try preparationControl.checkpoint()
            guard !interrupted else { throw CancellationError() }
            progress = 0
            try FileManager.default.createDirectory(at: selectedCheckpointDirectory, withIntermediateDirectories: true)
            var configuration = hasCheckpointFiles ? PhotogrammetrySession.Configuration(checkpointDirectory: selectedCheckpointDirectory) : .init()
            configuration.checkpointDirectory = selectedCheckpointDirectory
            selectedOptions.apply(to: &configuration)
            if #available(macOS 15.0, *) { configuration.ignoreBoundingBox = true }
            if #available(macOS 14.0, *), let polygonCount {
                configuration.customDetailSpecification.maximumPolygonCount = polygonCount
                switch selectedTextureDimension {
                case 2048: configuration.customDetailSpecification.maximumTextureDimension = .twoK
                case 4096: configuration.customDetailSpecification.maximumTextureDimension = .fourK
                case 8192: configuration.customDetailSpecification.maximumTextureDimension = .eightK
                default:
                    if #available(macOS 15.0, *) { configuration.customDetailSpecification.maximumTextureDimension = .sixteenK }
                }
                configuration.customDetailSpecification.textureFormat = .png
                configuration.customDetailSpecification.outputTextureMaps = [.diffuseColor, .normal]
            }
            let session = try PhotogrammetrySession(input: prepared.directory, configuration: configuration)
            self.session = session
                var completedURL: URL?
                var calibrationURLs: [URL] = []
                var skipped = 0
                var downsampled = false
                do {
                    // Preserve Apple's scene/camera solution in the same CRS as
                    // this model. Reusing ARKit poses here would mix two frames.
                    try session.process(requests: [.poses, .pointCloud, .bounds, .modelFile(url: output, detail: quality)])
                    for try await event in session.outputs {
                        switch event {
                        case .requestProgress(let request, let fraction):
                            if case .modelFile = request, fraction.isFinite {
                                progress = fraction; state = "Reconstruyendo fotografías · \(detail)"
                            }
                        case .inputComplete: state = "Fotografías leídas; alineando y reconstruyendo"
                        case .requestComplete(_, let result):
                            switch result {
                            case .modelFile(let url): completedURL = url
                            case .poses(let poses):
                                let url = sessionDirectory.appendingPathComponent("calibracion-fotogrametrica.json")
                                try DesktopPhotogrammetryCalibration.writePoses(poses, items: prepared.items, to: url)
                                calibrationURLs.append(url)
                            case .pointCloud(let cloud):
                                let url = sessionDirectory.appendingPathComponent("puntos-fotogrametricos.ply")
                                try DesktopPhotogrammetryCalibration.writePointCloud(cloud, to: url)
                                calibrationURLs.append(url)
                            case .bounds(let bounds):
                                let url = sessionDirectory.appendingPathComponent("limites-fotogrametricos.json")
                                try DesktopPhotogrammetryCalibration.writeBounds(bounds, to: url)
                                calibrationURLs.append(url)
                            case .modelEntity: break
                            @unknown default: break
                            }
                        case .invalidSample, .skippedSample:
                            skipped += 1; notice = "Apple omitió \(skipped) fotografías. Las originales siguen intactas."
                        case .automaticDownsampling:
                            downsampled = true; notice = "El motor Apple ha reducido imágenes para ajustarse a sus recursos. Las fuentes originales no cambian."
                        case .processingCancelled:
                            state = "Interrumpida"
                            notice = hasCheckpointFiles ? "Hay archivos de checkpoint del motor. Reintentar los ofrece a Apple; el motor decide qué trabajo puede reutilizar." : "Fuentes conservadas. Reintentar inicia la reconstrucción desde las fotografías."
                            return
                        case .requestError(_, let error): throw error
                        case .processingComplete:
                            guard !interrupted, let url = completedURL, try HybridTransfer.size(url) > 0 else {
                                throw RGBDDatasetError.invalid("El motor terminó sin un modelo fotográfico utilizable.")
                            }
                            state = "Guardando resultado fotográfico independiente"
                            let geometryCounts = try await Task.detached(priority: .userInitiated) {
                                try DesktopPhotogrammetryCalibration.geometryCounts(url)
                            }.value
                            let originalMesh = URL(fileURLWithPath: job.sourcePath).appendingPathComponent("malla-original.json")
                            let reconstructionNote: String = "Reconstrucción fotográfica local en Mac con Apple PhotogrammetrySession, detalle \(selectedDetail), \(selectedOptions.summary). Usa exclusivamente \(prepared.items.count) fotos del manifiesto, con nombres ordenados por tiempo. Conserva cámaras estimadas y nube de puntos en el sistema de coordenadas fotogramétrico, sin mezclarlas con ARKit. No usa esta malla LiDAR como geometría ni demuestra mayor precisión; su escala no está alineada ni validada contra LiDAR. Fotos omitidas por Apple: \(skipped)."
                            let downsamplingNote: String = downsampled ? " El motor informó reducción automática de imágenes; originales intactos." : ""
                            var reconstructionStatistics: [String: Double] = selectedOptions.statistics
                            reconstructionStatistics["photogrammetricReconstruction"] = 1
                            reconstructionStatistics["photogrammetryManifestPhotos"] = Double(prepared.items.count)
                            reconstructionStatistics["appleSkippedPhotos"] = Double(skipped)
                            reconstructionStatistics["appleAutomaticDownsampling"] = downsampled ? 1 : 0
                            reconstructionStatistics["photogrammetryCalibrationFiles"] = Double(calibrationURLs.count)
                            reconstructionStatistics["photogrammetryRequestedTextureDimension"] = polygonCount == nil ? 0 : Double(selectedTextureDimension)
                            reconstructionStatistics["photogrammetryRequestedPolygonCount"] = polygonCount.map { Double($0) } ?? 0
                            reconstructionStatistics["photogrammetryDetailLevel"] = Double(quality.rawValue)
                            reconstructionStatistics["photogrammetryEffectiveVertexCount"] = Double(geometryCounts.vertexCount)
                            reconstructionStatistics["photogrammetryEffectiveTriangleCount"] = Double(geometryCounts.faceCount)
                            let auxiliaryURLs: [URL] = [originalMesh, sessionDirectory.appendingPathComponent("input-order.json")] + calibrationURLs
                            let result = CaptureResult(mesh: nil, modelURL: url,
                                auxiliaryURLs: auxiliaryURLs, mode: .object, duration: job.duration,
                                note: reconstructionNote + downsamplingNote,
                                cleanupDirectory: sessionDirectory, captureDatasetURL: dataset,
                                statistics: reconstructionStatistics, modelGeometryCounts: geometryCounts)
                            if let record = await library.save(result) {
                                saved = record; onSave(record); state = "Completada"; progress = 1
                                try? FileManager.default.removeItem(at: sessionDirectory)
                            } else { state = "Guardado pendiente"; notice = library.error ?? "Resultado y fuentes conservados para reintentar." }
                            return
                        default: break
                        }
                    }
                    throw RGBDDatasetError.invalid("La sesión terminó sin confirmar un resultado.")
                } catch { state = interrupted ? "Interrumpida" : "Error"; notice = error.localizedDescription + " Las fotografías y checkpoints se conservan." }
          } catch { state = interrupted ? "Interrumpida" : "Error"; notice = error.localizedDescription + " Fuentes originales conservadas." }
        }
    }
    func interrupt() {
        guard busy else { return }
        if library.isSaving { library.cancelSaving(); return }
        interrupted = true; state = "Interrumpiendo el motor Apple"; preparationControl?.cancel(); session?.cancel()
    }
    func retrySave() {
        guard let result = library.pendingCapture else { return }
        Task {
            if let record = await library.save(result) {
                saved = record; onSave(record); state = "Completada"; progress = 1
                if let owned = result.cleanupDirectory, owned.path.hasPrefix(directory.path + "/") { try? FileManager.default.removeItem(at: owned) }
            } else { notice = library.error ?? "No se pudo guardar." }
        }
    }
}

struct DesktopPhotogrammetryView: View {
    @StateObject var controller: DesktopPhotogrammetry
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reconstrucción fotográfica en Mac").font(.title)
            Text("Crea otro modelo a partir de todas las fotografías, con el motor local de Apple. Ajusta la búsqueda de correspondencias, el aislamiento del objeto y el presupuesto de salida. No se recorta por una caja de objeto. El resultado de una sala depende de sus fotografías; esta opción no garantiza una mejora.")
                .foregroundStyle(.secondary)
            Picker("Detalle del motor", selection: $controller.detail) {
                Text("Reduced · compacto").tag("reduced")
                Text("Medium · intermedio").tag("medium")
                Text("Full · detalle completo").tag("full")
                Text("Raw · reconstrucción densa").tag("raw")
                Text("Personalizado · límites de salida").tag("custom")
            }.disabled(controller.busy)
            if controller.detail == "custom" {
                TextField("Máximo de triángulos", text: $controller.customPolygonCount).disabled(controller.busy)
                Picker("Dimensión máxima de textura", selection: $controller.customTextureDimension) {
                    Text("2K").tag(2048); Text("4K").tag(4096); Text("8K").tag(8192)
                    if #available(macOS 15.0, *) { Text("16K").tag(16384) }
                }.disabled(controller.busy)
                Text("Es un máximo editable: Apple puede generar menos triángulos. La textura limita su dimensión, no la precisión geométrica. Más triángulos no demuestran más precisión; el resultado se guarda como otra captura.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Sensibilidad alta a detalles de las fotografías", isOn: $controller.qualityOptions.highSensitivity).disabled(controller.busy)
            Toggle("Aislar objeto mediante máscara", isOn: $controller.qualityOptions.objectMasking).disabled(controller.busy)
            Toggle("Fotos en secuencia de captura", isOn: $controller.qualityOptions.sequentialOrdering).disabled(controller.busy)
            Text("La sensibilidad alta puede ayudar con superficies poco texturizadas y requiere más recursos. La máscara excluye el fondo; desactívala para reconstruir una sala. Usa secuencia cuando las fotos vecinas se solapan.").font(.caption).foregroundStyle(.secondary)
            Text("No hay cuota de fotografías de Forma. Apple aplica los límites y recursos de su motor; cualquier omisión o reducción que informe aparecerá aquí. Los originales no se modifican.").font(.caption).foregroundStyle(.secondary)
            Text(controller.state).font(.headline)
            ProgressView(value: controller.progress)
            if !controller.notice.isEmpty { Text(controller.notice).textSelection(.enabled) }
            Text("Interrumpir cancela la sesión de Apple. Se conservan fuentes y checkpoints disponibles; no se presenta como una pausa cooperativa ni se garantiza reanudación en el mismo punto.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if controller.busy { Button("Interrumpir y conservar fuentes") { controller.interrupt() } }
                else if controller.state == "Guardado pendiente" { Button("Reintentar guardado") { controller.retrySave() } }
                else if controller.saved == nil { Button(controller.hasCheckpointFiles ? "Reintentar con checkpoint disponible" : "Reconstruir localmente") { controller.start() } }
                Spacer()
                Button("Cerrar") { dismiss() }.disabled(controller.busy)
            }
        }.padding(28).frame(width: 680).interactiveDismissDisabled(controller.busy)
    }
}
