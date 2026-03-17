import SwiftData
import SwiftUI

enum SettingsPresentationMode {
    case onboarding
    case sheet
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let settings: AppSettings
    let mode: SettingsPresentationMode
    let onValidated: () -> Void

    @StateObject private var viewModel: SettingsViewModel

    init(
        settings: AppSettings,
        mode: SettingsPresentationMode,
        onValidated: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.mode = mode
        self.onValidated = onValidated
        self._viewModel = StateObject(wrappedValue: SettingsViewModel(settings: settings))
    }

    var body: some View {
        Form {
            if mode == .onboarding {
                Section {
                    Text("Connect Porch to the OpenAI-compatible server running on your MacBook or another host you trust.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Server") {
                TextField("http://192.168.1.50:1234/v1", text: $viewModel.baseURL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)

                SecureField("Optional API key", text: $viewModel.apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                HStack {
                    Label(viewModel.validationState.statusText, systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                    Spacer()
                    Text(viewModel.validationSummary)
                        .font(.footnote)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                if viewModel.availableModels.isEmpty {
                    Text("Validate the connection to load models.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Default model", selection: $viewModel.selectedModelID) {
                        ForEach(viewModel.availableModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                }

                TextField("System prompt (optional)", text: $viewModel.systemPrompt, axis: .vertical)
                    .lineLimit(2 ... 6)
            }

            Section("Generation") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(viewModel.parameters.temperature.formatted(.number.precision(.fractionLength(2))))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: temperatureBinding,
                        in: 0 ... 2,
                        step: 0.05
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Top-p")
                        Spacer()
                        Text(viewModel.parameters.topP.formatted(.number.precision(.fractionLength(2))))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: topPBinding, in: 0 ... 1, step: 0.05)
                }

                Stepper(value: maxTokensBinding, in: 256 ... 16384, step: 256) {
                    LabeledContent("Max tokens", value: "\(viewModel.parameters.maxTokens)")
                }

                Stepper(value: frequencyPenaltyBinding, in: -2 ... 2, step: 0.1) {
                    LabeledContent(
                        "Frequency penalty",
                        value: viewModel.parameters.frequencyPenalty.formatted(.number.precision(.fractionLength(1)))
                    )
                }

                Stepper(value: presencePenaltyBinding, in: -2 ... 2, step: 0.1) {
                    LabeledContent(
                        "Presence penalty",
                        value: viewModel.parameters.presencePenalty.formatted(.number.precision(.fractionLength(1)))
                    )
                }

                TextField("Stop sequences, one per line", text: stopSequencesBinding, axis: .vertical)
                    .lineLimit(2 ... 5)
            }

            Section {
                Button {
                    Task {
                        let didValidate = await viewModel.validateAndSave(into: settings, modelContext: modelContext)
                        guard didValidate else { return }
                        onValidated()
                        if mode == .sheet {
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isWorking {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Text(mode == .onboarding ? "Validate & Continue" : "Validate & Save")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(viewModel.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isWorking)
                .listRowBackground(Color.accentColor)
                .foregroundStyle(.white)
            }
        }
        .navigationTitle(mode == .onboarding ? "Server Setup" : "Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusColor: Color {
        switch viewModel.validationState {
        case .valid:
            .green
        case .invalid:
            .red
        case .validating:
            .orange
        case .notValidated:
            .secondary
        }
    }

    private var statusIcon: String {
        switch viewModel.validationState {
        case .valid:
            "checkmark.circle.fill"
        case .invalid:
            "xmark.circle.fill"
        case .validating:
            "hourglass.circle.fill"
        case .notValidated:
            "circle.dotted"
        }
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { viewModel.parameters.temperature },
            set: { viewModel.parameters.temperature = $0 }
        )
    }

    private var topPBinding: Binding<Double> {
        Binding(
            get: { viewModel.parameters.topP },
            set: { viewModel.parameters.topP = $0 }
        )
    }

    private var maxTokensBinding: Binding<Int> {
        Binding(
            get: { viewModel.parameters.maxTokens },
            set: { viewModel.parameters.maxTokens = $0 }
        )
    }

    private var frequencyPenaltyBinding: Binding<Double> {
        Binding(
            get: { viewModel.parameters.frequencyPenalty },
            set: { viewModel.parameters.frequencyPenalty = $0 }
        )
    }

    private var presencePenaltyBinding: Binding<Double> {
        Binding(
            get: { viewModel.parameters.presencePenalty },
            set: { viewModel.parameters.presencePenalty = $0 }
        )
    }

    private var stopSequencesBinding: Binding<String> {
        Binding(
            get: { viewModel.parameters.stopSequences.joined(separator: "\n") },
            set: { viewModel.parameters.stopSequences = $0.split(separator: "\n").map(String.init) }
        )
    }
}
