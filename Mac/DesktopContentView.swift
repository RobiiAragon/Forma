import SwiftUI
import AppKit
import Network
import Darwin

struct DesktopContentView: View {
    @ObservedObject var store: DesktopStore
    @State private var fps = 60
    @State private var showsDiagnostics = false
    @State private var previewMode = DesktopPreviewMode.original
    @State private var photogrammetry: DesktopJob?
    @State private var localAI: DesktopJob?
    @State private var gaussian: DesktopJob?
    @State private var geometryRefinement: DesktopJob?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Forma Desktop").font(.largeTitle.weight(.semibold))
                Text("Fuentes del iPhone · procesamiento local en tu Mac").foregroundStyle(.secondary)
                Button("Importar carpeta RGB-D…") { store.chooseImport() }.disabled(store.isImporting)
                if store.isImporting { ProgressView("Copiando originales…") }
                if store.library.pendingCapture != nil, !store.library.isSaving {
                    Text("Hay un resultado sin guardar; sus archivos se conservan.").font(.caption)
                    Button("Reintentar guardado pendiente") { store.retrySave() }
                }
                ReceiverPanel(receiver: store.receiver, start: { store.stopReception(); store.receive() },
                              usb: store.receiveUSB, stopUSB: store.stopUSBReception, stop: store.stopReception)
                if let active = store.activeGaussianJob {
                    DesktopGaussianStatus(controller: store.gaussianController(for: active)) { gaussian = active }
                }
                List(selection: $store.selectedID) {
                    ForEach(store.jobs) { job in
                        VStack(alignment: .leading) {
                            Text(job.title).fontWeight(.medium)
                            if job.processingRequest?.kind == .gaussian {
                                Label("Gaussian híbrido", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(job.state).font(.caption).foregroundStyle(.secondary)
                            if job.state == "Procesando" { ProgressView(value: job.progress) }
                        }.tag(job.id)
                    }
                }
            }.padding().navigationSplitViewColumnWidth(min: 280, ideal: 330)
        } detail: {
            if let job = store.selected {
                VStack(alignment: .leading, spacing: 14) {
                    Text(job.title).font(.title)
                    Text(job.state + " · " + job.status).foregroundStyle(.secondary)
                    if let request = job.processingRequest, request.kind == .gaussian {
                        Text("Solicitado desde iPhone · \(request.iterations ?? 3000) pasos · factor de reducción \(request.downscale ?? 1, specifier: "%g")")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    DesktopSavingPanel(library: store.library)
                    if ["Procesando", "Pausando", "Pausado"].contains(job.state), !store.library.isSaving {
                        ProgressView(value: job.progress)
                        HStack {
                            if job.state == "Pausado" || job.state == "Pausando" { Button("Reanudar") { store.resume(job.id) } }
                            else { Button("Pausar") { store.pause() } }
                            Button("Cancelar procesamiento", role: .destructive) { store.cancel() }
                        }
                    } else if job.state == "Guardado pendiente" { Button("Reintentar guardado") { store.retrySave() } }
                    else if job.resultID == nil { Button("Procesar desde originales") { store.resume(job.id) } }
                    Button("Reconstrucción fotográfica Full / Raw…") { photogrammetry = job }
                        .disabled(!store.canStartPhotogrammetry)
                    if FileManager.default.fileExists(atPath: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("dataset/dataset.json").path) {
                        Button("Gaussian Splatting en Mac…") { gaussian = job }
                            .disabled(!store.canStartPhotogrammetry && !store.gaussianBusy)
                    }
                    if let record = store.record(job), let model = store.library.modelURL(for: record) {
                        if let source = record.sourceScanID, let original = store.jobs.first(where: { $0.resultID == source }) {
                            HStack {
                                Text(record.gaussianModelFile == nil
                                     ? ((record.statistics?["refinedFromSavedCapture"] ?? 0) == 1 ? "Copia con geometría refinada · original conservado" : "Copia con IA · geometría original conservada")
                                     : "Representación Gaussian · fuentes originales conservadas").font(.caption).foregroundStyle(.secondary)
                                Button("Abrir original") { store.selectedID = original.id }
                            }
                        }
                        if LocalAIModelRestoration.supports(model) {
                            Button("Restaurar textura con IA local…") { localAI = job }.disabled(!store.canStartPhotogrammetry)
                        }
                        if SavedScanRefinement.canRefine(scan: record, directory: store.library.directory(for: record)) {
                            Button(store.isRefiningGeometry(job) ? "Ver reprocesamiento de geometría…" : "Refinar geometría y paredes…") { geometryRefinement = job }
                                .disabled(!store.canStartPhotogrammetry && !store.isRefiningGeometry(job))
                        }
                        HStack {
                            if record.gaussianModelFile == nil {
                                Picker("Vista", selection: $previewMode) { ForEach(DesktopPreviewMode.allCases) { Text($0.title).tag($0) } }
                            }
                            Picker("Objetivo de pantalla", selection: $fps) {
                                ForEach([30, 60, 120].filter { $0 <= (NSScreen.main?.maximumFramesPerSecond ?? 60) }, id: \.self) { Text("\($0) FPS").tag($0) }
                            }.frame(width: 240)
                            Toggle("Diagnóstico", isOn: $showsDiagnostics).toggleStyle(.checkbox)
                        }
                        if localAI == nil && photogrammetry == nil && gaussian == nil && geometryRefinement == nil {
                            if let splat = store.library.gaussianURL(for: record) {
                                DesktopGaussianViewer(modelURL: splat, captureDatasetURL: URL(fileURLWithPath: job.sourcePath).appendingPathComponent("dataset"),
                                                      targetFPS: fps, showsDiagnostics: showsDiagnostics)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                DesktopModelViewer(meshURL: store.library.directory(for: record).appendingPathComponent("malla.json"), modelURL: model,
                                    mode: previewMode, targetFPS: fps, showsDiagnostics: showsDiagnostics).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            ContentUnavailableView("Visor en reposo", systemImage: "cpu", description: Text("Los recursos quedan disponibles para el procesamiento local."))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        Text(record.gaussianModelFile == nil
                            ? "Textura original usa todos sus píxeles. Textura ligera reduce solo las copias de pantalla; la exportación conserva los originales. El objetivo de FPS depende de pantalla y GPU; no cambia los datos del sensor."
                            : "Visor Gaussian Metal con armónicos esféricos SH3. El PLY conserva los coeficientes; el complemento SPLAT usa color base. Gira y amplía para explorar.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Mostrar exportaciones en Finder") { NSWorkspace.shared.open(store.library.directory(for: record)) }
                            ShareLink(item: record.gaussianModelFile != nil || record.modelFile?.hasSuffix(".usdz") == true ? model : store.library.directory(for: record).appendingPathComponent("modelo-texturizado.zip")) { Label("Exportar modelo nativo", systemImage: "square.and.arrow.up") }
                        }
                    } else {
                        ContentUnavailableView("Fuentes conservadas", systemImage: "cube", description: Text("El modelo aparecerá al terminar el procesamiento. Puedes revisar el avance o los trabajos pendientes en la cola."))
                        Button("Mostrar originales") { NSWorkspace.shared.open(URL(fileURLWithPath: job.sourcePath)) }
                    }
                }.padding(24)
            } else { ContentUnavailableView("Tu Mac procesa, tu iPhone captura", systemImage: "iphone.and.arrow.right.inward", description: Text("Activa la recepción local o importa una carpeta RGB-D de Forma.")) }
        }
        .sheet(item: $photogrammetry) { job in DesktopPhotogrammetryView(controller: store.photogrammetryController(for: job)) }
        .sheet(item: $localAI) { job in
            if let controller = store.localAIController(for: job) { DesktopLocalAIView(controller: controller) }
        }
        .sheet(item: $gaussian) { job in DesktopGaussianView(controller: store.gaussianController(for: job)) }
        .sheet(item: $geometryRefinement) { job in
            if let controller = store.geometryController(for: job) { DesktopGeometryRefinementView(controller: controller) }
        }
        .alert("Forma Desktop", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Entendido") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

private struct DesktopGaussianStatus: View {
    @ObservedObject var controller: DesktopGaussian
    var open: () -> Void
    var body: some View {
        GroupBox("Gaussian en curso") {
            VStack(alignment: .leading, spacing: 7) {
                Text(controller.state).font(.caption)
                ProgressView(value: controller.progress)
                Text("\(controller.iteration.formatted()) pasos · \(controller.splats.formatted()) gaussianas")
                    .font(.caption2.monospacedDigit())
                Button("Ver entrenamiento y controles", action: open)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DesktopGaussianViewer: View {
    let modelURL: URL
    let captureDatasetURL: URL?
    let targetFPS: Int
    let showsDiagnostics: Bool
    @State private var resetRequest = UUID()
    @State private var performance: ViewerPerformanceSnapshot?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DesktopGaussianPreview(modelURL: modelURL, resetRequest: resetRequest, targetFPS: targetFPS,
                onPerformanceUpdate: { performance = $0 }, captureDatasetURL: captureDatasetURL)
            HStack {
                if showsDiagnostics {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text(diagnostic).font(.caption.monospacedDigit()).padding(8).background(.ultraThinMaterial)
                    }
                }
                Spacer()
                Button("Reencuadrar") { resetRequest = UUID() }.padding(8)
            }
        }
    }
    private var diagnostic: String {
        guard let performance else { return "Preparando Gaussian…" }
        let cadence = performance.activeFramesPerSecond(at: ProcessInfo.processInfo.systemUptime)
            .map { String(format: "%.1f FPS presentados", $0) } ?? "Visor en reposo"
        let ready = performance.readySeconds.map { String(format: " · Primera imagen %.2f s", $0) } ?? ""
        return cadence + ready
    }
}

private struct ReceiverPanel: View {
    @ObservedObject var receiver: HybridTransferReceiver
    var start: () -> Void
    var usb: () -> Void
    var stopUSB: () -> Void
    var stop: () -> Void
    @StateObject private var wifi = DesktopWiFiAddresses()
    var body: some View {
        GroupBox("Conexión local") {
            VStack(alignment: .leading, spacing: 8) {
                Text(receiver.status).font(.caption)
                if receiver.isListening {
                    Text(receiver.pairingCode).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copiar clave de sesión") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(receiver.pairingCode, forType: .string) }
                    Text("Pégala en Forma del iPhone. Solo esta sesión puede enviar fuentes; el transporte está cifrado.").font(.caption2).foregroundStyle(.secondary)
                    Text("Wi-Fi es la ruta predeterminada.").font(.caption2).foregroundStyle(.secondary)
                    if let port = receiver.listeningPort {
                        if wifi.addresses.isEmpty {
                            Text(verbatim: "Conexión por dirección · puerto \(port)").font(.caption2).textSelection(.enabled)
                        } else {
                            ForEach(wifi.addresses, id: \.self) { address in
                                Text(verbatim: "Conexión por dirección: \(address):\(port)").font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    if receiver.isUSBContinuousEnabled {
                        Text(receiver.usbStatus).font(.caption)
                        Text("Puedes consultar, controlar y descargar desde el iPhone sin volver a conectar aquí.").font(.caption2).foregroundStyle(.secondary)
                        Button("Detener USB-C") { stopUSB() }
                    } else {
                        Text("Para usar el cable, activa USB-C aquí y elige USB-C en el iPhone.").font(.caption2).foregroundStyle(.secondary)
                        Button("Activar USB-C continuo") { usb() }
                    }
                    Button("Cerrar recepción") { stop() }
                } else { Button("Recibir desde iPhone") { start() } }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Read-only network inventory: Network chooses Wi-Fi interface names; getifaddrs
/// supplies their current IPv4 values. No assumed en0 mapping or permission prompt.
@MainActor
private final class DesktopWiFiAddresses: ObservableObject {
    @Published private(set) var addresses: [String] = []
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let names = path.status == .satisfied && path.usesInterfaceType(.wifi)
                ? Set(path.availableInterfaces.filter { $0.type == .wifi }.map(\.name)) : []
            let addresses = Self.ipv4Addresses(for: names)
            Task { @MainActor [weak self] in
                if self?.addresses != addresses { self?.addresses = addresses }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.forma.desktop.wifi-addresses"))
    }
    deinit { monitor.cancel() }
    nonisolated private static func ipv4Addresses(for names: Set<String>) -> [String] {
        guard !names.isEmpty else { return [] }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var values: Set<String> = []
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard let name = entry.ifa_name, names.contains(String(cString: name)),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                values.insert(String(cString: host))
            }
        }
        return values.sorted()
    }
}

private struct DesktopSavingPanel: View {
    @ObservedObject var library: ScanStore
    var body: some View {
        if library.isSaving {
            VStack(alignment: .leading) {
                Text(library.savingStage + (library.savingState.isPauseActive ? " · Pausa" : ""))
                ProgressView(value: library.savingTotalBytes > 0 ? Double(library.savingCompletedBytes)/Double(library.savingTotalBytes) : 0)
                HStack {
                    Button(library.savingState.isPauseActive ? "Reanudar guardado" : "Pausar guardado") { library.toggleSavingPause() }
                    Button("Cancelar guardado", role: .destructive) { library.cancelSaving() }
                }
            }
        }
    }
}
