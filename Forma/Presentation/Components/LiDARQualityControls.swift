import SwiftUI

struct LiDARQualityControls: View {
    @Binding var settings: LiDARQualitySettings
    var includeCaptureSettings = true
    var captureSettingsLocked = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var toleranceWidth = 92.0
    @FocusState private var toleranceFocused: Bool

    var body: some View {
        DisclosureGroup("Geometría y detalle") {
            VStack(alignment: .leading, spacing: 10) {
                if includeCaptureSettings {
                    Toggle("Reconocer paredes y suelos al capturar", isOn: $settings.nativePlaneAssistance)
                        .disabled(captureSettingsLocked)
                        .frame(minHeight: minimumControlHeight)
                    Text("ARKit puede aplanar las superficies que reconoce. Desactívalo para conservar relieves reales.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Fotografías más solapadas", isOn: $settings.densePhotographs)
                        .disabled(captureSettingsLocked)
                        .frame(minHeight: minimumControlHeight)
                    Text("Guarda vistas con la mitad de desplazamiento entre fotos. Aumenta almacenamiento y procesamiento; conserva el objetivo de 5 fps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Reducir ruido en superficies planas", isOn: $settings.correctPlanarNoise)
                    .frame(minHeight: minimumControlHeight)
                    .accessibilityIdentifier("planarNoiseCorrection")
                if settings.correctPlanarNoise {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        Text("Desplazamiento máximo (mm)")
                        TextField("3", value: Binding(get: { Double(settings.planarToleranceMeters) * 1000 },
                            set: { settings.planarToleranceMeters = Float($0 / 1000) }), format: .number)
                            .frame(width: toleranceWidth).frame(minHeight: minimumControlHeight).textFieldStyle(.roundedBorder)
                            .focused($toleranceFocused)
                            .accessibilityLabel("Desplazamiento máximo en milímetros")
                            .accessibilityHint("Introduce un valor positivo. Solo modifica la copia procesada.")
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .accessibilityIdentifier("planarToleranceMillimeters")
                    }
                    if !settings.planarToleranceMeters.isFinite || settings.planarToleranceMeters <= 0 {
                        Text("Introduce una tolerancia mayor que cero.")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("planarToleranceValidation")
                    }
                    Text("Solo regiones amplias compatibles con un plano; conserva bordes, índices y escala. Un relieve menor que la tolerancia puede confundirse con ruido. La copia original se conserva.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("ARKit no ofrece un control de resolución o densidad de triángulos del LiDAR. Más fotos pueden mejorar la textura, no la precisión física del sensor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.font(.subheadline)
        #if os(iOS)
        .toolbar {
            if toleranceFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Listo") { toleranceFocused = false }
                }
            }
        }
        #endif
    }

    private var minimumControlHeight: CGFloat {
        #if os(iOS)
        44
        #else
        24
        #endif
    }
}
