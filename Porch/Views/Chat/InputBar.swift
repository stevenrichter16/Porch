import PhotosUI
import SwiftUI

struct InputBar: View {
    @Binding var text: String
    let globalParameters: GenerationParameters
    @Binding var nextMessageParameterOverride: GenerationParameters?
    let isStreaming: Bool
    var pendingImages: Binding<[ImageAttachment]>?
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isShowingOverrideSheet = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !overrideChips.isEmpty {
                overrideChipRow
            }

            if let images = pendingImages?.wrappedValue, !images.isEmpty {
                imagePreviewRow(images)
            }

            composerRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PorchTheme.chatBackground)
        .sheet(isPresented: $isShowingOverrideSheet, content: overrideSheet)
        .onChange(of: selectedPhotoItems) { _, newItems in
            Task {
                await loadSelectedPhotos(newItems)
            }
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
        HStack(alignment: .bottom, spacing: 8) {
            if pendingImages != nil {
                attachmentButton
            }
            composerTextField
            composerTuneButton
            composerSendButton
        }
    }

    private var attachmentButton: some View {
        PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 1,
            matching: .images
        ) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(PorchTheme.accent)
        }
        .buttonStyle(.plain)
        .disabled(isStreaming)
        .accessibilityLabel("Attach images")
    }

    private func imagePreviewRow(_ images: [ImageAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let uiImage = attachment.thumbnail {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        Button {
                            pendingImages?.wrappedValue.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        var newAttachments: [ImageAttachment] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                #if canImport(UIKit)
                let thumbnail = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 112, height: 112))
                #else
                let thumbnail: UIImage? = nil
                #endif
                let attachment = ImageAttachment(
                    imageData: data,
                    mimeType: "image/jpeg",
                    thumbnail: thumbnail
                )
                newAttachments.append(attachment)
            }
        }
        pendingImages?.wrappedValue = newAttachments
        selectedPhotoItems = []
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
