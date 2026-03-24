import Foundation
import SwiftUI

struct ChatListView: View {
    let chats: [ChatThread]
    @Binding var selectedChatID: UUID?
    let availableModels: [RemoteModel]
    let isReadyForChat: Bool
    let onCreateChat: (String) -> Void
    let onOpenSettings: () -> Void
    let onRenameChat: (ChatThread, String) -> Void
    let onDeleteChat: (ChatThread) -> Void
    let onDeleteChats: ([ChatThread]) -> Void

    @State private var chatToRename: ChatThread?
    @State private var renameText = ""
    @State private var chatToDelete: ChatThread?
    @State private var selectedChatIDs = Set<UUID>()
    @State private var isSelectingChats = false
    @State private var isShowingRenameAlert = false
    @State private var isShowingDeleteDialog = false
    @State private var isShowingBulkDeleteDialog = false

    var body: some View {
        chatList
    }

    @ViewBuilder
    private var chatList: some View {
        if isSelectingChats {
            List(selection: $selectedChatIDs) {
                chatListContent
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(PorchTheme.chatBackground)
            .tint(PorchTheme.accent)
            .navigationTitle("Porch")
            .toolbar { toolbarContent }
            .alert("Rename Chat", isPresented: $isShowingRenameAlert, presenting: chatToRename) { chat in
                TextField("Chat name", text: $renameText)
                Button("Save") {
                    onRenameChat(chat, renameText)
                    chatToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    chatToRename = nil
                }
            }
            .confirmationDialog(
                "Delete this chat?",
                isPresented: $isShowingDeleteDialog,
                titleVisibility: .visible,
                presenting: chatToDelete
            ) { chat in
                Button("Delete", role: .destructive) {
                    onDeleteChat(chat)
                    chatToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    chatToDelete = nil
                }
            } message: { _ in
                Text("This removes the conversation and its messages from the device.")
            }
            .confirmationDialog(
                bulkDeleteTitle,
                isPresented: $isShowingBulkDeleteDialog,
                titleVisibility: .visible
            ) {
                Button(bulkDeleteActionTitle, role: .destructive) {
                    let chatsToDelete = chats.filter { selectedChatIDs.contains($0.id) }
                    onDeleteChats(chatsToDelete)
                    exitSelectionMode()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the selected conversations and their messages from the device.")
            }
        } else {
            List(selection: $selectedChatID) {
                chatListContent
            }
            .scrollContentBackground(.hidden)
            .background(PorchTheme.chatBackground)
            .tint(PorchTheme.accent)
            .navigationTitle("Porch")
            .toolbar { toolbarContent }
            .alert("Rename Chat", isPresented: $isShowingRenameAlert, presenting: chatToRename) { chat in
                TextField("Chat name", text: $renameText)
                Button("Save") {
                    onRenameChat(chat, renameText)
                    chatToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    chatToRename = nil
                }
            }
            .confirmationDialog(
                "Delete this chat?",
                isPresented: $isShowingDeleteDialog,
                titleVisibility: .visible,
                presenting: chatToDelete
            ) { chat in
                Button("Delete", role: .destructive) {
                    onDeleteChat(chat)
                    chatToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    chatToDelete = nil
                }
            } message: { _ in
                Text("This removes the conversation and its messages from the device.")
            }
            .confirmationDialog(
                bulkDeleteTitle,
                isPresented: $isShowingBulkDeleteDialog,
                titleVisibility: .visible
            ) {
                Button(bulkDeleteActionTitle, role: .destructive) {
                    let chatsToDelete = chats.filter { selectedChatIDs.contains($0.id) }
                    onDeleteChats(chatsToDelete)
                    exitSelectionMode()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the selected conversations and their messages from the device.")
            }
        }
    }

    @ViewBuilder
    private var chatListContent: some View {
        if chats.isEmpty {
            ContentUnavailableView(
                isReadyForChat ? "No Chats Yet" : "Setup Required",
                systemImage: isReadyForChat ? "bubble.left.and.bubble.right" : "server.rack",
                description: Text(
                    isReadyForChat
                    ? "Create a new chat to start talking to your Mac-hosted model."
                    : "Validate your server connection before creating chats."
                )
            )
            .listRowBackground(Color.clear)
        } else {
            ForEach(chats) { chat in
                chatRow(chat)
            }
        }
    }

    private var toolbarContent: some ToolbarContent {
        Group {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelectingChats {
                    Button(role: .destructive) {
                        isShowingBulkDeleteDialog = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(selectedChatIDs.isEmpty)

                    Button("Done") {
                        exitSelectionMode()
                    }
                } else {
                    if !chats.isEmpty {
                        Button {
                            enterSelectionMode()
                        } label: {
                            Image(systemName: "checklist")
                        }
                    }

                    Menu {
                        ForEach(availableModels) { model in
                            Button {
                                onCreateChat(model.id)
                            } label: {
                                Label(model.id, systemImage: "cpu")
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(!isReadyForChat || availableModels.isEmpty)
                }
            }
        }
    }

    private func chatRow(_ chat: ChatThread) -> some View {
        let baseRow = ChatRow(chat: chat)
            .tag(chat.id)
            .listRowBackground(PorchTheme.chatBackground)
            .listRowSeparatorTint(PorchTheme.messageDivider)

        if isSelectingChats {
            return AnyView(baseRow)
        }

        return AnyView(
            baseRow
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        presentDelete(chat)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        presentRename(chat)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(PorchTheme.accent)
                }
                .contextMenu {
                    Button {
                        presentRename(chat)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        presentDelete(chat)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
        )
    }

    private func presentRename(_ chat: ChatThread) {
        chatToRename = chat
        renameText = chat.title
        isShowingRenameAlert = true
    }

    private func presentDelete(_ chat: ChatThread) {
        chatToDelete = chat
        isShowingDeleteDialog = true
    }

    private func enterSelectionMode() {
        isSelectingChats = true
        selectedChatIDs.removeAll(keepingCapacity: false)
    }

    private func exitSelectionMode() {
        isSelectingChats = false
        selectedChatIDs.removeAll(keepingCapacity: false)
        isShowingBulkDeleteDialog = false
    }

    private var bulkDeleteTitle: String {
        let count = selectedChatIDs.count
        return count == 1 ? "Delete 1 chat?" : "Delete \(count) chats?"
    }

    private var bulkDeleteActionTitle: String {
        let count = selectedChatIDs.count
        return count == 1 ? "Delete Chat" : "Delete Chats"
    }
}

private struct ChatRow: View {
    let chat: ChatThread

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(chat.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(updatedAtText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Label(chat.modelID, systemImage: "cpu")
                .font(.caption2)
                .foregroundStyle(PorchTheme.assistantRoleLabel)
                .lineLimit(1)

            if !chat.lastMessagePreview.isEmpty {
                Text(chat.lastMessagePreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private var updatedAtText: String {
        Self.relativeFormatter.localizedString(for: chat.updatedAt, relativeTo: Date())
    }
}
