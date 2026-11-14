import XCTest
import simd
@testable import Forma

final class PhotometricHarmonizerTests: XCTestCase {
    func testKnownExposureRecoversRelativeBrightnessAndKeepsActualReferenceUnchanged() throws {
        let link = try XCTUnwrap(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: pairs(firstExposure: 1, secondExposure: 0.5)))
        let result = try PhotometricHarmonizer.harmonize(frameIndices: [0, 1], links: [link])
        XCTAssertEqual(result.gains[0] ?? 0, 0.5, accuracy: 0.002)
        XCTAssertEqual(result.gains[1], 1, "The darker observed photograph is the unchanged reference")
        XCTAssertEqual(result.referenceFrames, [1])
        XCTAssertEqual(result.adjustedPhotoCount, 1)
        XCTAssertLessThan(result.seamRMSEAfter, result.seamRMSEBefore * 0.01)
        XCTAssertLessThan(result.seamLogRMSEAfter, result.seamLogRMSEBefore * 0.01,
                          "Relative error must improve; darkening alone cannot satisfy this metric")
        XCTAssertTrue(result.gains.values.allSatisfy { $0 > 0 && $0 <= 1 })
        let original = SIMD3<Double>(0.32, 0.20, 0.08)
        let corrected = original * (result.gains[0] ?? 1)
        XCTAssertEqual(corrected.x / corrected.y, original.x / original.y, accuracy: 1e-12)
        XCTAssertEqual(corrected.z / corrected.y, original.z / original.y, accuracy: 1e-12)
    }

    func testIdenticalExposureProducesIdentityRatherThanAColorNeutralization() throws {
        let link = try XCTUnwrap(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: pairs(firstExposure: 1, secondExposure: 1)))
        let result = try PhotometricHarmonizer.harmonize(frameIndices: [0, 1], links: [link])
        XCTAssertEqual(result.gains, [0: 1, 1: 1])
        XCTAssertEqual(result.adjustedPhotoCount, 0)
        XCTAssertEqual(result.acceptedComponentCount, 0)
        XCTAssertEqual(result.seamLogRMSEAfter, result.seamLogRMSEBefore, accuracy: 1e-9)
    }

    func testDisconnectedPhotographsReceiveNoInventedCalibration() throws {
        let link = try XCTUnwrap(PhotometricHarmonizer.makeLink(first: 2, second: 3, pairs: pairs(firstExposure: 0.6, secondExposure: 1)))
        let result = try PhotometricHarmonizer.harmonize(frameIndices: [0, 1, 2, 3, 4], links: [link])
        XCTAssertEqual(result.gains[0], 1)
        XCTAssertEqual(result.gains[1], 1)
        XCTAssertEqual(result.gains[4], 1)
        XCTAssertEqual(result.gains[2], 1)
        XCTAssertEqual(result.gains[3] ?? 0, 0.6, accuracy: 0.002)
        XCTAssertEqual(result.referenceFrames, [2])
    }

    func testSparseDarkClippedOrInconsistentEvidenceCannotCreateALink() throws {
        XCTAssertNil(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: Array(pairs(firstExposure: 1, secondExposure: 0.5).prefix(5))))
        let invalid = (0..<30).map { i in
            PhotometricHarmonizer.ColorPair(first: SIMD3<Float>(repeating: i.isMultiple(of: 2) ? 0.001 : 1),
                                             second: SIMD3(repeating: 0.2), isValidation: i.isMultiple(of: 3))
        }
        XCTAssertNil(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: invalid))
        let inconsistent = (0..<30).map { i in
            PhotometricHarmonizer.ColorPair(first: SIMD3<Float>(repeating: i.isMultiple(of: 2) ? 0.1 : 0.5),
                                             second: SIMD3(repeating: 0.2), isValidation: i.isMultiple(of: 3))
        }
        XCTAssertNil(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: inconsistent))
    }

    func testMinorityOutliersDoNotShiftKnownExposure() throws {
        var observations = pairs(firstExposure: 1, secondExposure: 0.5)
        for _ in 0..<4 {
            observations.append(.init(first: SIMD3(repeating: 0.1), second: SIMD3(repeating: 0.7), isValidation: false))
        }
        let link = try XCTUnwrap(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: observations))
        XCTAssertEqual(link.sampleCount, 36)
        let result = try PhotometricHarmonizer.harmonize(frameIndices: [0, 1], links: [link])
        XCTAssertEqual(result.gains[0] ?? 0, 0.5, accuracy: 0.002)
    }

    func testHeldOutContradictionRejectsAdjustmentEvenWhenTrainingLooksPerfect() throws {
        var observations = pairs(firstExposure: 1, secondExposure: 0.5)
        for index in observations.indices where observations[index].isValidation {
            observations[index].second = observations[index].first * 2
        }
        let link = try XCTUnwrap(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: observations))
        let result = try PhotometricHarmonizer.harmonize(frameIndices: [0, 1], links: [link])
        XCTAssertEqual(result.gains, [0: 1, 1: 1])
        XCTAssertEqual(result.acceptedComponentCount, 0, "Reserved points cannot be filtered according to the fitted exposure")
    }

    func testExposurePropagatesOnlyAcrossSupportedGraphAndDoesNotClipHighlights() throws {
        let a = try XCTUnwrap(PhotometricHarmonizer.makeLink(first: 0, second: 1, pairs: pairs(firstExposure: 1, secondExposure: 0.75)))
        let b = try XCTUnwrap(PhotometricHarmonizer.makeLink(first: 1, second: 2, pairs: pairs(firstExposure: 0.75, secondExposure: 0.5)))
        let result = try PhotometricHarmonizer.harmonize(frameIndices: [0, 1, 2], links: [a, b])
        XCTAssertEqual(result.gains[2], 1)
        XCTAssertEqual(result.gains[0] ?? 0, 0.5, accuracy: 0.005)
        XCTAssertEqual(result.gains[1] ?? 0, 2.0 / 3, accuracy: 0.005)
        XCTAssertTrue(result.gains.values.allSatisfy { 0.99 * $0 <= 0.99 })
        XCTAssertLessThan(result.seamLogRMSEAfter, result.seamLogRMSEBefore * 0.02)
    }

    func testSRGBTransferUsesLinearLightRatherThanEncodedBrightnessRatios() {
        XCTAssertEqual(PhotometricHarmonizer.linearSRGB(0.5), 0.21404114, accuracy: 0.000001)
        for value in (0...255).map({ Float($0) / 255 }) {
            XCTAssertEqual(PhotometricHarmonizer.encodedSRGB(PhotometricHarmonizer.linearSRGB(value)), value, accuracy: 0.000002)
        }
    }

    private func pairs(firstExposure: Float, secondExposure: Float) -> [PhotometricHarmonizer.ColorPair] {
        (0..<36).map { index in
            let intensity = 0.5 + Float(index % 9) / 16
            // Spatially varying, colored albedo shared by both observations.
            let albedo = SIMD3<Float>(0.32, 0.20, 0.08) * intensity
            return .init(first: albedo * firstExposure, second: albedo * secondExposure,
                         isValidation: index.isMultiple(of: 3))
        }
    }
}
