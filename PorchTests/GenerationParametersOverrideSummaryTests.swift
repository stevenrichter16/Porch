import XCTest
@testable import Porch

final class GenerationParametersOverrideSummaryTests: XCTestCase {
    func testChipsReflectOnlyChangedParameterCategories() {
        let defaults = GenerationParameters.default
        let override = GenerationParameters(
            temperature: 1.15,
            maxTokens: 4096,
            topP: 0.8,
            frequencyPenalty: defaults.frequencyPenalty,
            presencePenalty: 0.5,
            stopSequences: []
        )

        let chips = GenerationParametersOverrideSummary.chips(
            override: override,
            defaults: defaults
        )

        XCTAssertEqual(chips.map(\.title), ["Temp 1.15", "Max 4096", "Advanced 2"])
    }

    func testNormalizedOverrideReturnsNilWhenEqualToDefaults() {
        XCTAssertNil(
            GenerationParametersOverrideSummary.normalizedOverride(
                .default,
                defaults: .default
            )
        )
    }

    func testAdvancedDifferenceCountIncludesStopSequences() {
        let defaults = GenerationParameters.default
        let override = GenerationParameters(
            temperature: defaults.temperature,
            maxTokens: defaults.maxTokens,
            topP: defaults.topP,
            frequencyPenalty: defaults.frequencyPenalty,
            presencePenalty: defaults.presencePenalty,
            stopSequences: ["DONE"]
        )

        XCTAssertEqual(
            GenerationParametersOverrideSummary.advancedDifferenceCount(
                parameters: override,
                defaults: defaults
            ),
            1
        )
    }
}
