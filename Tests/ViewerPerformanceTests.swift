import XCTest
import UIKit
import SceneKit
import simd
@testable import Forma

final class ViewerPerformanceTests: XCTestCase {
    func testAntialiasingUsesSupportedSamplesWithoutChangingModelResolution() {
        XCTAssertEqual(PreviewAntialiasing.sharp.supportedSamples { [1,2].contains($0) },2)
        XCTAssertEqual(PreviewAntialiasing.sharp.supportedSamples { [1,2,4,8].contains($0) },4)
        XCTAssertEqual(PreviewAntialiasing.fluid.supportedSamples { _ in true },1)
        XCTAssertEqual(PreviewAntialiasing.sharp.supportedSamples { _ in false },1)
        XCTAssertEqual(PreviewAntialiasing.sceneKitMode(samples: 1),.none)
        XCTAssertEqual(PreviewAntialiasing.sceneKitMode(samples: 4),.multisampling4X)
    }

    func testCadenceUsesObservedFramesAndShowsNoFPSDuringIdle() {
        let recorder = ViewerPerformanceRecorder(source: .sceneKitRender,startedAt: 100)
        recorder.loaded(loadSeconds: 0.04,preparationSeconds: 0.01)
        XCTAssertEqual(recorder.snapshot().frameCount,0)
        XCTAssertNil(recorder.snapshot().framesPerSecond)
        for index in 0..<31 { _ = recorder.frame(at: 100.1+Double(index)/60) }
        let active = recorder.snapshot()
        XCTAssertEqual(active.frameCount,31)
        XCTAssertEqual(active.readySeconds ?? 0,0.1,accuracy: 0.000001)
        XCTAssertEqual(active.activeFramesPerSecond(at: 100.7) ?? 0,60,accuracy: 0.001)
        XCTAssertNil(active.activeFramesPerSecond(at: 101.5),"An idle view must not advertise a synthetic display-link FPS")
        _ = recorder.frame(at: 100.6) // Duplicate callback timestamp.
        _ = recorder.frame(at: 0)
        XCTAssertEqual(recorder.snapshot().frameCount,31)
        _ = recorder.frame(at: 102)
        XCTAssertEqual(recorder.snapshot().frameCount,32)
        XCTAssertNil(recorder.snapshot().framesPerSecond,"A new burst starts a new cadence window")
    }

    func testExactRadixDepthOrderMatchesStableComparisonIncludingNegativeZeroAndTies() throws {
        let edges: [Float] = [-Float.greatestFiniteMagnitude,-100,-1,-Float.leastNonzeroMagnitude,-0.0,0.0,Float.leastNonzeroMagnitude,1,100,Float.greatestFiniteMagnitude]
        let edgePoints = (edges + edges.reversed()).map { point(SIMD3(0,0,$0)) }
        try assertMatchesComparison(edgePoints,direction: SIMD3(0,0,1))
        var state: UInt64 = 42
        func coordinate() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
        let points = (0..<32_768).map { _ in point(SIMD3(coordinate(),coordinate(),coordinate())) }
        for direction in [SIMD3<Float>(0,0,1),simd_normalize(SIMD3<Float>(1,2,3)),simd_normalize(SIMD3<Float>(-2,1,-3))] {
            try assertMatchesComparison(points,direction: direction)
        }
    }

    func testExactDepthOrderRejectsNonFiniteDepthAndCancelsInsideWork() throws {
        XCTAssertThrowsError(try GaussianDepthOrder.sortedIndices(points: [point(SIMD3(0,0,.nan))],direction: SIMD3(0,0,1)))
        let points = (0..<32_768).map { point(SIMD3(Float($0 % 17),0,Float($0 % 199))) }
        var checks = 0
        XCTAssertThrowsError(try GaussianDepthOrder.sortedIndices(points: points,direction: SIMD3(0,0,1)) {
            checks += 1
            if checks == 12 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks,12,"Cancellation must be polled during radix work, before publishing a partial order")
        XCTAssertThrowsError(try GaussianDepthOrder.workingBytes(pointCount: Int.max))
    }

    @MainActor
    func testMeshPreparationDeduplicatesMaterialWorkAndRestoresFullTextureWithoutCopies() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16,height: 16)).image {
            UIColor.red.setFill(); $0.fill(CGRect(x: 0,y: 0,width: 16,height: 16))
        }
        let material = SCNMaterial(); material.name = "authored-photograph"
        material.diffuse.contents = image; material.isDoubleSided = true; material.cullMode = .front
        material.emission.contents = UIColor.white // OBJ Ka must not wash out an unlit photograph.
        let geometry = SCNBox(width: 1,height: 2,length: 3,chamferRadius: 0)
        geometry.materials = [material]
        let scene = SCNScene()
        scene.rootNode.simdPosition = SIMD3(2,3,4)
        for index in 0..<512 {
            let node = SCNNode(geometry: geometry)
            node.name = "instance-\(index)"; node.simdPosition = SIMD3(Float(index),2,3)
            node.simdScale = SIMD3(2,3,4)
            scene.rootNode.addChildNode(node)
        }
        let originalCount = geometry.sources(for: .vertex)[0].vectorCount
        let originalMetric = scene.rootNode.childNodes[0].simdConvertPosition(SIMD3(0.1,0.2,0.3),to: nil)
        let prepared = try MeshPreviewPreparation.prepare(scene,isOBJ: true)
        XCTAssertEqual(prepared.materialSets.count,1,"Shared geometry must not clone the same material for every node")
        XCTAssertEqual(geometry.sources(for: .vertex)[0].vectorCount,originalCount)
        let first = try XCTUnwrap(prepared.content.childNode(withName: "instance-0",recursively: true))
        XCTAssertLessThan(simd_distance(first.simdConvertPosition(SIMD3(0.1,0.2,0.3),to: nil),originalMetric),0.00001)
        let materials = try XCTUnwrap(prepared.materialSets.first)
        materials.apply(wireframe: false,showTexture: true)
        let textured = try XCTUnwrap(geometry.materials.first)
        XCTAssertFalse(textured.isDoubleSided); XCTAssertEqual(textured.cullMode,.back)
        XCTAssertEqual(textured.lightingModel,.constant)
        XCTAssertEqual(textured.emission.contents as? UIColor, UIColor.black)
        let retainedImage = try XCTUnwrap(textured.diffuse.contents as? UIImage)
        XCTAssertEqual(retainedImage.pngData(),image.pngData(),"No texture pixels may be resized or discarded")
        materials.apply(wireframe: false,showTexture: false)
        let solid = try XCTUnwrap(geometry.materials.first)
        materials.apply(wireframe: true,showTexture: false)
        XCTAssertTrue(geometry.materials.first === solid)
        XCTAssertEqual(solid.fillMode,.lines)
        materials.apply(wireframe: false,showTexture: true)
        XCTAssertTrue(geometry.materials.first === textured,"Restoring appearance must reuse the original prepared material")
        XCTAssertEqual(textured.fillMode,.fill)
        XCTAssertEqual((textured.diffuse.contents as? UIImage)?.pngData(),image.pngData())
        XCTAssertThrowsError(try MeshPreviewPreparation.prepare(scene,isOBJ: true) { throw CancellationError() })
    }

    @MainActor
    func testRecenterReusesImportedSceneAndGeometryAndClearsResultCallbacks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Forma-ViewerReset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("authored.obj")
        try "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".write(to: url,atomically: true,encoding: .utf8)
        let view = SCNView(frame: CGRect(x: 0,y: 0,width: 480,height: 480))
        var distances: [Float?] = [], areas: [Float?] = []
        let coordinator = MeasurementPreview.Coordinator { distances.append($0) }
        coordinator.attach(view)
        defer { coordinator.stop() }
        coordinator.update(url: url,measuring: true,wireframe: false,onAreaMeasurement: { areas.append($0) },onMeasurement: { distances.append($0) })
        let deadline = Date().addingTimeInterval(5)
        while view.scene == nil,Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let scene = try XCTUnwrap(view.scene)
        var geometry: SCNGeometry?
        scene.rootNode.enumerateChildNodes { node,_ in if let value = node.geometry { geometry = value } }
        let originalGeometry = try XCTUnwrap(geometry)
        view.pointOfView?.position = SCNVector3(8,9,10)
        await Task.yield()
        let previousDistanceCallbacks = distances.count,previousAreaCallbacks = areas.count
        coordinator.update(url: url,measuring: true,wireframe: false,viewpoint: .front,resetRequest: UUID(),onAreaMeasurement: { areas.append($0) },onMeasurement: { distances.append($0) })
        await Task.yield()
        XCTAssertTrue(view.scene === scene,"Recenter must not reload a model or its textures")
        var retained = false
        scene.rootNode.enumerateChildNodes { node,_ in if node.geometry === originalGeometry { retained = true } }
        XCTAssertTrue(retained)
        XCTAssertEqual(view.pointOfView?.position.z,4.7)
        XCTAssertGreaterThan(distances.count,previousDistanceCallbacks)
        XCTAssertGreaterThan(areas.count,previousAreaCallbacks)
        XCTAssertNil(distances.last.flatMap { $0 }); XCTAssertNil(areas.last.flatMap { $0 })
        XCTAssertEqual(view.preferredFramesPerSecond,UIScreen.main.maximumFramesPerSecond)
    }

    private func point(_ position: SIMD3<Float>) -> GaussianPoint {
        GaussianPoint(positionOpacity: SIMD4(position,1),scale: SIMD4(1,1,1,0),rotation: SIMD4(0,0,0,1),color: SIMD4(1,1,1,1))
    }

    private func assertMatchesComparison(_ points: [GaussianPoint],direction: SIMD3<Float>,file: StaticString = #filePath,line: UInt = #line) throws {
        let depths = points.map { simd_dot(direction,SIMD3($0.positionOpacity.x,$0.positionOpacity.y,$0.positionOpacity.z)) }
        let expected = (0..<points.count).sorted {
            depths[$0] == depths[$1] ? $0 < $1 : depths[$0] < depths[$1]
        }.map { UInt32($0) }
        let actual = try GaussianDepthOrder.sortedIndices(points: points,direction: direction)
        XCTAssertEqual(actual,expected,file: file,line: line)
        XCTAssertEqual(Set(actual).count,points.count,"No Gaussian may be dropped",file: file,line: line)
    }
}
