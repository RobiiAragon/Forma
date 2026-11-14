import SwiftUI
import SceneKit

struct MeshPreview: UIViewRepresentable {
    var modelURL: URL? = nil
    var mesh: MeshSnapshot? = nil
    var decorative = false
    var wireframe = false

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.scene = SCNScene()
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = !decorative
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        let scene = view.scene!
        let source: SCNNode
        if let modelURL, let imported = try? SCNScene(url: modelURL, options: nil) {
            source = imported.rootNode.clone()
        } else if let mesh {
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })],
                elements: [SCNGeometryElement(indices: mesh.triangles, primitiveType: .triangles)])
            source = SCNNode(geometry: geometry)
        } else { source = SCNNode() }
        let (lo, hi) = source.boundingBox
        let center = SCNVector3((lo.x+hi.x)*0.5, (lo.y+hi.y)*0.5, (lo.z+hi.z)*0.5)
        let extent = max(hi.x-lo.x, max(hi.y-lo.y, hi.z-lo.z))
        let normalizer = SCNNode()
        source.position = SCNVector3(-center.x, -center.y, -center.z)
        normalizer.addChildNode(source)
        let scale: Float = extent > 0 ? 2.4/extent : 1
        normalizer.scale = SCNVector3(scale, scale, scale)
        scene.rootNode.addChildNode(normalizer)
        let orange = UIColor(red: 1, green: 0.36, blue: 0.18, alpha: 1)
        if mesh != nil || decorative {
            source.enumerateChildNodes { node, _ in Self.style(node, color: orange) }
            Self.style(source, color: orange)
        }
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 100
        camera.position = SCNVector3(0, 0.1, 4.7)
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .omni; key.light?.intensity = 1100
        key.position = SCNVector3(-3, 4, 5)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight(); fill.light?.type = .ambient; fill.light?.intensity = 450
        fill.light?.color = UIColor(red: 0.55, green: 0.62, blue: 0.72, alpha: 1)
        scene.rootNode.addChildNode(fill)
        if decorative {
            normalizer.eulerAngles = SCNVector3(-0.3, 0.1, 0.4)
            if !UIAccessibility.isReduceMotionEnabled {
                normalizer.runAction(.repeatForever(.rotateBy(x: 0, y: .pi*2, z: 0, duration: 40)))
            }
        }
        view.accessibilityLabel = decorative ? "Escultura geométrica decorativa" : "Visor 3D. Arrastra para girar; pellizca para ampliar."
        return view
    }

    private static func style(_ node: SCNNode, color: UIColor) {
        guard let geometry = node.geometry else { return }
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.4
        material.metalness.contents = 0.25
        material.isDoubleSided = false
        material.cullMode = .back
        geometry.materials = [material]
    }

    func updateUIView(_ view: SCNView, context: Context) {
        view.scene?.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.materials.forEach { $0.fillMode = wireframe ? .lines : .fill }
        }
    }
    static func dismantleUIView(_ view: SCNView, coordinator: ()) {
        view.scene?.rootNode.removeAllActions()
        view.scene?.rootNode.enumerateChildNodes { node, _ in node.removeAllActions() }
        view.isPlaying = false
        view.scene = nil
    }
}
