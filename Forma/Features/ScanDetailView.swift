import SwiftUI

struct ScanDetailView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    var scan: ScanRecord
    @State private var wireframe = false
    @State private var showingShare = false
    @State private var confirmDelete = false
    @State private var integrity: String?
    @State private var verifying = false
    @State private var measuring = false
    @State private var measuredDistance: Float?
    @State private var showTexture = true
    @State private var expandedPreview = false
    @State private var training = false
    @State private var isDetailVisible = false
    @State private var generatedScan: ScanRecord?
    @State private var sharingSources: [URL] = []
    @State private var preparingSources = false
    @State private var localError: String?
    @StateObject private var refinement = ScanRefinementViewModel()
    @State private var sendingToMac = false
    @State private var gaussianOnMac = false
    @State private var localAI = false
    @State private var aiSaved: ScanRecord?
    @State private var sendAfterAI = false

    var body: some View {
        ZStack {
            FormaStyle.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "arrow.left").font(.system(size: 20)).frame(width: 44, height: 44)
                                .background(FormaStyle.panel, in: Circle())
                        }.accessibilityLabel("Volver a biblioteca").accessibilityIdentifier("detailBack")
                        Spacer()
                        Eyebrow(text: scan.isDemo ? "Ejemplo interactivo" : scan.statistics?["localAITextureRestoration"] == 1 ? "Textura restaurada · IA local" : scan.gaussianModelFile != nil ? "Gaussian Splatting · Metal" : scan.mode == .lidar && (scan.statistics?["texturedFaces"] ?? 0) == 0 ? "Malla LiDAR" : scan.mode.subtitle)
                        Spacer()
                        Button { confirmDelete = true } label: { Image(systemName: "trash").foregroundStyle(FormaStyle.muted).frame(width: 44, height: 44) }
                            .accessibilityLabel("Eliminar captura").accessibilityIdentifier("deleteScan").disabled(refinement.isRunning)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(scan.name).font(.system(size: 30, weight: .regular, design: .serif)).foregroundStyle(FormaStyle.cream)
                        Text(scan.createdAt.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(FormaStyle.muted)
                    }
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 24).fill(FormaStyle.panel)
                        if refinement.isRunning {
                            VStack(spacing: 12) {
                                ProgressView(value: refinement.progress).tint(FormaStyle.accent)
                                Text(refinement.status).font(.caption).foregroundStyle(FormaStyle.cream)
                            }.padding(30)
                        } else if !isDetailVisible || expandedPreview || localAI || training {
                            // NavigationStack retains ancestor screens. Drop their
                            // renderers too, so a descendant can train without
                            // retaining an earlier model's textures in memory.
                            Color.clear
                        } else if let url = store.gaussianURL(for: scan) {
                            GaussianPreview(modelURL: url, captureDatasetURL: store.datasetURL(for: scan)).clipShape(RoundedRectangle(cornerRadius: 24))
                        } else if let url = store.modelURL(for: scan) {
                            MeasurementPreview(modelURL: url, measuring: measuring, wireframe: wireframe, showTexture: showTexture) { measuredDistance = $0 }
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "hand.draw")
                            Text(measuring ? "Toca dos puntos de la superficie" : "Gira · amplía · explora")
                        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(FormaStyle.muted)
                            .padding(12).background(.black.opacity(0.5), in: Capsule()).padding(.bottom, 15)
                    }.frame(height: 330).accessibilityIdentifier("modelPreview")
                        .overlay(alignment: .topTrailing) {
                            Button { expandedPreview = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(FormaStyle.cream)
                                    .frame(width: 44, height: 44).background(.black.opacity(0.7), in: Circle())
                            }.padding(12).accessibilityLabel("Abrir visor a pantalla completa")
                                .accessibilityIdentifier("expandModel")
                                .disabled(refinement.isRunning)
                        }
                    if scan.gaussianModelFile == nil {
                        if (scan.statistics?["texturedFaces"] ?? 0) > 0 || scan.mode == .object {
                            Toggle(isOn: $showTexture) {
                                Label("Mostrar textura fotográfica", systemImage: "photo.on.rectangle.angled").font(.subheadline)
                            }.tint(FormaStyle.accent).accessibilityIdentifier("textureToggle")
                        }
                        Toggle(isOn: $wireframe) {
                        Label("Ver estructura de malla", systemImage: "triangle").font(.subheadline)
                    }.tint(FormaStyle.accent).accessibilityIdentifier("wireframeToggle")
                    Toggle(isOn: $measuring) {
                        Label("Medir entre dos puntos", systemImage: "ruler").font(.subheadline)
                    }.tint(FormaStyle.accent).accessibilityIdentifier("measureToggle")
                    }
                    if measuring {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(measuredDistance.map { String(format: "%.3f m", $0) } ?? "Selecciona dos superficies")
                                .font(.system(size: 23, weight: .medium, design: .monospaced)).foregroundStyle(FormaStyle.accent)
                                .accessibilityIdentifier("measurementResult")
                            Text("Distancia estimada sobre el modelo. Un tercer toque empieza otra medida. Los decimales no indican precisión certificada.")
                                .font(.system(size: 11)).foregroundStyle(FormaStyle.muted)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 15))
                    }
                    HStack(spacing: 10) {
                        metric(scan.gaussianModelFile != nil ? Int(scan.statistics?["splats"] ?? 0).formatted() : scan.faceCount > 0 ? scan.faceCount.formatted() : "USDZ",
                            scan.gaussianModelFile != nil ? "GAUSSIANAS" : scan.faceCount > 0 ? "TRIÁNGULOS" : "MODELO 3D")
                        metric(scan.gaussianModelFile != nil ? Int(scan.statistics?["steps"] ?? 0).formatted() : scan.vertexCount > 0 ? scan.vertexCount.formatted() : scan.mode.title,
                            scan.gaussianModelFile != nil ? "PASOS REALES" : scan.vertexCount > 0 ? "VÉRTICES" : "CAPTURA")
                        metric("Local", "PROCESAMIENTO")
                    }
                    if !scan.note.isEmpty {
                        Text(scan.note).font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(4)
                    }
                    if scan.mode == .lidar, !scan.isDemo, scan.gaussianModelFile == nil, store.datasetURL(for: scan) == nil {
                        Text(scan.sourceScanID == nil
                            ? "Esta captura se guardó sin fotografías calibradas. Haz una nueva captura en Espacios para obtener textura fotográfica y entrenar gaussianas."
                            : "Esta versión no duplica las fotografías calibradas. Consulta su captura original para acceder a las fuentes disponibles.")
                            .font(.system(size: 12)).foregroundStyle(FormaStyle.cream).lineSpacing(4)
                            .padding(16).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let data = scan.statistics, let coverage = data["textureCoverage"] {
                        VStack(alignment: .leading, spacing: 9) {
                            Eyebrow(text: "Textura fotográfica")
                            Text("\(Int((coverage*100).rounded())) % de caras con observación válida")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(FormaStyle.cream)
                            ProgressView(value: coverage).tint(FormaStyle.accent)
                            Text("\(Int(data["keyframes"] ?? 0)) fotografías · hasta \(Int(data["maxImageWidth"] ?? 0)) × \(Int(data["maxImageHeight"] ?? 0)) px")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(FormaStyle.muted)
                            if let materials = data["atlasMaterialCount"], let sources = data["sourceTextureCount"], sources > 0 {
                                Text("\(Int(sources)) fotos de textura · \(Int(materials)) texturas de visualización · píxeles nativos")
                                    .font(.system(size: 11)).foregroundStyle(FormaStyle.muted)
                            }
                            if let adjusted = data["adjustedPhotoCount"], adjusted > 0 {
                                Text("Exposición ajustada en \(Int(adjusted)) fotos con comprobación en muestras reservadas.")
                                    .font(.system(size: 11)).foregroundStyle(FormaStyle.muted)
                            }
                            Text("Indica observación de las caras de esta malla, no el porcentaje del mundo capturado ni su precisión.")
                                .font(.system(size: 10)).foregroundStyle(FormaStyle.muted)
                        }.padding(18).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if scan.gaussianModelFile == nil, scan.modelFile.map({ ["obj", "usdz"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) == true,
                       (scan.statistics?["texturedFaces"] ?? 0) > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "IA local / sin conexión")
                            Text("Restaurar la textura").font(.system(size: 23, design: .serif))
                            Text("Procesa una copia con Real-ESRGAN dentro de Forma. Conserva la malla y las fotos; puedes comparar la apariencia con el original.")
                                .font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(4)
                            PrimaryButton(title: "Restaurar textura con IA", symbol: "sparkles") { localAI = true }
                                .disabled(refinement.isRunning || store.isSaving || store.pendingCapture != nil)
                                .accessibilityIdentifier("restoreLocalAITexture")
                        }.padding(18).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if SavedScanRefinement.canRefine(scan: scan, directory: store.directory(for: scan)) {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "Mejoras locales")
                            Text(store.datasetURL(for: scan) == nil ? "Refinar continuidad de la malla" : "Reprocesar texturas y malla")
                                .font(.system(size: 23, design: .serif))
                            Text("Crea una versión nueva y conserva esta captura. Une bordes compatibles y permite corregir ruido en regiones planas; cuando existen fotos calibradas, vuelve a proyectarlas sobre la geometría resultante.")
                                .font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(4)
                            LiDARQualityControls(settings: $refinement.quality, includeCaptureSettings: false).disabled(refinement.isRunning)
                            if let metrics = scan.statistics, metrics["planarCorrectionRequested"] == 1 {
                                Text("Planos aceptados: \(Int(metrics["planarAcceptedRegions"] ?? 0)) · vértices corregidos: \(Int(metrics["planarMovedVertices"] ?? 0)). Desplazamiento máximo: \((metrics["planarMaxDisplacementMeters"] ?? 0) * 1000, specifier: "%.2f") mm.")
                                    .font(.caption).foregroundStyle(FormaStyle.muted)
                            }
                            if refinement.isRunning {
                                ProgressView(value: refinement.progress).tint(FormaStyle.accent)
                                Text(refinement.status).font(.caption)
                                Button("Cancelar procesamiento") { refinement.cancel() }
                                    .font(.system(size: 12)).accessibilityIdentifier("cancelRefinement")
                            } else {
                                PrimaryButton(title: "Reprocesar con mejoras", symbol: "slider.horizontal.3") { refineSavedCapture() }
                                    .disabled(store.isSaving || store.pendingCapture != nil)
                                    .accessibilityIdentifier("refineSavedScan")
                            }
                        }.padding(18).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let sourceID = scan.sourceScanID, let original = store.scans.first(where: { $0.id == sourceID }) {
                        Button { generatedScan = original } label: {
                            Label("Abrir captura original", systemImage: "square.stack.3d.up")
                                .font(.system(size: 13)).frame(maxWidth: .infinity)
                        }.accessibilityIdentifier("openOriginalScan")
                    }
                    if store.datasetURL(for: scan) != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "Forma Desktop / procesamiento híbrido")
                            Text("Procesar las fuentes en Mac").font(.system(size: 23, design: .serif))
                            Text("Envía las fotografías, la profundidad y la malla original para realizar el trabajo pesado en tu computadora. La captura del iPhone se conserva.")
                                .font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(4)
                            PrimaryButton(title: "Enviar a Forma Desktop", symbol: "desktopcomputer") { sendingToMac = true }
                                .disabled(store.isSaving || refinement.isRunning).accessibilityIdentifier("sendToMac")
                        }.padding(18).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 12) {
                            Eyebrow(text: "Reconstrucción fotométrica local")
                            Text("Lleva la captura más lejos.").font(.system(size: 24, design: .serif))
                            Text("Optimiza gaussianas 3D en la GPU del iPhone usando las fotos y cámaras calibradas que ya guardaste. Puedes elegir resolución e iteraciones y continuar desde un checkpoint.")
                                .font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(4)
                            PrimaryButton(title: scan.gaussianModelFile == nil ? "Entrenar Gaussian Splatting" : "Continuar entrenamiento", symbol: "sparkles") { training = true }
                                .disabled(store.pendingCapture != nil || store.isSaving || refinement.isRunning)
                                .accessibilityIdentifier("trainGaussian")
                            Button { gaussianOnMac = true } label: {
                                Label("Entrenar Gaussian en Mac", systemImage: "desktopcomputer")
                                    .font(.system(size: 13)).frame(maxWidth: .infinity)
                            }.disabled(store.isSaving || refinement.isRunning).accessibilityIdentifier("trainGaussianOnMac")
                            Button {
                                preparingSources = true
                                Task {
                                    do { sharingSources = [try await store.exportDataset(scan)] }
                                    catch { localError = error.localizedDescription }
                                    preparingSources = false
                                }
                            } label: {
                                Label(preparingSources ? "Preparando originales…" : "Exportar fotos, profundidad y cámaras", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 12)).frame(maxWidth: .infinity)
                            }.disabled(preparingSources).accessibilityIdentifier("exportSources")
                            if preparingSources || store.isSaving { ProgressView().tint(FormaStyle.accent) }
                        }.padding(18).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 18))
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "Archivos / sin restricciones de exportación")
                        ForEach(scan.exports.filter { $0 != "captura.json" }, id: \.self) { name in
                            ShareLink(item: store.directory(for: scan).appendingPathComponent(name)) {
                                HStack {
                                    Image(systemName: "doc").foregroundStyle(FormaStyle.accent)
                                    Text(name).font(.system(size: 12, design: .monospaced)).foregroundStyle(FormaStyle.cream).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "square.and.arrow.up").foregroundStyle(FormaStyle.muted)
                                }.padding(14).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    PrimaryButton(title: "Compartir todos los archivos", symbol: "square.and.arrow.up") { showingShare = true }
                        .accessibilityIdentifier("shareAll")
                    Button {
                        verifying = true
                        Task {
                            do { integrity = try await store.verify(scan) ? "Archivos íntegros: las huellas SHA-256 coinciden." : "Hay archivos modificados o ausentes." }
                            catch { integrity = "No se pudo comprobar: \(error.localizedDescription)" }
                            verifying = false
                        }
                    } label: {
                        HStack {
                            if verifying { ProgressView() } else { Image(systemName: "checkmark.shield") }
                            Text(verifying ? "Verificando…" : "Verificar integridad")
                        }.font(.system(size: 13)).frame(maxWidth: .infinity)
                    }.disabled(verifying).accessibilityIdentifier("verifyIntegrity")
                    if let integrity { Text(integrity).font(.caption).foregroundStyle(FormaStyle.cream).accessibilityIdentifier("integrityResult") }
                    Text("Las medidas son estimaciones. El informe y las huellas de integridad no certifican precisión ni cadena de custodia. STL no guarda unidades; los archivos de Forma usan metros.")
                        .font(.system(size: 10)).foregroundStyle(FormaStyle.muted).lineSpacing(4)
                }.padding(24)
            }.scrollIndicators(.hidden)
        }.toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingShare) { ActivitySheet(items: store.files(for: scan)) }
            .sheet(isPresented: $localAI, onDismiss: {
                if let saved = aiSaved { generatedScan = saved; aiSaved = nil }
                else if sendAfterAI { sendAfterAI = false; sendingToMac = true }
            }) {
                LocalAITextureView(record: scan, library: store, onSaved: { aiSaved = $0 },
                    onUseMac: store.datasetURL(for: scan) == nil ? nil : { sendAfterAI = true; localAI = false })
            }
            .sheet(isPresented: $sendingToMac) {
                let source = store.datasetSource(for: scan) ?? scan
                HybridDeliveryView(scan: source, directory: store.directory(for: source), initialDestination: nil)
            }
            .sheet(isPresented: $gaussianOnMac) {
                let source = store.datasetSource(for: scan) ?? scan
                HybridGaussianSetupView(scan: source, directory: store.directory(for: source))
            }
            .sheet(isPresented: Binding(get: { !sharingSources.isEmpty }, set: { if !$0 { sharingSources = [] } })) { ActivitySheet(items: sharingSources) }
            .fullScreenCover(isPresented: $expandedPreview) {
                if let url = store.gaussianURL(for: scan) ?? store.modelURL(for: scan) {
                    ModelStudioView(modelURL: url, isGaussian: scan.gaussianModelFile != nil,
                                    hasTexture: (scan.statistics?["texturedFaces"] ?? 0) > 0 || scan.mode == .object,
                                    isDemo: scan.isDemo, captureDatasetURL: store.datasetURL(for: scan))
                }
            }
            .fullScreenCover(isPresented: $training) {
                if let dataset = store.datasetURL(for: scan) {
                    GaussianTrainingView(datasetURL: dataset, initialCheckpointURL: scan.gaussianModelFile == nil ? nil : store.directory(for: scan).appendingPathComponent("modelo/entrenamiento.ckpt")) { result in
                        training = false
                        Task { if let saved = await store.save(result) { generatedScan = saved } }
                    }
                }
            }
            .navigationDestination(item: $generatedScan) { ScanDetailView(scan: $0) }
            .onAppear { isDetailVisible = true }
            .onChange(of: refinement.saved?.id) { _, _ in
                if let saved = refinement.saved { generatedScan = saved }
            }
            .onChange(of: refinement.error) { _, error in
                if let error { localError = error }
            }
            .onDisappear {
                isDetailVisible = false
                refinement.cancel()
            }
            .alert("No se pudo completar la operación", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
                Button("Entendido", role: .cancel) { localError = nil }
            } message: { Text(localError ?? "") }
            .confirmationDialog("¿Eliminar esta captura y sus archivos locales?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Eliminar captura", role: .destructive) { store.delete(scan); if store.error == nil { dismiss() } }
            }
    }

    private func refineSavedCapture() {
        refinement.start(scan: scan, store: store)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value).font(.system(size: 16, weight: .medium)).lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.system(size: 7, design: .monospaced)).tracking(0.6).foregroundStyle(FormaStyle.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 13))
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    var items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
