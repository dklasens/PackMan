import XCTest

final class PackManUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInitialStateHasCleanScanActionAndNoTable() {
        let app = launch("initial")
        XCTAssertTrue(app.staticTexts["Ready to Scan"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(element("package-npm-alpha", in: app).exists)
        XCTAssertTrue(button("scanCancelButton", in: app).isEnabled)
        XCTAssertFalse(button("updateSelectedButton", in: app).isEnabled)
    }

    func testToolbarDoesNotShiftWhenScanStarts() {
        let app = launch("slowScan")
        let updateButton = button("updateSelectedButton", in: app)
        XCTAssertTrue(updateButton.waitForExistence(timeout: 2))
        let frameBefore = updateButton.frame
        element("scanCancelButton", in: app).click()
        XCTAssertTrue(element("sourceProgress", in: app).waitForExistence(timeout: 2))
        let frameDuring = updateButton.frame
        XCTAssertEqual(frameBefore.midX, frameDuring.midX, accuracy: 1.0)
        XCTAssertEqual(frameBefore.width, frameDuring.width, accuracy: 1.0)
        element("scanCancelButton", in: app).click()
        XCTAssertTrue(app.staticTexts["Scan Cancelled"].firstMatch.waitForExistence(timeout: 3))
    }

    func testPartialScanShowsUpdatesAndPersistentWarning() {
        let app = launch("partial")
        button("scanCancelButton", in: app).click()
        XCTAssertTrue(element("package-npm-alpha", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(element("scanIssueBanner", in: app).exists)
        XCTAssertFalse(app.staticTexts["System is Up to Date"].exists)
        XCTAssertTrue(app.staticTexts["Alpha Tool"].exists)
    }

    func testCheckboxSelectionControlsUpdateAction() {
        let app = launch("updates")
        button("scanCancelButton", in: app).click()
        XCTAssertTrue(element("package-npm-alpha", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(button("Update 2", in: app).isEnabled)
        button("selectAllUpdates", in: app).click()
        XCTAssertFalse(button("updateSelectedButton", in: app).isEnabled)
        button("selectAllUpdates", in: app).click()
        XCTAssertTrue(button("Update 2", in: app).isEnabled)
    }

    func testSuccessfulUpdatesAreRemovedAndSummarized() {
        let app = launch("updates")
        button("scanCancelButton", in: app).click()
        XCTAssertTrue(button("Update 2", in: app).waitForExistence(timeout: 3))
        button("Update 2", in: app).click()
        XCTAssertTrue(app.staticTexts["Updates Completed"].firstMatch.waitForExistence(timeout: 4))
        XCTAssertFalse(element("package-npm-alpha", in: app).exists)
        XCTAssertFalse(element("package-npm-beta", in: app).exists)
        XCTAssertFalse(button("updateSelectedButton", in: app).isEnabled)
    }

    func testSourceSheetShowsResolvedExecutableAndHealth() {
        let app = launch("updates")
        button("scanCancelButton", in: app).click()
        XCTAssertTrue(element("package-npm-alpha", in: app).waitForExistence(timeout: 3))
        button("sourcesButton", in: app).click()
        XCTAssertTrue(app.staticTexts["/ui-test/npm"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["npm 12.0.0 • Custom"].exists)
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-scenario", scenario]
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func button(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }
}
