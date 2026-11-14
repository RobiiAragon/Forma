import SwiftUI
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import simd

enum DesktopPreviewMode: String, CaseIterable, Identifiable {
    case geometry, adaptive, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .geometry: return "Geometría nativa"
        case .adaptive: return "Textura ligera"
        case .original: return "Textura original"
        }
    }
}

struct DesktopModelViewer: NSViewRepresentable {
    var meshURL: URL
    var modelURL: URL
    var mode: DesktopPreviewMode
    var targetFPS: Int
    var showsDiagnostics = false

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SCNView {
        let view = InteractionSCNView()
        view.backgroundColor = .black
        view.allowsCameraControl = true
        view.cameraControlConfiguration.autoSwitchToFreeCamera = false
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        context.coordinator.attach(view)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        view.preferredFramesPerSecond = min(targetFPS, view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        context.coordinator.showsDiagnostics = showsDiagnostics
        context.coordinator.load(meshURL: meshURL, modelURL: modelURL, mode: mode)
    }
    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) { coordinator.stop(); view.scene = nil; view.isPlaying = false }

    @MainActor final class Coordinator: NSObject {
        weak var view: SCNView?
        weak var label: NSTextField?
        var key = ""
        var task: Task<Void, Never>?
        var temporary: URL?
        var counter: FrameCounter?
        var showsDiagnostics = false
        func attach(_ view: SCNView) {
            self.view = view
            let label = NSTextField(labelWithString: "Preparando visor…")
            label.textColor = .white; label.backgroundColor = .black; label.drawsBackground = true
            label.maximumNumberOfLines = 4; label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            let reset = NSButton(title: "Reencuadrar", target: self, action: #selector(reframe))
            reset.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(reset)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(lessThanOrEqualTo: reset.leadingAnchor, constant: -12),
                reset.topAnchor.constraint(equalTo: view.topAnchor, constant: 12), reset.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)])
            self.label = label
        }
        @objc private func reframe() {
            guard let view, let node = view.pointOfView, let camera = node.camera else { return }
            view.defaultCameraController.stopInertia()
            SCNTransaction.begin(); SCNTransaction.disableActions = true
            node.position = SCNVector3(3,2,4)
            node.look(at: SCNVector3Zero)
            camera.fieldOfView = 60
            view.defaultCameraController.target = SCNVector3Zero
            DesktopCameraPolicy.apply(to: camera, cameraPosition: node.simdWorldPosition, contentRadius: counter?.contentRadius ?? 1.2)
            SCNTransaction.commit()
        }
        func stop() { task?.cancel(); task = nil; view?.delegate = nil; if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil }
        func load(meshURL: URL, modelURL: URL, mode: DesktopPreviewMode) {
            let newKey = modelURL.path + mode.rawValue
            guard newKey != key else { return }
            key = newKey; stop(); view?.scene = nil; label?.stringValue = "Preparando \(mode.title.lowercased())…"
            let worker = Task.detached(priority: .userInitiated) { try Self.prepare(meshURL: meshURL, modelURL: modelURL, mode: mode) }
            task = Task {
                do {
                    let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled, key == newKey else { if let folder = prepared.1 { try? FileManager.default.removeItem(at: folder) }; return }
                    temporary = prepared.1
                    view?.scene = prepared.0
                    view?.pointOfView = prepared.camera
                    view?.defaultCameraController.pointOfView = prepared.camera
                    view?.defaultCameraController.automaticTarget = false
                    view?.defaultCameraController.target = SCNVector3Zero
                    let counter = FrameCounter(contentRadius: prepared.contentRadius, activity: (view as? InteractionSCNView)?.interaction) { [weak self] measured in
                        Task { @MainActor in
                            self?.label?.stringValue = self?.showsDiagnostics == true
                                ? (measured.map { String(format: "Render: %.1f llamadas/s · %@", $0, mode.title) } ?? "Render en reposo · \(mode.title)")
                                : mode.title + " · gira y amplía"
                        }
                    }
                    self.counter = counter; view?.delegate = counter
                    label?.stringValue = mode.title + " · gira y amplía"
                } catch { if key == newKey { label?.stringValue = error.localizedDescription } }
            }
        }
        nonisolated static func prepare(meshURL: URL, modelURL: URL, mode: DesktopPreviewMode) throws -> (SCNScene, URL?, camera: SCNNode, contentRadius: Double) {
            var temporary: URL?
            var success = false
            defer { if !success, let temporary { try? FileManager.default.removeItem(at: temporary) } }
            try Task.checkCancellation()
            let scene: SCNScene
            if mode == .geometry && FileManager.default.fileExists(atPath: meshURL.path) {
                let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: meshURL))
                try MeshExporter.validate(mesh)
                var normals = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)
                for index in stride(from: 0, to: mesh.triangles.count, by: 3) {
                    if index & 4095 == 0 { try Task.checkCancellation() }
                    let a = Int(mesh.triangles[index]), b = Int(mesh.triangles[index+1]), c = Int(mesh.triangles[index+2])
                    let normal = simd_cross(mesh.vertices[b]-mesh.vertices[a], mesh.vertices[c]-mesh.vertices[a])
                    normals[a] += normal; normals[b] += normal; normals[c] += normal
                }
                for i in normals.indices { let length = simd_length(normals[i]); if length > 0 { normals[i] /= length } }
                func source(_ values: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
                    let bytes = values.withUnsafeBytes { Data($0) }
                    return SCNGeometrySource(data: bytes, semantic: semantic, vectorCount: values.count, usesFloatComponents: true,
                        componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
                }
                let indices = mesh.triangles.withUnsafeBytes { Data($0) }
                let element = SCNGeometryElement(data: indices, primitiveType: .triangles, primitiveCount: mesh.faceCount, bytesPerIndex: 4)
                let geometry = SCNGeometry(sources: [source(mesh.vertices, .vertex), source(normals, .normal)], elements: [element])
                let material = SCNMaterial(); material.diffuse.contents = NSColor(white: 0.7, alpha: 1); material.lightingModel = .lambert
                material.isDoubleSided = false; material.cullMode = .back; geometry.materials = [material]
                scene = SCNScene(); scene.rootNode.addChildNode(SCNNode(geometry: geometry))
            } else if modelURL.pathExtension.lowercased() == "usdz" {
                scene = try DesktopUSDZPreview.load(modelURL, mode: mode)
            } else {
                let package = modelURL.deletingLastPathComponent()
                let inventory = try TextureAssetInventory.loadIfPresent(modelURL: modelURL)
                let photos = (inventory?.assets ?? []).map { asset in
                    (String(asset.url.path.dropFirst(package.path.count + 1)), asset.url, asset.width, asset.height)
                }
                let others = ([modelURL] + (inventory.map { [$0.mtlURL] } ?? [])).map { file in
                    (String(file.path.dropFirst(package.path.count + 1)), file)
                }
                let nativePixels = (inventory?.assets ?? []).reduce(0.0) { $0 + Double($1.width) * Double($1.height) }
                var importURL = modelURL
                if mode == .adaptive {
                    // The lightweight mode explicitly resizes display copies.
                    // Original mode attempts the complete scene without an app budget cutoff.
                    let workingSet = Double(MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? ProcessInfo.processInfo.physicalMemory / 2)
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FormaDesktopPreview-\(UUID().uuidString)")
                    temporary = directory
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    for (name, file) in others {
                        let output = directory.appendingPathComponent(name)
                        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: file, to: output)
                    }
                    let previewBudget = min(256 * 1_048_576.0, workingSet / 12)
                    let scale = min(1, sqrt(previewBudget / max(1, nativePixels * 4 * 1.34)))
                    for (name, file, width, height) in photos {
                        try Task.checkCancellation()
                        try autoreleasepool {
                            let output = directory.appendingPathComponent(name)
                            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                            guard let image = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(max(width,height))*scale)), kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary),
                                  let encoder = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                                throw RGBDDatasetError.invalid("No se pudo preparar una textura de pantalla.")
                            }
                            CGImageDestinationAddImage(encoder, thumbnail, nil)
                            guard CGImageDestinationFinalize(encoder) else { throw RGBDDatasetError.invalid("No se pudo escribir una textura de pantalla.") }
                        }
                    }
                    importURL = directory.appendingPathComponent(modelURL.lastPathComponent)
                }
                guard let imported = SCNSceneSource(url: importURL)?.scene(options: [.convertToYUp: true], statusHandler: { _, _, _, abort in
                    if Task.isCancelled { abort.pointee = true }
                }) else { throw RGBDDatasetError.invalid("SceneKit no pudo abrir el modelo.") }
                scene = imported
                _ = try ImportedMeshBatching.consolidate(in: scene, checkCancellation: { try Task.checkCancellation() })
                let textureBase = importURL.deletingLastPathComponent()
                scene.rootNode.enumerateChildNodes { node, _ in
                    node.geometry?.materials.forEach { material in
                        if let path = material.diffuse.contents as? String, ScanStore.safeRelativePath(path) {
                            let texture = textureBase.appendingPathComponent(path)
                            if FileManager.default.fileExists(atPath: texture.path) { material.diffuse.contents = texture }
                        }
                        material.isDoubleSided = false; material.cullMode = .back; material.lightingModel = .constant
                        material.emission.contents = NSColor.black
                        if mode == .geometry {
                            material.diffuse.contents = NSColor(white: 0.7, alpha: 1)
                            material.normal.contents = nil; material.displacement.contents = nil
                            material.ambientOcclusion.contents = nil; material.multiply.contents = nil
                            material.metalness.contents = 0; material.roughness.contents = 0.85
                            material.lightingModel = .lambert
                        }
                    }
                }
            }
            try Task.checkCancellation()
            let bounds = scene.rootNode.boundingBox
            let low = SIMD3<Double>(Double(bounds.min.x),Double(bounds.min.y),Double(bounds.min.z))
            let high = SIMD3<Double>(Double(bounds.max.x),Double(bounds.max.y),Double(bounds.max.z))
            let extent = high-low, largest = max(extent.x,max(extent.y,extent.z))
            guard [low.x,low.y,low.z,high.x,high.y,high.z].allSatisfy(\.isFinite),
                  extent.x >= 0, extent.y >= 0, extent.z >= 0, largest.isFinite, largest > 0 else {
                throw RGBDDatasetError.invalid("La malla no tiene dimensiones visibles.")
            }
            let scale = 2.4/largest
            let center = low*0.5 + high*0.5
            let offset = -center*scale
            guard Float(scale).isFinite, Float(scale) > 0,
                  [offset.x,offset.y,offset.z].allSatisfy({ Float($0).isFinite }) else {
                throw RGBDDatasetError.invalid("Las dimensiones de la malla no permiten preparar una cámara finita.")
            }
            let contentRadius = simd_length(extent*scale)*0.5
            let wrapper = SCNNode()
            for node in scene.rootNode.childNodes { wrapper.addChildNode(node) }
            wrapper.simdScale = SIMD3(repeating: Float(scale))
            wrapper.simdPosition = SIMD3(Float(offset.x),Float(offset.y),Float(offset.z))
            scene.rootNode.addChildNode(wrapper)
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(3,2,4)
            camera.look(at: SCNVector3Zero); scene.rootNode.addChildNode(camera)
            DesktopCameraPolicy.apply(to: camera.camera!, cameraPosition: camera.simdWorldPosition, contentRadius: contentRadius)
            success = true
            return (scene, temporary, camera, contentRadius)
        }
    }

    final class InteractionActivity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastInput: TimeInterval = 0
        func record() { lock.lock(); lastInput = ProcessInfo.processInfo.systemUptime; lock.unlock() }
        var isRecent: Bool { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime-lastInput < 3 }
    }
    final class InteractionSCNView: SCNView {
        let interaction = InteractionActivity()
        override func mouseDown(with event: NSEvent) { interaction.record(); super.mouseDown(with: event) }
        override func mouseDragged(with event: NSEvent) { interaction.record(); super.mouseDragged(with: event) }
        override func rightMouseDown(with event: NSEvent) { interaction.record(); super.rightMouseDown(with: event) }
        override func rightMouseDragged(with event: NSEvent) { interaction.record(); super.rightMouseDragged(with: event) }
        override func otherMouseDragged(with event: NSEvent) { interaction.record(); super.otherMouseDragged(with: event) }
        override func scrollWheel(with event: NSEvent) {
            interaction.record()
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
            zoom(logScale: Double(event.scrollingDeltaY) * sensitivity, event: event)
        }
        override func magnify(with event: NSEvent) {
            interaction.record()
            zoom(logScale: Double(event.magnification) * 2, event: event)
        }
        override func rotate(with event: NSEvent) { interaction.record(); super.rotate(with: event) }

        private func zoom(logScale: Double, event: NSEvent) {
            guard logScale.isFinite, logScale != 0, let node = pointOfView, let camera = node.camera,
                  bounds.width > 0, bounds.height > 0 else { return }
            defaultCameraController.stopInertia()
            var location = convert(event.locationInWindow, from: nil)
            let options: [SCNHitTestOption: Any] = [.backFaceCulling: true,
                .searchMode: SCNHitTestSearchMode.closest.rawValue]
            var hit = hitTest(location, options: options).first
            if hit == nil && logScale > 0 {
                // A hole or empty background is not a useful zoom anchor. Find
                // a visible surface near the middle, rather than magnifying a void.
                for y in [0.5,0.47,0.53] {
                    for x in [0.5,0.47,0.53] where hit == nil {
                        let sample = CGPoint(x: bounds.width*x, y: bounds.height*y)
                        if let found = hitTest(sample, options: options).first { hit = found; location = sample }
                    }
                    if hit != nil { break }
                }
                guard hit != nil else { return }
            }
            let oldField = Double(camera.fieldOfView)
            let newField = DesktopCameraPolicy.zoomFieldOfView(current: oldField, logScale: logScale)
            if let hit {
                let local = node.convertPosition(hit.worldCoordinates, from: nil)
                let shift = DesktopCameraPolicy.zoomAnchorShift(oldFieldOfView: oldField, newFieldOfView: newField,
                    viewport: SIMD2(Double(bounds.width),Double(bounds.height)),
                    point: SIMD2(Double(location.x),Double(location.y)), depth: -Double(local.z),
                    horizontalProjection: camera.projectionDirection == .horizontal)
                let world = node.simdConvertVector(shift, to: nil)
                if world.x.isFinite && world.y.isFinite && world.z.isFinite {
                    node.simdWorldPosition += world
                    let target = defaultCameraController.target
                    defaultCameraController.target = SCNVector3(target.x + CGFloat(world.x), target.y + CGFloat(world.y), target.z + CGFloat(world.z))
                }
            }
            camera.fieldOfView = CGFloat(newField)
        }
    }
    final class FrameCounter: NSObject, SCNSceneRendererDelegate {
        var start: TimeInterval = 0, count = 0
        let contentRadius: Double
        let activity: InteractionActivity?
        let report: @Sendable (Double?) -> Void
        init(contentRadius: Double, activity: InteractionActivity?, report: @escaping @Sendable (Double?) -> Void) {
            self.contentRadius = contentRadius; self.activity = activity; self.report = report
        }
        func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard let node = renderer.pointOfView, let camera = node.camera else { return }
            DesktopCameraPolicy.apply(to: camera, cameraPosition: node.presentation.simdWorldPosition, contentRadius: contentRadius)
        }
        func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            if start == 0 { start = time; count = 0 }
            count += 1
            if time-start >= 1 { report(activity?.isRecent == true ? Double(count-1)/(time-start) : nil); start = time; count = 0 }
        }
    }
}
