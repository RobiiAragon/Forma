import XCTest
@testable import Forma

final class GaussianTrainingPresetTests: XCTestCase {
    func testResumeShortcutPreservesExactCustomScaleText() {
        for preset in GaussianTrainingPreset.allCases {
            var iterations = "30000"
            var downscale = "1,25"
            preset.apply(iterations: &iterations, downscale: &downscale, preservingScale: true)
            XCTAssertEqual(downscale, "1,25", "A shortcut must not change a checkpoint's resolution")
            XCTAssertEqual(Int(iterations), preset.iterations)
        }
    }

    func testNewRunShortcutsUseSupportedNativeControls() {
        for preset in GaussianTrainingPreset.allCases {
            var iterations = "1"
            var downscale = "8"
            preset.apply(iterations: &iterations, downscale: &downscale, preservingScale: false)
            XCTAssertGreaterThan(Int(iterations) ?? 0, 0)
            XCTAssertGreaterThanOrEqual(Float(downscale) ?? 0, 1)
            XCTAssertEqual(Float(downscale), preset.downscale)
        }
    }
}
