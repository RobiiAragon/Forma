import Foundation
import SceneKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// OBJ import may create an element for every `usemtl` run (100,000+ in a
/// photographic room), despite sharing only a few materials. Consolidate opaque
/// runs without changing vertex, normal, UV or material data. Explicitly
/// transparent materials, strips, polygons and partial primitive ranges are
/// barriers: their elements retain their original order and representation.
enum ImportedMeshBatching {
    struct Statistics: Sendable {
        var geometryCount = 0
        var changedGeometryCount = 0
        var originalElementCount = 0
        var batchedElementCount = 0
        var primitiveCount = 0
    }
    private struct Key: Hashable {
        var material: ObjectIdentifier?
        var primitive: Int
        var indexBytes: Int
        var pointSize: UInt64
        var minimumPointRadius: UInt64
        var maximumPointRadius: UInt64
    }
    private struct Group {
        var head: SCNGeometryElement
        var material: SCNMaterial?
        var parts: [Data]
        var primitiveCount: Int
    }

    @discardableResult
    static func consolidate(in scene: SCNScene,
                            checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> Statistics {
        var nodes: [SCNNode] = [], stack = [scene.rootNode]
        var originals: [ObjectIdentifier: SCNGeometry] = [:]
        var protected = Set<ObjectIdentifier>()
        while let node = stack.popLast() {
            try checkCancellation()
            stack.append(contentsOf: node.childNodes)
            guard let geometry = node.geometry else { continue }
            nodes.append(node); originals[ObjectIdentifier(geometry)] = geometry
            if node.skinner != nil || node.morpher != nil { protected.insert(ObjectIdentifier(geometry)) }
        }
        var replacements: [ObjectIdentifier: SCNGeometry] = [:]
        var statistics = Statistics()
        statistics.geometryCount = originals.count
        for (id, geometry) in originals {
            try checkCancellation()
            statistics.originalElementCount += geometry.elementCount
            statistics.primitiveCount += geometry.elements.reduce(0) { $0 + $1.primitiveCount }
            if !protected.contains(id), let replacement = try consolidate(geometry, checkCancellation: checkCancellation) {
                replacements[id] = replacement
                statistics.changedGeometryCount += 1
                statistics.batchedElementCount += replacement.elementCount
            } else { statistics.batchedElementCount += geometry.elementCount }
        }
        // Build all replacements before publishing any. Cancellation during
        // preparation leaves the imported scene untouched.
        try checkCancellation()
        for node in nodes {
            if let geometry = node.geometry, let replacement = replacements[ObjectIdentifier(geometry)] { node.geometry = replacement }
        }
        return statistics
    }

    private static func consolidate(_ geometry: SCNGeometry, checkCancellation: () throws -> Void) throws -> SCNGeometry? {
        guard geometry.elementCount > 1 else { return nil }
        // SceneKit bridges these Objective-C arrays. Fetching a 100k-entry
        // materials array for every element can otherwise become quadratic.
        let sourceElements = geometry.elements
        let sourceMaterials = geometry.materials
        var groups: [Group] = [], indices: [Key: Int] = [:]
        var output: [SCNGeometryElement] = [], materials: [SCNMaterial] = []
        var merged = false
        func append(_ element: SCNGeometryElement, material: SCNMaterial?) {
            output.append(element); if let material { materials.append(material) }
        }
        func flush() throws {
            for group in groups {
                try checkCancellation()
                if group.parts.count == 1 { append(group.head, material: group.material); continue }
                var data = Data()
                for part in group.parts {
                    var position = part.startIndex
                    while position < part.endIndex {
                        try checkCancellation()
                        let end = min(part.endIndex, position + min(1_048_576, part.endIndex-position))
                        data.append(part[position..<end]); position = end
                    }
                }
                let element = SCNGeometryElement(data: data, primitiveType: group.head.primitiveType,
                    primitiveCount: group.primitiveCount, bytesPerIndex: group.head.bytesPerIndex)
                element.pointSize = group.head.pointSize
                element.minimumPointScreenSpaceRadius = group.head.minimumPointScreenSpaceRadius
                element.maximumPointScreenSpaceRadius = group.head.maximumPointScreenSpaceRadius
                append(element, material: group.material)
            }
            groups.removeAll(keepingCapacity: true); indices.removeAll(keepingCapacity: true)
        }
        for (offset, element) in sourceElements.enumerated() {
            try checkCancellation()
            let material = sourceMaterials.isEmpty ? nil : sourceMaterials[offset % sourceMaterials.count]
            guard let key = key(element, material: material) else {
                try flush(); append(element, material: material); continue
            }
            if let index = indices[key] {
                let (count, overflow) = groups[index].primitiveCount.addingReportingOverflow(element.primitiveCount)
                guard !overflow else { throw CocoaError(.fileReadCorruptFile) }
                groups[index].primitiveCount = count
                groups[index].parts.append(element.data); merged = true
            } else {
                indices[key] = groups.count
                groups.append(.init(head: element, material: material, parts: [element.data], primitiveCount: element.primitiveCount))
            }
        }
        try flush()
        guard merged else { return nil }
        let replacement = SCNGeometry(sources: geometry.sources, elements: output)
        replacement.name = geometry.name
        replacement.materials = materials
        replacement.boundingBox = geometry.boundingBox
        replacement.levelsOfDetail = geometry.levelsOfDetail
        replacement.subdivisionLevel = geometry.subdivisionLevel
        replacement.wantsAdaptiveSubdivision = geometry.wantsAdaptiveSubdivision
        replacement.edgeCreasesSource = geometry.edgeCreasesSource
        replacement.edgeCreasesElement = geometry.edgeCreasesElement
        replacement.tessellator = geometry.tessellator
        replacement.shaderModifiers = geometry.shaderModifiers
        replacement.program = geometry.program
        return replacement
    }

    private static func key(_ element: SCNGeometryElement, material: SCNMaterial?) -> Key? {
        let vertices: Int
        switch element.primitiveType {
        case .triangles: vertices = 3
        case .line: vertices = 2
        case .point: vertices = 1
        default: return nil // Concatenating strips/polygon headers changes topology.
        }
        guard element.primitiveCount > 0, [1,2,4].contains(element.bytesPerIndex),
              element.primitiveRange.location == NSNotFound || element.primitiveRange == NSRange(location: 0, length: element.primitiveCount),
              opaque(material) else { return nil }
        let (indices, firstOverflow) = element.primitiveCount.multipliedReportingOverflow(by: vertices)
        let (bytes, secondOverflow) = indices.multipliedReportingOverflow(by: element.bytesPerIndex)
        guard !firstOverflow, !secondOverflow, bytes == element.data.count,
              element.pointSize.isFinite, element.minimumPointScreenSpaceRadius.isFinite,
              element.maximumPointScreenSpaceRadius.isFinite else { return nil }
        return .init(material: material.map(ObjectIdentifier.init), primitive: element.primitiveType.rawValue,
            indexBytes: element.bytesPerIndex, pointSize: Double(element.pointSize).bitPattern,
            minimumPointRadius: Double(element.minimumPointScreenSpaceRadius).bitPattern,
            maximumPointRadius: Double(element.maximumPointScreenSpaceRadius).bitPattern)
    }

    private static func opaque(_ material: SCNMaterial?) -> Bool {
        guard let material else { return true }
        guard material.transparency >= 1, material.writesToDepthBuffer,
              material.blendMode == .alpha || material.blendMode == .replace else { return false }
        guard let contents = material.transparent.contents else { return true }
        if let value = contents as? NSNumber { return value.doubleValue >= 1 }
        #if os(iOS)
        if let color = contents as? UIColor { return color.cgColor.alpha >= 1 }
        #else
        if let color = contents as? NSColor { return color.alphaComponent >= 1 }
        #endif
        return false // Authored transparency maps keep their original order.
    }
}
