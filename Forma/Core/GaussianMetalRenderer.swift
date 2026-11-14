import Foundation
import MetalKit
import simd

/// Shared complete SH3 renderer; platform wrappers own only labels and gestures.
@MainActor
final class GaussianMetalRenderer: NSObject, MTKViewDelegate {
    private weak var view: MTKView?
    private var onStatusChange: (String) -> Void = { _ in }
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var pointsBuffer: MTLBuffer?
    private var orderBuffer: MTLBuffer?
    private var harmonicsBuffer: MTLBuffer?
    private var asset: GaussianAsset?
    private var yaw: Float = 0
    private var pitch: Float = 0.1
    private var distance: Float = 1
    private var fieldOfView: Float = .pi / 3
    private var orbitTarget: SIMD3<Float>?
    private var viewpoints: [GaussianViewpoint] = []
    private var selectedViewpoint: Int?
    private var lastCapturedViewpoint = 0
    private var captureZoom: Float = 1
    private var loadedDatasetURL: URL?
    private var viewpointTask: Task<Void, Never>?
    private var viewpointError: String?
    var onViewpointChange: ((Int, Int?) -> Void)?
    private var sorting = false
    private var sortAgain = false
    private var sortedDirection: SIMD3<Float>?
    private var frameInFlight = false
    private var pendingFrame = false
    private var token = UUID()
    private var isStopped = false
    private var work = GaussianWorkControl()
    private var loadedURL: URL?
    private var lastResetRequest: UUID?
    private var performance = ViewerPerformanceRecorder(source: .metalPresentation)
    private var onPerformanceUpdate: ((ViewerPerformanceSnapshot) -> Void)?
    private struct Camera { var view: simd_float4x4; var projection: simd_float4x4; var viewport: SIMD4<Float>; var eyeAndDegree: SIMD4<Float> }
    private struct Prepared {
        var asset: GaussianAsset
        var points: MTLBuffer
        var harmonics: MTLBuffer
    }

    func attach(_ view: MTKView, url: URL, onStatusChange: @escaping (String) -> Void) {
        self.view = view
        self.onStatusChange = onStatusChange
        view.delegate = self
        guard let device = view.device, let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "formaGaussianVertex"),
              let fragment = library.makeFunction(name: "formaGaussianFragment") else {
            onStatusChange("Metal o los shaders Gaussian no están disponibles en este dispositivo.")
            return
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = view.colorPixelFormat
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
        catch { onStatusChange("No se pudo preparar el visor Metal: \(error.localizedDescription)"); return }
        queue = device.makeCommandQueue()
        load(url)
    }

    func update(url: URL,resetRequest: UUID?,onPerformanceUpdate: ((ViewerPerformanceSnapshot) -> Void)?,
                captureDatasetURL: URL? = nil) {
        let enablePerformance = self.onPerformanceUpdate == nil && onPerformanceUpdate != nil
        self.onPerformanceUpdate = onPerformanceUpdate
        if loadedURL != url { load(url) }
        configureViewpoints(captureDatasetURL)
        if lastResetRequest != resetRequest {
            lastResetRequest = resetRequest
            if selectedViewpoint != nil { showCapturedView() } else { showOverview() }
        }
        if enablePerformance {
            let currentToken = token
            Task { @MainActor [weak self] in
                guard let self,self.token == currentToken else { return }
                self.onPerformanceUpdate?(self.performance.snapshot())
            }
        }
    }

    private func configureViewpoints(_ directory: URL?) {
        guard directory != loadedDatasetURL else { return }
        viewpointTask?.cancel(); loadedDatasetURL = directory
        viewpoints = []; selectedViewpoint = nil; viewpointError = nil; captureZoom = 1
        onViewpointChange?(0, nil)
        guard let directory else { requestSort(); return }
        viewpointTask = Task { [weak self] in
            do {
                let native = try await GaussianViewpoint.load(fromDataset: directory)
                let upright = try native.map { try $0.uprightPresentation }
                try Task.checkCancellation()
                guard let self, !self.isStopped, self.loadedDatasetURL == directory else { return }
                self.viewpoints = upright
                self.selectedViewpoint = upright.isEmpty ? nil : 0
                self.lastCapturedViewpoint = 0; self.captureZoom = 1
                self.onViewpointChange?(upright.count, self.selectedViewpoint)
                self.requestSort()
            } catch is CancellationError { }
            catch {
                guard let self, self.loadedDatasetURL == directory else { return }
                self.viewpointError = error.localizedDescription
                if let asset = self.asset { self.onStatusChange(self.status(for: asset)) }
            }
        }
    }

    func showOverview() {
        selectedViewpoint = nil; orbitTarget = nil
        yaw = 0; pitch = 0.1; fieldOfView = .pi / 3; distance = (asset?.radius ?? 1) * 3.2
        onViewpointChange?(viewpoints.count, viewpoints.isEmpty ? nil : lastCapturedViewpoint)
        requestSort()
    }
    func showCapturedView() { selectViewpoint(lastCapturedViewpoint) }
    func previousCapturedView() {
        if let index = GaussianViewpoint.previousIndex(before: selectedViewpoint ?? lastCapturedViewpoint, count: viewpoints.count) {
            selectViewpoint(index)
        }
    }
    func nextCapturedView() {
        if let index = GaussianViewpoint.nextIndex(after: selectedViewpoint ?? lastCapturedViewpoint, count: viewpoints.count) {
            selectViewpoint(index)
        }
    }
    private func selectViewpoint(_ index: Int) {
        guard viewpoints.indices.contains(index) else { return }
        selectedViewpoint = index; lastCapturedViewpoint = index; captureZoom = 1
        onViewpointChange?(viewpoints.count, index)
        requestSort()
    }
    private var capturedView: GaussianViewpoint? {
        selectedViewpoint.flatMap { viewpoints.indices.contains($0) ? viewpoints[$0] : nil }
    }

    private func load(_ url: URL) {
        guard let device = view?.device, pipeline != nil else { return }
        work.cancel(); work = GaussianWorkControl(); token = UUID()
        loadedURL = url; sortedDirection = nil; sorting = false; sortAgain = false
        frameInFlight = false; pendingFrame = false
        pointsBuffer = nil; harmonicsBuffer = nil; orderBuffer = nil; asset = nil
        yaw = 0; pitch = 0.1; fieldOfView = .pi / 3; orbitTarget = nil
        onStatusChange("Cargando Gaussian 3D…")
        performance = ViewerPerformanceRecorder(source: .metalPresentation)
        let currentToken = token
        let work = self.work
        let performance = self.performance
        GaussianWorkQueue.queue.async { [weak self] in
            let result = Result {
                let started = CACurrentMediaTime()
                let asset = try GaussianAsset.load(url: url, checkCancellation: work.checkCancellation)
                let loaded = CACurrentMediaTime()
                // Metal buffer copies can touch hundreds of MB. Keep those
                // copies off the UI thread as well as decoding and ordering.
                let prepared = try Self.prepare(asset,device: device,work: work)
                performance.loaded(loadSeconds: loaded-started,preparationSeconds: CACurrentMediaTime()-loaded)
                return prepared
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == currentToken, !self.isStopped else { return }
                switch result {
                case .failure(let error): self.onStatusChange(error.localizedDescription)
                case .success(let prepared):
                    self.pointsBuffer = prepared.points; self.harmonicsBuffer = prepared.harmonics
                    self.asset = prepared.asset; self.distance = prepared.asset.radius * 3.2
                    self.onStatusChange(self.status(for: prepared.asset))
                    self.onPerformanceUpdate?(performance.snapshot())
                    self.requestSort()
                }
            }
        }
    }

    nonisolated private static func prepare(_ asset: GaussianAsset,device: MTLDevice,work: GaussianWorkControl) throws -> Prepared {
        try work.checkCancellation()
        let bytes = try GaussianMemoryGuard.bytes(asset.points.count, stride: MemoryLayout<GaussianPoint>.stride)
        let harmonicBytes = try GaussianMemoryGuard.bytes(max(1,asset.harmonics.count), stride: MemoryLayout<SIMD4<Float>>.stride)
        guard bytes <= device.maxBufferLength, harmonicBytes <= device.maxBufferLength,
              asset.points.count <= Int(UInt32.max) else {
            throw RGBDDatasetError.invalid("El modelo excede el espacio de un buffer Metal de este dispositivo. Los archivos completos siguen disponibles para exportar.")
        }
        // CPU arrays are still live during both GPU copies. Account only for
        // the additional GPU allocations, with a fresh available-memory query.
        try GaussianMemoryGuard.require(try GaussianMemoryGuard.sum(bytes,harmonicBytes), phase: "copiar el modelo completo a Metal")
        guard let buffer = asset.points.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared) }) else {
            throw RGBDDatasetError.invalid("Metal no pudo reservar memoria para el modelo completo. Libera memoria y vuelve a abrirlo. Los archivos siguen disponibles para exportar.")
        }
        try work.checkCancellation()
        let harmonics: MTLBuffer?
        if asset.harmonics.isEmpty {
            var zero = SIMD4<Float>.zero
            harmonics = device.makeBuffer(bytes: &zero, length: harmonicBytes, options: .storageModeShared)
        } else {
            harmonics = asset.harmonics.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: harmonicBytes, options: .storageModeShared) }
        }
        guard let harmonics else {
            throw RGBDDatasetError.invalid("Metal no pudo reservar memoria para todos los armónicos. Libera memoria y vuelve a abrir el PLY completo. Los archivos siguen disponibles para exportar.")
        }
        var displayAsset = asset
        displayAsset.harmonics = [] // GPU owns SH data; CPU only needs positions for sorting.
        try work.checkCancellation()
        return Prepared(asset: displayAsset,points: buffer,harmonics: harmonics)
    }

    private func status(for asset: GaussianAsset) -> String {
        let camera = selectedViewpoint.map { "Vista capturada \($0 + 1) de \(viewpoints.count)" } ?? "Vista libre"
        let issue = viewpointError.map { "\n\($0)" } ?? ""
        return "\(asset.points.count.formatted()) Gaussianas · \(asset.harmonicDegree >= 0 ? "SH\(asset.harmonicDegree)" : "SPLAT") · Metal\n\(camera) · Arrastra para girar · Pellizca para ampliar\(issue)"
    }

    private func viewDirection() -> SIMD3<Float> {
        if let capturedView { return capturedView.backward }
        return simd_normalize(SIMD3<Float>(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch)))
    }

    private func viewMatrix() -> simd_float4x4 {
        if let capturedView { return capturedView.viewMatrix }
        let target = orbitTarget ?? asset?.center ?? .zero
        let z = viewDirection(), eye = target + z * distance
        let x = simd_normalize(simd_cross(SIMD3<Float>(0,1,0),z)), y = simd_cross(z,x)
        return simd_float4x4(columns: (SIMD4(x.x,y.x,z.x,0), SIMD4(x.y,y.y,z.y,0), SIMD4(x.z,y.z,z.z,0), SIMD4(-simd_dot(x,eye),-simd_dot(y,eye),-simd_dot(z,eye),1)))
    }

    private func requestSort() {
        guard let asset, let device = view?.device, !isStopped else { return }
        requestFrame()
        let direction = viewDirection()
        onStatusChange(status(for: asset))
        if sortedDirection == direction, orderBuffer != nil { return }
        if sorting { sortAgain = true; return }
        sorting = true
        let count = asset.points.count, currentToken = token
        let work = self.work
        GaussianWorkQueue.queue.async { [weak self] in
            let result = Result { () throws -> MTLBuffer in
                try work.checkCancellation()
                // Exact keys, two index arrays, histogram and new GPU order.
                let peakBytes = try GaussianDepthOrder.workingBytes(pointCount: count,includeGPUOrder: true)
                try GaussianMemoryGuard.require(peakBytes, phase: "ordenar todas las Gaussianas por profundidad")
                let indices = try GaussianDepthOrder.sortedIndices(points: asset.points,direction: direction,checkCancellation: work.checkCancellation)
                try work.checkCancellation()
                let orderBytes = try GaussianMemoryGuard.bytes(count, stride: MemoryLayout<UInt32>.stride)
                try GaussianMemoryGuard.require(orderBytes, phase: "copiar el orden de profundidad a Metal")
                guard let buffer = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: orderBytes, options: .storageModeShared) }) else {
                    throw RGBDDatasetError.invalid("Metal no pudo reservar el orden de profundidad completo. Libera memoria y vuelve a abrir el visor. Los archivos siguen disponibles para exportar.")
                }
                return buffer
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == currentToken, !self.isStopped else { return }
                self.sorting = false
                switch result {
                case .success(let buffer):
                    self.orderBuffer = buffer; self.sortedDirection = direction
                    self.onStatusChange(self.status(for: asset))
                case .failure(let error): self.onStatusChange(error.localizedDescription)
                }
                self.requestFrame()
                if self.sortAgain { self.sortAgain = false; self.requestSort() }
            }
        }
    }

    private func requestFrame() {
        guard !isStopped else { return }
        if frameInFlight { pendingFrame = true }
        else {
            #if os(macOS)
            view?.needsDisplay = true
            #else
            view?.setNeedsDisplay()
            #endif
        }
    }

    func orbit(deltaX: Float, deltaY: Float) {
        guard deltaX.isFinite, deltaY.isFinite else { return }
        if let camera = capturedView {
            let back = camera.backward
            distance = max(0.01, simd_dot((asset?.center ?? .zero) - camera.position, -back))
            orbitTarget = camera.position - back * distance
            yaw = atan2(back.x, back.z); pitch = asin(min(1, max(-1, back.y)))
            fieldOfView = 2 * atan(Float(camera.imageHeight) / (2 * camera.intrinsics[1][1] * captureZoom))
            selectedViewpoint = nil; onViewpointChange?(viewpoints.count, lastCapturedViewpoint)
        }
        yaw -= deltaX * 0.008
        pitch = min(1.53,max(-1.53,pitch + deltaY * 0.008))
        requestSort()
    }

    func zoom(scale: Float) {
        if capturedView != nil {
            let next = captureZoom * scale
            guard next.isFinite, next > 0 else { return }
            captureZoom = next; requestFrame(); return
        }
        guard scale.isFinite, scale > 0 else { return }
        let next = fieldOfView / scale
        guard next.isFinite, next > 0 else { return }
        // Optical zoom keeps the camera outside the content bounding sphere.
        // It cannot cross through the model or invalidate its depth ordering.
        fieldOfView = min(.pi * 0.95,max(0.000001,next))
        if orderBuffer == nil { requestSort() } else { requestFrame() }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestFrame() }
    func draw(in view: MTKView) {
        if frameInFlight { pendingFrame = true; return }
        guard let pointsBuffer, let orderBuffer, let harmonicsBuffer, let pipeline, let queue, let asset,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let w = Float(view.drawableSize.width), h = Float(view.drawableSize.height)
        guard w > 0, h > 0 else { encoder.endEncoding(); return }
        let f: Float = 1/tan(fieldOfView/2), near: Float = max(0.0000001,asset.radius*0.00001), far = max(asset.radius*100,distance*20)
        var projection = simd_float4x4(columns: (SIMD4(f*h/w,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,far*near/(near-far),0)))
        var viewport = SIMD4(w,h,f*h*0.5,f*h*0.5)
        if let capturedView {
            do {
                let calibrated = try capturedView.projection(viewport: SIMD2(w,h), near: near, far: far, zoom: captureZoom)
                projection = calibrated.matrix
                let origin = calibrated.viewportOrigin, size = calibrated.viewportSize
                viewport = SIMD4(size.x,size.y,calibrated.focalPixels.x,calibrated.focalPixels.y)
                encoder.setViewport(MTLViewport(originX: Double(origin.x),originY: Double(origin.y),width: Double(size.x),height: Double(size.y),znear: 0,zfar: 1))
                let x = max(0,Int(floor(origin.x))), y = max(0,Int(floor(origin.y)))
                encoder.setScissorRect(MTLScissorRect(x: x,y: y,width: min(Int(w)-x,Int(ceil(origin.x+size.x))-x),height: min(Int(h)-y,Int(ceil(origin.y+size.y))-y)))
            } catch {
                encoder.endEncoding(); onStatusChange(error.localizedDescription); return
            }
        }
        let viewTransform = viewMatrix()
        let eye = viewTransform.inverse.columns.3
        var camera = Camera(view: viewTransform, projection: projection, viewport: viewport, eyeAndDegree: SIMD4(eye.x,eye.y,eye.z,Float(asset.harmonicDegree)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(pointsBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(orderBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&camera, length: MemoryLayout<Camera>.stride, index: 2)
        encoder.setVertexBuffer(harmonicsBuffer, offset: 0, index: 3)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: asset.points.count)
        let currentToken = token
        #if !targetEnvironment(simulator)
        let performance = self.performance
        drawable.addPresentedHandler { [weak self] presented in
            guard let snapshot = performance.frame(at: presented.presentedTime) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.token == currentToken,!self.isStopped else { return }
                self.onPerformanceUpdate?(snapshot)
            }
        }
        #endif
        frameInFlight = true
        command.addCompletedHandler { [weak self] completed in
            let message = completed.error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == currentToken, !self.isStopped else { return }
                self.frameInFlight = false
                if let message {
                    self.onStatusChange("Metal no pudo dibujar el modelo: \(message). Los archivos completos siguen disponibles para exportar.")
                }
                if self.pendingFrame { self.pendingFrame = false; self.requestFrame() }
            }
        }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
    func stop() {
        viewpointTask?.cancel(); viewpointTask = nil; viewpoints = []; onViewpointChange = nil
        work.cancel(); isStopped = true; token = UUID(); view?.delegate = nil; view = nil
        frameInFlight = false; pendingFrame = false
        asset = nil; pointsBuffer = nil; orderBuffer = nil; harmonicsBuffer = nil; pipeline = nil; queue = nil
    }
}
