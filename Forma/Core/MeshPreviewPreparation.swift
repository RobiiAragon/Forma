import Foundation
import SceneKit
import simd
import QuartzCore

enum MeshPreviewTextureMode: String, CaseIterable, Identifiable, Sendable {
    case lightweight, original
    var id: String { rawValue }
    var title: String { self == .original ? "Textura original" : "Textura ligera" }
}

/// Import/preparation is serialized to avoid two closing/opening views decoding
/// full texture sets simultaneously. SceneKit's progress handler also gets aborts.
enum MeshPreviewPreparation {
    static let queue = DispatchQueue(label: "com.forma.mesh-viewer",qos: .userInitiated)

    struct Prepared {
        var content: SCNNode
        var low: SIMD3<Float>
        var high: SIMD3<Float>
        var materialSets: [MeshPreviewMaterials]
        var loadSeconds: TimeInterval = 0
        var preparationSeconds: TimeInterval = 0
        var texturePreviewAdapted = false
        var sourceURL: URL? = nil
    }

    static func load(url: URL, textureMode: MeshPreviewTextureMode = .lightweight,
                     texturePreviewBudgetBytes: UInt64? = nil,
                     checkCancellation: @escaping () throws -> Void) throws -> Prepared {
        try checkCancellation()
        let started = CACurrentMediaTime()
        // Original is an explicit direct import. It never consults the proxy's
        // resource estimate, generates thumbnails or substitutes asset URLs.
        let proxy: TexturePreviewProxy.Result
        if textureMode == .original { proxy = .init(url: url, adapted: false) }
        else { proxy = try TexturePreviewProxy.prepare(url, budgetBytes: texturePreviewBudgetBytes, checkCancellation: checkCancellation) }
        guard let source = SCNSceneSource(url: proxy.url,options: nil) else {
            throw failure("SceneKit no pudo leer el archivo del modelo.")
        }
        var loadingError: Error?
        let scene = source.scene(options: [.convertUnitsToMeters: NSNumber(value: 1),.convertToYUp: true]) { _,_,error,abort in
            if let error { loadingError = error }
            do { try checkCancellation() }
            catch { loadingError = error; abort.pointee = true }
        }
        try checkCancellation()
        guard let scene else { throw loadingError ?? failure("El modelo no contiene una escena válida.") }
        if url.pathExtension.lowercased() == "obj" {
            _ = try ImportedMeshBatching.consolidate(in: scene, checkCancellation: checkCancellation)
        }
        // Resolve file maps before detaching nodes from their imported scene.
        // A disposable viewer proxy has a different asset directory from its source.
        scene.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.materials.forEach { material in
                if let path = material.diffuse.contents as? String,
                   !path.hasPrefix("/"), URL(string: path)?.scheme == nil {
                    let texture = proxy.url.deletingLastPathComponent().appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: texture.path) { material.diffuse.contents = texture }
                }
            }
        }
        let importedAt = CACurrentMediaTime()
        var prepared = try prepare(scene,isOBJ: url.pathExtension.lowercased() == "obj",checkCancellation: checkCancellation)
        prepared.loadSeconds = importedAt-started
        prepared.preparationSeconds = CACurrentMediaTime()-importedAt
        prepared.texturePreviewAdapted = proxy.adapted
        prepared.sourceURL = proxy.url
        return prepared
    }

    static func prepare(_ scene: SCNScene,isOBJ: Bool,checkCancellation: () throws -> Void = {}) throws -> Prepared {
        try checkCancellation()
        // Keep the complete hierarchy/transforms. Clone once on the worker,
        // sharing original geometry/image storage rather than flattening it.
        let content = SCNNode()
        content.addChildNode(scene.rootNode.clone())
        var hasSurface = false, cancelled = false
        var seen = Set<ObjectIdentifier>()
        var materialSets: [MeshPreviewMaterials] = []
        content.enumerateChildNodes { node,stop in
            do { try checkCancellation() }
            catch { cancelled = true; stop.pointee = true; return }
            node.categoryBitMask = 1
            node.camera = nil; node.light = nil
            guard let geometry = node.geometry,geometry.elementCount > 0,
                  geometry.sources(for: .vertex).contains(where: { $0.vectorCount > 0 }) else { return }
            hasSurface = true
            guard seen.insert(ObjectIdentifier(geometry)).inserted else { return }
            let photographic = geometry.materials.contains { hasPhotograph($0) }
            let authored = photographic || geometry.materials.contains { !($0.name ?? "").isEmpty }
            if (isOBJ && !authored) || geometry.materials.isEmpty {
                let material = SCNMaterial()
                #if os(iOS)
                material.diffuse.contents = UIColor(red: 1,green: 0.36,blue: 0.18,alpha: 1)
                #else
                material.diffuse.contents = NSColor(red: 1,green: 0.36,blue: 0.18,alpha: 1)
                #endif
                material.lightingModel = .physicallyBased
                material.roughness.contents = 0.6; material.metalness.contents = 0.05
                geometry.materials = [material]
            }
            geometry.materials.forEach {
                $0.isDoubleSided = false; $0.cullMode = .back
                if isOBJ && hasPhotograph($0) {
                    $0.lightingModel = .constant
                    #if os(iOS)
                    $0.emission.contents = UIColor.black
                    #else
                    $0.emission.contents = NSColor.black
                    #endif
                }
            }
            materialSets.append(MeshPreviewMaterials(geometry: geometry))
        }
        if cancelled { try checkCancellation(); throw CancellationError() }
        try checkCancellation()
        let bounds = content.boundingBox
        let low = SIMD3<Float>(Float(bounds.min.x),Float(bounds.min.y),Float(bounds.min.z))
        let high = SIMD3<Float>(Float(bounds.max.x),Float(bounds.max.y),Float(bounds.max.z))
        let extent = high-low
        let largest = max(extent.x,max(extent.y,extent.z))
        guard hasSurface,low.x.isFinite,low.y.isFinite,low.z.isFinite,
              high.x.isFinite,high.y.isFinite,high.z.isFinite,largest.isFinite,largest > 0,
              (2.4/largest).isFinite else {
            throw failure("El archivo no contiene superficies 3D visibles con dimensiones válidas.")
        }
        return Prepared(content: content,low: low,high: high,materialSets: materialSets)
    }

    private static func hasPhotograph(_ material: SCNMaterial) -> Bool {
        #if os(iOS)
        let isImage = material.diffuse.contents is UIImage
        #else
        let isImage = material.diffuse.contents is NSImage
        #endif
        return isImage || material.diffuse.contents is URL || material.diffuse.contents is String
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "FormaMeshPreview",code: 1,userInfo: [NSLocalizedDescriptionKey:text])
    }
}

/// Two reusable appearances per unique geometry. Switching texture/solid/wireframe
/// never recopies geometry or an image and does not clone every material per toggle.
final class MeshPreviewMaterials {
    let geometry: SCNGeometry
    let textured: [SCNMaterial]
    private var solid: [SCNMaterial]?

    init(geometry: SCNGeometry) {
        self.geometry = geometry
        textured = geometry.materials.map { $0.copy() as! SCNMaterial }
    }

    @MainActor
    func apply(wireframe: Bool,showTexture: Bool) {
        let materials: [SCNMaterial]
        if showTexture { materials = textured }
        else if let solid { materials = solid }
        else {
            let neutral = textured.map { original -> SCNMaterial in
                let material = original.copy() as! SCNMaterial
                #if os(iOS)
                material.diffuse.contents = UIColor(white: 0.72,alpha: 1)
                #else
                material.diffuse.contents = NSColor(white: 0.72,alpha: 1)
                #endif
                material.lightingModel = .lambert
                material.normal.contents = nil
                material.displacement.contents = nil
                material.ambientOcclusion.contents = nil
                material.emission.contents = nil
                material.multiply.contents = nil
                material.metalness.contents = 0; material.roughness.contents = 0.85
                return material
            }
            solid = neutral; materials = neutral
        }
        for material in materials {
            material.fillMode = wireframe ? .lines : .fill
            material.isDoubleSided = false; material.cullMode = .back
        }
        let current = geometry.materials
        if current.count != materials.count || zip(current,materials).contains(where: { $0 !== $1 }) {
            geometry.materials = materials
        }
    }
}
