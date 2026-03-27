import XCTest

enum PorchUITestScenario: String {
    case onboardingReadyState = "onboarding_ready_state"
    case createOrSelectChat = "create_or_select_chat"
    case openSettings = "open_settings"
}

enum PorchUITestIDs {
    static let chatList = "porch.chat.list"
    static let chatDetailRoot = "porch.chat.detail.root"
    static let settingsRoot = "porch.settings.root"
    static let settingsButton = "porch.chat.settings"
    static let newChatButton = "porch.chat.new"
    static let chatDetailEmpty = "porch.chat.detail.empty"
}

extension XCUIApplication {
    func launchForOpenClaw(scenario: PorchUITestScenario) {
        launchEnvironment["OPENCLAW_UI_TEST_MODE"] = "1"
        launchEnvironment["OPENCLAW_UI_TEST_SCENARIO"] = scenario.rawValue
        launchEnvironment["OPENCLAW_UI_TEST_DISABLE_AUDIO"] = "1"
        launch()
    }

    func firstMatchingElement(identifier: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@", identifier)
        return descendants(matching: .any).matching(predicate).firstMatch
    }
}
