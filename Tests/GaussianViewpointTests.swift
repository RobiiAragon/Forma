import XCTest
import simd
@testable import Forma

final class GaussianViewpointTests: XCTestCase {
    func testOffCenterIntrinsicsMapNativePixelCentersIntoAspectFitMetalViewport() throws {
        let view = try GaussianViewpoint(frame: frame())
        let pixels: [SIMD2<Float>] = [SIMD2(0,0),SIMD2(799,0),SIMD2(0,599),SIMD2(799,599),SIMD2(370.25,281.75)]
        for viewport in [SIMD2<Float>(1200,900), SIMD2<Float>(900,1200)] {
            let projection = try view.projection(viewport: viewport, near: 0.01, far: 100)
            let scale = min(viewport.x / 800, viewport.y / 600)
            XCTAssertEqual(projection.focalPixels.x, 650 * scale, accuracy: 0.0001)
            XCTAssertEqual(projection.focalPixels.y, 660 * scale, accuracy: 0.0001)
            for pixel in pixels {
                let camera = cameraPoint(pixel, view: view)
                let clip = projection.matrix * SIMD4(camera, 1)
                let drawable = projection.viewportOrigin + SIMD2((clip.x / clip.w + 1) * 0.5,
                    (1 - clip.y / clip.w) * 0.5) * projection.viewportSize
                let expected = projection.viewportOrigin + (pixel + SIMD2(repeating: 0.5)) * scale
                XCTAssertEqual(drawable.x, expected.x, accuracy: 0.0002)
                XCTAssertEqual(drawable.y, expected.y, accuracy: 0.0002)
                let world = view.cameraToWorld * SIMD4(camera, 1)
                let native = try XCTUnwrap(view.project(worldPoint: SIMD3(world.x,world.y,world.z)))
                XCTAssertEqual(native.pixel.x, pixel.x, accuracy: 0.002)
                XCTAssertEqual(native.pixel.y, pixel.y, accuracy: 0.002)
            }
            for (depth, expected) in [(Float(0.01), Float(0)), (Float(100), Float(1))] {
                let clip = projection.matrix * SIMD4<Float>(0,0,-depth,1)
                XCTAssertEqual(clip.z / clip.w, expected, accuracy: 0.00001, "Metal depth range is 0...1")
            }
        }
    }

    func testQuarterTurnsPreserveAllCornerWorldRaysAndSourceIdentity() throws {
        let view = try GaussianViewpoint(frame: frame(), sourceFrameIndex: 17)
        let pixels: [SIMD2<Float>] = [SIMD2(0,0),SIMD2(799,0),SIMD2(0,599),SIMD2(799,599),SIMD2(370.25,281.75)]
        for turns in -4...7 {
            let rotated = try view.rotatedForPresentation(quarterTurns: turns)
            let count = (turns % 4 + 4) % 4
            XCTAssertEqual(rotated.frameID, view.frameID)
            XCTAssertEqual(rotated.sourceFrameIndex, 17)
            XCTAssertEqual(rotated.rgbFile, view.rgbFile)
            XCTAssertEqual(rotated.position, view.position)
            XCTAssertEqual(rotated.backward, view.backward)
            XCTAssertEqual(rotated.presentationQuarterTurns, count)
            XCTAssertEqual(rotated.imageWidth, count.isMultiple(of: 2) ? 800 : 600)
            XCTAssertEqual(rotated.imageHeight, count.isMultiple(of: 2) ? 600 : 800)
            for pixel in pixels {
                let world = view.cameraToWorld * SIMD4(cameraPoint(pixel, view: view), 1)
                var expected = pixel, width = 800, height = 600
                for _ in 0..<count {
                    expected = SIMD2(Float(height - 1) - expected.y, expected.x)
                    swap(&width, &height)
                }
                let actual = try XCTUnwrap(rotated.project(worldPoint: SIMD3(world.x,world.y,world.z)))
                XCTAssertEqual(actual.pixel.x, expected.x, accuracy: 0.002)
                XCTAssertEqual(actual.pixel.y, expected.y, accuracy: 0.002)
                let projection = try rotated.projection(viewport: SIMD2(1200,900), near: 0.01, far: 100)
                let clip = projection.matrix * rotated.viewMatrix * world
                let position = projection.viewportOrigin + SIMD2((clip.x / clip.w + 1) / 2, (1 - clip.y / clip.w) / 2) * projection.viewportSize
                let scale = min(Float(1200) / Float(width), Float(900) / Float(height))
                XCTAssertEqual(position.x, projection.viewportOrigin.x + (expected.x + 0.5) * scale, accuracy: 0.003)
                XCTAssertEqual(position.y, projection.viewportOrigin.y + (expected.y + 0.5) * scale, accuracy: 0.003)
            }
        }
    }

    func testUprightPresentationMaximizesWorldUpWithoutMovingTheCamera() throws {
        var record = frame()
        let roll = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(0,0,1)))
        record.cameraToWorld = (0..<4).flatMap { column in (0..<4).map { roll[column][$0] } }
        let native = try GaussianViewpoint(frame: record)
        let upright = try native.uprightPresentation
        XCTAssertEqual(upright.up.y, 1, accuracy: 0.00001)
        XCTAssertEqual(upright.presentationQuarterTurns, 1)
        XCTAssertEqual(upright.position, native.position)
        XCTAssertEqual(upright.backward, native.backward)
        XCTAssertEqual(try upright.uprightPresentation.presentationQuarterTurns, upright.presentationQuarterTurns)
    }

    func testSequencePreservesEveryObservationAndStableTimestampTies() throws {
        var later = frame(); later.id = "later"; later.timestamp = 4
        var first = frame(); first.id = "tie"; first.timestamp = 1
        let second = first // Duplicate identity is retained, not silently deduplicated.
        let views = try GaussianViewpoint.views(in: .init(createdAt: Date(), frames: [later,first,second]))
        XCTAssertEqual(views.map(\.frameID), ["tie","tie","later"])
        XCTAssertEqual(views.map(\.sourceFrameIndex), [1,2,0])
        XCTAssertEqual(GaussianViewpoint.nextIndex(after: 0, count: 3), 1)
        XCTAssertEqual(GaussianViewpoint.previousIndex(before: 2, count: 3), 1)
        XCTAssertNil(GaussianViewpoint.previousIndex(before: 0, count: 3))
        XCTAssertNil(GaussianViewpoint.nextIndex(after: 2, count: 3))
        XCTAssertNil(GaussianViewpoint.nextIndex(after: Int.max, count: Int.max))
        XCTAssertEqual(try GaussianViewpoint.views(in: .init(createdAt: Date(), frames: [])).count, 0)
    }

    func testMalformedPoseIsExplicitlyRejectedWithoutSkippingAnotherObservation() throws {
        var broken = frame(); broken.id = "broken-calibration"; broken.cameraToWorld[0] = .nan
        XCTAssertThrowsError(try GaussianViewpoint.views(in: .init(createdAt: Date(), frames: [frame(),broken]))) {
            XCTAssertTrue($0.localizedDescription.contains("broken-calibration"))
        }
        var reflected = frame(); reflected.cameraToWorld[0] *= -1; reflected.cameraToWorld[1] *= -1; reflected.cameraToWorld[2] *= -1
        XCTAssertThrowsError(try GaussianViewpoint(frame: reflected))
        let view = try GaussianViewpoint(frame: frame())
        XCTAssertThrowsError(try view.projection(viewport: SIMD2(0,900), near: 0.01, far: 10))
        XCTAssertThrowsError(try view.projection(viewport: SIMD2(1200,900), near: 10, far: 0.01))
        XCTAssertThrowsError(try view.projection(viewport: SIMD2(1200,900), near: 0.01, far: 10, zoom: .infinity))
    }

    private func cameraPoint(_ pixel: SIMD2<Float>, view: GaussianViewpoint) -> SIMD3<Float> {
        let ray = simd_inverse(view.intrinsics) * SIMD3(pixel, 1)
        return SIMD3(ray.x, -ray.y, -ray.z) * 2
    }
    private func frame() -> RGBDFrameRecord {
        var pose = simd_float4x4(simd_quatf(angle: 0.73, axis: simd_normalize(SIMD3<Float>(1,2,3))))
        pose.columns.3 = SIMD4(2,-1,4,1)
        return RGBDFrameRecord(id: "authored-view", timestamp: 1, rgbFile: "images/authored.png", imageWidth: 800, imageHeight: 600,
            cameraToWorld: (0..<4).flatMap { column in (0..<4).map { pose[column][$0] } },
            intrinsics: [650,0.2,0, 1.5,660,0, 370.25,281.75,1], source: "authored fixture",
            exposureDuration: nil, exposureOffset: nil)
    }
}
