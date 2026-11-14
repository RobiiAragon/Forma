import SwiftUI
import MetalKit

/// iPhone wrapper around the shared complete SH3 Metal renderer.
struct GaussianPreview: UIViewRepresentable {
    var modelURL: URL
    var resetRequest: UUID? = nil
    var onPerformanceUpdate: ((ViewerPerformanceSnapshot) -> Void)? = nil
    var captureDatasetURL: URL? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.055, green: 0.06, blue: 0.067, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isOpaque = true
        view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        view.accessibilityIdentifier = "gaussianPreview"
        context.coordinator.attach(view,url: modelURL)
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        view.preferredFramesPerSecond = view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        context.coordinator.renderer.update(url: modelURL,resetRequest: resetRequest,onPerformanceUpdate: onPerformanceUpdate,
                                            captureDatasetURL: captureDatasetURL)
    }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.renderer.stop(); view.delegate = nil
    }

    @MainActor final class Coordinator: NSObject {
        let renderer = GaussianMetalRenderer()
        private var previousPan = CGPoint.zero
        func attach(_ view: MTKView,url: URL) {
            let label = UILabel()
            label.text = "Cargando Gaussian 3D…"
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            label.font = .preferredFont(forTextStyle: .caption1)
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            label.layer.cornerRadius = 10; label.layer.masksToBounds = true
            label.accessibilityIdentifier = "gaussianViewerStatus"
            view.addSubview(label)
            NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                label.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
            func button(_ title: String, _ action: Selector) -> UIButton {
                let button = UIButton(type: .system)
                button.configuration = .tinted(); button.setTitle(title, for: .normal)
                button.addTarget(self, action: action, for: .touchUpInside)
                return button
            }
            let previous = button("‹", #selector(previousView))
            let captured = button("Capturada", #selector(capturedView))
            let overview = button("General", #selector(overview))
            let next = button("›", #selector(nextView))
            previous.accessibilityLabel = "Vista capturada anterior"; next.accessibilityLabel = "Vista capturada siguiente"
            let controls = UIStackView(arrangedSubviews: [previous, captured, overview, next])
            controls.spacing = 6; controls.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controls)
            NSLayoutConstraint.activate([controls.topAnchor.constraint(equalTo: label.bottomAnchor,constant: 8),
                controls.centerXAnchor.constraint(equalTo: view.centerXAnchor)])
            previous.isEnabled = false; next.isEnabled = false; captured.isEnabled = false
            renderer.onViewpointChange = { [weak previous, weak next, weak captured] count, index in
                previous?.isEnabled = (index ?? 0) > 0
                next?.isEnabled = count > 0 && (index ?? 0) < count - 1
                captured?.isEnabled = count > 0
            }
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self,action: #selector(pan(_:))))
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self,action: #selector(pinch(_:))))
            renderer.attach(view,url: url) { [weak label] in label?.text = $0 }
        }
        @objc private func previousView() { renderer.previousCapturedView() }
        @objc private func nextView() { renderer.nextCapturedView() }
        @objc private func capturedView() { renderer.showCapturedView() }
        @objc private func overview() { renderer.showOverview() }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            let point = gesture.translation(in: gesture.view)
            if gesture.state == .began { previousPan = point }
            renderer.orbit(deltaX: Float(point.x-previousPan.x),deltaY: Float(point.y-previousPan.y))
            previousPan = point
        }
        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            renderer.zoom(scale: Float(gesture.scale)); gesture.scale = 1
        }
    }
}
