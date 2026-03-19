import SwiftUI

struct GitHubContextSelectionSheet: View {
    @StateObject private var viewModel: GitHubContextSelectionViewModel

    let onSave: (GitHubChatContext) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    init(
        initialContext: GitHubChatContext?,
        keychain: KeychainStoreProtocol = KeychainStore(),
        session: URLSession = .shared,
        onSave: @escaping (GitHubChatContext) -> Void,
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._viewModel = StateObject(
            wrappedValue: GitHubContextSelectionViewModel(
                initialContext: initialContext,
                keychain: keychain,
                session: session
            )
        )
        self.onSave = onSave
        self.onClear = onClear
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            repositoriesSection
            manualSection

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }

            if viewModel.hasDraftSelection {
                Section {
                    Button("Clear Context", role: .destructive) {
                        onClear()
                    }
                }
            }
        }
        .navigationTitle("GitHub Context")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard let context = viewModel.selectedContextDraft else { return }
                    onSave(context)
                }
                .disabled(!viewModel.canSave)
            }
        }
        .task {
            async let accessibleRepositoriesTask: Void = viewModel.loadAccessibleRepositoriesIfNeeded()
            async let initialContextTask: Void = viewModel.loadInitialContextIfNeeded()
            _ = await (accessibleRepositoriesTask, initialContextTask)
        }
    }

    private var repositoriesSection: some View {
        Section("Repositories") {
            TextField("Filter repositories", text: $viewModel.searchQuery)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if viewModel.isLoadingAccessibleRepositories && viewModel.availableRepositories.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading accessible repositories…")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage = viewModel.repoListErrorMessage, viewModel.availableRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)

                    Button("Retry") {
                        Task { await viewModel.reloadAccessibleRepositories() }
                    }
                }
            } else if viewModel.filteredAvailableRepositories.isEmpty {
                Text(emptyRepositoriesMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.filteredAvailableRepositories, id: \.full_name) { repository in
                    repositoryEntry(repository)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            if viewModel.isLoadingAccessibleRepositories && !viewModel.availableRepositories.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more repositories…")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = viewModel.repoListErrorMessage, !viewModel.availableRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)

                    Button("Retry loading repositories") {
                        Task { await viewModel.reloadAccessibleRepositories() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
        }
    }

    private var manualSection: some View {
        Section("Manual Repository Fallback") {
            Text("Load a repository directly if it is not visible in the list above.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Owner", text: $viewModel.ownerInput)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            TextField("Repository", text: $viewModel.repoInput)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            Button {
                Task { await viewModel.loadManualRepository() }
            } label: {
                if viewModel.isLoadingRepository {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading Repository")
                    }
                } else {
                    Text("Load Repository")
                }
            }
            .disabled(
                viewModel.ownerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                viewModel.repoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                viewModel.isLoadingRepository
            )
        }
    }

    private var emptyRepositoriesMessage: String {
        let trimmedQuery = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return "No accessible repositories were found for this token."
        }
        return "No repositories match “\(trimmedQuery)”."
    }

    @ViewBuilder
    private func repositoryEntry(_ repository: GitHubRepository) -> some View {
        let isExpanded = viewModel.isRepositoryExpanded(repository)
        let isSelected = viewModel.isRepositorySelected(repository)
        let needsAttention = viewModel.selectedBranchNeedsAttention(for: repository)
        let borderColor = needsAttention ? PorchTheme.errorBanner : (isSelected ? PorchTheme.accent : PorchTheme.messageDivider.opacity(0.55))
        let backgroundColor = isSelected ? PorchTheme.assistantRowBackground.opacity(0.45) : PorchTheme.inputFieldBackground

        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task { await viewModel.toggleRepositoryExpansion(repository) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(repository.full_name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let selectedBranch = viewModel.selectedBranchSummary(for: repository) {
                            HStack(spacing: 6) {
                                Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(needsAttention ? PorchTheme.errorBanner : PorchTheme.accent)

                                Text(needsAttention ? "\(selectedBranch) needs attention" : "Selected: \(selectedBranch)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(needsAttention ? PorchTheme.errorBanner : PorchTheme.accent)
                            }
                        } else {
                            Text("Tap to expand and choose a branch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let description = repository.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        HStack(spacing: 10) {
                            if let language = repository.language, !language.isEmpty {
                                Label(language, systemImage: "circle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(repository.private ? "Private" : "Public")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .trailing, spacing: 8) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.headline)
                                .foregroundStyle(needsAttention ? PorchTheme.errorBanner : PorchTheme.accent)
                        }

                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(PorchTheme.messageDivider)

                expandedRepositoryContent(repository)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: isExpanded || isSelected ? 1.5 : 1)
        )
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
    }

    @ViewBuilder
    private func expandedRepositoryContent(_ repository: GitHubRepository) -> some View {
        if viewModel.isLoadingBranches(for: repository) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading branches…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } else if let errorMessage = viewModel.branchLoadError(for: repository) {
            VStack(alignment: .leading, spacing: 10) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Retry branches") {
                    Task { await viewModel.retryExpandedRepositoryBranches() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.branches(for: repository)) { branch in
                    branchRow(branch, for: repository)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Manual branch fallback")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("Branch name", text: $viewModel.expandedManualBranchInput)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(PorchTheme.chatBackground)
                        )

                    Button {
                        Task { await viewModel.validateExpandedManualBranch() }
                    } label: {
                        if viewModel.isValidatingBranch {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Validating Branch")
                            }
                        } else {
                            Text("Validate Branch")
                        }
                    }
                    .disabled(
                        viewModel.expandedManualBranchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        viewModel.isValidatingBranch
                    )

                    if let branchValidationMessage = viewModel.expandedBranchValidationMessage {
                        Text(branchValidationMessage)
                            .font(.caption)
                            .foregroundStyle(viewModel.isExpandedBranchValid ? Color.secondary : PorchTheme.errorBanner)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func branchRow(_ branch: GitHubBranchSummary, for repository: GitHubRepository) -> some View {
        let isSelected = viewModel.isBranchSelected(branch, for: repository)
        let isDefault = branch.name == viewModel.defaultBranchName(for: repository)
        let fillColor = isSelected ? PorchTheme.accent.opacity(0.12) : PorchTheme.chatBackground

        return Button {
            viewModel.selectBranch(branch, for: repository)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(isSelected ? PorchTheme.accent : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(branch.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        if isDefault {
                            Text("Default")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PorchTheme.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(PorchTheme.accent.opacity(0.12))
                                )
                        }
                    }

                    Text("Tap to use this branch in the chat.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                    .foregroundStyle(isSelected ? PorchTheme.accent : .secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fillColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
