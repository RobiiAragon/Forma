import XCTest

final class FormaUITests: XCTestCase {
    func testPrimaryCaptureControlSupportsLargestDynamicType() throws {
        let app = XCUIApplication()
        app.launchEnvironment["FORMA_UI_TESTING"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let capture = app.buttons["startCapture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 10))
        for _ in 0..<4 where !capture.isHittable { app.swipeUp() }
        XCTAssertTrue(capture.isHittable)
        XCTAssertGreaterThanOrEqual(capture.frame.height, 44)
        XCTAssertGreaterThanOrEqual(capture.frame.width, 44)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Forma-largest-Dynamic-Type"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    func testLibraryDemoAndDeviceNavigation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["FORMA_UI_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["startCapture"].waitForExistence(timeout: 10))
        app.buttons["tab-2"].tap()
        XCTAssertTrue(app.staticTexts["Diagnóstico de capacidades".uppercased()].waitForExistence(timeout: 5))
        app.buttons["tab-1"].tap()
        XCTAssertTrue(app.staticTexts["Cada detalle\nempieza contigo."].waitForExistence(timeout: 5))
        app.buttons["tab-0"].tap()
        // The library can grow with capture modes and recoverable training sessions.
        // Bring its saved-model rows above the fixed bottom navigation before tapping.
        app.scrollViews.firstMatch.swipeUp()
        if app.buttons["demoScan"].exists { app.buttons["demoScan"].tap() }
        else {
            app.swipeUp()
            app.buttons["exploreDemo"].tap()
        }
        XCTAssertTrue(app.buttons["detailBack"].waitForExistence(timeout: 15))
        app.buttons["expandModel"].tap()
        XCTAssertTrue(app.buttons["studioClose"].waitForExistence(timeout: 8))
        app.buttons["studioPerformance"].tap()
        XCTAssertTrue(app.otherElements["studioPerformanceHUD"].waitForExistence(timeout: 5))
        app.buttons["studioAntialiasing"].tap()
        app.buttons["Fluido · sin suavizado"].tap()
        XCTAssertTrue(app.buttons["studioAntialiasing"].label.contains("Fluido"))
        app.buttons["studioAntialiasing"].tap()
        app.buttons["Nítido · 4×"].tap()
        app.buttons["studioPerformance"].tap()
        app.buttons["studioAppearance_wireframe"].tap()
        app.buttons["studioAppearance_solid"].tap()
        app.buttons["studioRecenter"].tap()
        app.buttons["studioViewpoint"].tap()
        app.buttons["Frontal"].tap()
        app.buttons["studioMeasure"].tap()
        XCTAssertTrue(app.segmentedControls["studioMeasurementMode"].waitForExistence(timeout: 5))
        app.segmentedControls["studioMeasurementMode"].buttons["Área plana"].tap()
        XCTAssertTrue(app.staticTexts["studioMeasurementResult"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["studioMeasurementResult"].label.contains("m²"))
        app.buttons["studioResetMeasurement"].tap()
        app.buttons["studioClose"].tap()
        XCTAssertTrue(app.switches["measureToggle"].waitForExistence(timeout: 5))
        app.switches["measureToggle"].tap()
        XCTAssertTrue(app.staticTexts["measurementResult"].waitForExistence(timeout: 5))
        app.switches["measureToggle"].tap()
        app.swipeUp()
        app.swipeUp()
        app.buttons["verifyIntegrity"].tap()
        XCTAssertTrue(app.staticTexts["integrityResult"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["integrityResult"].label.contains("coinciden"))
        app.swipeDown()
        app.swipeDown()
        app.buttons["detailBack"].tap()
        XCTAssertTrue(app.buttons["demoScan"].waitForExistence(timeout: 5))
    }

    func testSimulatorExplainsUnavailableCaptureWithoutSavingFakeData() throws {
        let app = XCUIApplication()
        app.launchEnvironment["FORMA_UI_TESTING"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["startCapture"].waitForExistence(timeout: 10))
        for (mode, message) in [("lidar", "LiDAR no disponible"), ("object", "Dispositivo no compatible"), ("room", "No se pudo crear el plano")] {
            app.buttons["mode-\(mode)"].tap()
            app.buttons["startCapture"].tap()
            if mode == "lidar" {
                XCTAssertTrue(app.buttons["chooseStandalone"].waitForExistence(timeout: 5))
                app.buttons["chooseStandalone"].tap()
                app.buttons["confirmCaptureExecution"].tap()
            }
            XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["closeCapture"].exists)
            app.buttons["closeCapture"].tap()
            XCTAssertTrue(app.buttons["startCapture"].waitForExistence(timeout: 5))
        }
    }
}
