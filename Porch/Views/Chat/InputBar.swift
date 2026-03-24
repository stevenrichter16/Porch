import SwiftUI

struct InputBar: View {
    @Binding var text: String
    let globalParameters: GenerationParameters
    @Binding var nextMessageParameterOverride: GenerationParameters?
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isShowingOverrideSheet = false
    @State private var isShowingPromptSuggestions = false
    @State private var promptSuggestionQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !overrideChips.isEmpty {
                overrideChipRow
            }

            composerRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PorchTheme.chatBackground)
        .sheet(isPresented: $isShowingOverrideSheet, content: overrideSheet)
        .sheet(isPresented: $isShowingPromptSuggestions, onDismiss: clearPromptSuggestionQuery) {
            promptSuggestionSheet
        }
    }

    private func buttonAction() {
        if isStreaming {
            onStop()
        } else {
            onSend()
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var overrideChips: [GenerationParameterOverrideChip] {
        GenerationParametersOverrideSummary.chips(
            override: nextMessageParameterOverride,
            defaults: globalParameters
        )
    }

    private var overrideChipRow: some View {
        Button(action: openOverrideSheet) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(overrideChips) { chip in
                        ComposerOverrideChip(title: chip.title)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit next message settings")
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            composerTextField
            composerPromptSuggestionButton
            composerTuneButton
            composerSendButton
        }
    }

    @ViewBuilder
    private func overrideSheet() -> some View {
        NavigationStack {
            NextMessageParametersSheet(
                defaults: globalParameters,
                initialParameters: nextMessageParameterOverride ?? globalParameters
            ) { parameters in
                nextMessageParameterOverride = GenerationParametersOverrideSummary.normalizedOverride(
                    parameters,
                    defaults: globalParameters
                )
                isShowingOverrideSheet = false
            } onCancel: {
                isShowingOverrideSheet = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func openOverrideSheet() {
        isShowingOverrideSheet = true
    }

    private func openPromptSuggestions() {
        isShowingPromptSuggestions = true
    }

    private func selectPromptSuggestion(_ prompt: String) {
        text = prompt
        isShowingPromptSuggestions = false
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func clearPromptSuggestionQuery() {
        promptSuggestionQuery = ""
    }

    private var composerTextField: some View {
        TextField("Message...", text: $text, axis: .vertical)
            .focused($isFocused)
            .lineLimit(1 ... 6)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(PorchTheme.inputFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: PorchTheme.inputFieldCornerRadius, style: .continuous))
    }

    private var composerTuneButton: some View {
        ComposerTuneButton(
            isActive: !overrideChips.isEmpty,
            action: openOverrideSheet
        )
    }

    private var composerPromptSuggestionButton: some View {
        Button(action: openPromptSuggestions) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(PorchTheme.inputFieldBackground)

                Image(systemName: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .disabled(isStreaming)
        .accessibilityLabel("Open project prompt suggestions")
    }

    private var composerSendButton: some View {
        ComposerActionButton(
            isStreaming: isStreaming,
            isDisabled: !isStreaming && trimmedText.isEmpty,
            onLongPress: sendButtonLongPressAction,
            action: buttonAction
        )
    }

    private var sendButtonLongPressAction: (() -> Void)? {
        guard !isStreaming, !trimmedText.isEmpty else {
            return nil
        }

        return openOverrideSheet
    }

    @ViewBuilder
    private var promptSuggestionSheet: some View {
        NavigationStack {
            List {
                ForEach(filteredPromptSuggestionSections) { section in
                    Section(section.title) {
                        ForEach(section.prompts) { prompt in
                            Button {
                                selectPromptSuggestion(prompt.prompt)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(prompt.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(prompt.prompt)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $promptSuggestionQuery, prompt: "Search Porch prompts")
            .navigationTitle("Project Prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isShowingPromptSuggestions = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filteredPromptSuggestionSections: [PromptSuggestionSection] {
        let query = promptSuggestionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return promptSuggestionSections
        }

        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return promptSuggestionSections.compactMap { section in
            let prompts = section.prompts.filter { prompt in
                let haystack = [prompt.title, prompt.prompt]
                    .joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return haystack.contains(normalizedQuery)
            }
            guard !prompts.isEmpty else { return nil }
            return PromptSuggestionSection(id: section.id, title: section.title, prompts: prompts)
        }
    }

    private var promptSuggestionSections: [PromptSuggestionSection] {
        [
            PromptSuggestionSection(
                title: "Refactor",
                prompts: [
                    PromptSuggestion(
                        title: "Refactor Timestamp Formatter",
                        prompt: "Do a small refactoring of the message timestamp formatter"
                    ),
                    PromptSuggestion(
                        title: "Refactor Chat Title Generator",
                        prompt: "Do a small refactoring of the ChatTitleGenerator"
                    ),
                    PromptSuggestion(
                        title: "Refactor Input Bar",
                        prompt: "Do a small refactoring of the InputBar composer layout"
                    ),
                    PromptSuggestion(
                        title: "Refactor GitHub Prompt Guidance",
                        prompt: "Do a small refactoring of the GitHub prompt guidance in ChatViewModel"
                    )
                ]
            ),
            PromptSuggestionSection(
                title: "Explain Code",
                prompts: [
                    PromptSuggestion(
                        title: "Explain Chat Titles",
                        prompt: "Find the file that formats chat titles and explain it"
                    ),
                    PromptSuggestion(
                        title: "Explain Timestamp Formatting",
                        prompt: "Find the file that formats chat timestamps and explain how it works"
                    ),
                    PromptSuggestion(
                        title: "Explain Send/Stop Flow",
                        prompt: "Find where the chat composer is implemented and explain how send and stop work"
                    ),
                    PromptSuggestion(
                        title: "Explain Redundant Tool Suppression",
                        prompt: "Explain how ChatViewModel suppresses redundant GitHub tool calls"
                    ),
                    PromptSuggestion(
                        title: "Explain Tool Bubble Labels",
                        prompt: "Find the file that renders tool call bubbles and explain how GitHub tools are labeled"
                    )
                ]
            ),
            PromptSuggestionSection(
                title: "Targeted Reads",
                prompts: [
                    PromptSuggestion(
                        title: "Tail of GitHub Context VM",
                        prompt: "Show me the last 40 lines of the GitHub context selection view model"
                    ),
                    PromptSuggestion(
                        title: "InputBar Long Press Lines",
                        prompt: "Show me the lines in InputBar.swift that handle long-press on the send button"
                    ),
                    PromptSuggestion(
                        title: "GitHub Repo Tree Tool",
                        prompt: "Show me the lines around the GitHub repo tree tool implementation"
                    ),
                    PromptSuggestion(
                        title: "Connector Helper Tail",
                        prompt: "Show me the last 60 lines of GitHubConnector.swift around the helper methods"
                    )
                ]
            ),
            PromptSuggestionSection(
                title: "GitHub Workflows",
                prompts: [
                    PromptSuggestion(
                        title: "Compare Branches",
                        prompt: "Compare main to <some branch>"
                    ),
                    PromptSuggestion(
                        title: "Search GitHub Context Issues",
                        prompt: "Search issues for GitHub context"
                    ),
                    PromptSuggestion(
                        title: "Search Web Search Issues",
                        prompt: "Search issues for web search connector"
                    ),
                    PromptSuggestion(
                        title: "Review Pull Request",
                        prompt: "Review pull request #<n> and summarize the changed files"
                    ),
                    PromptSuggestion(
                        title: "Summarize Logging Hot Paths",
                        prompt: "Review the GitHub connector logging hot paths and summarize what is timed"
                    )
                ]
            ),
            PromptSuggestionSection(
                title: "Project Exploration",
                prompts: [
                    PromptSuggestion(
                        title: "Apply GitHub Context",
                        prompt: "Find the code that applies GitHub context to a chat and explain it"
                    ),
                    PromptSuggestion(
                        title: "Generation Override Flow",
                        prompt: "Search the project for generation parameter overrides and summarize the flow"
                    ),
                    PromptSuggestion(
                        title: "Web Search Tool Exposure",
                        prompt: "Find where web search tools are exposed and explain how they enter the tool loop"
                    ),
                    PromptSuggestion(
                        title: "Find GitHub Connector State",
                        prompt: "Find the files that hold GitHub connector state and summarize how they interact"
                    )
                ]
            )
        ]
    }
}

private struct PromptSuggestionSection: Identifiable {
    let id: String
    let title: String
    let prompts: [PromptSuggestion]

    init(id: String? = nil, title: String, prompts: [PromptSuggestion]) {
        self.id = id ?? title
        self.title = title
        self.prompts = prompts
    }
}

private struct PromptSuggestion: Identifiable {
    let title: String
    let prompt: String

    var id: String { prompt }
}

private enum ComposerActionButtonStyle {
    static let morphAnimation = Animation.spring(response: 0.24, dampingFraction: 0.76, blendDuration: 0.08)
    static let pulseAnimation = Animation.easeInOut(duration: 1.35).repeatForever(autoreverses: true)
    static let pulseScale: CGFloat = 1.06
    static let morphDipScale: CGFloat = 0.9
    static let idleShadowOpacity: Double = 0.08
    static let activeShadowOpacity: Double = 0.26
    static let idleShadowRadius: CGFloat = 6
    static let activeShadowRadius: CGFloat = 14
    static let cornerRadius: CGFloat = 12
}

private struct ComposerActionButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isStreaming: Bool
    let isDisabled: Bool
    let onLongPress: (() -> Void)?
    let action: () -> Void

    @State private var isPulsing = false
    @State private var morphScale: CGFloat = 1
    @State private var suppressNextTap = false

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                pulseHalo

                RoundedRectangle(cornerRadius: ComposerActionButtonStyle.cornerRadius, style: .continuous)
                    .fill(buttonColor)

                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.headline.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(.white)
            .frame(width: PorchTheme.sendButtonSize, height: PorchTheme.sendButtonSize)
            .scaleEffect(buttonScale)
            .shadow(
                color: buttonColor.opacity(shadowOpacity),
                radius: shadowRadius,
                y: 4
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    guard let onLongPress, !isStreaming, !isDisabled else { return }
                    suppressNextTap = true
                    onLongPress()
                    DispatchQueue.main.async {
                        suppressNextTap = false
                    }
                }
        )
        .animation(ComposerActionButtonStyle.morphAnimation, value: isStreaming)
        .animation(.easeOut(duration: 0.18), value: isDisabled)
        .accessibilityLabel(isStreaming ? "Stop generating" : "Send message")
        .onAppear {
            syncPulseState()
        }
        .onChange(of: isStreaming) { previousValue, newValue in
            if !previousValue && newValue {
                runMorph()
            }
            syncPulseState()
        }
        .onChange(of: reduceMotion) { _, _ in
            syncPulseState()
        }
    }

    private var buttonColor: Color {
        isStreaming ? PorchTheme.errorBanner : PorchTheme.accent
    }

    private var buttonScale: CGFloat {
        let pulseScale = isStreaming && !reduceMotion && isPulsing
            ? ComposerActionButtonStyle.pulseScale
            : 1

        return morphScale * pulseScale
    }

    private var shadowOpacity: Double {
        isStreaming && !reduceMotion && isPulsing
            ? ComposerActionButtonStyle.activeShadowOpacity
            : ComposerActionButtonStyle.idleShadowOpacity
    }

    private var shadowRadius: CGFloat {
        isStreaming && !reduceMotion && isPulsing
            ? ComposerActionButtonStyle.activeShadowRadius
            : ComposerActionButtonStyle.idleShadowRadius
    }

    private var pulseHalo: some View {
        RoundedRectangle(cornerRadius: ComposerActionButtonStyle.cornerRadius, style: .continuous)
            .fill(buttonColor.opacity(isStreaming && !reduceMotion ? 0.18 : 0))
            .scaleEffect(isStreaming && !reduceMotion && isPulsing ? 1.22 : 1.0)
            .opacity(isStreaming && !reduceMotion && isPulsing ? 1 : 0)
    }

    private func runMorph() {
        morphScale = ComposerActionButtonStyle.morphDipScale
        withAnimation(ComposerActionButtonStyle.morphAnimation) {
            morphScale = 1
        }
    }

    private func handleTap() {
        guard !suppressNextTap else { return }
        action()
    }

    private func syncPulseState() {
        guard isStreaming, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.15)) {
                isPulsing = false
            }
            return
        }

        isPulsing = false
        withAnimation(ComposerActionButtonStyle.pulseAnimation) {
            isPulsing = true
        }
    }
}

private struct ComposerTuneButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? PorchTheme.accent : PorchTheme.actionButtonColor)
                .frame(width: PorchTheme.sendButtonSize, height: PorchTheme.sendButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(PorchTheme.inputFieldBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive ? PorchTheme.accent.opacity(0.35) : .clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next message settings")
    }
}

private struct ComposerOverrideChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PorchTheme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PorchTheme.inputFieldBackground, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PorchTheme.accent.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct NextMessageParametersSheet: View {
    let defaults: GenerationParameters
    let onApply: (GenerationParameters) -> Void
    let onCancel: () -> Void

    @State private var draftParameters: GenerationParameters
    @State private var isShowingAdvanced: Bool

    init(
        defaults: GenerationParameters,
        initialParameters: GenerationParameters,
        onApply: @escaping (GenerationParameters) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.defaults = defaults
        self.onApply = onApply
        self.onCancel = onCancel
        self._draftParameters = State(initialValue: initialParameters)
        self._isShowingAdvanced = State(
            initialValue: GenerationParametersOverrideSummary.advancedDifferenceCount(
                parameters: initialParameters,
                defaults: defaults
            ) > 0
        )
    }

    var body: some View {
        Form {
            Section {
                Text("Applies to the next message only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Generation") {
                GenerationParametersTemperatureControl(parameters: $draftParameters)
                GenerationParametersMaxTokensControl(parameters: $draftParameters)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $isShowingAdvanced) {
                    GenerationParametersTopPControl(parameters: $draftParameters)
                    GenerationParametersFrequencyPenaltyControl(parameters: $draftParameters)
                    GenerationParametersPresencePenaltyControl(parameters: $draftParameters)
                    GenerationParametersStopSequencesField(parameters: $draftParameters)
                }
            }

            Section {
                Button("Reset to defaults") {
                    draftParameters = defaults
                    isShowingAdvanced = false
                }
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Next Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    onApply(draftParameters)
                }
                .fontWeight(.semibold)
            }
        }
    }
}
