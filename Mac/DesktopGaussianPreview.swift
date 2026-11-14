import SwiftUI
import MetalKit

/// Uses every point and all SH3 bands from the exported PLY, matching iPhone.
struct DesktopGaussianPreview: NSViewRepresentable {
    var modelURL: URL
    var resetRequest: UUID? = nil
    var targetFPS = 120
    var onPerformanceUpdate: ((ViewerPerformanceSnapshot) -> Void)? = nil
    var captureDatasetURL: URL? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTKView {
        let view = GaussianInteractionMTKView(frame: .zero,device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.055,green: 0.06,blue: 0.067,alpha: 1)
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.setAccessibilityIdentifier("desktopGaussianPreview")
        context.coordinator.attach(view,url: modelURL)
        return view
    }
    func updateNSView(_ view: MTKView,context: Context) {
        view.preferredFramesPerSecond = min(targetFPS,view.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        context.coordinator.renderer.update(url: modelURL,resetRequest: resetRequest,onPerformanceUpdate: onPerformanceUpdate,
                                            captureDatasetURL: captureDatasetURL)
    }
    static func dismantleNSView(_ view: MTKView,coordinator: Coordinator) {
        coordinator.renderer.stop(); view.delegate = nil
        (view as? GaussianInteractionMTKView)?.onScroll = nil
    }

    @MainActor final class Coordinator: NSObject {
        let renderer = GaussianMetalRenderer()
        private var previousPan = CGPoint.zero
        func attach(_ view: GaussianInteractionMTKView,url: URL) {
            let label = NSTextField(labelWithString: "Cargando Gaussian 3D…")
            label.textColor = .white
            label.backgroundColor = NSColor.black.withAlphaComponent(0.65); label.drawsBackground = true
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.maximumNumberOfLines = 0; label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            label.wantsLayer = true; label.layer?.cornerRadius = 10
            label.setAccessibilityIdentifier("gaussianViewerStatus")
            view.addSubview(label)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.topAnchor,constant: 12),
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor,constant: 12),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor,constant: -12),
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
            let previous = NSButton(title: "‹", target: self, action: #selector(previousView))
            let captured = NSButton(title: "Vista capturada", target: self, action: #selector(capturedView))
            let overview = NSButton(title: "General", target: self, action: #selector(overview))
            let next = NSButton(title: "›", target: self, action: #selector(nextView))
            previous.setAccessibilityLabel("Vista capturada anterior"); next.setAccessibilityLabel("Vista capturada siguiente")
            let controls = NSStackView(views: [previous, captured, overview, next])
            controls.spacing = 8; controls.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controls)
            NSLayoutConstraint.activate([controls.topAnchor.constraint(equalTo: label.bottomAnchor,constant: 8),
                controls.centerXAnchor.constraint(equalTo: view.centerXAnchor)])
            previous.isEnabled = false; next.isEnabled = false; captured.isEnabled = false
            renderer.onViewpointChange = { [weak previous, weak next, weak captured] count, index in
                previous?.isEnabled = (index ?? 0) > 0
                next?.isEnabled = count > 0 && (index ?? 0) < count - 1
                captured?.isEnabled = count > 0
            }
            view.addGestureRecognizer(NSPanGestureRecognizer(target: self,action: #selector(pan(_:))))
            view.addGestureRecognizer(NSMagnificationGestureRecognizer(target: self,action: #selector(magnify(_:))))
            view.onScroll = { [weak self] amount,precise in
                self?.renderer.zoom(scale: Float(exp(amount * (precise ? 0.01 : 0.08))))
            }
            renderer.attach(view,url: url) { [weak label] text in
                label?.stringValue = text.replacingOccurrences(of: "Pellizca para ampliar",with: "Pellizca o usa la rueda para ampliar")
            }
        }
        @objc private func previousView() { renderer.previousCapturedView() }
        @objc private func nextView() { renderer.nextCapturedView() }
        @objc private func capturedView() { renderer.showCapturedView() }
        @objc private func overview() { renderer.showOverview() }
        @objc private func pan(_ gesture: NSPanGestureRecognizer) {
            let point = gesture.translation(in: gesture.view)
            if gesture.state == .began { previousPan = point }
            renderer.orbit(deltaX: Float(point.x-previousPan.x),deltaY: -Float(point.y-previousPan.y))
            previousPan = point
        }
        @objc private func magnify(_ gesture: NSMagnificationGestureRecognizer) {
            renderer.zoom(scale: Float(1+gesture.magnification)); gesture.magnification = 0
        }
    }
}

@MainActor final class GaussianInteractionMTKView: MTKView {
    var onScroll: ((CGFloat,Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY,event.hasPreciseScrollingDeltas)
    }
}
