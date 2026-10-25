import XCTest

final class CredentialInputTests: XCTestCase {
    @MainActor func testPrivateKeyIsMaskedAndClearedOnBackground() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--cove-ui-testing"]
        app.launch()
        let profile = app.buttons["Your space"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 10))
        profile.tap()
        app.buttons["phone-sign-in"].tap()
        app.buttons["phone-key-sign-in"].tap()
        let field = app.secureTextFields["phone-nsec"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let fixture = "not-a-real-private-key"
        field.typeText(fixture)
        XCTAssertFalse((field.value as? String ?? "").contains(fixture))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // Empty SecureField exposes its placeholder; input remains masked otherwise.
        XCTAssertEqual(field.value as? String, "nsec1…")
        XCTAssertFalse(app.buttons["phone-nsec-submit"].isEnabled)
    }
}
