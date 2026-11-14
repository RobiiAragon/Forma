import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedMode: ScanMode = .lidar
    @State private var capture: ScanMode?
    @State private var selectedScan: ScanRecord?
    @State private var tab = 0
    @State private var search = ""
    @State private var discardPending = false
    @State private var recoverySessions: [GaussianRecoverySession] = []
    @State private var resumeSession: GaussianRecoverySession?
    @State private var choosingExecution = false
    @State private var beginAfterSetup = false
    @State private var hybridDestination: HybridCaptureDestination?
    @State private var hybridDeliveryScan: ScanRecord?
    private var filtered: [ScanRecord] {
        search.isEmpty ? store.scans : store.scans.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.mode.title.localizedCaseInsensitiveContains(search) }
    }
    private var shouldRefreshRecovery: Bool {
        scenePhase == .active && tab == 0 && capture == nil && resumeSession == nil &&
        selectedScan == nil && !choosingExecution && hybridDeliveryScan == nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FormaStyle.background.ignoresSafeArea()
                Group {
                    if tab == 0 { library }
                    else if tab == 1 { GuideView() }
                    else { DeviceInspectorView() }
                }
                if store.isSaving {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 15) {
                        ProgressView().tint(FormaStyle.accent)
                        Text(store.savingState.phase == .paused ? "Trabajo en pausa" : store.savingState.phase == .cancelled ? "Cancelando…" : store.isRecoveringPending ? "Recuperando guardado" : "Guardando tu captura")
                            .font(.headline).accessibilityIdentifier("savingState")
                        Text(store.savingStage).font(.caption).foregroundStyle(.secondary)
                        if store.savingTotalBytes > 0 {
                            ProgressView(value: min(1, Double(store.savingCompletedBytes) / Double(store.savingTotalBytes)))
                                .tint(FormaStyle.accent)
                            Text(ByteCountFormatter.string(fromByteCount: store.savingCompletedBytes, countStyle: .file)
                                 + " de " + ByteCountFormatter.string(fromByteCount: store.savingTotalBytes, countStyle: .file))
                                .font(.caption.monospacedDigit()).accessibilityIdentifier("savingBytes")
                        }
                        if store.savingState.phase == .pauseRequested {
                            Text("Solicitando pausa al terminar el bloque actual…").font(.caption)
                        } else if store.savingState.phase == .paused {
                            Text("Puedes continuar desde el mismo punto. Tus fuentes se conservan.").font(.caption)
                        }
                        Button { store.toggleSavingPause() } label: {
                            Label(store.savingState.isPauseActive ? "Continuar guardado" : "Pausar guardado",
                                  systemImage: store.savingState.isPauseActive ? "play.fill" : "pause.fill")
                        }.buttonStyle(.borderedProminent).tint(FormaStyle.accent)
                            .disabled(store.savingState.phase == .cancelled).accessibilityIdentifier("pauseSaving")
                        Button("Cancelar y conservar captura pendiente") { store.cancelSaving() }
                            .font(.caption).disabled(store.savingState.phase == .cancelled)
                            .accessibilityIdentifier("cancelSaving")
                    }.padding(30).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $capture) { mode in
                Group {
                    switch mode {
                    case .lidar: LiDARCaptureView(onComplete: save, offloadProcessing: hybridDestination != nil)
                    case .object: ObjectScanView(onComplete: save)
                    case .room: RoomScanView(onComplete: save)
                    }
                }.preferredColorScheme(.dark)
            }
            .fullScreenCover(item: $resumeSession) { session in
                GaussianTrainingView(session: session) { result in
                    resumeSession = nil
                    save(result)
                }
            }
            .sheet(isPresented: $choosingExecution, onDismiss: {
                if beginAfterSetup { beginAfterSetup = false; capture = .lidar }
            }) {
                CaptureSetupView(onStandalone: {
                    hybridDestination = nil; beginAfterSetup = true; choosingExecution = false
                }, onHybrid: { destination in
                    hybridDestination = destination; beginAfterSetup = true; choosingExecution = false
                })
            }
            .sheet(item: $hybridDeliveryScan) { scan in
                HybridDeliveryView(scan: scan, directory: store.directory(for: scan), initialDestination: hybridDestination)
            }
            .task(id: shouldRefreshRecovery) {
                guard shouldRefreshRecovery else { return }
                while !Task.isCancelled {
                    let worker = Task.detached(priority: .utility) { GaussianRecovery.sessions() }
                    let sessions = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }
                    if recoverySessions != sessions { recoverySessions = sessions }
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                }
            }
            .navigationDestination(item: $selectedScan) { scan in ScanDetailView(scan: scan) }
            .alert("No se pudo completar", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                if let pending = store.pendingCapture {
                    Button("Reintentar guardado") { store.error = nil; save(pending) }
                }
                Button("Entendido", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
            .confirmationDialog("¿Descartar la captura que no se pudo guardar? Se eliminarán sus datos temporales.", isPresented: $discardPending, titleVisibility: .visible) {
                Button("Descartar captura pendiente", role: .destructive) { store.discardPendingCapture() }
            }
        }
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack {
                    HStack(spacing: 9) {
                        Image(systemName: "viewfinder").font(.system(size: 25, weight: .light)).foregroundStyle(FormaStyle.accent)
                        Text("FORMA").font(.system(size: 23, weight: .bold, design: .rounded)).tracking(4)
                    }.accessibilityElement(children: .combine)
                    Spacer()
                    Text("ESTUDIO 3D").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.5).foregroundStyle(FormaStyle.muted)
                }.padding(.top, 12)
                hero
                VStack(alignment: .leading, spacing: 13) {
                    Eyebrow(text: "01 / Elige cómo capturar")
                    HStack(spacing: 9) {
                        ForEach(ScanMode.allCases) { mode in modeCard(mode) }
                    }
                    PrimaryButton(title: "Capturar \(selectedMode.title.lowercased())") {
                        if selectedMode == .lidar { choosingExecution = true }
                        else { hybridDestination = nil; capture = selectedMode }
                    }
                        .accessibilityIdentifier("startCapture")
                        .disabled(store.pendingCapture != nil || store.isSaving)
                        .opacity(store.pendingCapture == nil ? 1 : 0.45)
                    Button { selectedMode = .lidar; capture = .lidar } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles").font(.system(size: 23, weight: .light)).foregroundStyle(FormaStyle.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Crear Gaussian 3D").font(.system(size: 14, weight: .semibold)).foregroundStyle(FormaStyle.cream)
                                Text("Captura fuentes LiDAR + fotos y entrena desde el resultado.")
                                    .font(.system(size: 10)).foregroundStyle(FormaStyle.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").foregroundStyle(FormaStyle.accent)
                        }.padding(16).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain).disabled(store.pendingCapture != nil || store.isSaving)
                        .accessibilityIdentifier("newGaussian")
                }
                if !recoverySessions.isEmpty {
                    VStack(alignment: .leading, spacing: 13) {
                        Eyebrow(text: "Entrenamientos guardados / continuar")
                        ForEach(recoverySessions) { session in
                            Button { resumeSession = session } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").foregroundStyle(FormaStyle.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.state == "exported" ? "Gaussian listo para guardar" : "Continuar Gaussian 3D")
                                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(FormaStyle.cream)
                                        Text("\(session.step.formatted()) pasos · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(FormaStyle.muted)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").foregroundStyle(FormaStyle.muted)
                                }.padding(16).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 15))
                            }.buttonStyle(.plain).disabled(store.pendingCapture != nil || store.isSaving)
                                .accessibilityIdentifier("resumeGaussian")
                        }
                    }
                }
                HStack {
                    Text("Tu biblioteca").font(.system(size: 23, weight: .medium, design: .serif))
                    Spacer()
                    Text(String(format: "%02d", store.scans.count)).font(.system(size: 14, design: .monospaced)).foregroundStyle(FormaStyle.muted)
                }
                if store.scans.isEmpty {
                    emptyLibrary
                } else {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(FormaStyle.muted)
                        TextField("Buscar capturas", text: $search).font(.subheadline).accessibilityIdentifier("scanSearch")
                    }.padding(14).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 13))
                ForEach(filtered) { scan in
                        Button { selectedScan = scan } label: { ScanRow(scan: scan) }.buttonStyle(.plain)
                            .accessibilityIdentifier(scan.isDemo ? "demoScan" : "scan-\(scan.id)")
                    }
                    if filtered.isEmpty { Text("No hay capturas que coincidan.").foregroundStyle(.secondary).font(.subheadline) }
                }
                if let pending = store.pendingCapture, !store.isSaving {
                    Button {
                        store.error = nil
                        save(pending)
                    } label: {
                        Label("Captura pendiente · reintentar guardado", systemImage: "arrow.clockwise")
                            .font(.system(size: 13)).foregroundStyle(FormaStyle.accent)
                            .frame(maxWidth: .infinity).padding(16)
                            .background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 15))
                    }.accessibilityIdentifier("retrySave")
                    Button("Descartar captura pendiente", role: .destructive) { discardPending = true }
                        .font(.system(size: 12)).frame(maxWidth: .infinity)
                }
                if store.pendingSaveCount > 0, !store.isSaving {
                    Button {
                        Task { await store.recoverPendingSaves() }
                    } label: {
                        Label("Recuperar guardados pendientes (\(store.pendingSaveCount))", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 13)).foregroundStyle(FormaStyle.accent)
                    }.accessibilityIdentifier("recoverPendingSaves")
                }
                HStack(spacing: 7) {
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                    Text("LOCAL POR NATURALEZA. TUYO POR COMPLETO.")
                        .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1)
                }.foregroundStyle(FormaStyle.muted).frame(maxWidth: .infinity).padding(.bottom, 14)
            }.padding(.horizontal, 24)
        }.scrollIndicators(.hidden)
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 24).fill(FormaStyle.panel)
            GeometryReader { proxy in
                MeshPreview(mesh: DemoGeometry.sculpture(), decorative: true)
                    .frame(width: proxy.size.width*0.65, height: 235)
                    .position(x: proxy.size.width*0.84, y: 123)
                    .accessibilityHidden(true)
            }.clipped()
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield").font(.system(size: 9))
                    Text("SIN NUBE · SIN CUOTAS").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.7)
                }.foregroundStyle(FormaStyle.muted)
                VStack(alignment: .leading, spacing: -3) {
                    Text("Dale forma")
                    Text("a lo real.").foregroundStyle(FormaStyle.accent)
                }.font(.system(size: 39, weight: .regular, design: .serif)).tracking(-1.6).foregroundStyle(FormaStyle.cream)
                Text("Tu mundo, en tres dimensiones.")
                    .font(.system(size: 11)).foregroundStyle(FormaStyle.muted)
            }.padding(22)
        }.frame(height: 226).clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func modeCard(_ mode: ScanMode) -> some View {
        let active = mode == selectedMode
        return Button { selectedMode = mode } label: {
            VStack(alignment: .leading, spacing: 15) {
                Image(systemName: mode.symbol).font(.system(size: 22, weight: .light))
                    .foregroundStyle(active ? FormaStyle.accent : FormaStyle.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(FormaStyle.cream)
                    Text(mode == .lidar ? "LiDAR + textura" : mode == .object ? "Foto → 3D" : "RoomPlan")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(FormaStyle.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(active ? FormaStyle.accent.opacity(0.08) : FormaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(active ? FormaStyle.accent.opacity(0.6) : .white.opacity(0.06), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(mode.title): \(mode.subtitle)")
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier("mode-\(mode.rawValue)")
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 25, weight: .ultraLight)).foregroundStyle(FormaStyle.muted)
            Text("Lo que descubras, queda aquí.").font(.system(size: 14)).foregroundStyle(FormaStyle.cream)
            Text("Captura tu primer espacio u objeto.").font(.system(size: 12)).foregroundStyle(FormaStyle.muted)
            Button {
                Task {
                    let result = CaptureResult(mesh: DemoGeometry.sculpture(), mode: .lidar, duration: 0,
                        isDemo: true, note: "Ejemplo matemático generado. No es un escaneo ni una prueba de precisión. Malla sin textura. Unidades: metros.")
                    if let scan = await store.save(result) { selectedScan = scan }
                }
            } label: {
                HStack(spacing: 6) { Text("Explorar un ejemplo"); Image(systemName: "arrow.right") }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(FormaStyle.accent)
            }.accessibilityIdentifier("exploreDemo").padding(.top, 5)
                .disabled(store.pendingCapture != nil || store.isSaving)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
            .background(RoundedRectangle(cornerRadius: 18).stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 5])).foregroundStyle(.white.opacity(0.12)))
    }

    private var bottomBar: some View {
        HStack {
            tabButton(0, "square.grid.2x2", "Biblioteca")
            Spacer()
            tabButton(1, "book.closed", "Guía")
            Spacer()
            tabButton(2, "cpu", "Dispositivo")
        }.padding(.horizontal, 38).padding(.top, 15).padding(.bottom, 10)
            .background(FormaStyle.background.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
    }

    private func tabButton(_ number: Int, _ icon: String, _ title: String) -> some View {
        Button { tab = number } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 19, weight: .light))
                Text(title).font(.system(size: 9, weight: .medium))
            }.foregroundStyle(tab == number ? FormaStyle.accent : FormaStyle.muted)
        }.accessibilityIdentifier("tab-\(number)")
    }

    private func save(_ result: CaptureResult) {
        capture = nil
        Task {
            if let scan = await store.save(result) {
                selectedScan = scan
                if (scan.statistics?["remoteProcessingPending"] ?? 0) > 0 { hybridDeliveryScan = scan }
            }
        }
    }
}

private struct ScanRow: View {
    var scan: ScanRecord
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(FormaStyle.accent.opacity(0.09))
                Image(systemName: scan.isDemo ? "torus" : scan.gaussianModelFile != nil ? "sparkles" : scan.mode.symbol)
                    .font(.system(size: 28, weight: .ultraLight)).foregroundStyle(FormaStyle.accent)
            }.frame(width: 65, height: 65)
            VStack(alignment: .leading, spacing: 6) {
                Text(scan.name).font(.system(size: 14, weight: .medium)).lineLimit(2).foregroundStyle(FormaStyle.cream)
                Text(scan.isDemo ? "EJEMPLO · GEOMETRÍA GENERADA" : "\(scan.mode.title.uppercased()) · \(scan.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 8, design: .monospaced)).tracking(0.5).foregroundStyle(FormaStyle.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundStyle(FormaStyle.muted)
        }.padding(12).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

extension ScanRecord: Hashable {
    static func == (lhs: ScanRecord, rhs: ScanRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
