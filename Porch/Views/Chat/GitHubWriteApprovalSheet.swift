import SwiftUI

struct GitHubWriteApprovalSheet: View {
    let approval: PendingGitHubWriteApproval
    let onApprove: (String, String) -> Void
    let onCancel: () -> Void

    @State private var branchName: String
    @State private var commitMessage: String

    init(
        approval: PendingGitHubWriteApproval,
        onApprove: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.approval = approval
        self.onApprove = onApprove
        self.onCancel = onCancel
        self._branchName = State(initialValue: approval.proposedBranchName)
        self._commitMessage = State(initialValue: approval.commitMessage)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summarySection
                editSection
                diffSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(PorchTheme.chatBackground)
        .navigationTitle("Approve GitHub Changes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Create Branch & Push") {
                    onApprove(
                        branchName.trimmingCharacters(in: .whitespacesAndNewlines),
                        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .disabled(
                    branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Porch prepared a GitHub write request. Review the branch details and diff preview before you allow it to create a branch and push one commit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            detailRow(label: "Repository", value: approval.repositoryFullName)
            detailRow(label: "Base branch", value: approval.resolvedBaseRef)

            HStack(spacing: 10) {
                summaryBadge(count: approval.createdCount, label: "Create", color: .green)
                summaryBadge(count: approval.updatedCount, label: "Update", color: PorchTheme.accent)
                summaryBadge(count: approval.deletedCount, label: "Delete", color: .red)
            }
        }
        .padding(16)
        .background(PorchTheme.inputFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var editSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Branch & Commit")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Target branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("porch/change-20260318-120000", text: $branchName)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(PorchTheme.inputFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Commit message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Describe the change", text: $commitMessage, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(PorchTheme.inputFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diff Preview")
                .font(.headline)

            ForEach(approval.diffPreviews) { preview in
                DisclosureGroup {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(preview.diffText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(PorchTheme.inputFieldBackground.opacity(0.78))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } label: {
                    HStack(spacing: 10) {
                        Text(preview.path)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 0)

                        operationBadge(preview.operation)
                    }
                }
                .padding(14)
                .background(PorchTheme.inputFieldBackground.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func summaryBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.caption.weight(.bold))
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func operationBadge(_ operation: GitHubFileOperation) -> some View {
        let color: Color
        switch operation {
        case .create:
            color = .green
        case .update:
            color = PorchTheme.accent
        case .delete:
            color = .red
        }

        return Text(operation.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
