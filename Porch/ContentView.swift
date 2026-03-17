//
//  ContentView.swift
//  Porch
//
//  Created by Steven Richter on 3/16/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRecords: [AppSettings]
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var chats: [ChatThread]

    @State private var selectedChat: ChatThread?
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar
    @State private var isShowingSettings = false

    var body: some View {
        Group {
            if let settings = settingsRecords.first {
                NavigationSplitView(preferredCompactColumn: $preferredColumn) {
                    ChatListView(
                        chats: chats,
                        selectedChat: $selectedChat,
                        isReadyForChat: settings.isReadyForChat,
                        onCreateChat: { createChat(using: settings) },
                        onOpenSettings: { isShowingSettings = true },
                        onRenameChat: renameChat(_:to:),
                        onDeleteChat: deleteChat(_:)
                    )
                } detail: {
                    if settings.isReadyForChat {
                        if let selectedChat {
                            ChatDetailView(
                                chat: selectedChat,
                                settings: settings,
                                modelContext: modelContext
                            )
                        } else {
                            ContentUnavailableView(
                                "Choose a Chat",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Create a conversation or select one from the list.")
                            )
                        }
                    } else {
                        NavigationStack {
                            SettingsView(settings: settings, mode: .onboarding) {
                                preferredColumn = .sidebar
                                if selectedChat == nil {
                                    selectedChat = chats.first
                                }
                            }
                        }
                    }
                }
                .sheet(isPresented: $isShowingSettings) {
                    NavigationStack {
                        SettingsView(settings: settings, mode: .sheet)
                    }
                }
                .task(id: settings.isReadyForChat) {
                    if settings.isReadyForChat {
                        if selectedChat == nil {
                            selectedChat = chats.first
                        }
                        preferredColumn = .sidebar
                    } else {
                        preferredColumn = .detail
                    }
                }
            } else {
                ProgressView("Loading Porch...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func createChat(using settings: AppSettings) {
        let chat = ChatThread(
            serverBaseURL: settings.activeBaseURL,
            modelID: settings.defaultModelID,
            systemPrompt: settings.defaultSystemPrompt
        )
        modelContext.insert(chat)
        chat.markUpdated()
        try? modelContext.save()
        selectedChat = chat
        preferredColumn = .detail
    }

    private func renameChat(_ chat: ChatThread, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.title = trimmed
        chat.markUpdated()
        try? modelContext.save()
    }

    private func deleteChat(_ chat: ChatThread) {
        let nextSelection = chats.first { $0.id != chat.id }
        if selectedChat?.id == chat.id {
            selectedChat = nextSelection
        }
        modelContext.delete(chat)
        try? modelContext.save()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [AppSettings.self, ChatThread.self, ChatMessage.self], inMemory: true)
}
