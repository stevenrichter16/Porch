# Chat Management — Implementation Guide

## Scope

This document covers the implementation of the chat management system: persisting chats and messages locally, navigating between multiple conversations, creating/renaming/deleting chats, and wiring it all into the streaming architecture from the SSE guide.

---

## Data Layer: SwiftData Models

SwiftData is the right choice here. It's native to SwiftUI, requires zero boilerplate compared to Core Data, and supports CloudKit sync if you add that later. The `@Model` macro turns plain Swift classes into persistent objects, and `@Query` in SwiftUI views gives you live-updating reads for free.

### The Schema

Two models with a one-to-many relationship: a `Chat` has many `Message`s.

```swift
import Foundation
import SwiftData

@Model
class Chat {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var systemPrompt: String
    var modelIdentifier: String   // Which model this chat uses
    var serverBaseURL: String     // Which server this chat targets

    @Relationship(deleteRule: .cascade)
    var messages: [Message] = []

    init(
        title: String = "New Chat",
        systemPrompt: String = "",
        modelIdentifier: String = "",
        serverBaseURL: String = ""
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.systemPrompt = systemPrompt
        self.modelIdentifier = modelIdentifier
        self.serverBaseURL = serverBaseURL
    }

    /// Sorted messages for building the API request
    var sortedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }
}

@Model
class Message {
    var id: UUID
    var role: String            // "system", "user", "assistant"
    var content: String
    var createdAt: Date
    var isPartial: Bool         // True if generation was stopped mid-stream

    var chat: Chat?

    init(
        role: String,
        content: String,
        chat: Chat? = nil,
        isPartial: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.createdAt = Date()
        self.isPartial = isPartial
        self.chat = chat
    }
}
```

### Key Design Decisions

**`deleteRule: .cascade`** — When a chat is deleted, all its messages are automatically deleted. This is critical; without it, SwiftData defaults to `.nullify`, which would leave orphaned messages in the database.

**`modelIdentifier` and `serverBaseURL` on Chat** — Each chat remembers which server and model it was created with. This means you can have one chat using Llama on your Mac and another using Mistral on a different machine, and switching between them Just Works. If the user changes their default server/model, existing chats keep their original configuration.

**`isPartial` on Message** — When the user hits Stop during generation, the accumulated text gets saved as a message with `isPartial = true`. This lets the UI optionally render a "stopped" indicator or offer a "Continue" action.

**`updatedAt` on Chat** — Updated every time a message is added. This is what the chat list sorts by to show most-recently-active chats first.

### Registering the Container

In your `App` struct, register the model container. You only need to specify the root model (`Chat`); SwiftData discovers `Message` automatically through the relationship.

```swift
import SwiftUI
import SwiftData

@main
struct LocalChatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Chat.self)
    }
}
```

For unit testing, you can create an in-memory container:

```swift
let config = ModelConfiguration(isStoredInMemoryOnly: true)
let container = try ModelContainer(for: Chat.self, configurations: config)
```

---

## Navigation Architecture

### iPhone vs iPad

The app needs two behaviors:

- **iPhone (compact width)**: A navigation stack. The chat list is the root view; tapping a chat pushes the chat view onto the stack. Standard iOS messaging app pattern.
- **iPad (regular width)**: A sidebar/detail split view. The chat list is a persistent sidebar; the selected chat's conversation fills the detail pane.

`NavigationSplitView` handles both automatically. On iPhone, it collapses to a single-column stack. On iPad, it presents as a two-column split.

### The Root View

```swift
import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedChat: Chat?

    var body: some View {
        NavigationSplitView {
            ChatListView(selectedChat: $selectedChat)
        } detail: {
            if let chat = selectedChat {
                ChatDetailView(chat: chat)
            } else {
                ContentUnavailableView(
                    "No Chat Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a conversation or start a new one")
                )
            }
        }
    }
}
```

### Controlling Column Behavior on iPhone

By default, `NavigationSplitView` shows the sidebar (chat list) first on iPhone. If you want the app to open directly to the most recent chat, you can use `preferredCompactColumn`:

```swift
@State private var preferredColumn = NavigationSplitViewColumn.detail

NavigationSplitView(preferredCompactColumn: $preferredColumn) {
    ChatListView(selectedChat: $selectedChat)
} detail: {
    // ...
}
```

This is a UX choice — messaging apps typically show the list first, so the default behavior is probably fine.

---

## Chat List View

This is the sidebar that shows all conversations, sorted by most recently updated.

```swift
import SwiftUI
import SwiftData

struct ChatListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
    @Binding var selectedChat: Chat?

    @State private var chatToRename: Chat?
    @State private var renameText: String = ""
    @State private var chatToDelete: Chat?
    @State private var showDeleteConfirmation = false

    var body: some View {
        List(selection: $selectedChat) {
            ForEach(chats) { chat in
                ChatRow(chat: chat)
                    .tag(chat)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            chatToDelete = chat
                            showDeleteConfirmation = true
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
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNewChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .alert("Rename Chat", isPresented: .init(
            get: { chatToRename != nil },
            set: { if !$0 { chatToRename = nil } }
        )) {
            TextField("Chat name", text: $renameText)
            Button("Save") {
                if let chat = chatToRename {
                    chat.title = renameText
                }
                chatToRename = nil
            }
            Button("Cancel", role: .cancel) {
                chatToRename = nil
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let chat = chatToDelete {
                    deleteChat(chat)
                }
            }
        } message: {
            Text("This will permanently delete the conversation and all its messages.")
        }
    }

    private func createNewChat() {
        let chat = Chat(
            title: "New Chat",
            systemPrompt: "",         // Pull from user's default settings
            modelIdentifier: "",      // Pull from user's default model
            serverBaseURL: ""         // Pull from user's default server
        )
        modelContext.insert(chat)
        selectedChat = chat
    }

    private func deleteChat(_ chat: Chat) {
        if selectedChat == chat {
            selectedChat = nil
        }
        modelContext.delete(chat)
    }
}
```

### Chat Row

The individual row in the chat list, showing title, preview text, and timestamp.

```swift
struct ChatRow: View {
    let chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(chat.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(chat.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastMessage = chat.sortedMessages.last {
                Text(lastMessage.content)
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
```

### Interaction Patterns

The view provides **three ways** to manage chats:

1. **Swipe actions** (trailing edge): Delete and Rename buttons appear when swiping a chat row left. This is the most discoverable mobile interaction.
2. **Context menu** (long-press): Same actions via a popover menu. More common on iPad.
3. **Toolbar button**: The compose icon (`square.and.pencil`) creates a new chat and selects it.

Delete uses a `confirmationDialog` to prevent accidental data loss. Rename uses an `alert` with a `TextField` — this is a deliberate choice over a sheet because the rename interaction should be lightweight and fast.

---

## Chat Detail View (Connecting to Streaming)

The detail view manages a single conversation. This bridges the SwiftData persistence layer and the SSE streaming client from the previous guide.

```swift
import SwiftUI
import SwiftData

struct ChatDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var chat: Chat

    @State private var inputText = ""
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var streamTask: Task<Void, Never>?
    @State private var error: String?

    private let client = StreamingChatClient()

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let error { errorBanner(error) }
            Divider()
            inputBar
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.sortedMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if isStreaming && !streamingText.isEmpty {
                        MessageBubble(
                            message: Message(role: "assistant", content: streamingText)
                        )
                        .id("streaming")
                    }
                }
                .padding()
            }
            .onChange(of: streamingText) {
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.count) {
                if let lastId = chat.sortedMessages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom) {
            TextField("Message", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)

            if isStreaming {
                Button {
                    stopGenerating()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.8))
            .onTapGesture { error = nil }
    }

    // MARK: - Send & Stream

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // Persist the user message
        let userMessage = Message(role: "user", content: text, chat: chat)
        modelContext.insert(userMessage)
        chat.updatedAt = Date()

        // Build the API messages array from persisted history
        var apiMessages: [ChatMessage] = []
        if !chat.systemPrompt.isEmpty {
            apiMessages.append(ChatMessage(role: "system", content: chat.systemPrompt))
        }
        for msg in chat.sortedMessages {
            apiMessages.append(ChatMessage(role: msg.role, content: msg.content))
        }

        // Start streaming
        streamingText = ""
        isStreaming = true
        error = nil

        streamTask = Task {
            do {
                let request = try buildStreamingRequest(
                    baseURL: chat.serverBaseURL,
                    model: chat.modelIdentifier,
                    messages: apiMessages
                )

                let stream = client.streamCompletion(request: request)

                for try await token in stream {
                    streamingText += token
                }

                // Generation complete — persist the assistant message
                let assistantMessage = Message(
                    role: "assistant",
                    content: streamingText,
                    chat: chat
                )
                modelContext.insert(assistantMessage)
                chat.updatedAt = Date()
                streamingText = ""

            } catch is CancellationError {
                // User hit stop — save partial response
                if !streamingText.isEmpty {
                    let partial = Message(
                        role: "assistant",
                        content: streamingText,
                        chat: chat,
                        isPartial: true
                    )
                    modelContext.insert(partial)
                    chat.updatedAt = Date()
                }
                streamingText = ""
            } catch {
                self.error = error.localizedDescription
            }

            isStreaming = false
        }
    }

    private func stopGenerating() {
        streamTask?.cancel()
    }
}
```

### Design Notes

**`@Bindable var chat`** — In SwiftData with iOS 17+, `@Bindable` allows you to create bindings directly to a SwiftData model's properties. We use this for the `chat` parameter so child views can bind to `chat.title`, `chat.systemPrompt`, etc.

**Messages are persisted immediately** — The user message is inserted into SwiftData *before* the API call starts. This means if the app crashes mid-generation, the user's input isn't lost. The assistant message is only persisted once generation completes (or is stopped).

**`chat.updatedAt = Date()`** — Updated after each message insertion. This keeps the chat list sorted by recent activity. SwiftData's `@Query` with `.reverse` sort order picks this up automatically.

**Auto-save** — SwiftData auto-saves on a schedule and when the app goes to background. You don't need to call `modelContext.save()` explicitly for most operations. If you want immediate persistence (e.g., right before a crash-prone operation), you can call it explicitly.

---

## Auto-Generating Chat Titles

New chats start as "New Chat", which isn't useful once you have more than a few. There are several strategies for auto-titling.

### Option 1: First Message Truncation (Simplest)

Use the first few words of the user's first message as the title.

```swift
private func autoTitle(from text: String) -> String {
    let words = text.split(separator: " ").prefix(6)
    let title = words.joined(separator: " ")
    return title.count < text.count ? title + "…" : title
}
```

Call it when the first user message is sent:

```swift
if chat.messages.isEmpty || chat.title == "New Chat" {
    chat.title = autoTitle(from: text)
}
```

### Option 2: LLM-Generated Title (Better UX, Costs a Request)

After the first assistant response completes, fire a second lightweight request asking the model to summarize the conversation into a short title.

```swift
private func generateTitle(for chat: Chat) async {
    let titlePrompt = [
        ChatMessage(role: "system", content: "Generate a short 3-5 word title for this conversation. Respond with ONLY the title, nothing else."),
        ChatMessage(role: "user", content: chat.sortedMessages.first?.content ?? "")
    ]

    do {
        let request = try buildStreamingRequest(
            baseURL: chat.serverBaseURL,
            model: chat.modelIdentifier,
            messages: titlePrompt
        )

        // Use non-streaming for title generation (simpler)
        var titleRequest = request
        // Modify the body to set stream: false
        // ... or just accumulate the stream

        let stream = client.streamCompletion(request: request)
        var title = ""
        for try await token in stream {
            title += token
        }

        chat.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        // Fall back to truncation
        chat.title = autoTitle(from: chat.sortedMessages.first?.content ?? "New Chat")
    }
}
```

This is a nice-to-have for post-MVP. The truncation approach is perfectly fine for v1.

### Option 3: Hybrid

Use truncation immediately (so the title appears instantly), then replace it with an LLM-generated title once the first response completes. This gives the user immediate feedback while upgrading to a better title in the background.

---

## Regenerate & Edit Messages

### Regenerate Last Response

Delete the last assistant message and re-run generation with the same history.

```swift
func regenerateLastResponse() {
    guard let lastMessage = chat.sortedMessages.last,
          lastMessage.role == "assistant" else { return }

    modelContext.delete(lastMessage)

    // Re-send with the same message history (now minus the deleted response)
    sendMessage()  // This reads from chat.sortedMessages, which no longer
                   // includes the deleted message
}
```

This requires a slight refactor — `sendMessage()` currently reads from `inputText`. You'd split it into two methods: one that handles user input, and one that just triggers generation from the existing history.

```swift
/// Send a new user message and generate a response
func sendUserMessage(_ text: String) {
    let userMessage = Message(role: "user", content: text, chat: chat)
    modelContext.insert(userMessage)
    chat.updatedAt = Date()
    generateResponse()
}

/// Generate an assistant response from the current message history
func generateResponse() {
    // Build API messages from chat.sortedMessages
    // Start streaming task
    // ...
}

/// Delete last assistant message and regenerate
func regenerate() {
    guard let last = chat.sortedMessages.last, last.role == "assistant" else { return }
    modelContext.delete(last)
    generateResponse()
}
```

### Edit a Previous User Message

When the user edits a message, you need to decide what happens to all messages *after* it. The ChatGPT approach is to delete everything after the edited message and regenerate. This is destructive but simple.

```swift
func editMessage(_ message: Message, newContent: String) {
    // Delete all messages after this one
    let sorted = chat.sortedMessages
    guard let index = sorted.firstIndex(where: { $0.id == message.id }) else { return }

    for msg in sorted[(index + 1)...] {
        modelContext.delete(msg)
    }

    // Update the message content
    message.content = newContent

    // Regenerate the assistant response
    generateResponse()
}
```

A more advanced approach (conversation branching) would keep the old messages and create a fork. That's a post-MVP feature that would require a tree structure rather than a flat array.

---

## Search Across Chats

SwiftData supports `#Predicate` for filtering. You can add a search bar to the chat list:

```swift
struct ChatListView: View {
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
    @State private var searchText = ""

    private var filteredChats: [Chat] {
        if searchText.isEmpty { return chats }
        let query = searchText.lowercased()
        return chats.filter { chat in
            chat.title.lowercased().contains(query) ||
            chat.messages.contains { $0.content.lowercased().contains(query) }
        }
    }

    var body: some View {
        List(selection: $selectedChat) {
            ForEach(filteredChats) { chat in
                // ...
            }
        }
        .searchable(text: $searchText, prompt: "Search chats")
    }
}
```

Note: Searching within message content like this does an in-memory scan. For an MVP with reasonable chat volumes (hundreds of chats, not millions) this is fine. If performance becomes an issue, you could use `FetchDescriptor` with `#Predicate` for database-level filtering on the chat title, and only do in-memory search for message content.

---

## Export Chat

A lightweight export feature that converts a chat to Markdown:

```swift
func exportAsMarkdown(chat: Chat) -> String {
    var md = "# \(chat.title)\n\n"
    md += "Model: \(chat.modelIdentifier)\n"
    md += "Date: \(chat.createdAt.formatted())\n\n---\n\n"

    for message in chat.sortedMessages {
        let label = message.role == "user" ? "**You**" : "**Assistant**"
        md += "\(label)\n\n\(message.content)\n\n---\n\n"
    }

    return md
}
```

Wire it up to the iOS share sheet:

```swift
Button {
    let markdown = exportAsMarkdown(chat: chat)
    let activityVC = UIActivityViewController(
        activityItems: [markdown],
        applicationActivities: nil
    )
    // Present it
} label: {
    Label("Export", systemImage: "square.and.arrow.up")
}
```

---

## Data Migration Strategy

SwiftData handles lightweight migrations automatically — adding new properties, adding new models, etc. As long as you provide default values for new properties, SwiftData silently upgrades the schema on app launch.

For example, if in v1.1 you add a `pinned: Bool` property to `Chat`:

```swift
@Model
class Chat {
    // ... existing properties
    var pinned: Bool = false    // Default value = automatic migration
}
```

SwiftData will add the column and set `false` for all existing chats. No migration code needed.

For destructive changes (renaming properties, changing types), you'd need to define a `VersionedSchema` and `SchemaMigrationPlan`. That's unlikely to be needed for v1.

---

## Testing Strategy

### SwiftData Models

Test with in-memory containers so tests are fast and isolated:

```swift
@Test func chatCascadeDelete() throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Chat.self, configurations: config)
    let context = container.mainContext

    let chat = Chat(title: "Test")
    let message = Message(role: "user", content: "Hello", chat: chat)
    context.insert(chat)
    context.insert(message)
    try context.save()

    // Delete chat
    context.delete(chat)
    try context.save()

    // Verify message was cascade-deleted
    let remaining = try context.fetch(FetchDescriptor<Message>())
    #expect(remaining.isEmpty)
}
```

### Chat Operations

Test the business logic functions in isolation:

- `autoTitle(from:)` — pure function, trivial to test
- `exportAsMarkdown(chat:)` — pure function, test against expected output
- Regenerate flow — insert messages, call regenerate, verify the last assistant message was deleted
- Edit flow — insert messages, edit mid-conversation, verify downstream messages deleted

### Navigation

SwiftUI previews are the quickest way to verify navigation behavior. Create previews with pre-populated in-memory containers:

```swift
#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Chat.self, configurations: config)

    // Seed with sample data
    let chat = Chat(title: "Sample Chat")
    container.mainContext.insert(chat)

    return ContentView()
        .modelContainer(container)
}
```

---

## File Checklist

```
Models/
├── Chat.swift                    # @Model class with relationship to Message
└── Message.swift                 # @Model class

Views/
├── ContentView.swift             # NavigationSplitView root
├── ChatList/
│   ├── ChatListView.swift        # @Query-powered list with swipe/context actions
│   └── ChatRow.swift             # Individual row (title, preview, timestamp)
├── ChatDetail/
│   ├── ChatDetailView.swift      # Message list + input bar + streaming
│   └── MessageBubble.swift       # Individual message rendering
└── Settings/
    └── ChatSettingsView.swift    # Per-chat system prompt, model, server overrides

Utilities/
├── ChatTitleGenerator.swift      # Auto-title logic (truncation + optional LLM)
└── ChatExporter.swift            # Markdown/JSON export
```

---

## Open Questions

- **How much history to send?** The full `sortedMessages` array gets sent as context to the API. For long conversations this will eventually exceed the model's context window. Options: truncate from the beginning, summarize older messages, or let the server error and surface it to the user. For MVP, probably just send everything and handle the error gracefully.
- **Pin/archive chats?** A `pinned` flag and an `archived` flag on Chat would let users organize conversations. Low effort, nice QoL.
- **Chat folders/tags?** Probably overkill for v1. Revisit if the user base asks for it.
- **Undo delete?** SwiftData supports `modelContext.undoManager`. You could wire this up so deleted chats can be recovered with a shake gesture or an undo toast. Nice touch but not essential.
