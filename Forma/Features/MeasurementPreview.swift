import SwiftUI
import SceneKit
import simd

enum PreviewViewpoint: String, CaseIterable, Identifiable {
    case perspective, front, top, side

    var id: String { rawValue }
    var title: String {
        switch self {
        case .perspective: return "Perspectiva"
        case .front: return "Frontal"
        case .top: return "Superior"
        case .side: return "Lateral"
        }
    }

    var symbol: String {
        switch self {
        case .perspective: return "cube"
        case .front: return "square"
        case .top: return "square.topthird.inset.filled"
        case .side: return "square.lefthalf.filled"
        }
    }
}

/// The imported model keeps its metric transforms. Only its display parent is normalized.
@MainActor
struct MeasurementPreview: UIViewRepresentable {
    var modelURL: URL
    var measuring: Bool
    var wireframe: Bool
    var showTexture: Bool = true
    var textureMode: MeshPreviewTextureMode = .lightweight
    var viewpoint: PreviewViewpoint = .perspective
    var measureArea: Bool = false
    var resetRequest: UUID? = nil
    var antialiasing: PreviewAntialiasing = .sharp
    var onPerformanceUpdate: ((ViewerPerformanceSnapshot) -> Void)? = nil
    var onAreaMeasurement: (Float?) -> Void = { _ in }
    var onMeasurement: (Float?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMeasurement: onMeasurement) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        applyAntialiasing(view)
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.accessibilityIdentifier = "measurementPreview"
        context.coordinator.attach(view)
        context.coordinator.update(url: modelURL, measuring: measuring, wireframe: wireframe, showTexture: showTexture,
                                   textureMode: textureMode, viewpoint: viewpoint, measureArea: measureArea, resetRequest: resetRequest, onPerformanceUpdate: onPerformanceUpdate, onAreaMeasurement: onAreaMeasurement,
                                   onMeasurement: onMeasurement)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        applyAntialiasing(view)
        context.coordinator.update(url: modelURL, measuring: measuring, wireframe: wireframe, showTexture: showTexture,
                                   textureMode: textureMode, viewpoint: viewpoint, measureArea: measureArea, resetRequest: resetRequest, onPerformanceUpdate: onPerformanceUpdate, onAreaMeasurement: onAreaMeasurement,
                                   onMeasurement: onMeasurement)
    }

    private func applyAntialiasing(_ view: SCNView) {
        let samples = antialiasing.supportedSamples { view.device?.supportsTextureSampleCount($0) ?? ($0 == 1) }
        let mode = PreviewAntialiasing.sceneKitMode(samples: samples)
        if view.antialiasingMode != mode { view.antialiasingMode = mode }
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
        view.isPlaying = false
        view.scene = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var view: SCNView?
        private weak var statusLabel: UILabel?
        private var content: SCNNode?
        private var annotations: SCNNode?
        private var selected: [(metric: SIMD3<Float>, display: SIMD3<Float>)] = []
        private var loadedURL: URL?
        private var loadToken = UUID()
        private var measuring = false
        private var measureArea = false
        private var wireframe = false
        private var showTexture = true
        private var textureMode: MeshPreviewTextureMode = .lightweight
        private struct InspectionState {
            var cameraTransform: simd_float4x4
            var camera: SCNCamera?
            var target: SCNVector3
            var annotations: SCNNode
            var restoreCamera = true
        }
        private var pendingInspection: InspectionState?
        private var viewpoint: PreviewViewpoint = .perspective
        private var measurementError: String?
        private var materialSets: [MeshPreviewMaterials] = []
        private var loadControl = GaussianWorkControl()
        private var lastResetRequest: UUID?
        private var performance = ViewerPerformanceRecorder(source: .sceneKitRender)
        private var frameObserver: MeshPreviewFrameObserver?
        private var onPerformanceUpdate: ((ViewerPerformanceSnapshot) -> Void)?
        private var isLoaded = false
        private var texturePreviewAdapted = false
        private var onMeasurement: (Float?) -> Void
        private var onAreaMeasurement: (Float?) -> Void = { _ in }
        private let accent = UIColor(red: 1, green: 0.36, blue: 0.18, alpha: 1)

        init(onMeasurement: @escaping (Float?) -> Void) { self.onMeasurement = onMeasurement }

        func attach(_ view: SCNView) {
            self.view = view
            view.preferredFramesPerSecond = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delegate = self
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)

            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textColor = .white
            label.backgroundColor = .black.withAlphaComponent(0.7)
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.textAlignment = .center
            label.layer.cornerRadius = 12
            label.layer.masksToBounds = true
            label.isUserInteractionEnabled = false
            label.accessibilityIdentifier = "measurementStatus"
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
            statusLabel = label
        }

        func update(url: URL, measuring: Bool, wireframe: Bool, showTexture: Bool = true,
                    textureMode: MeshPreviewTextureMode = .lightweight, viewpoint: PreviewViewpoint = .perspective, measureArea: Bool = false,
                    resetRequest: UUID? = nil,
                    onPerformanceUpdate: ((ViewerPerformanceSnapshot) -> Void)? = nil,
                    onAreaMeasurement: @escaping (Float?) -> Void = { _ in },
                    onMeasurement: @escaping (Float?) -> Void) {
            self.onMeasurement = onMeasurement
            self.onAreaMeasurement = onAreaMeasurement
            let enablePerformance = self.onPerformanceUpdate == nil && onPerformanceUpdate != nil
            self.onPerformanceUpdate = onPerformanceUpdate
            let changedMode = self.measuring != measuring || self.measureArea != measureArea
            self.measuring = measuring
            self.measureArea = measureArea
            if changedMode {
                clearSelection()
                // UIViewRepresentable updates must not synchronously mutate the caller's State.
                resetResultsLater()
            }
            let changedWireframe = self.wireframe != wireframe
            let changedTexture = self.showTexture != showTexture
            self.wireframe = wireframe
            self.showTexture = showTexture
            let changedTextureMode = self.textureMode != textureMode
            self.textureMode = textureMode
            let changedViewpoint = self.viewpoint != viewpoint
            self.viewpoint = viewpoint
            let reset = lastResetRequest != resetRequest
            lastResetRequest = resetRequest
            if loadedURL != url { load(url, preservingInspection: false) }
            else {
                if changedTextureMode { load(url, preservingInspection: true) }
                else if changedWireframe || changedTexture { applyWireframe() }
                if reset { clearSelection(); resetResultsLater() }
                if changedViewpoint || reset {
                    pendingInspection?.restoreCamera = false
                    applyViewpoint()
                }
            }
            if isLoaded { showInstructions() }
            if enablePerformance {
                let token = loadToken
                Task { @MainActor [weak self] in
                    guard let self,self.loadToken == token else { return }
                    self.onPerformanceUpdate?(self.performance.snapshot())
                }
            }
        }

        private func resetResultsLater() {
            Task { @MainActor [weak self] in
                self?.onMeasurement(nil)
                self?.onAreaMeasurement(nil)
            }
        }

        private func load(_ url: URL, preservingInspection: Bool) {
            if preservingInspection {
                if pendingInspection == nil, isLoaded, let view, let camera = view.pointOfView, let annotations {
                    view.defaultCameraController.stopInertia()
                    pendingInspection = InspectionState(cameraTransform: camera.simdWorldTransform,
                        camera: camera.camera?.copy() as? SCNCamera, target: view.defaultCameraController.target,
                        annotations: annotations)
                    annotations.removeFromParentNode()
                }
            } else {
                clearSelection(); pendingInspection = nil
                resetResultsLater()
            }
            loadControl.cancel(); loadControl = GaussianWorkControl()
            loadedURL = url
            isLoaded = false
            content = nil
            materialSets.removeAll()
            annotations = nil
            view?.delegate = nil
            view?.scene = nil
            showStatus("Cargando modelo 3D…")
            let token = UUID()
            loadToken = token
            performance = ViewerPerformanceRecorder(source: .sceneKitRender)
            frameObserver = MeshPreviewFrameObserver(performance: performance) { [weak self] snapshot in
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.loadToken == token else { return }
                    self.onPerformanceUpdate?(snapshot)
                }
            }
            let control = loadControl
            let textureMode = self.textureMode
            // Import, hierarchy/material preparation and bounds all run on the
            // worker. Closing/resetting a viewer cannot queue duplicate imports.
            MeshPreviewPreparation.queue.async { [weak self] in
                let result = autoreleasepool {
                    Result { try MeshPreviewPreparation.load(url: url,textureMode: textureMode,checkCancellation: control.checkCancellation) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadToken == token else { return }
                    switch result {
                    case .success(let prepared): self.install(prepared)
                    case .failure(let error):
                        self.showStatus("No se pudo abrir el modelo 3D.\n\(error.localizedDescription)")
                    }
                }
            }
        }

        private func install(_ prepared: MeshPreviewPreparation.Prepared) {
            texturePreviewAdapted = prepared.texturePreviewAdapted
            guard let view else { return }
            performance.loaded(loadSeconds: prepared.loadSeconds,preparationSeconds: prepared.preparationSeconds)
            onPerformanceUpdate?(performance.snapshot())
            // The identity container includes every original node transform, including USD unit conversion.
            let content = prepared.content
            materialSets = prepared.materialSets
            let low = prepared.low, high = prepared.high
            let extent = high - low
            let largest = max(extent.x, max(extent.y, extent.z))
            let center = low * 0.5 + high * 0.5
            let scale: Float = 2.4 / largest
            let display = SCNNode()
            display.simdScale = SIMD3(repeating: scale)
            display.simdPosition = -center * scale
            display.addChildNode(content)
            let scene = SCNScene()
            scene.rootNode.addChildNode(display)

            let inspection = pendingInspection
            let annotations = inspection?.annotations ?? SCNNode()
            annotations.categoryBitMask = 2
            scene.rootNode.addChildNode(annotations)
            self.annotations = annotations
            self.content = content

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.005
            camera.camera?.zFar = 100
            camera.position = SCNVector3(0, 0.1, 4.7)
            scene.rootNode.addChildNode(camera)
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .omni
            key.light?.intensity = 850
            key.position = SCNVector3(-3, 4, 5)
            scene.rootNode.addChildNode(key)
            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .ambient
            fill.light?.intensity = 180
            scene.rootNode.addChildNode(fill)

            view.delegate = frameObserver
            view.scene = scene
            view.pointOfView = camera
            view.defaultCameraController.target = SCNVector3Zero
            view.defaultCameraController.automaticTarget = false
            isLoaded = true
            if let inspection, inspection.restoreCamera {
                camera.camera = inspection.camera ?? camera.camera
                camera.simdTransform = inspection.cameraTransform
                view.defaultCameraController.pointOfView = camera
                view.defaultCameraController.target = inspection.target
            } else { applyViewpoint() }
            pendingInspection = nil
            applyWireframe()
            if isLoaded { showInstructions() }
        }

        private func applyViewpoint() {
            guard isLoaded, let view, let camera = view.pointOfView else { return }
            view.defaultCameraController.stopInertia()
            camera.removeAllActions()
            camera.removeAllAnimations()
            let position: SCNVector3
            let up: SCNVector3
            switch viewpoint {
            case .perspective:
                position = SCNVector3(3.1, 2.1, 4.0)
                up = SCNVector3(0, 1, 0)
            case .front:
                position = SCNVector3(0, 0, 4.7)
                up = SCNVector3(0, 1, 0)
            case .top:
                position = SCNVector3(0, 4.7, 0)
                // Looking straight down needs an up axis distinct from the viewing axis.
                up = SCNVector3(0, 0, -1)
            case .side:
                position = SCNVector3(4.7, 0, 0)
                up = SCNVector3(0, 1, 0)
            }
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            camera.position = position
            camera.look(at: SCNVector3Zero, up: up, localFront: SCNVector3(0, 0, -1))
            view.defaultCameraController.pointOfView = camera
            view.defaultCameraController.target = SCNVector3Zero
            SCNTransaction.commit()
        }

        private func applyWireframe() {
            materialSets.forEach { $0.apply(wireframe: wireframe,showTexture: showTexture) }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard measuring, isLoaded, gesture.state == .ended, let view, let content else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [
                .rootNode: content,
                .categoryBitMask: 1,
                .boundingBoxOnly: false,
                .backFaceCulling: true,
                .searchMode: SCNHitTestSearchMode.closest.rawValue
            ])
            guard let hit = hits.first else {
                showStatus("Toca una superficie del modelo. El fondo y los huecos no tienen medida.")
                return
            }
            // Converting the hit to the metric container removes only the display normalization.
            // It retains imported child scales, rotations and translations, including nested USDZ nodes.
            let metric = content.simdConvertPosition(hit.simdWorldCoordinates, from: nil)
            let point = hit.simdWorldCoordinates
            guard metric.x.isFinite, metric.y.isFinite, metric.z.isFinite else { return }
            if !measureArea, selected.count == 2 { clearSelection(); onMeasurement(nil) }
            selected.append((metric, point))
            addMarker(at: point)
            measurementError = nil
            if measureArea {
                annotations?.childNode(withName: "polygonClosure", recursively: false)?.removeFromParentNode()
                if selected.count >= 2 {
                    addLine(from: selected[selected.count - 2].display, to: point)
                }
                if selected.count >= 3 {
                    addLine(from: point, to: selected[0].display, name: "polygonClosure")
                    do {
                        let area = try SurfaceMeasurement.polygonArea(selected.map(\.metric))
                        onAreaMeasurement(area)
                    } catch {
                        measurementError = error.localizedDescription
                        onAreaMeasurement(nil)
                    }
                }
            } else if selected.count == 2 {
                let distance = simd_distance(selected[0].metric, selected[1].metric)
                guard distance.isFinite else { clearSelection(); onMeasurement(nil); return }
                addLine(from: selected[0].display, to: selected[1].display)
                onMeasurement(distance)
            }
            showInstructions()
        }

        private func addMarker(at point: SIMD3<Float>) {
            let geometry = SCNSphere(radius: 0.025)
            geometry.segmentCount = 14
            geometry.materials = [markerMaterial()]
            let marker = SCNNode(geometry: geometry)
            marker.simdPosition = point
            marker.categoryBitMask = 2
            marker.renderingOrder = 100
            annotations?.addChildNode(marker)
        }

        private func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>, name: String? = nil) {
            let delta = b - a
            let length = simd_length(delta)
            guard length > 0, length.isFinite else { return }
            let line = SCNNode(geometry: SCNCylinder(radius: 0.006, height: CGFloat(length)))
            line.geometry?.materials = [markerMaterial()]
            line.simdPosition = (a + b) * 0.5
            line.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            line.categoryBitMask = 2
            line.name = name
            line.renderingOrder = 99
            annotations?.addChildNode(line)
        }

        private func markerMaterial() -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = accent
            material.lightingModel = .constant
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            return material
        }

        private func clearSelection() {
            selected.removeAll()
            measurementError = nil
            annotations?.childNodes.forEach { $0.removeFromParentNode() }
            pendingInspection?.annotations.childNodes.forEach { $0.removeFromParentNode() }
        }

        private func showInstructions() {
            if !measuring { showStatus("Arrastra para girar · Pellizca para ampliar" + (texturePreviewAdapted && showTexture ? "\nTexturas de pantalla adaptadas a la memoria · Exportación original" : "")) }
            else if let measurementError { showStatus(measurementError + "\nUsa Rehacer para seleccionar otro contorno.") }
            else if measureArea {
                if selected.count < 3 {
                    showStatus("Marca al menos 3 esquinas en orden sobre una superficie plana.\n\(selected.count) puntos · Puedes girar el modelo entre puntos.")
                } else {
                    showStatus("\(selected.count) puntos · Toca otra esquina para ampliar el contorno.\nÁrea plana estimada del modelo · Usa Rehacer para empezar.")
                }
            }
            else if selected.isEmpty { showStatus("Toca dos superficies para medir.\nArrastra para girar · Medida estimada del modelo") }
            else if selected.count == 1 { showStatus("Primer punto marcado. Toca el segundo punto.\nPuedes girar el modelo entre ambos puntos.") }
            else { showStatus("Distancia en línea recta sobre el modelo.\nToca para comenzar otra medida · Precisión no certificada") }
        }

        private func showStatus(_ text: String) {
            statusLabel?.text = text
            view?.accessibilityLabel = "Visor 3D. \(text)"
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func stop() {
            loadControl.cancel()
            view?.delegate = nil; frameObserver = nil
            loadToken = UUID()
            clearSelection()
            content = nil
            materialSets.removeAll()
            annotations = nil
            pendingInspection = nil
            view = nil
        }
    }
}

/// SceneKit calls this after rendering a scene. These timestamps reflect render
/// callbacks; they are deliberately not labelled as measured GPU presentations.
private final class MeshPreviewFrameObserver: NSObject,SCNSceneRendererDelegate {
    private let performance: ViewerPerformanceRecorder
    private let onSnapshot: (ViewerPerformanceSnapshot) -> Void
    init(performance: ViewerPerformanceRecorder,onSnapshot: @escaping (ViewerPerformanceSnapshot) -> Void) {
        self.performance = performance; self.onSnapshot = onSnapshot
    }
    func renderer(_ renderer: SCNSceneRenderer,didRenderScene scene: SCNScene,atTime time: TimeInterval) {
        if let snapshot = performance.frame(at: CACurrentMediaTime()) { onSnapshot(snapshot) }
    }
}
