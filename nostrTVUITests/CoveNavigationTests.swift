import XCTest

final class CoveNavigationTests: XCTestCase {
    @MainActor
    func testPlayerPanelsReturnFocusWithoutLeavingPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--cove-ui-testing"]
        app.launch()
        let featured = app.buttons["watch-featured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 10))
        focus(featured, moving: .down)
        XCUIRemote.shared.press(.select)
        let chat = app.buttons["player-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        focus(chat, moving: .right)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(app.staticTexts["In good company"].exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["In good company"].exists)

        let playerImage = XCTAttachment(screenshot: app.screenshot())
        playerImage.name = "Cove Player"
        playerImage.lifetime = .keepAlways
        add(playerImage)

        let zap = app.buttons["player-zap"]
        focus(zap, moving: .right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Make their day."].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(zap.waitForExistence(timeout: 5))
        XCTAssertTrue(zap.hasFocus, "Back from the zap panel must restore its opener")

        let cinema = app.buttons["player-cinema"]
        focus(cinema, moving: .right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["cinema-surface"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["In good company"].exists)
        XCTAssertTrue(app.buttons["cinema-surface"].hasFocus)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(cinema.waitForExistence(timeout: 5))
        XCTAssertTrue(cinema.hasFocus)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(featured.waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Cove Discover"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testSignedOutFollowingAndPreferences() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--cove-ui-testing"]
        app.launch()
        let following = app.buttons["nav-following"]
        XCTAssertTrue(following.waitForExistence(timeout: 10))
        focus(following, moving: .right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Your people are here."].waitForExistence(timeout: 5))
        focus(app.buttons["nav-profile"], moving: .right)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Make yourself at home."].waitForExistence(timeout: 5))
        let preference = app.buttons["preference-chat"]
        focus(preference, moving: .down)
        let originalValue = preference.value as? String
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(preference.value as? String, originalValue)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(preference.value as? String, originalValue)
    }

    @MainActor private func focus(_ element: XCUIElement, moving direction: XCUIRemote.Button) {
        for _ in 0..<10 {
            if element.hasFocus { return }
            XCUIRemote.shared.press(direction)
        }
        XCTAssertTrue(element.hasFocus, "Remote navigation should reach \(element.identifier)")
    }
}
