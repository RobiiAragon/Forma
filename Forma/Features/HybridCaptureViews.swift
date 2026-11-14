import SwiftUI
import UIKit
import Combine
import Network

private final class HybridTransferMetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HybridTransfer.TransferMetrics?
    func set(_ value: HybridTransfer.TransferMetrics) {
        lock.lock(); defer { lock.unlock() }; self.value = value
    }
    func get() -> HybridTransfer.TransferMetrics? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

struct HybridCaptureDestination {
    enum Transport: String, CaseIterable {
        case wifi, nearby, usb
        var isWireless: Bool { self != .usb }
        var name: String {
            switch self { case .wifi: return "Wi-Fi"; case .nearby: return "Wi-Fi directo"; case .usb: return "USB-C" }
        }
    }
    var peer: HybridTransfer.Peer?
    var pairingCode: String
    var transport: Transport = .wifi
    var displayName: String { peer?.displayName ?? "Mac por USB-C" }
}

struct HybridGaussianSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let scan: ScanRecord
    let directory: URL
    @State private var iterations = "3000"
    @State private var downscale = "1"
    @State private var request: HybridTransfer.ProcessingRequest?
    @State private var delivering = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Gaussian en tu Mac").font(.title2)
                    Text("El iPhone envía las fotos y cámaras originales. La GPU de tu Mac realiza el entrenamiento y guarda otra versión en Forma Desktop, aunque cierres Forma o bloquees el teléfono.")
                }
                Section("Entrenamiento") {
                    Menu("Aplicar ajuste rápido") {
                        ForEach(GaussianTrainingPreset.allCases) { preset in
                            Button(preset.title) {
                                preset.apply(iterations: &iterations, downscale: &downscale, preservingScale: false)
                            }
                        }
                    }.accessibilityIdentifier("hybridGaussianQualityPresets")
                    Text(GaussianTrainingPreset.explanation).font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Iteraciones") {
                        TextField("3000", text: $iterations).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("hybridGaussianIterations")
                    }
                    LabeledContent("Factor de reducción") {
                        TextField("1", text: $downscale).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("hybridGaussianDownscale")
                    }
                    Text("Factor 1 conserva toda la resolución. El objetivo de pasos es editable y no hay cuotas de fotos, gaussianas ni trabajos. Más pasos no garantizan por sí solos mejor calidad.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button("Conectar y enviar al Mac") {
                    guard let count = Int(iterations.trimmingCharacters(in: .whitespaces)),
                          let scale = Float(downscale.replacingOccurrences(of: ",", with: ".")) else {
                        error = "Introduce un número de iteraciones y un factor de resolución válidos."; return
                    }
                    let configuration = HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: count, downscale: scale)
                    do { try configuration.validate(); request = configuration; error = nil; delivering = true }
                    catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("configureHybridGaussian")
            }
            .navigationTitle("Procesamiento híbrido").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .sheet(isPresented: $delivering) {
                if let request {
                    HybridDeliveryView(scan: scan, directory: directory, initialDestination: nil, processingRequest: request)
                }
            }
        }.preferredColorScheme(.dark)
    }
}

struct CaptureSetupView: View {
    var onStandalone: () -> Void
    var onHybrid: (HybridCaptureDestination) -> Void
    var connectingOnly = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = HybridTransferBrowser()
    @State private var useMac = false
    @State private var selectedPeerID = ""
    @State private var pairingCode = ""
    @State private var showPairingCode = false
    @State private var transport = HybridCaptureDestination.Transport.wifi
    @State private var connectingByAddress = false
    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(connectingOnly ? "Conectar con Forma Desktop" : "¿Dónde quieres procesar el espacio?").font(.title2.bold())
                    Text(connectingOnly ? "Elige cómo conectar con tu Mac para este trabajo guardado." : "El iPhone conserva la geometría y las fotos originales. Elige quién realiza el texturizado al terminar.")
                        .foregroundStyle(.secondary)
                    if !connectingOnly {
                    Button { useMac = false } label: {
                        option("Standalone · iPhone", subtitle: "Captura y procesamiento en el celular.", icon: "iphone", selected: !useMac)
                    }.buttonStyle(.plain).accessibilityIdentifier("chooseStandalone")
                    Button { useMac = true; browse() } label: {
                        option("Híbrido · Mac", subtitle: "El iPhone captura; Forma Desktop procesa las fuentes en tu Mac.", icon: "desktopcomputer", selected: useMac)
                    }.buttonStyle(.plain).accessibilityIdentifier("chooseHybrid")
                    }
                    if useMac || connectingOnly {
                        Picker("Conexión", selection: $transport) {
                            Text("Wi-Fi").tag(HybridCaptureDestination.Transport.wifi)
                            Text("Directo").tag(HybridCaptureDestination.Transport.nearby)
                            Text("USB-C").tag(HybridCaptureDestination.Transport.usb)
                        }.pickerStyle(.segmented)
                        Text(connectionInstructions)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if transport.isWireless && browser.peers.isEmpty {
                            HStack { ProgressView(); Text(browser.status).font(.caption) }
                            Button("Buscar de nuevo") { browse() }
                        }
                        ForEach(transport.isWireless ? browser.peers : []) { peer in
                            Button { selectedPeerID = peer.id; connectingByAddress = false } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    Text(peer.displayName)
                                    Spacer()
                                    if selectedPeerID == peer.id && !connectingByAddress { Image(systemName: "checkmark.circle.fill") }
                                }.padding().background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                        if transport == .wifi {
                            DisclosureGroup("Conectar por dirección", isExpanded: $connectingByAddress) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Introduce la IP o el nombre .local y el puerto que muestra Forma Desktop. Se usa la misma clave de sesión y el mismo cifrado local.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    TextField("Dirección del Mac · mi-mac.local o IP", text: $manualHost)
                                        .keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("hybridManualHost")
                                    TextField("Puerto de recepción", text: $manualPort)
                                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                                        .accessibilityIdentifier("hybridManualPort")
                                }.padding(.top, 10)
                            }.font(.subheadline).accessibilityIdentifier("hybridManualAddressDisclosure")
                        }
                        HStack {
                            Group {
                                if showPairingCode { TextField("Clave de sesión del Mac", text: $pairingCode) }
                                else { SecureField("Clave de sesión del Mac", text: $pairingCode) }
                            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("hybridPairingCode")
                            Button { showPairingCode.toggle() } label: {
                                Image(systemName: showPairingCode ? "eye.slash" : "eye")
                            }.accessibilityLabel(showPairingCode ? "Ocultar clave de sesión" : "Mostrar clave de sesión")
                        }
                        Text("La transferencia es local y cifrada. Si se corta, puedes continuar con lo que la Mac ya recibió.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !connectingOnly {
                    Label("Vista del celular a \(CapturePacingPolicy.phonePreviewFPS) fps; frecuencia real de ARKit indicada durante la captura.", systemImage: "thermometer.medium")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    Button {
                        if useMac || connectingOnly {
                            let peer: HybridTransfer.Peer?
                            if transport == .wifi && connectingByAddress {
                                do {
                                    let address = try HybridConnectionAddress.parse(host: manualHost, port: manualPort)
                                    peer = .init(id: address.id, displayName: address.displayName, endpoint: address.endpoint)
                                } catch { self.error = error.localizedDescription; return }
                            } else {
                                peer = browser.peers.first(where: { $0.id == selectedPeerID }) ?? (browser.peers.count == 1 ? browser.peers.first : nil)
                            }
                            guard transport == .usb || peer != nil else {
                                error = "Selecciona una Mac disponible antes de comenzar."; return
                            }
                            do { _ = try HybridTransfer.pairingKey(pairingCode) }
                            catch { self.error = error.localizedDescription; return }
                            // Apple recommends stopping nearby discovery before
                            // starting its peer-to-peer data connection.
                            browser.stop()
                            onHybrid(.init(peer: transport.isWireless ? peer : nil, pairingCode: pairingCode, transport: transport))
                        } else { onStandalone() }
                        dismiss()
                    } label: {
                        Label(connectingOnly ? "Usar esta conexión" : useMac ? "Capturar para procesar en Mac" : "Capturar en iPhone", systemImage: connectingOnly ? "link" : "viewfinder")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(FormaStyle.accent).accessibilityIdentifier("confirmCaptureExecution")
                }.padding(24)
            }.background(FormaStyle.background)
                .navigationTitle(connectingOnly ? "Conexión local" : "Procesamiento").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }.preferredColorScheme(.dark).onAppear { if connectingOnly { browse() } }.onDisappear { browser.stop() }
            .onChange(of: transport) { _, _ in selectedPeerID = ""; error = nil; browse() }
    }

    private func browse() {
        if transport.isWireless { browser.start(peerToPeer: transport == .nearby) }
        else { browser.stop() }
    }
    private var connectionInstructions: String {
        switch transport {
        case .wifi: return "Opción predeterminada. Abre Forma Desktop en la misma red. Selecciona tu Mac y pega su clave de sesión."
        case .nearby: return "Acerca el iPhone y la Mac con Wi-Fi activado. Activa Recibir desde iPhone en Forma Desktop y usa su clave. La conexión directa de Apple permite transferir sin depender del router."
        case .usb: return "Conecta el cable, activa Recibir desde iPhone y USB-C continuo en Forma Desktop y pega su clave. Las consultas y transferencias se conectan automáticamente mientras USB-C siga activo."
        }
    }

    private func option(_ title: String, subtitle: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? FormaStyle.accent : .secondary)
        }.padding(18).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

@MainActor
struct HybridDeliveryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: HybridDeliveryController
    @State private var selecting = false

    init(scan: ScanRecord, directory: URL, initialDestination: HybridCaptureDestination?,
         processingRequest: HybridTransfer.ProcessingRequest? = nil) {
        _controller = StateObject(wrappedValue: HybridDeliveryController.controller(
            scan: scan, directory: directory, destination: initialDestination, processingRequest: processingRequest))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "desktopcomputer.and.arrow.down").font(.system(size: 44)).foregroundStyle(FormaStyle.accent)
                Text(controller.processingRequest?.kind == .gaussian ? "Gaussian en tu Mac" : "Procesar en tu Mac").font(.title.bold())
                Text("Se envían la malla, las fotografías y la calibración originales. Forma Desktop procesa las fuentes y guarda el resultado en su biblioteca. El proceso del Mac continúa aunque bloquees el iPhone.")
                    .foregroundStyle(.secondary)
                if let request = controller.processingRequest, request.kind == .gaussian {
                    Text("\(request.iterations ?? 3000) pasos · factor de reducción \(request.downscale ?? 1, specifier: "%g")")
                        .font(.caption.monospacedDigit())
                }
                if let destination = controller.destination {
                    Label(destination.displayName, systemImage: destination.transport.isWireless ? "wifi" : "cable.connector")
                }
                Text(controller.status).font(.headline)
                if let date = controller.destinationAcknowledgedAt {
                    HStack {
                        Text("Confirmación de esta conexión")
                        Text(date, style: .relative)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if controller.transferring { ProgressView(value: controller.progress).tint(FormaStyle.accent) }
                if let error = controller.error { Text(error).foregroundStyle(.orange).font(.subheadline) }
                if controller.remoteJobID != nil && !controller.transferring && !controller.pausedByUser {
                    if let remote = controller.remoteStatus {
                        HStack {
                            Text(controller.remoteStatusIsCurrentDestination ? "Último estado de esta conexión" : "Estado guardado de una conexión anterior")
                            if let date = controller.statusObservedAt { Text(date, style: .relative) }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(controller.remoteStatusLabel).font(.headline)
                        ProgressView(value: remote.progress).tint(FormaStyle.accent)
                        if let step = remote.iteration {
                            VStack(alignment: .leading) {
                                if let target = remote.targetIterations { Text("\(step) / \(target) pasos") }
                                else { Text("\(step) pasos") }
                                if let splats = remote.splats { Text("\(splats.formatted()) gaussianas") }
                            }.font(.caption.monospacedDigit())
                        }
                        if let error = remote.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    if let error = controller.statusError { Text(error).font(.caption).foregroundStyle(.orange) }
                    Button(controller.destination == nil ? "Conectar para consultar el proceso" : "Actualizar estado del Mac") {
                        if controller.destination == nil { selecting = true } else { controller.refreshRemoteStatus() }
                    }.buttonStyle(.borderedProminent).tint(FormaStyle.accent).disabled(controller.checkingStatus)
                    if controller.checkingStatus {
                        HStack { ProgressView(); Text(controller.destination?.transport == .usb ? "Esperando conexión USB-C con Forma Desktop…" : "Consultando tu Mac…").font(.caption) }
                        Button("Cancelar consulta") { controller.stopRemoteMonitoring() }.font(.caption)
                    }
                    Button("Elegir otra conexión") { selecting = true }
                    Button("Reenviar/verificar fuentes en esta Mac") {
                        if controller.destination == nil { selecting = true }
                        else { controller.send(verifyingDelivery: true) }
                    }.font(.caption)
                    HybridRemoteJobPanel(controller: controller)
                } else {
                if controller.transferring {
                    Button("Pausar envío") { controller.pause() }.buttonStyle(.bordered)
                    Button("Cancelar transferencia") { controller.cancel() }.font(.caption)
                } else {
                    Button(controller.destination == nil ? "Conectar con Forma Desktop" : controller.pausedByUser ? "Continuar envío" : "Enviar fuentes al Mac") {
                        if controller.destination == nil { selecting = true } else { controller.send() }
                    }.buttonStyle(.borderedProminent).tint(FormaStyle.accent)
                    if controller.destination != nil { Button("Elegir otra conexión") { selecting = true } }
                    if controller.pausedByUser { Button("Cancelar transferencia") { controller.cancel() }.font(.caption) }
                }
                }
                Text("Puedes cerrar esta pantalla y volver al mismo envío. Al reintentar se verifica lo recibido y se continúa sin duplicar el trabajo. Tus originales se conservan.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(26)
            }.background(FormaStyle.background)
                .navigationTitle("Forma híbrida").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
                .sheet(isPresented: $selecting) {
                    CaptureSetupView(onStandalone: { selecting = false }, onHybrid: {
                        controller.selectDestination($0); selecting = false
                        if controller.remoteJobID != nil { controller.refreshRemoteStatus() }
                    }, connectingOnly: true)
                }
        }.preferredColorScheme(.dark)
            .onAppear { controller.startIfNeeded(); controller.startRemoteMonitoring() }
            .onDisappear { controller.stopRemoteMonitoring() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { controller.startRemoteMonitoring() }
                else if phase == .background { controller.stopRemoteMonitoring() }
            }
    }
}

/// The network operation survives dismissal. Only explicit controls cancel its task.
@MainActor
final class HybridDeliveryController: ObservableObject {
    private static var jobs: [String: HybridDeliveryController] = [:]
    static func controller(scan: ScanRecord, directory: URL, destination: HybridCaptureDestination?,
                           processingRequest: HybridTransfer.ProcessingRequest? = nil) -> HybridDeliveryController {
        // Configuration is part of the remote identity; a different target is another job.
        let key = (try? HybridDeliveryReceipt.key(scanID: scan.id, request: processingRequest)) ?? UUID().uuidString
        if let existing = jobs[key] {
            if existing.destination == nil, let destination { existing.selectDestination(destination) }
            return existing
        }
        let job = HybridDeliveryController(scan: scan, directory: directory, destination: destination, processingRequest: processingRequest)
        jobs[key] = job
        return job
    }
    @Published private(set) var destination: HybridCaptureDestination?
    @Published private(set) var transferring = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Fuentes guardadas en el iPhone"
    @Published private(set) var error: String?
    @Published private(set) var pausedByUser = false
    @Published private(set) var remoteJobID: UUID?
    /// An ACK is evidence for this selected connection only. Recovered receipts
    /// cannot authenticate a different Mac or even a later pairing session.
    @Published private(set) var destinationAcknowledgedAt: Date?
    @Published private(set) var remoteStatus: HybridTransfer.RemoteJobStatus?
    @Published private(set) var statusObservedAt: Date?
    @Published private(set) var statusError: String?
    @Published private(set) var checkingStatus = false
    @Published private(set) var commanding = false
    @Published private(set) var commandNotice: String?
    @Published private(set) var pendingCommand: HybridTransfer.RemoteJobCommand?
    @Published private(set) var receivingResult = false
    @Published private(set) var resultProgress = 0.0
    @Published private(set) var resultPaused = false
    @Published private(set) var resultNotice: String?
    @Published private(set) var downloadedResult: HybridTransfer.DownloadedResult?
    @Published private(set) var savedResult: ScanRecord?
    @Published private(set) var savingResult = false
    let processingRequest: HybridTransfer.ProcessingRequest?
    private let scan: ScanRecord
    private let directory: URL
    private let receiptDirectory: URL
    private var started = false
    private var transferTask: Task<Void, Never>?
    private var activityID: UUID?
    private var generation = UUID()
    private var receipt: HybridDeliveryReceipt?
    private var monitorTask: Task<Void, Never>?
    private var monitorGeneration = UUID()
    private var monitoringVisible = false
    private var commandTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var resultActivityID: UUID?
    private var resultLibrary: ScanStore?
    private var resultGeneration = UUID()
    private var statusIsFresh = false
    private let resultImporter: HybridResultImport

    init(scan: ScanRecord, directory: URL, destination: HybridCaptureDestination?,
         processingRequest: HybridTransfer.ProcessingRequest?,
         receiptDirectory: URL = HybridDeliveryReceipt.directory) {
        self.scan = scan; self.directory = directory; self.destination = destination
        self.receiptDirectory = receiptDirectory
        self.resultImporter = HybridResultImport(metadataDirectory: receiptDirectory.appendingPathComponent("imports", isDirectory: true))
        self.processingRequest = processingRequest
        do {
            receipt = try HybridDeliveryReceipt.load(scanID: scan.id, request: processingRequest, in: receiptDirectory)
            remoteJobID = receipt?.jobID; remoteStatus = receipt?.lastStatus
            statusObservedAt = receipt?.statusObservedAt
            pendingCommand = receipt?.pendingCommand
            if remoteJobID != nil { status = historicalDeliveryStatus }
        } catch { self.error = "No se pudo recuperar el recibo: \(error.localizedDescription)" }
    }
    func startIfNeeded() {
        guard !started else { return }
        started = true
        recoverDownloadedResult()
        if destination != nil, remoteJobID == nil { send() }
    }
    func pause() {
        guard transferring else { return }
        pausedByUser = true
        transferTask?.cancel()
    }
    func cancel() {
        pausedByUser = false
        if !transferring, let activityID {
            status = "Transferencia cancelada; fuentes conservadas"
            ProcessingActivityCoordinator.shared.finish(id: activityID, success: false, status: status)
            self.activityID = nil
        }
        transferTask?.cancel()
    }
    func selectDestination(_ value: HybridCaptureDestination) {
        guard !transferring, !receivingResult, !commanding else { error = "Termina o pausa la transferencia antes de cambiar de conexión."; return }
        monitorGeneration = UUID(); monitorTask?.cancel(); monitorTask = nil; checkingStatus = false
        destination = value; remoteStatus = nil; statusObservedAt = nil; statusIsFresh = false; statusError = nil
        destinationAcknowledgedAt = nil
        status = historicalDeliveryStatus
    }
    private var historicalDeliveryStatus: String {
        guard remoteJobID != nil else { return "Fuentes guardadas en el iPhone" }
        return destination == nil ? "Entrega anterior guardada; conecta para verificar o consultar" :
            "Entrega anterior guardada; verifica o consulta esta Mac"
    }
    var remoteStatusIsCurrentDestination: Bool { statusIsFresh }
    func send(verifyingDelivery: Bool = false) {
        let isVerification = verifyingDelivery || (pausedByUser && remoteJobID != nil)
        guard !transferring, !commanding, !receivingResult, !savingResult, pendingCommand == nil,
              remoteJobID == nil || isVerification, let destination else { return }
        monitorGeneration = UUID(); monitorTask?.cancel(); monitorTask = nil; checkingStatus = false
        guard let relative = scan.datasetDirectory, ScanStore.safeRelativePath(relative),
              let raw = SavedScanRefinement.originalMeshURL(scan: scan, directory: directory) else {
            error = "Esta captura no conserva las fotografías y la malla necesarias para procesar en Mac."; return
        }
        transferring = true; pausedByUser = false; progress = 0; error = nil; status = "Preparando envío cifrado"
        destinationAcknowledgedAt = nil
        let run = UUID(); generation = run
        transferTask = Task { [self] in
            let oldIdle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            let activityID = self.activityID ?? UUID(); self.activityID = activityID
            _ = await ProcessingActivityCoordinator.shared.begin(id: activityID, title: "Enviando captura al Mac",
                onAction: { [weak self] action in
                    if action == "pause" { self?.pause() }
                    if action == "resume" { self?.send(verifyingDelivery: isVerification) }
                }, onExpiration: { [weak self] in
                    // CPU/network has no foreground GPU requirement. Preserve the
                    // connection/task; iOS may suspend it and TCP may then require retry.
                    self?.status = "iOS terminó la autorización continua; las fuentes y el avance recibido se conservan."
                })
            var succeeded = false
            ProcessingActivityCoordinator.shared.update(id: activityID, progress: progress,
                status: status, phase: "running", energyLabel: "Transferencia local")
            defer {
                transferring = false; UIApplication.shared.isIdleTimerDisabled = oldIdle
                if pausedByUser {
                    ProcessingActivityCoordinator.shared.update(id: activityID, progress: progress,
                        status: status, phase: "paused", energyLabel: "Pausa manual")
                } else {
                    ProcessingActivityCoordinator.shared.finish(id: activityID, success: succeeded, status: status)
                    self.activityID = nil
                }
                transferTask = nil
            }
            do {
                status = "Leyendo la malla original"
                let mesh = try await Task.detached(priority: .utility) {
                    try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: raw))
                }.value
                try Task.checkCancellation()
                let preparation: @Sendable (HybridTransfer.TransferStage) -> Void = { [weak self] stage in
                    Task { @MainActor in
                        guard let self, self.generation == run, self.transferring, !self.pausedByUser else { return }
                        switch stage {
                        case .connecting: self.status = "Conectando con Forma Desktop"
                        case .authenticating: self.status = "Verificando la clave de sesión con la Mac"
                        case .hashing(let completed, let total):
                            let percent = total > 0 ? Int(min(100, max(0, completed / total * 100))) : 100
                            self.status = "Verificando fuentes originales · \(percent)%"
                        case .negotiating: self.status = "Consultando los archivos ya recibidos en Mac"
                        case .verifying: self.status = "Esperando la verificación final de la Mac"
                        }
                        ProcessingActivityCoordinator.shared.update(id: activityID, progress: self.progress,
                            status: self.status, phase: "running", energyLabel: "Transferencia local")
                    }
                }
                let update: @Sendable (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == run, self.transferring, !self.pausedByUser else { return }
                        self.progress = fraction
                        self.status = "Enviando fuentes por " + destination.transport.name
                        ProcessingActivityCoordinator.shared.update(id: activityID, progress: fraction,
                            status: self.status, phase: "running", energyLabel: "Transferencia local")
                    }
                }
                let received: UUID
                let transportMetrics = HybridTransferMetricsBox()
                if destination.transport == .usb {
                    status = "Esperando conexión USB-C con Forma Desktop…"
                    received = try await HybridTransfer.sendOverUSBWaitingForMac(datasetDirectory: directory.appendingPathComponent(relative), mesh: mesh,
                        duration: scan.duration, pairingCode: destination.pairingCode, processingRequest: processingRequest, stage: preparation, metrics: { transportMetrics.set($0) }, progress: update)
                } else if let peer = destination.peer {
                    received = try await HybridTransfer.send(datasetDirectory: directory.appendingPathComponent(relative), mesh: mesh,
                        duration: scan.duration, to: peer, pairingCode: destination.pairingCode, processingRequest: processingRequest, stage: preparation, metrics: { transportMetrics.set($0) }, progress: update)
                } else { throw HybridTransfer.TransferError.failed("Selecciona la Mac para esta conexión Wi-Fi.") }
                remoteJobID = received
                let acknowledgedAt = Date()
                if receipt?.jobID != received {
                    receipt = HybridDeliveryReceipt(scanID: scan.id, processingRequest: processingRequest,
                        jobID: received, acknowledgedAt: acknowledgedAt)
                }
                receipt?.recordAcknowledgement(at: acknowledgedAt)
                destinationAcknowledgedAt = acknowledgedAt
                receipt?.sourceConnectionUsesWiFi = transportMetrics.get()?.connectionUsesWiFi
                do { try receipt?.save(in: receiptDirectory) }
                catch { self.error = "El Mac recibió las fuentes, pero no se pudo guardar el recibo local: \(error.localizedDescription)" }
                status = "Mac confirmó todos los archivos; procesamiento disponible en Forma Desktop"
                progress = 1; succeeded = true
                if monitoringVisible { refreshRemoteStatus() }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    status = pausedByUser ? "Envío en pausa; puedes continuar desde lo recibido" : "Transferencia cancelada; fuentes conservadas"
                } else {
                    self.error = error.localizedDescription
                    status = "No se completó el envío; puedes reintentar desde lo recibido"
                }
            }
        }
    }

    var remoteStatusLabel: String {
        guard let remoteStatus else { return "Estado del proceso pendiente de consultar" }
        if remoteStatus.resultAvailable { return "Resultado guardado en Forma Desktop" }
        switch remoteStatus.state {
        case "queued": return "En cola en tu Mac"
        case "preparing": return "Preparando las cámaras en Mac"
        case "running": return "Procesando en tu Mac"
        case "checkpointing": return "Guardando avance en Mac"
        case "pausing": return "Pausa solicitada en Forma Desktop"
        case "paused": return "Pausado en tu Mac"
        case "exporting", "saving", "awaiting-save": return "Guardando el resultado en Mac"
        case "failed", "interrupted": return "Revisar el proceso en Forma Desktop"
        case "cancelled": return "Proceso cancelado en Forma Desktop"
        case "unknown": return "El trabajo no está disponible en esta Mac"
        default: return "Consultando el proceso de tu Mac"
        }
    }

    func startRemoteMonitoring() {
        monitoringVisible = true
        if remoteJobID != nil, destination?.transport.isWireless == true { refreshRemoteStatus() }
    }
    func stopRemoteMonitoring() {
        monitoringVisible = false
        statusIsFresh = false
        monitorGeneration = UUID()
        monitorTask?.cancel(); monitorTask = nil; checkingStatus = false
    }
    func refreshRemoteStatus() {
        guard !checkingStatus, !commanding, !receivingResult, !savingResult,
              let jobID = remoteJobID, let destination else { return }
        monitorTask?.cancel()
        let token = UUID(); monitorGeneration = token
        monitorTask = Task { [weak self] in
            guard let self else { return }
            defer { if monitorGeneration == token { checkingStatus = false; monitorTask = nil } }
            repeat {
                guard monitorGeneration == token, !Task.isCancelled else { break }
                checkingStatus = true
                do {
                    let value: HybridTransfer.RemoteJobStatus
                    if destination.transport == .usb {
                        value = try await HybridTransfer.statusOverUSBWaitingForMac(jobID: jobID, pairingCode: destination.pairingCode)
                    } else if let peer = destination.peer {
                        value = try await HybridTransfer.status(jobID: jobID, to: peer, pairingCode: destination.pairingCode)
                    } else { throw HybridTransfer.TransferError.failed("Selecciona una Mac para consultar el estado.") }
                    try Task.checkCancellation()
                    guard monitorGeneration == token else { break }
                    remoteStatus = value; statusObservedAt = Date(); statusIsFresh = true; statusError = nil
                    receipt?.lastStatus = value; receipt?.statusObservedAt = statusObservedAt
                    do { try receipt?.save(in: receiptDirectory) }
                    catch { statusError = "Estado recibido; no se pudo guardar el recibo actualizado: \(error.localizedDescription)" }
                    // An ACK can reach the phone just before the Mac publishes its queue row.
                    // Keep observing an unknown job while this screen is visible.
                    if value.resultAvailable || ["failed", "cancelled"].contains(value.state) { break }
                } catch {
                    if Task.isCancelled || monitorGeneration != token { break }
                    statusError = "No se pudo consultar el Mac: \(error.localizedDescription)"
                    break
                }
                checkingStatus = false
                guard monitoringVisible, destination.transport.isWireless else { break }
                do { try await Task.sleep(for: .seconds(4)) } catch { break }
            } while !Task.isCancelled
        }
    }

    var availableRemoteCommands: [HybridTransfer.RemoteJobCommand.Action] {
        statusIsFresh && remoteStatus?.controlRevision != nil && !commanding && pendingCommand == nil
            ? remoteStatus?.supportedCommands ?? [] : []
    }
    func sendRemoteCommand(_ action: HybridTransfer.RemoteJobCommand.Action) {
        guard availableRemoteCommands.contains(action), let jobID = remoteJobID,
              let revision = remoteStatus?.controlRevision else { return }
        pendingCommand = .init(id: UUID(), jobID: jobID, action: action, expectedRevision: revision)
        receipt?.pendingCommand = pendingCommand
        do { try receipt?.save(in: receiptDirectory) }
        catch { commandNotice = "No se pudo conservar la orden antes de enviarla: \(error.localizedDescription)"; return }
        retryRemoteCommand()
    }
    func retryRemoteCommand() {
        guard !commanding, let command = pendingCommand, let destination else { return }
        receipt?.pendingCommand = command
        do { try receipt?.save(in: receiptDirectory) }
        catch { commandNotice = "No se pudo conservar la orden antes de enviarla: \(error.localizedDescription)"; return }
        monitorGeneration = UUID(); monitorTask?.cancel(); monitorTask = nil; checkingStatus = false
        commanding = true; commandNotice = "Consultando la confirmación de la orden…"
        commandTask = Task { [self] in
            defer {
                commanding = false; commandTask = nil
                if monitoringVisible, destination.transport.isWireless { refreshRemoteStatus() }
            }
            do {
                let reply: HybridTransfer.RemoteCommandReply
                if destination.transport == .usb {
                    commandNotice = "Pulsa Recibir por USB en Forma Desktop para transmitir la orden"
                    reply = try await HybridTransfer.commandOverUSBWaitingForMac(command, pairingCode: destination.pairingCode)
                } else if let peer = destination.peer {
                    reply = try await HybridTransfer.command(command, to: peer, pairingCode: destination.pairingCode)
                } else { throw HybridTransfer.TransferError.failed("Selecciona tu Mac para enviar la orden.") }
                try reply.validate(command: command)
                remoteStatus = reply.status; statusObservedAt = Date(); statusIsFresh = true
                receipt?.lastStatus = reply.status; receipt?.statusObservedAt = statusObservedAt
                pendingCommand = nil; receipt?.pendingCommand = nil
                let messages = [
                    "uncertain": "No se puede confirmar la ejecución anterior. Revisa el estado antes de dar otra orden.",
                    "rejected": "La Mac rechazó la orden. Actualiza el estado antes de volver a intentarlo.",
                    "pending": "La orden está registrada; todavía no se confirma su aplicación.",
                    "accepted": "Orden recibida por tu Mac. El estado indica cuándo se aplica."
                ]
                commandNotice = reply.error ?? messages[reply.state] ?? "Confirmación recibida. Consulta el estado del trabajo."
                try receipt?.save(in: receiptDirectory)
            } catch {
                commandNotice = "No se recibió confirmación: \(error.localizedDescription). Reintentar consultará la misma orden, sin repetir sus efectos."
            }
        }
    }
    func discardPendingCommand() {
        guard !commanding else { return }
        pendingCommand = nil; receipt?.pendingCommand = nil; statusIsFresh = false
        do { try receipt?.save(in: receiptDirectory) }
        catch { commandNotice = error.localizedDescription; return }
        commandNotice = "Orden local cerrada. Consulta el estado del Mac antes de dar otra."
        refreshRemoteStatus()
    }

    func downloadResult(library: ScanStore) {
        guard !transferring, !commanding, !receivingResult, !savingResult, pendingCommand == nil,
              let jobID = remoteJobID, let destination else { return }
        monitorGeneration = UUID(); monitorTask?.cancel(); monitorTask = nil; checkingStatus = false
        resultLibrary = library; receivingResult = true; resultPaused = false; resultNotice = nil
        let token = UUID(); resultGeneration = token
        let downloadRoot = receiptDirectory.appendingPathComponent("results/\(jobID.uuidString)", isDirectory: true)
        resultTask = Task { [self] in
            let activity = resultActivityID ?? UUID(); resultActivityID = activity
            _ = await ProcessingActivityCoordinator.shared.begin(id: activity, title: "Recibiendo modelo del Mac",
                onAction: { [weak self] action in
                    if action == "pause" { self?.pauseResultDownload() }
                    if action == "resume" { self?.resumeResultDownload() }
                }, onExpiration: { [weak self] in
                    self?.resultNotice = "iOS terminó la autorización continua; la descarga parcial se conserva."
                })
            var complete = false
            defer {
                receivingResult = false; resultTask = nil
                if monitoringVisible, destination.transport.isWireless { refreshRemoteStatus() }
                if resultPaused {
                    ProcessingActivityCoordinator.shared.update(id: activity, progress: resultProgress,
                        status: "Descarga en pausa", phase: "paused", energyLabel: "Pausa manual")
                } else {
                    ProcessingActivityCoordinator.shared.finish(id: activity, success: complete,
                        status: complete ? "Resultado recibido" : "La descarga parcial se conserva")
                    resultActivityID = nil
                }
            }
            let progress: @Sendable (Double) -> Void = { [weak self] value in
                Task { @MainActor in
                    guard let self, self.resultGeneration == token, self.receivingResult, !self.resultPaused else { return }
                    self.resultProgress = value
                    ProcessingActivityCoordinator.shared.update(id: activity, progress: value,
                        status: "Recibiendo modelo del Mac", phase: "running", energyLabel: "Transferencia local")
                }
            }
            do {
                let bundle: HybridTransfer.DownloadedResult
                if destination.transport == .usb {
                    resultNotice = "Pulsa Recibir por USB en Forma Desktop para iniciar la descarga"
                    bundle = try await HybridTransfer.downloadResultOverUSBWaitingForMac(jobID: jobID,
                        pairingCode: destination.pairingCode, directory: downloadRoot, progress: progress)
                } else if let peer = destination.peer {
                    bundle = try await HybridTransfer.downloadResult(jobID: jobID, to: peer,
                        pairingCode: destination.pairingCode, directory: downloadRoot, progress: progress)
                } else { throw HybridTransfer.TransferError.failed("Selecciona tu Mac para descargar el modelo.") }
                try Task.checkCancellation()
                let root = receiptDirectory.standardizedFileURL.path + "/"
                guard bundle.directory.standardizedFileURL.path.hasPrefix(root) else {
                    throw HybridTransfer.TransferError.failed("La descarga no pertenece a su carpeta local.")
                }
                downloadedResult = bundle; resultProgress = 1; complete = true
                receipt?.downloadedResultDirectory = String(bundle.directory.standardizedFileURL.path.dropFirst(root.count))
                try receipt?.save(in: receiptDirectory)
                await saveDownloadedResult(in: library)
            } catch {
                resultNotice = Task.isCancelled ? (resultPaused ? "Descarga pausada; puedes continuar desde lo recibido" : "Descarga cancelada; parciales conservados") : error.localizedDescription
            }
        }
    }
    func pauseResultDownload() {
        guard receivingResult else { return }
        if savingResult { resultLibrary?.pauseSaving(); return }
        resultPaused = true; resultTask?.cancel()
    }
    func resumeResultDownload() {
        if savingResult {
            if let resultLibrary, resultLibrary.savingState.isPauseActive { resultLibrary.toggleSavingPause() }
            return
        }
        if let resultLibrary { downloadResult(library: resultLibrary) }
    }
    func cancelResultDownload() {
        resultPaused = false; resultTask?.cancel()
        if !receivingResult, let id = resultActivityID {
            ProcessingActivityCoordinator.shared.finish(id: id, success: false, status: "Descarga cancelada")
            resultActivityID = nil
        }
    }
    func saveDownloadedResult(in library: ScanStore) async {
        guard !savingResult, let bundle = downloadedResult else { return }
        savingResult = true; defer { savingResult = false }
        do {
            savedResult = try await resultImporter.save(bundle, sourceScanID: scan.id, library: library)
            resultNotice = "Modelo guardado en la biblioteca del iPhone"
        } catch { resultNotice = error.localizedDescription }
    }
    private func recoverDownloadedResult() {
        guard downloadedResult == nil, let relative = receipt?.downloadedResultDirectory,
              ScanStore.safeRelativePath(relative), relative.hasPrefix("results/") else { return }
        let folder = receiptDirectory.appendingPathComponent(relative)
        let owned = receiptDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(owned) else {
            resultNotice = "La carpeta recuperada no pertenece a los resultados de Forma."; return
        }
        let token = resultGeneration
        Task { [weak self] in
            do {
                let bundle = try await Task.detached(priority: .utility) { try HybridTransfer.loadDownloadedResult(from: folder) }.value
                guard let self, self.resultGeneration == token, !self.receivingResult,
                      bundle.descriptor.jobID == self.remoteJobID else { return }
                self.downloadedResult = bundle; self.resultProgress = 1
                self.resultNotice = "Descarga completa recuperada; lista para guardar"
            } catch { self?.resultNotice = "No se pudo recuperar la descarga: \(error.localizedDescription)" }
        }
    }
}

private struct HybridRemoteJobPanel: View {
    @EnvironmentObject private var library: ScanStore
    @ObservedObject var controller: HybridDeliveryController
    @State private var opened: ScanRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading) {
                ForEach(controller.availableRemoteCommands, id: \.rawValue) { action in
                    Button(title(action)) { controller.sendRemoteCommand(action) }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                }
            }
            if controller.commanding { ProgressView("Confirmando orden en Mac…") }
            if let notice = controller.commandNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if controller.pendingCommand != nil, !controller.commanding {
                Button("Consultar confirmación de la misma orden") { controller.retryRemoteCommand() }
                Button("Cerrar orden pendiente") { controller.discardPendingCommand() }.font(.caption)
            }
            if controller.receivingResult {
                ProgressView(value: controller.resultProgress).tint(FormaStyle.accent)
                if !controller.savingResult {
                    Button("Pausar descarga") { controller.pauseResultDownload() }
                    Button("Cancelar descarga") { controller.cancelResultDownload() }.font(.caption)
                }
            } else if controller.resultPaused {
                Button("Continuar descarga") { controller.downloadResult(library: library) }
            } else if controller.downloadedResult != nil {
                if let saved = controller.savedResult {
                    Button("Abrir modelo guardado") { opened = saved }.buttonStyle(.borderedProminent)
                } else {
                    Button("Guardar resultado descargado") { Task { await controller.saveDownloadedResult(in: library) } }
                        .disabled(controller.savingResult)
                }
            } else if controller.remoteStatus?.resultAvailable == true {
                Button("Traer resultado a este iPhone") { controller.downloadResult(library: library) }
                    .buttonStyle(.borderedProminent).tint(FormaStyle.accent)
            }
            if controller.savingResult { ProgressView("Guardando modelo…") }
            if let notice = controller.resultNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.sheet(item: $opened) { scan in NavigationStack { ScanDetailView(scan: scan).environmentObject(library) } }
    }
    private func title(_ action: HybridTransfer.RemoteJobCommand.Action) -> String {
        switch action {
        case .pause: return "Pausar Mac"
        case .resume: return "Reanudar Mac"
        case .cancel: return "Cancelar proceso"
        case .export: return "Exportar avance"
        }
    }
}
