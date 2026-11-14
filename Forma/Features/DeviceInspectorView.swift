import SwiftUI
import UniformTypeIdentifiers

struct DeviceInspectorView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var report: DeviceHardwareReport?
    @State private var exportDocument: HardwareReportDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    private var diskFree: String {
        guard let values = try? store.baseURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return "No disponible" }
        return Self.bytes(UInt64(max(0, bytes)))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Eyebrow(text: "Diagnóstico de capacidades")
                Text("Tu estudio\nde bolsillo.").font(.system(size: 40, weight: .regular, design: .serif)).foregroundStyle(FormaStyle.cream)
                if let report {
                    identity(report)
                    reconstruction(report)
                    cameras(report)
                    arFormats(report)
                    resources(report)
                    auxiliarySensors(report)
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            do {
                                exportDocument = HardwareReportDocument(data: try report.jsonData())
                                isExporting = true
                            } catch { exportError = error.localizedDescription }
                        } label: {
                            Label("Exportar diagnóstico JSON", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.bordered).tint(FormaStyle.accent).accessibilityIdentifier("hardware-export-json")
                        Button("Actualizar capacidades y memoria") { self.report = DeviceHardwareReport.capture() }
                            .font(.system(size: 12)).accessibilityIdentifier("hardware-refresh")
                        Text("Consulta del \(report.capturedAt.formatted(date: .abbreviated, time: .shortened)). La memoria disponible puede cambiar después.")
                            .font(.system(size: 11)).foregroundStyle(FormaStyle.muted)
                    }
                    Text("Este diagnóstico consulta capacidades sin activar la cámara, grabar sensores ni pedir permisos. El archivo no incluye tu nombre, número de serie, identificadores únicos, ubicación ni fotos.")
                        .font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(5)
                    Text("La resolución y la frecuencia de cada formato describen opciones de captura. No se suman entre cámaras ni garantizan que puedan usarse juntas. La calidad final depende de las fotografías y del recorrido.")
                        .font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(5)
                    Text("FORMA / \(report.applicationVersion ?? "—") (\(report.applicationBuild ?? "—")) · METAL + RGB-D")
                        .font(.system(size: 9, design: .monospaced)).tracking(1).foregroundStyle(FormaStyle.muted)
                        .accessibilityIdentifier("hardware-app-version")
                } else { ProgressView("Consultando capacidades…").tint(FormaStyle.accent) }
            }.padding(24).padding(.top, 15)
        }.scrollIndicators(.hidden)
            .task { if report == nil { report = DeviceHardwareReport.capture() } }
            .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json,
                          defaultFilename: "Forma-capacidades") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
            .alert("No se pudo exportar el diagnóstico", isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("Aceptar", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
    }
    private func identity(_ report: DeviceHardwareReport) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen3").font(.system(size: 65, weight: .ultraLight)).foregroundStyle(FormaStyle.accent)
            Text(report.hardwareModel ?? "Simulador").font(.system(size: 19, weight: .medium, design: .serif))
            Text("iOS \(report.operatingSystemVersion)").font(.system(size: 11, design: .monospaced)).foregroundStyle(FormaStyle.muted)
            if !report.isPhysicalDevice {
                Text("SIMULADOR · SENSORES DEL IPHONE SIN CONSULTAR")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(FormaStyle.accent)
            }
        }.frame(maxWidth: .infinity).padding(26).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 22))
    }
    private func reconstruction(_ report: DeviceHardwareReport) -> some View {
        VStack(spacing: 0) {
            capability("Reconstrucción LiDAR", report.ar.sceneMesh)
            Divider().overlay(.white.opacity(0.06))
            capability("Profundidad de escena", report.ar.sceneDepth)
            Divider().overlay(.white.opacity(0.06))
            capability("Fotogrametría local", report.ar.localPhotogrammetry)
            Divider().overlay(.white.opacity(0.06))
            capability("RoomPlan", report.ar.roomPlan)
        }.padding(.horizontal, 18).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
    }
    private func cameras(_ report: DeviceHardwareReport) -> some View {
        DisclosureGroup {
            if report.cameras.isEmpty {
                Text("No hay inventario de cámaras físicas disponible.").font(.caption).foregroundStyle(FormaStyle.muted)
            }
            ForEach(report.cameras) { camera in
                DisclosureGroup(camera.displayName) {
                    VStack(alignment: .leading, spacing: 12) {
                        value("Formatos", "\(camera.formats.count)")
                        value("Mayor foto admitida", camera.largestPhotoDimensions?.label ?? "No disponible")
                        value("Mayor raster de vídeo", camera.largestVideoDimensions?.label ?? "No disponible")
                        value("Frecuencia máxima de algún formato", camera.maximumFramesPerSecond.map { Self.rate($0) + " fps" } ?? "No disponible")
                        value("Enfoque mínimo", camera.minimumFocusDistanceMillimeters.map { "\($0) mm" } ?? "Desconocido")
                        Text("Los máximos pueden pertenecer a formatos distintos.").font(.caption2).foregroundStyle(FormaStyle.muted)
                        ForEach(camera.formats) { format in
                            DisclosureGroup("\(format.videoDimensions.label) · \(Self.rates(format.frameRates))") {
                                cameraFormat(format).padding(.vertical, 8)
                            }.font(.system(size: 11))
                        }
                    }.padding(.vertical, 12)
                }.font(.system(size: 13)).padding(.vertical, 8)
            }
        } label: { Label("Cámaras y formatos (\(report.cameras.count))", systemImage: "camera") }
            .tint(FormaStyle.accent).padding(20).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityIdentifier("hardware-cameras")
    }
    private func cameraFormat(_ format: DeviceHardwareReport.CameraFormat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            value("Formato", format.pixelFormat)
            value("Campo de visión", format.fieldOfViewDegrees.map { Self.rate($0) + "°" } ?? "Desconocido")
            value("Binning", format.isBinned ? "Sí" : "No")
            value("HDR disponible", format.supportsHDR ? "Sí" : "No")
            value("Fotos", format.photoDimensions?.map(\.label).joined(separator: ", ") ?? "No disponible")
            if let aperture = format.aperture {
                value("Aperturas recomendadas", aperture.recommendedStops?.map { "ƒ/" + Self.rate($0) }.joined(separator: ", ") ?? "No disponible")
                value("Prioridad de obturación", aperture.supportsShutterPriority ? "Admitida" : "No admitida")
            }
            ForEach(Array(format.depthFormats.enumerated()), id: \.offset) { _, depth in
                value("Profundidad \(depth.pixelFormat)", "\(depth.dimensions?.label ?? "Resolución no disponible") · \(Self.rates(depth.frameRates))")
                if depth.dimensionsUnavailableReason != nil {
                    Text("Este formato no publica una resolución de profundidad válida; se comprueba con el búfer real de una captura.")
                        .font(.caption2).foregroundStyle(FormaStyle.muted)
                }
            }
            if format.depthFormats.isEmpty { value("Profundidad", "Sin formato asociado") }
        }
    }
    private func arFormats(_ report: DeviceHardwareReport) -> some View {
        DisclosureGroup {
            VStack(spacing: 12) {
                capability("Malla clasificada", report.ar.classifiedMesh)
                capability("Profundidad suavizada", report.ar.smoothedSceneDepth)
                ForEach(report.ar.videoFormats) { format in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(format.dimensions.label) · \(format.framesPerSecond) fps")
                        Text((format.recommendedForHighResolution ? "Admite captura HiRes recomendada" : "Formato de vídeo") + (format.supportsHDR ? " · HDR" : ""))
                            .font(.caption2).foregroundStyle(FormaStyle.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("La foto HiRes real se comprueba al capturar. Estos formatos no certifican 48 MP ni FPS sostenidos.")
                    .font(.caption2).foregroundStyle(FormaStyle.muted)
            }.font(.system(size: 12)).padding(.top, 12)
        } label: { Label("Captura ARKit (\(report.ar.videoFormats.count) formatos)", systemImage: "viewfinder") }
            .tint(FormaStyle.accent).padding(20).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
    }
    private func resources(_ report: DeviceHardwareReport) -> some View {
        VStack(spacing: 18) {
            value("Espacio disponible", diskFree)
            value("Memoria física del iPhone", report.memory.physicalBytes.map(Self.bytes) ?? "No consultada")
            value("Memoria adicional disponible ahora", report.memory.processAvailableBytes.map(Self.bytes) ?? "No consultada")
            value("Estado térmico", thermalText)
            if let gpu = report.gpu {
                value(report.isPhysicalDevice ? "GPU" : "GPU del host de simulación", gpu.name)
                value("Familias Metal", gpu.supportedFamilies.joined(separator: ", "))
                value("Conjunto de trabajo recomendado", gpu.recommendedWorkingSetBytes.map(Self.bytes) ?? "No disponible")
                if gpu.recommendedWorkingSetUnavailableReason != nil {
                    Text("Metal no proporcionó una recomendación de memoria válida en esta consulta.")
                        .font(.caption2).foregroundStyle(FormaStyle.muted)
                }
                value("Mayor búfer Metal", Self.bytes(gpu.maximumBufferLengthBytes))
                value("Memoria Metal asignada ahora", Self.bytes(gpu.currentlyAllocatedBytes))
            }
            value("Cuenta / suscripción", "No se necesita")
            Text("Las cifras de memoria son estimaciones instantáneas del sistema; no garantizan una reserva futura.")
                .font(.caption2).foregroundStyle(FormaStyle.muted)
        }.padding(20).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
    }
    private func auxiliarySensors(_ report: DeviceHardwareReport) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                capability("Acelerómetro", report.motion.accelerometer)
                capability("Giroscopio", report.motion.gyroscope)
                capability("Magnetómetro", report.motion.magnetometer)
                capability("Movimiento fusionado", report.motion.fusedDeviceMotion)
                capability("Altitud relativa", report.motion.relativeAltitude)
                capability("Altitud absoluta", report.motion.absoluteAltitude)
                capability("UWB · distancia precisa", report.nearby.preciseDistance)
                capability("UWB · dirección", report.nearby.direction)
                Text("Se consulta disponibilidad. Forma no inicia mediciones ni solicita ubicación para este diagnóstico.")
                    .font(.caption2).foregroundStyle(FormaStyle.muted)
            }
        } label: { Label("Sensores auxiliares", systemImage: "gyroscope") }
            .tint(FormaStyle.accent).padding(20).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
    }
    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Normal"
        case .fair: return "Templado"
        case .serious: return "Caliente"
        case .critical: return "Crítico"
        @unknown default: return "Desconocido"
        }
    }
    private func capability(_ title: String, _ supported: Bool?) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if let supported {
                Image(systemName: supported ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(supported ? Color.green.opacity(0.8) : FormaStyle.muted)
                    .accessibilityLabel(supported ? "Disponible" : "No disponible")
            } else { Text("Sin consultar").font(.caption2).foregroundStyle(FormaStyle.muted) }
        }.padding(.vertical, 12)
    }
    private func value(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(FormaStyle.muted)
            Spacer(); Text(detail).multilineTextAlignment(.trailing)
        }.font(.system(size: 12))
    }
    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
    }
    private static func rate(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
    private static func rates(_ ranges: [DeviceHardwareReport.FrameRateRange]) -> String {
        ranges.map { $0.minimum == $0.maximum ? rate($0.maximum) : rate($0.minimum) + "–" + rate($0.maximum) }.joined(separator: ", ") + " fps"
    }
}

private struct HardwareReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
