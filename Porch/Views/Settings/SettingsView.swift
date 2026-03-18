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
                GenerationParametersTemperatureControl(parameters: parametersBinding)
                GenerationParametersTopPControl(parameters: parametersBinding)
                GenerationParametersMaxTokensControl(parameters: parametersBinding)
                GenerationParametersFrequencyPenaltyControl(parameters: parametersBinding)
                GenerationParametersPresencePenaltyControl(parameters: parametersBinding)
                GenerationParametersStopSequencesField(parameters: parametersBinding)
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

    private var parametersBinding: Binding<GenerationParameters> {
        Binding(
            get: { viewModel.parameters },
            set: { viewModel.parameters = $0 }
        )
    }
}
