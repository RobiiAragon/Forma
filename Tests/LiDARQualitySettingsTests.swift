import XCTest
@testable import Forma

final class LiDARQualitySettingsTests: XCTestCase {
    func testDenseSamplingChangesPoseThresholdsAndManifestRoundTrips() throws {
        var settings = LiDARQualitySettings()
        let original = settings.translationBetweenPhotos
        settings.densePhotographs = true
        settings.nativePlaneAssistance = true
        settings.correctPlanarNoise = true
        settings.planarToleranceMeters = 0.004
        XCTAssertEqual(settings.translationBetweenPhotos, original / 2)
        XCTAssertEqual(settings.angleBetweenPhotos, Float(0.035))
        XCTAssertTrue(settings.planarConfiguration.enabled)
        XCTAssertEqual(settings.planarConfiguration.toleranceMeters, 0.004, accuracy: 1e-8)
        let manifest = RGBDDatasetManifest(createdAt: Date(), frames: [], lidarQuality: settings)
        let restored = try JSONDecoder().decode(RGBDDatasetManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(restored.lidarQuality, settings)
    }

    func testOldManifestDoesNotInventNewOptionsAndInvalidToleranceIsRejected() throws {
        let old = Data("{\"createdAt\":0,\"schemaVersion\":1,\"units\":\"meters\",\"matrixLayout\":\"columnMajor\",\"cameraConvention\":\"ARKit\",\"frames\":[]}".utf8)
        XCTAssertNil(try JSONDecoder().decode(RGBDDatasetManifest.self, from: old).lidarQuality)
        for invalid: Float in [0, -1, .nan, .infinity] {
            var settings = LiDARQualitySettings(); settings.planarToleranceMeters = invalid
            XCTAssertThrowsError(try settings.validate())
        }
    }
}
