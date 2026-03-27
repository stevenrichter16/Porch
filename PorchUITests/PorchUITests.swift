import XCTest

final class PorchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testReadyStateBypassesOnboarding() throws {
        let app = XCUIApplication()
        app.launchForOpenClaw(scenario: .onboardingReadyState)

        XCTAssertTrue(app.firstMatchingElement(identifier: PorchUITestIDs.chatList).waitForExistence(timeout: 5))
        XCTAssertTrue(app.firstMatchingElement(identifier: PorchUITestIDs.newChatButton).waitForExistence(timeout: 5))
        XCTAssertFalse(app.firstMatchingElement(identifier: PorchUITestIDs.settingsRoot).exists)
    }

    @MainActor
    func testSeededChatCanBeSelected() throws {
        let app = XCUIApplication()
        app.launchForOpenClaw(scenario: .createOrSelectChat)

        XCTAssertTrue(app.firstMatchingElement(identifier: PorchUITestIDs.chatList).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OpenClaw Seeded Chat"].waitForExistence(timeout: 5))
        app.staticTexts["OpenClaw Seeded Chat"].tap()
        XCTAssertTrue(app.firstMatchingElement(identifier: PorchUITestIDs.chatDetailRoot).waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsSheetOpensFromSidebar() throws {
        let app = XCUIApplication()
        app.launchForOpenClaw(scenario: .openSettings)

        let settingsButton = app.firstMatchingElement(identifier: PorchUITestIDs.settingsButton)
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        XCTAssertTrue(app.firstMatchingElement(identifier: PorchUITestIDs.settingsRoot).waitForExistence(timeout: 5))
    }
}
