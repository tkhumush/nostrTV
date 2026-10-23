import XCTest

final class PhoneNavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 120 }

    @MainActor private func launch(authenticated: Bool = false, media: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--cove-ui-testing"] + (authenticated ? ["--cove-ui-authenticated"] : [])
        app.launchArguments += ["--cove-test-media", media.absoluteString]
        app.launch()
        return app
    }

    @MainActor func testBrowseWatchCreatorAndChatPreference() async throws {
        let server = try PhoneMediaServer()
        let media = try await server.start()
        defer { server.stop() }
        let app = launch(media: media)
        let card = app.buttons["phone-stream-preview-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("vinyl")
        XCTAssertTrue(app.buttons["phone-stream-preview-2"].waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)
        // The integrated portrait search keeps a nonempty query visible when
        // focus is dismissed. Clear it explicitly before returning to browsing.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let closeSearch = app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "close", "cancel")).firstMatch
        XCTAssertTrue(closeSearch.waitForExistence(timeout: 5))
        closeSearch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["phone-close-player"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["phone-close-player"].label, "Back")
        XCTAssertFalse(app.staticTexts["Live together"].exists)
        let video = app.descendants(matching: .any).matching(identifier: "phone-video").firstMatch
        XCTAssertLessThanOrEqual(video.frame.minY, app.windows.firstMatch.frame.minY + 1)
        XCTAssertTrue(app.staticTexts["Live chat"].exists)
        app.buttons["phone-creator"].tap()
        XCTAssertTrue(app.buttons["phone-creator-zap"].waitForExistence(timeout: 5))
        app.buttons["phone-creator-zap"].tap()
        XCTAssertTrue(app.staticTexts["This creator hasn’t set up Lightning yet."].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        app.buttons["phone-toggle-chat"].tap()
        XCTAssertFalse(app.staticTexts["Live chat"].exists)
        app.buttons["phone-toggle-chat"].tap()
        XCTAssertTrue(app.staticTexts["Live chat"].exists)
        app.buttons["phone-close-player"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    @MainActor func testRotationPreservesSessionAndDraft() async throws {
        let server = try PhoneMediaServer()
        let media = try await server.start()
        defer { server.stop() }
        let app = launch(authenticated: true, media: media)
        app.buttons["phone-stream-preview-0"].tap()
        let identity = app.staticTexts["phone-session-id"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        let original = identity.label
        let playing = NSPredicate { _, _ in (Double(identity.value as? String ?? "") ?? 0) > 0.5 }
        let playingExpectation = expectation(for: playing, evaluatedWith: identity)
        await fulfillment(of: [playingExpectation], timeout: 15)
        let position = Double(identity.value as? String ?? "") ?? 0
        let composer = app.descendants(matching: .any).matching(identifier: "phone-chat-message").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Keep this draft through every fold")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(identity.label, original)
        XCTAssertGreaterThanOrEqual(Double(identity.value as? String ?? "") ?? 0, position)
        XCTAssertEqual(composer.value as? String, "Keep this draft through every fold")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(identity.label, original)
        XCTAssertEqual(composer.value as? String, "Keep this draft through every fold")
        let video = app.descendants(matching: .any).matching(identifier: "phone-video").firstMatch
        let chat = app.descendants(matching: .any).matching(identifier: "phone-chat").firstMatch
        XCTAssertTrue(video.exists)
        XCTAssertTrue(chat.exists)
        XCTAssertLessThanOrEqual(video.frame.maxY, chat.frame.minY + 1)
        XCTAssertTrue(composer.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Portrait video above chat with keyboard"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Opt in with TEST_RUNNER_COVE_TEST_DUO_POSES=1 and operate Device Hub's hinge/rotate controls.
    /// The ordinary suite skips this hardware-pose scenario; all assertions run against the real app.
    @MainActor func testDuoOpenPortraitAndClosePreservePlayback() async throws {
        executionTimeAllowance = 180
        guard ProcessInfo.processInfo.environment["COVE_TEST_DUO_POSES"] == "1" else {
            throw XCTSkip("Enable the Device Hub pose verification run explicitly.")
        }
        let server = try PhoneMediaServer()
        let media = try await server.start()
        defer { server.stop() }
        let app = launch(authenticated: true, media: media)
        XCTAssertTrue(app.buttons["phone-stream-preview-0"].waitForExistence(timeout: 10))
        app.buttons["phone-stream-preview-0"].tap()
        let identity = app.staticTexts["phone-session-id"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        let original = identity.label
        let composer = app.descendants(matching: .any).matching(identifier: "phone-chat-message").firstMatch
        composer.tap()
        composer.typeText("My draft stays with me")
        let before = Double(identity.value as? String ?? "") ?? 0
        let closed = app.frame.size
        print("COVE_TEST_READY_FOR_OPEN_PORTRAIT")
        let open = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > closed.width + 60
        }, object: app)
        await fulfillment(of: [open], timeout: 60)
        // Device Hub's native pose controls own the inner display orientation.
        // XCTest's application frame can retain portrait coordinates during the
        // opening transition. Wait for the actual window after native rotation.
        print("COVE_TEST_READY_FOR_ROTATE_PORTRAIT")
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = app.windows.firstMatch.frame
            return window.height > window.width
        }, object: app)
        await fulfillment(of: [portrait], timeout: 60)
        XCTAssertEqual(identity.label, original)
        XCTAssertEqual(composer.value as? String, "My draft stays with me")
        XCTAssertGreaterThan(Double(identity.value as? String ?? "") ?? 0, before)
        let video = app.descendants(matching: .any).matching(identifier: "phone-video").firstMatch
        let chat = app.descendants(matching: .any).matching(identifier: "phone-chat").firstMatch
        XCTAssertGreaterThan(video.frame.width, closed.width - 100)
        XCTAssertLessThanOrEqual(video.frame.maxY, chat.frame.minY + 1)
        XCTAssertTrue(composer.isHittable)
        attach(app, name: "Duo open portrait — video above chat, draft and playback retained")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(video.frame.maxY, chat.frame.minY + 1)
        XCTAssertTrue(composer.isHittable)
        attach(app, name: "Duo open portrait with keyboard — video stays above chat")
        let openPosition = Double(identity.value as? String ?? "") ?? 0
        print("COVE_TEST_READY_FOR_CLOSED_PORTRAIT")
        let close = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = app.windows.firstMatch.frame
            return app.frame.width <= closed.width + 10 && window.height > window.width
        }, object: app)
        await fulfillment(of: [close], timeout: 60)
        XCTAssertEqual(identity.label, original)
        XCTAssertEqual(composer.value as? String, "My draft stays with me")
        XCTAssertGreaterThan(Double(identity.value as? String ?? "") ?? 0, openPosition)
        XCTAssertLessThanOrEqual(video.frame.maxY, chat.frame.minY + 1)
        XCTAssertTrue(composer.isHittable)
        attach(app, name: "Duo closed portrait — same session and draft")
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        // Application screenshots use the outer/main display even while the
        // app is on Duo's inner display. Keep every active display instead.
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let shot = XCTAttachment(screenshot: screen.screenshot())
            shot.name = "\(name) — display \(index)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
}
