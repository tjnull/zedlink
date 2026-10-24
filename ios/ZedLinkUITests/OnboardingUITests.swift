import XCTest

final class OnboardingUITests: XCTestCase {
    func testLightThemeAndSystemTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-zedlink.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Notifications"].exists || app.staticTexts["Notifications"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Light-settings-system-tabs"; image.lifetime = .keepAlways; add(image)
    }

    func testSessionsKeyboardDismissesWhenLeavingSearch() {
        let app = XCUIApplication()
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("agent")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        let searchKey = app.keyboards.buttons["Search"]
        XCTAssertTrue(searchKey.waitForExistence(timeout: 3))
        searchKey.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))

        app.tabBars.buttons["Connections"].tap()
        XCTAssertTrue(app.staticTexts["No connections"].waitForExistence(timeout: 5))
    }

    func testFirstUseReachesPairingControls() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Choose a connection"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Connections"].tap()
        XCTAssertTrue(app.staticTexts["No connections"].waitForExistence(timeout: 5))
        app.buttons["add-connection"].tap()

        XCTAssertTrue(app.buttons["scan-pairing-qr"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use pairing link from clipboard"].exists)
        XCTAssertTrue(app.textFields["gateway-endpoint"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["test-connection"].exists)
        app.buttons["Gateway identity"].tap()
        XCTAssertTrue(app.textFields["expected-gateway-id"].exists)
        for _ in 0..<4 {
            if app.buttons["pair-and-save"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.secureTextFields["pairing-code"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pair-and-save"].exists)
    }
    /// Run only in an isolated simulator profile; never sends a pairing/network request.
    func testConnectionDraftSurvivesClosingAndChangingTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--zedlink-demo"]
        app.launch()
        app.tabBars.buttons["Connections"].tap()
        addConnection(app)
        let endpoint = app.textFields["gateway-endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap(); endpoint.typeText("https://demo.invalid")
        app.buttons["Close"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Connections"].tap()
        addConnection(app)
        XCTAssertEqual(app.textFields["gateway-endpoint"].value as? String, "https://demo.invalid")
    }

    /// "Add connection" ends the Saved connections section; in demo mode a connection and its workspaces come first,
    /// so the list has not made the button until it is scrolled to.
    private func addConnection(_ app: XCUIApplication) {
        let add = app.buttons["add-connection"]
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tap()
    }

}
