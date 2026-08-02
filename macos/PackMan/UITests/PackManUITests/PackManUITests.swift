import XCTest

final class PackManUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInitialStateHasCleanScanActionAndNoTable() {
        let app = launch("initial")
        XCTAssertTrue(app.staticTexts["Ready to Scan"].waitForExistence(timeout: 2))
        XCTAssertFalse(element("package-npm-alpha", in: app).exists)
        XCTAssertTrue(app.buttons["scanCancelButton"].isEnabled)
        XCTAssertFalse(app.buttons["updateSelectedButton"].isEnabled)
    }

    func testToolbarDoesNotShiftWhenScanStarts() {
        let app = launch("slowScan")
        let updateButton = app.buttons["updateSelectedButton"]
        XCTAssertTrue(updateButton.waitForExistence(timeout: 2))
        let frameBefore = updateButton.frame
        element("scanCancelButton", in: app).click()
        XCTAssertTrue(element("sourceProgress", in: app).waitForExistence(timeout: 2))
        let frameDuring = updateButton.frame
        XCTAssertEqual(frameBefore.midX, frameDuring.midX, accuracy: 1.0)
        XCTAssertEqual(frameBefore.width, frameDuring.width, accuracy: 1.0)
        element("scanCancelButton", in: app).click()
        XCTAssertTrue(app.staticTexts["Scan Cancelled"].waitForExistence(timeout: 3))
    }

    func testPartialScanShowsUpdatesAndPersistentWarning() {
        let app = launch("partial")
        app.buttons["scanCancelButton"].click()
        XCTAssertTrue(element("package-npm-alpha", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("scanIssueBanner", in: app).exists)
        XCTAssertFalse(app.staticTexts["System is Up to Date"].exists)
        XCTAssertTrue(app.staticTexts["Alpha Tool"].exists)
    }

    func testCheckboxSelectionControlsUpdateAction() {
        let app = launch("updates")
        app.buttons["scanCancelButton"].click()
        XCTAssertTrue(element("package-npm-alpha", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Update 2"].isEnabled)
        app.buttons["selectAllUpdates"].click()
        XCTAssertFalse(app.buttons["updateSelectedButton"].isEnabled)
        app.buttons["selectAllUpdates"].click()
        XCTAssertTrue(app.buttons["Update 2"].isEnabled)
    }

    func testSuccessfulUpdatesAreRemovedAndSummarized() {
        let app = launch("updates")
        app.buttons["scanCancelButton"].click()
        XCTAssertTrue(app.buttons["Update 2"].waitForExistence(timeout: 3))
        app.buttons["Update 2"].click()
        XCTAssertTrue(app.staticTexts["Updates Completed"].waitForExistence(timeout: 4))
        XCTAssertFalse(element("package-npm-alpha", in: app).exists)
        XCTAssertFalse(element("package-npm-beta", in: app).exists)
        XCTAssertFalse(app.buttons["updateSelectedButton"].isEnabled)
    }

    func testSourceSheetShowsResolvedExecutableAndHealth() {
        let app = launch("updates")
        app.buttons["scanCancelButton"].click()
        XCTAssertTrue(element("package-npm-alpha", in: app).waitForExistence(timeout: 3))
        app.buttons["sourcesButton"].click()
        XCTAssertTrue(app.staticTexts["/ui-test/npm"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["npm 12.0.0 • Custom"].exists)
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-scenario", scenario]
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
