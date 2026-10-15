import XCTest
import UIKit

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
        let cinemaScreenshot = app.screenshot()
        let cinemaImage = XCTAttachment(screenshot: cinemaScreenshot)
        cinemaImage.name = "Cove Cinema"
        cinemaImage.lifetime = .keepAlways
        add(cinemaImage)
        assertUntintedVideo(cinemaScreenshot.image)
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

    /// The offline player is black. A standard tvOS button focus fill over the
    /// cinema surface turns this gray even though the button label is clear.
    private func assertUntintedVideo(_ image: UIImage) {
        guard let source = image.cgImage else { return XCTFail("Missing screenshot pixels") }
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 8 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(source, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        for (x, y) in [(2, 2), (5, 2), (2, 5), (5, 5)] {
            let offset = (y * 8 + x) * 4
            XCTAssertLessThan(pixels[offset..<offset + 3].max()!, 12,
                "Cinema must not paint a focus tint over the video")
        }
    }
}
