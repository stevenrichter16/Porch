import SwiftUI

enum GenerationParametersControlValues {
    static let temperatureRange: ClosedRange<Double> = 0 ... 2
    static let temperatureStep: Double = 0.05
    static let topPRange: ClosedRange<Double> = 0 ... 1
    static let topPStep: Double = 0.05
    static let maxTokensRange: ClosedRange<Int> = 256 ... 16384
    static let maxTokensStep: Int = 256
    static let penaltyRange: ClosedRange<Double> = -2 ... 2
    static let penaltyStep: Double = 0.1
}

struct GenerationParameterOverrideChip: Identifiable, Equatable {
    let id: String
    let title: String
}

enum GenerationParametersOverrideSummary {
    static func chips(
        override parameters: GenerationParameters?,
        defaults: GenerationParameters
    ) -> [GenerationParameterOverrideChip] {
        guard let parameters else { return [] }

        var chips: [GenerationParameterOverrideChip] = []
        if parameters.temperature != defaults.temperature {
            chips.append(
                GenerationParameterOverrideChip(
                    id: "temperature",
                    title: "Temp \(parameters.temperature.formatted(.number.precision(.fractionLength(2))))"
                )
            )
        }

        if parameters.maxTokens != defaults.maxTokens {
            chips.append(
                GenerationParameterOverrideChip(
                    id: "maxTokens",
                    title: "Max \(parameters.maxTokens)"
                )
            )
        }

        let advancedCount = advancedDifferenceCount(parameters: parameters, defaults: defaults)
        if advancedCount > 0 {
            chips.append(
                GenerationParameterOverrideChip(
                    id: "advanced",
                    title: "Advanced \(advancedCount)"
                )
            )
        }

        return chips
    }

    static func advancedDifferenceCount(
        parameters: GenerationParameters,
        defaults: GenerationParameters
    ) -> Int {
        var count = 0
        if parameters.topP != defaults.topP {
            count += 1
        }
        if parameters.frequencyPenalty != defaults.frequencyPenalty {
            count += 1
        }
        if parameters.presencePenalty != defaults.presencePenalty {
            count += 1
        }
        if parameters.stopSequences != defaults.stopSequences {
            count += 1
        }
        return count
    }

    static func normalizedOverride(
        _ parameters: GenerationParameters,
        defaults: GenerationParameters
    ) -> GenerationParameters? {
        parameters == defaults ? nil : parameters
    }
}

struct GenerationParametersTemperatureControl: View {
    @Binding var parameters: GenerationParameters

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Temperature")
                Spacer()
                Text(parameters.temperature.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: temperatureBinding,
                in: GenerationParametersControlValues.temperatureRange,
                step: GenerationParametersControlValues.temperatureStep
            )
        }
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { parameters.temperature },
            set: { parameters.temperature = $0 }
        )
    }
}

struct GenerationParametersTopPControl: View {
    @Binding var parameters: GenerationParameters

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top-p")
                Spacer()
                Text(parameters.topP.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: topPBinding,
                in: GenerationParametersControlValues.topPRange,
                step: GenerationParametersControlValues.topPStep
            )
        }
    }

    private var topPBinding: Binding<Double> {
        Binding(
            get: { parameters.topP },
            set: { parameters.topP = $0 }
        )
    }
}

struct GenerationParametersMaxTokensControl: View {
    @Binding var parameters: GenerationParameters

    var body: some View {
        Stepper(
            value: maxTokensBinding,
            in: GenerationParametersControlValues.maxTokensRange,
            step: GenerationParametersControlValues.maxTokensStep
        ) {
            LabeledContent("Max tokens", value: "\(parameters.maxTokens)")
        }
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { parameters.maxTokens },
            set: { parameters.maxTokens = $0 }
        )
    }
}

struct GenerationParametersFrequencyPenaltyControl: View {
    @Binding var parameters: GenerationParameters

    var body: some View {
        Stepper(
            value: frequencyPenaltyBinding,
            in: GenerationParametersControlValues.penaltyRange,
            step: GenerationParametersControlValues.penaltyStep
        ) {
            LabeledContent(
                "Frequency penalty",
                value: parameters.frequencyPenalty.formatted(.number.precision(.fractionLength(1)))
            )
        }
    }

    private var frequencyPenaltyBinding: Binding<Double> {
        Binding(
            get: { parameters.frequencyPenalty },
            set: { parameters.frequencyPenalty = $0 }
        )
    }
}

struct GenerationParametersPresencePenaltyControl: View {
    @Binding var parameters: GenerationParameters

    var body: some View {
        Stepper(
            value: presencePenaltyBinding,
            in: GenerationParametersControlValues.penaltyRange,
            step: GenerationParametersControlValues.penaltyStep
        ) {
            LabeledContent(
                "Presence penalty",
                value: parameters.presencePenalty.formatted(.number.precision(.fractionLength(1)))
            )
        }
    }

    private var presencePenaltyBinding: Binding<Double> {
        Binding(
            get: { parameters.presencePenalty },
            set: { parameters.presencePenalty = $0 }
        )
    }
}

struct GenerationParametersStopSequencesField: View {
    @Binding var parameters: GenerationParameters

    var body: some View {
        TextField("Stop sequences, one per line", text: stopSequencesBinding, axis: .vertical)
            .lineLimit(2 ... 5)
    }

    private var stopSequencesBinding: Binding<String> {
        Binding(
            get: { parameters.stopSequences.joined(separator: "\n") },
            set: { parameters.stopSequences = $0.split(separator: "\n").map(String.init) }
        )
    }
}
