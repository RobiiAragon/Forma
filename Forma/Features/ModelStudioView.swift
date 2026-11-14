import SwiftUI

/// Full-screen inspection of a saved model. Camera/marker resets reuse the
/// imported model, original textures and GPU resources.
struct ModelStudioView: View {
    let modelURL: URL
    let isGaussian: Bool
    let hasTexture: Bool
    let isDemo: Bool
    let captureDatasetURL: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var appearance: StudioAppearance
    @State private var textureMode: MeshPreviewTextureMode = .lightweight
    @State private var viewpoint: PreviewViewpoint = .perspective
    @State private var resetRequest = UUID()
    @State private var measuring = false
    @State private var measurementMode: StudioMeasurementMode = .distance
    @State private var distance: Float?
    @State private var area: Float?
    @State private var showPerformance = false
    @State private var performance: ViewerPerformanceSnapshot?
    @AppStorage("viewerAntialiasingSamples") private var antialiasingSamples = PreviewAntialiasing.sharp.rawValue

    init(modelURL: URL, isGaussian: Bool, hasTexture: Bool, isDemo: Bool = false, captureDatasetURL: URL? = nil) {
        self.modelURL = modelURL
        self.isGaussian = isGaussian
        self.hasTexture = hasTexture
        self.isDemo = isDemo
        self.captureDatasetURL = captureDatasetURL
        _appearance = State(initialValue: hasTexture ? .texture : .solid)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                // Switching layout keeps the renderer's identity and complete
                // imported textures alive during orientation changes.
                layout {
                    framedRenderer
                    if landscape {
                        ScrollView { controls }
                            .frame(width: min(330, geometry.size.width * 0.38))
                    } else {
                        controls
                    }
                }
            }
        }
        .background(FormaStyle.background.ignoresSafeArea())
        .foregroundStyle(FormaStyle.cream)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
    }

    private var framedRenderer: some View {
        renderer
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FormaStyle.panel)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Estudio 3D")
                    .font(.system(size: 26, weight: .regular, design: .serif))
                Text(isDemo ? "EJEMPLO · GEOMETRÍA GENERADA" : isGaussian ? "GAUSSIAN · COLOR FOTOGRÁFICO" : "MALLA · EXPLORAR Y MEDIR")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(FormaStyle.muted)
            }
            Spacer(minLength: 4)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(FormaStyle.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar estudio 3D")
            .accessibilityIdentifier("studioClose")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var renderer: some View {
        if isGaussian {
            GaussianPreview(modelURL: modelURL,resetRequest: resetRequest,
                            onPerformanceUpdate: showPerformance ? { performance = $0 } : nil,
                            captureDatasetURL: captureDatasetURL)
                .accessibilityHint("Arrastra para girar y pellizca para ampliar la reconstrucción Gaussian.")
        } else {
            MeasurementPreview(modelURL: modelURL, measuring: measuring,
                               wireframe: appearance == .wireframe, showTexture: appearance == .texture,
                               textureMode: textureMode, viewpoint: viewpoint, measureArea: measurementMode == .area,resetRequest: resetRequest,
                               antialiasing: PreviewAntialiasing(rawValue: antialiasingSamples) ?? .sharp,
                               onPerformanceUpdate: showPerformance ? { performance = $0 } : nil,
                               onAreaMeasurement: { area = $0 }) { distance = $0 }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if !isGaussian { appearanceControls }
            if !isGaussian, hasTexture, appearance == .texture { textureModeControls }

            HStack(spacing: 10) {
                controlButton("Recentrar", symbol: "scope", identifier: "studioRecenter") { resetRenderer() }
                if !isGaussian {
                    Menu {
                        ForEach(PreviewViewpoint.allCases) { option in
                            Button {
                                viewpoint = option
                                // Selecting the current preset must also reset a manually orbited camera.
                                resetRenderer()
                            } label: {
                                Label(option.title, systemImage: option.symbol)
                            }
                        }
                    } label: {
                        controlLabel(viewpoint.title, symbol: viewpoint.symbol)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Orientación: \(viewpoint.title)")
                    .accessibilityIdentifier("studioViewpoint")

                    Button {
                        measuring.toggle()
                        distance = nil
                        area = nil
                    } label: {
                        controlLabel("Medir", symbol: "ruler", selected: measuring)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(measuring ? "Desactivar medición" : "Activar medición")
                    .accessibilityValue(measuring ? "Activada" : "Desactivada")
                    .accessibilityAddTraits(measuring ? .isSelected : [])
                    .accessibilityIdentifier("studioMeasure")
                }
                controlButton("Rendimiento",symbol: "speedometer",identifier: "studioPerformance") { showPerformance.toggle() }
            }

            if showPerformance { performanceHUD }

            if showPerformance && !isGaussian {
                Menu {
                    ForEach(PreviewAntialiasing.allCases) { option in
                        Button(option.title) { antialiasingSamples = option.rawValue }
                    }
                } label: {
                    Label("Bordes: \((PreviewAntialiasing(rawValue: antialiasingSamples) ?? .sharp).title)", systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studioAntialiasing")
                Text("Más suavizado mejora los contornos y requiere más GPU. Las fotos y la geometría conservan su resolución. Se usa el nivel compatible con el dispositivo.")
                    .font(.system(size: 10)).foregroundStyle(FormaStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if measuring && !isGaussian { measurementControls }
            else {
                Text(isGaussian ? "Arrastra para girar · Pellizca para ampliar" : "Gira y amplía con los dedos · Las vistas siguen los ejes del modelo")
                    .font(.system(size: 11))
                    .foregroundStyle(FormaStyle.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var performanceHUD: some View {
        TimelineView(.periodic(from: .now,by: 0.5)) { _ in
            VStack(alignment: .leading,spacing: 5) {
                if let performance {
                    let cadence = performance.activeFramesPerSecond(at: CACurrentMediaTime())
                    Text("\(performance.source.title): \(cadence.map { String(format: "%.1f",$0) } ?? "—") FPS · \(performance.frameCount.formatted()) cuadros")
                        .accessibilityIdentifier("studioObservedFrames")
                    Text("Lectura \(milliseconds(performance.loadSeconds)) · Preparación \(milliseconds(performance.preparationSeconds)) · Primer cuadro \(milliseconds(performance.readySeconds))")
                    #if targetEnvironment(simulator)
                    Text(performance.source == .metalPresentation ? "El simulador no ofrece tiempos de presentación Metal. Se muestran tiempos de CPU." : cadence == nil ? "Sin cadencia activa. Gira el modelo para medir." : "Medición de este visor durante el movimiento.")
                        .foregroundStyle(FormaStyle.muted)
                    #else
                    Text(cadence == nil ? "Sin cadencia activa. Gira el modelo para medir." : "Medición de este visor durante el movimiento.")
                        .foregroundStyle(FormaStyle.muted)
                    #endif
                } else { Text("Esperando medidas del visor…") }
            }
            .font(.system(size: 10,design: .monospaced))
            .frame(maxWidth: .infinity,alignment: .leading)
            .padding(10)
            .background(FormaStyle.panel,in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("studioPerformanceHUD")
        }
    }

    private func milliseconds(_ seconds: TimeInterval?) -> String {
        seconds.map { String(format: "%.0f ms",$0*1000) } ?? "—"
    }

    private var appearanceControls: some View {
        HStack(spacing: 5) {
            ForEach(StudioAppearance.allCases) { option in
                Button { appearance = option } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol)
                        Text(option.title)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(appearance == option ? Color.black : FormaStyle.cream)
                    .background(appearance == option ? FormaStyle.accent : .clear,
                                in: RoundedRectangle(cornerRadius: 12))
                    .opacity(option == .texture && !hasTexture ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(option == .texture && !hasTexture)
                .accessibilityLabel(option == .texture && !hasTexture ? "Textura no disponible en este modelo" : option.title)
                .accessibilityAddTraits(appearance == option ? .isSelected : [])
                .accessibilityIdentifier("studioAppearance_\(option.rawValue)")
            }
        }
        .padding(5)
        .background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 17))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apariencia de la malla")
    }

    private var textureModeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Resolución de textura", selection: $textureMode) {
                ForEach(MeshPreviewTextureMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 40)
            .accessibilityIdentifier("studioTextureMode")
            Text(textureMode == .original
                 ? "Usa las imágenes completas del modelo."
                 : "Adapta las imágenes de pantalla para explorar con fluidez.")
                .font(.system(size: 10))
                .foregroundStyle(FormaStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var measurementControls: some View {
        VStack(spacing: 10) {
            Picker("Tipo de medición", selection: $measurementMode) {
                Text("Distancia").tag(StudioMeasurementMode.distance)
                Text("Área plana").tag(StudioMeasurementMode.area)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("studioMeasurementMode")
            .onChange(of: measurementMode) { _, _ in
                distance = nil
                area = nil
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(measurementText)
                        .font(.system(size: 21, weight: .medium, design: .monospaced))
                        .foregroundStyle(FormaStyle.accent)
                        .accessibilityIdentifier("studioMeasurementResult")
                    Text(measurementMode == .area ? "Marca esquinas en orden en un mismo plano." : "Toca dos puntos de la superficie.")
                        .font(.system(size: 11))
                        .foregroundStyle(FormaStyle.muted)
                }
                Spacer(minLength: 0)
                Button { resetRenderer() } label: {
                    Label("Rehacer", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 66, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rehacer medición y recentrar modelo")
                .accessibilityIdentifier("studioResetMeasurement")
            }
            Text("Estimación del modelo en metros. La precisión depende de la captura.")
                .font(.system(size: 10))
                .foregroundStyle(FormaStyle.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private var measurementText: String {
        if measurementMode == .area {
            return area.map { String(format: "%.3f m²", $0) } ?? "Área: — m²"
        }
        return distance.map { String(format: "%.3f m", $0) } ?? "Distancia: — m"
    }

    private func controlButton(_ title: String, symbol: String, identifier: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) { controlLabel(title, symbol: symbol) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
    }

    private func controlLabel(_ title: String, symbol: String, selected: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .foregroundStyle(selected ? FormaStyle.accent : FormaStyle.cream)
        .background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? FormaStyle.accent : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }

    private func resetRenderer() {
        distance = nil
        area = nil
        resetRequest = UUID()
    }
}

private enum StudioAppearance: String, CaseIterable, Identifiable {
    case texture, solid, wireframe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .texture: return "Textura"
        case .solid: return "Sólido"
        case .wireframe: return "Malla"
        }
    }
    var symbol: String {
        switch self {
        case .texture: return "photo"
        case .solid: return "circle.fill"
        case .wireframe: return "triangle"
        }
    }
}

private enum StudioMeasurementMode: Hashable { case distance, area }
