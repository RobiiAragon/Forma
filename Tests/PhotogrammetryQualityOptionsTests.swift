import XCTest
import RealityKit
@testable import Forma

final class PhotogrammetryQualityOptionsTests: XCTestCase {
    func testSelectedSettingsReachNativeConfiguration() {
        var configuration = PhotogrammetrySession.Configuration()
        let options = PhotogrammetryQualityOptions(highSensitivity: true, objectMasking: false, sequentialOrdering: false)
        options.apply(to: &configuration)
        XCTAssertEqual(configuration.featureSensitivity, .high)
        XCTAssertFalse(configuration.isObjectMaskingEnabled)
        XCTAssertEqual(configuration.sampleOrdering, .unordered)
        XCTAssertEqual(options.statistics["photogrammetryHighSensitivity"], 1)
        XCTAssertEqual(options.statistics["photogrammetryObjectMasking"], 0)
    }

    func testEveryConfigurationGetsAnIndependentCheckpointKey() {
        var keys = Set<String>()
        for sensitivity in [false, true] {
            for masking in [false, true] {
                for ordering in [false, true] {
                    keys.insert(PhotogrammetryQualityOptions(highSensitivity: sensitivity, objectMasking: masking, sequentialOrdering: ordering).checkpointKey)
                }
            }
        }
        XCTAssertEqual(keys.count, 8)
    }
}
