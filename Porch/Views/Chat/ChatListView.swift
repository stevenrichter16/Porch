import SwiftUI

struct ChatListView: View {
    let chats: [ChatThread]
    @Binding var selectedChat: ChatThread?
    let isReadyForChat: Bool
    let onCreateChat: () -> Void
    let onOpenSettings: () -> Void
    let onRenameChat: (ChatThread, String) -> Void
    let onDeleteChat: (ChatThread) -> Void

    @State private var chatToRename: ChatThread?
    @State private var renameText = ""
    @State private var chatToDelete: ChatThread?

    var body: some View {
        List(selection: $selectedChat) {
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
                    ChatRow(chat: chat)
                        .tag(chat)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                chatToDelete = chat
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                chatToRename = chat
                                renameText = chat.title
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button {
                                chatToRename = chat
                                renameText = chat.title
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                chatToDelete = chat
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle("Porch")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onCreateChat) {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!isReadyForChat)
            }
        }
        .alert("Rename Chat", isPresented: renameAlertIsPresented) {
            TextField("Chat name", text: $renameText)
            Button("Save") {
                if let chatToRename {
                    onRenameChat(chatToRename, renameText)
                }
                chatToRename = nil
            }
            Button("Cancel", role: .cancel) {
                chatToRename = nil
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: deleteDialogIsPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let chatToDelete {
                    onDeleteChat(chatToDelete)
                }
                chatToDelete = nil
            }
        } message: {
            Text("This removes the conversation and its messages from the device.")
        }
    }

    private var renameAlertIsPresented: Binding<Bool> {
        Binding(
            get: { chatToRename != nil },
            set: { if !$0 { chatToRename = nil } }
        )
    }

    private var deleteDialogIsPresented: Binding<Bool> {
        Binding(
            get: { chatToDelete != nil },
            set: { if !$0 { chatToDelete = nil } }
        )
    }
}

private struct ChatRow: View {
    let chat: ChatThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(chat.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(chat.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .padding(.vertical, 4)
    }
}
