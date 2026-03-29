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

    @State private var selectedChatID: UUID?
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar
    @State private var isShowingSettings = false

    private var memoryConnector: MemoryConnector {
        MemoryConnector(modelContainer: modelContext.container)
    }

    var body: some View {
        Group {
            if let settings = settingsRecords.first {
                NavigationSplitView(preferredCompactColumn: $preferredColumn) {
                    ChatListView(
                        chats: chats,
                        selectedChatID: $selectedChatID,
                        availableModels: settings.availableModels,
                        isReadyForChat: settings.isReadyForChat,
                        onCreateChat: { modelID in
                            createChat(using: settings, modelID: modelID)
                        },
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
                                modelContext: modelContext,
                                memoryConnector: memoryConnector
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
                                if selectedChatID == nil {
                                    selectedChatID = chats.first?.id
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
                        if selectedChatID == nil {
                            selectedChatID = chats.first?.id
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

    private func createChat(using settings: AppSettings, modelID: String) {
        let chat = ChatThread(
            serverBaseURL: settings.activeBaseURL,
            modelID: modelID,
            systemPrompt: settings.defaultSystemPrompt
        )
        modelContext.insert(chat)
        chat.markUpdated()
        try? modelContext.save()
        selectedChatID = chat.id
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
        let nextSelectionID = chats.first { $0.id != chat.id }?.id
        if selectedChatID == chat.id {
            selectedChatID = nextSelectionID
        }
        modelContext.delete(chat)
        try? modelContext.save()
    }

    private var selectedChat: ChatThread? {
        guard let selectedChatID else { return nil }
        return chats.first { $0.id == selectedChatID }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [AppSettings.self, ChatThread.self, ChatMessage.self, MemoryEntry.self], inMemory: true)
}
