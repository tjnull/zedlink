import XCTest

/// Opt-in against an already paired, explicitly exposed disposable test thread.
/// No test selects a user's project implicitly or performs approval/tool mutations.
final class SessionWorkspaceUITests: XCTestCase {
    private func transcriptText(in app: XCUIApplication, containing phrase: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", phrase, phrase))
            .firstMatch
    }

    private func openDisposableSession() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let thread = environment["ZEDLINK_E2E_THREAD_ID"], !thread.isEmpty else {
            throw XCTSkip("Set ZEDLINK_E2E_THREAD_ID to an exposed disposable thread, after pairing this simulator.")
        }
        let app = XCUIApplication(); app.launch()
        let row = app.buttons["thread-" + thread]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Disposable test thread is unavailable; verify pairing, route, and exposure.")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer").firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.buttons["Connections"].exists)
        XCTAssertFalse(app.tabBars.buttons["Settings"].exists)
        return app
    }

    func testSessionNavigationAndWorkspaceViews() throws {
        let app = try openDisposableSession()
        app.buttons["open-changes"].tap()
        XCTAssertTrue(app.buttons["workspace-changes"].waitForExistence(timeout: 5))
        app.buttons["close-workspace"].tap()
        app.buttons["open-workspace"].tap()
        for page in ["files", "changes", "terminal", "debug", "activity"] {
            let tab = app.buttons["workspace-" + page]
            XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
            XCTAssertTrue(app.buttons["close-workspace"].exists)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "Workspace-" + page; capture.lifetime = .keepAlways; add(capture)
        }
        app.buttons["close-workspace"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer").firstMatch.waitForExistence(timeout: 5))
        app.buttons["back-to-sessions"].tap()
        XCTAssertTrue(app.tabBars.buttons["Connections"].waitForExistence(timeout: 5))
        let thread = ProcessInfo.processInfo.environment["ZEDLINK_E2E_THREAD_ID"]!
        XCTAssertTrue(app.buttons["thread-" + thread].waitForExistence(timeout: 5),
                      "Recently opened sessions must keep the same accessible entry point.")
    }

    func testComposerKeyboardDismissesOnWorkspaceNavigation() throws {
        let app = try openDisposableSession()
        app.descendants(matching: .any).matching(identifier: "composer").firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.toolbars.buttons["Done"].exists)
        app.buttons["open-workspace"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
        app.buttons["close-workspace"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testConversationAndComposerAfterSessionRefresh() throws {
        guard let phrase = ProcessInfo.processInfo.environment["ZEDLINK_E2E_TRANSCRIPT_TEXT"], phrase.count >= 2 else {
            throw XCTSkip("Set ZEDLINK_E2E_TRANSCRIPT_TEXT to visible text in the exposed disposable thread.")
        }
        let app = try openDisposableSession()
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        XCTAssertGreaterThan(composer.frame.width, app.frame.width * 0.65, "The prompt field should span the conversation width.")
        let message = transcriptText(in: app, containing: phrase)
        XCTAssertTrue(message.waitForExistence(timeout: 20), "The latest native transcript should appear after opening the session.")
        app.buttons["back-to-sessions"].tap()
        app.buttons["reconnect"].tap()
        let thread = ProcessInfo.processInfo.environment["ZEDLINK_E2E_THREAD_ID"]!
        app.buttons["thread-" + thread].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 20), "Refreshing should retain or reload the native transcript.")
        app.buttons["composer-add"].tap()
        XCTAssertTrue(app.buttons["Add image"].waitForExistence(timeout: 5))
    }

    func testPendingPermissionChoicesRemainReadable() throws {
        guard ProcessInfo.processInfo.environment["ZEDLINK_E2E_PERMISSION_FIXTURE"] == "1" else {
            throw XCTSkip("Use a disposable exposed thread paused on a permission request with one-time and lasting choices.")
        }
        let app = try openDisposableSession()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "native-approval").firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Review details"].exists)
        XCTAssertTrue(app.buttons["Remember a choice…"].exists)
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "approval-choice-"))
        XCTAssertGreaterThanOrEqual(choices.count, 2, "One-time Allow and Deny must be reachable without expanding the card.")
        app.buttons["Remember a choice…"].tap()
        XCTAssertGreaterThan(choices.count, 2, "The lasting choices must remain reachable after disclosure.")
        let stop = app.buttons["stop-current-turn"]
        XCTAssertTrue(stop.exists)
        XCTAssertGreaterThanOrEqual(stop.frame.width, 44)
    }

    func testInputRequestOpensFullWidthForm() throws {
        guard ProcessInfo.processInfo.environment["ZEDLINK_E2E_ELICITATION_FIXTURE"] == "1" else {
            throw XCTSkip("Use a disposable exposed thread paused on an input request; this test does not submit it.")
        }
        let app = try openDisposableSession()
        let request = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "input-request-")).firstMatch
        XCTAssertTrue(request.waitForExistence(timeout: 20))
        request.tap()
        XCTAssertTrue(app.navigationBars["Input requested"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Decline"].exists)
        XCTAssertTrue(app.buttons["Submit"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer").firstMatch.exists)
    }

    func testMessageTextSelectsInPlace() throws {
        guard let phrase = ProcessInfo.processInfo.environment["ZEDLINK_E2E_TRANSCRIPT_TEXT"], phrase.count >= 2 else {
            throw XCTSkip("Set ZEDLINK_E2E_TRANSCRIPT_TEXT to text in an exposed disposable thread.")
        }
        let app = try openDisposableSession()
        let message = transcriptText(in: app, containing: phrase)
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        message.press(forDuration: 1.2)
        XCTAssertFalse(app.navigationBars["Message text"].exists, "Selection should stay in the conversation.")
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 3) || app.buttons["Copy"].exists,
                      "Long-pressing message text should expose the native Copy action.")
    }

    func testNativePromptRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["ZEDLINK_E2E_ALLOW_SEND"] == "1" else {
            throw XCTSkip("Set ZEDLINK_E2E_ALLOW_SEND=1 only for the explicitly exposed disposable thread.")
        }
        let app = try openDisposableSession()
        let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
        composer.tap()
        composer.typeText("For this disposable test, reply exactly: ZEDLINK_IOS_ROUND_TRIP")
        app.buttons["send-prompt"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
        XCTAssertTrue(transcriptText(in: app, containing: "ZEDLINK_IOS_ROUND_TRIP").waitForExistence(timeout: 120), "Check the authoritative desktop thread and the configured model if the reply is missing.")
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Native-prompt-round-trip"; capture.lifetime = .keepAlways; add(capture)
    }

    func testProjectTextSearchAndFileContents() throws {
        let app = try openDisposableSession()
        guard let query = ProcessInfo.processInfo.environment["ZEDLINK_E2E_SEARCH_TEXT"], !query.isEmpty else {
            throw XCTSkip("Set ZEDLINK_E2E_SEARCH_TEXT to a known string in the disposable project.")
        }
        app.buttons["open-workspace"].tap()
        let field = app.textFields["project-content-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(query)
        app.buttons["Search"].tap()
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project-search-result-")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20)); result.tap()
        XCTAssertTrue(app.textFields["find-in-file"].waitForExistence(timeout: 10))
        app.textFields["find-in-file"].tap(); app.textFields["find-in-file"].typeText(query)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Search-file-contents"; capture.lifetime = .keepAlways; add(capture)
    }

    func testConversationSearchOpensLoadedMessage() throws {
        guard let phrase = ProcessInfo.processInfo.environment["ZEDLINK_E2E_TRANSCRIPT_TEXT"], phrase.count >= 2 else {
            throw XCTSkip("Set ZEDLINK_E2E_TRANSCRIPT_TEXT to text in the disposable thread's loaded page.")
        }
        let app = try openDisposableSession()
        app.buttons["Session actions"].tap()
        app.buttons["Find in conversation"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText(phrase)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation-search-result-")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "The phrase must be present in the loaded native transcript page.")
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "composer").firstMatch.waitForExistence(timeout: 5))
    }
}
