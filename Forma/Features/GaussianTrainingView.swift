import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct GaussianTrainingView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var trainer: GaussianTrainerService
    @State private var iterations = "3000"
    @State private var downscale = "1"
    @State private var selectingCheckpoint = false
    @State private var selectedCheckpoint: URL?
    @State private var copiedCheckpoint: URL?
    @State private var importError: String?
    let datasetURL: URL
    let initialCheckpointURL: URL?
    var onComplete: (CaptureResult) -> Void
    private let accent = Color(red: 1, green: 0.36, blue: 0.18)

    init(datasetURL: URL, initialCheckpointURL: URL? = nil, onComplete: @escaping (CaptureResult) -> Void) {
        self.datasetURL = datasetURL
        self.initialCheckpointURL = initialCheckpointURL
        self.onComplete = onComplete
        _trainer = StateObject(wrappedValue: GaussianJobRegistry.shared.trainer(datasetURL: datasetURL))
    }

    init(session: GaussianRecoverySession, onComplete: @escaping (CaptureResult) -> Void) {
        self.datasetURL = session.datasetURL
        self.initialCheckpointURL = session.checkpointURL
        self.onComplete = onComplete
        _trainer = StateObject(wrappedValue: GaussianJobRegistry.shared.trainer(session: session))
        _iterations = State(initialValue: String(session.targetIterations))
        _downscale = State(initialValue: String(session.downscale))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "sparkles.rectangle.stack").font(.system(size: 45, weight: .light)).foregroundStyle(accent)
                    Text("Gaussian Splatting").font(.largeTitle.bold())
                    Text("Entrena una representación fotométrica real de tu captura con la GPU Metal del iPhone.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Label(trainer.energyLabel, systemImage: "bolt")
                            .font(.subheadline).foregroundStyle(accent)
                        Text("Sin pausas por avisos de memoria o temperatura y sin esperas añadidas entre pasos. Guarda el avance periódicamente. Puedes pausar manualmente cuando quieras.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(trainer.executionNotice).font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Configuración de entrenamiento").font(.headline)
                        Menu("Aplicar ajuste rápido") {
                            ForEach(GaussianTrainingPreset.allCases) { preset in
                                Button(preset.title) {
                                    preset.apply(iterations: &iterations, downscale: &downscale,
                                                 preservingScale: trainer.checkpointURL != nil || selectedCheckpoint != nil)
                                }
                            }
                        }.accessibilityIdentifier("gaussianQualityPresets")
                        Text(GaussianTrainingPreset.explanation).font(.caption).foregroundStyle(.secondary)
                        if trainer.checkpointURL != nil || selectedCheckpoint != nil {
                            Text("Al continuar, los ajustes rápidos cambian solo los pasos y conservan el factor actual. Debe coincidir con el checkpoint.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Objetivo de iteraciones")
                            Spacer()
                            TextField("3000", text: $iterations).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 110)
                        }
                        HStack {
                            Text("Factor de reducción")
                            Spacer()
                            TextField("1", text: $downscale).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        }
                        Text("1 usa toda la resolución capturada. 2 reduce cada eje a la mitad. Más resolución necesita más memoria y tiempo. No se imponen cuotas de capturas ni de gaussianas.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(selectedCheckpoint == nil ? "Seleccionar checkpoint para continuar" : "Checkpoint seleccionado") { selectingCheckpoint = true }
                            .font(.subheadline).foregroundStyle(accent)
                    }
                    .padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                    .disabled(trainer.phase == .running || trainer.phase == .paused || trainer.phase == .exporting)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(trainer.message).font(.subheadline)
                        if trainer.iteration > 0 {
                            Text("\(trainer.iteration) pasos · \(trainer.splatCount.formatted()) gaussianas")
                                .font(.system(.title3, design: .monospaced))
                            Text(String(format: "%.0f ms por paso", trainer.milliseconds)).font(.caption).foregroundStyle(.secondary)
                        }
                        if trainer.phase == .running || trainer.phase == .exporting {
                            ProgressView(value: trainer.progressFraction).tint(accent)
                                .accessibilityIdentifier("gaussianTrainingProgress")
                            Text(trainer.progressFraction, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if trainer.pauseRequested {
                            Text("Pausando al terminar el bloque actual y guardar el checkpoint…")
                                .font(.caption).foregroundStyle(accent)
                        }
                        if trainer.memoryWarningCount > 0 {
                            Text("Avisos de memoria: \(trainer.memoryWarningCount). El entrenamiento continúa a la resolución elegida.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        actions
                    }
                    if let checkpoint = trainer.checkpointURL {
                        ShareLink(item: checkpoint) { Label("Compartir checkpoint", systemImage: "square.and.arrow.up") }
                            .font(.subheadline).foregroundStyle(accent)
                    }
                    Text("El visor PLY conserva armónicos esféricos de grado 3; SPLAT complementario usa color base de grado 0. Los splats no son una malla imprimible ni certifican exactitud métrica. iOS conserva el control de la memoria, la temperatura y la ejecución en segundo plano.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            .background(Color(red: 0.063, green: 0.067, blue: 0.075))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedCheckpoint = selectedCheckpoint ?? initialCheckpointURL
        }
        .onDisappear {
            if let copiedCheckpoint { try? FileManager.default.removeItem(at: copiedCheckpoint) }
        }
        .fileImporter(isPresented: $selectingCheckpoint, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let local = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-checkpoint-\(UUID().uuidString).ckpt")
                do {
                    try FileManager.default.copyItem(at: url, to: local)
                    if let copiedCheckpoint { try? FileManager.default.removeItem(at: copiedCheckpoint) }
                    copiedCheckpoint = local; selectedCheckpoint = local
                } catch { importError = "No se pudo importar: \(error.localizedDescription)" }
            } else if case .failure(let error) = result { importError = error.localizedDescription }
        }
        .alert("Checkpoint", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("Entendido") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    @ViewBuilder private var actions: some View {
        switch trainer.phase {
        case .settings, .failed, .ready:
            if let result = trainer.result, trainer.phase == .ready {
                Button { onComplete(result) } label: { Label("Guardar gaussianas", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(accent)
            }
            Button {
                let count = Int(iterations) ?? 0
                let reduction = Float(downscale.replacingOccurrences(of: ",", with: ".")) ?? 0
                trainer.start(datasetURL: datasetURL, iterations: count, downscale: reduction,
                              resumeURL: trainer.checkpointURL ?? selectedCheckpoint)
            } label: {
                Text(trainer.phase == .ready ? "Continuar desde checkpoint" : "Entrenar en este iPhone").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(accent)
        case .running:
            HStack {
                Button("Pausar y guardar estado") { trainer.pause() }.buttonStyle(.bordered).disabled(trainer.pauseRequested)
                Button("Terminar y exportar") { trainer.stopAndExport() }.buttonStyle(.borderedProminent).tint(accent).disabled(trainer.pauseRequested)
            }
            Button("Detener y conservar estado") { trainer.cancel() }.font(.caption)
        case .paused:
            HStack {
                Button("Continuar") { trainer.resume() }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(trainer.pauseRequested)
                Button("Exportar") { trainer.stopAndExport() }.buttonStyle(.bordered).disabled(trainer.pauseRequested)
            }
            Button("Detener y conservar estado") { trainer.cancel() }.font(.caption)
        case .exporting:
            EmptyView()
        }
    }
}
