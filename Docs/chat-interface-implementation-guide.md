# Chat Interface — Implementation Guide

## Scope

This document covers the implementation of the chat UI itself: message bubbles, Markdown rendering in responses, code blocks with copy support, streaming text display, auto-scrolling behavior, keyboard management, and the input bar. This is the view layer that sits on top of the data and streaming layers from the previous guides.

---

## The Streaming-vs-Rendered Duality

The single biggest design tension in an LLM chat interface is that you need two rendering modes for assistant messages:

1. **During streaming**: Raw text arriving token-by-token. Needs to be fast and lightweight. Re-rendering expensive Markdown on every token (50+ times per second) will cause jank.
2. **After streaming**: The complete message should render as full Markdown with headers, code blocks, tables, lists, and inline formatting.

The recommended approach: **render plain text during streaming, switch to Markdown once generation completes.** This is what most production chat clients do (including ChatGPT). The transition is imperceptible to the user because the streaming text already displays inline formatting like bold/italic correctly in most cases, and block-level elements (code blocks, tables) only render cleanly once the closing delimiters arrive anyway.

```swift
struct MessageBubble: View {
    let message: Message
    let isStreaming: Bool

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 48) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                messageContent
                    .padding(12)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if message.isPartial {
                    Text("Stopped")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if message.role == "assistant" { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if isStreaming {
            // Fast path: plain text with basic inline Markdown
            Text(LocalizedStringKey(message.content))
                .foregroundStyle(message.role == "user" ? .white : .primary)
        } else {
            // Full Markdown rendering (only for completed messages)
            MarkdownMessageView(content: message.content)
                .foregroundStyle(message.role == "user" ? .white : .primary)
        }
    }

    private var bubbleBackground: Color {
        message.role == "user" ? .blue : Color(.systemGray6)
    }
}
```

---

## Markdown Rendering Options

LLM responses almost always contain Markdown: headers, bold/italic, code blocks, lists, tables, and links. SwiftUI's built-in `Text` only handles inline Markdown (bold, italic, strikethrough, inline code, links). It cannot render block-level elements like code blocks, headers, tables, or lists.

### Option 1: MarkdownUI (Recommended for MVP)

The `swift-markdown-ui` package by Guille Gonzalez is the most mature option. It renders the full GitHub Flavored Markdown spec in native SwiftUI views: headings, lists, task lists, blockquotes, code blocks, tables, thematic breaks, and all inline formatting. It's used in production by apps like X (Grok) and Hugging Face Chat.

```swift
import MarkdownUI

struct MarkdownMessageView: View {
    let content: String

    var body: some View {
        Markdown(content)
            .markdownTheme(.chatAssistant) // Custom theme
            .markdownCodeSyntaxHighlighter(
                .splash(theme: .sundpianosDark(withFont: .init(size: 14)))
            )
            .textSelection(.enabled)
    }
}
```

MarkdownUI supports custom themes for controlling spacing, fonts, and colors across all block types. You can create a theme that matches your chat bubble aesthetic:

```swift
extension MarkdownUI.Theme {
    static let chatAssistant = Theme()
        .text { configuration in
            configuration.label
                .font(.body)
        }
        .code { configuration in
            configuration.label
                .font(.system(.callout, design: .monospaced))
                .padding(12)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    CopyButton(text: configuration.content)
                }
        }
        .heading1 { configuration in
            configuration.label
                .font(.title2.bold())
                .padding(.top, 8)
        }
        .heading2 { configuration in
            configuration.label
                .font(.title3.bold())
                .padding(.top, 6)
        }
}
```

**Status**: MarkdownUI is now in maintenance mode. The author has started a successor called **Textual**, which is a SwiftUI-native text rendering engine that supports both inline and structured content. For an MVP, MarkdownUI v2 is stable and battle-tested. Evaluate Textual for a future version once it matures.

**Trade-off**: Adds a dependency (MarkdownUI depends on `swift-cmark` and `NetworkImage`). But the alternative — building your own Markdown parser and renderer — is weeks of work for an inferior result. This is the right dependency to take on.

### Option 2: Native SwiftUI Text + Manual Block Parsing

If you want zero dependencies, you can use SwiftUI's built-in `Text(LocalizedStringKey(...))` for inline Markdown and manually parse block-level elements:

```swift
struct NativeMarkdownView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseBlocks(content), id: \.id) { block in
                switch block.type {
                case .paragraph(let text):
                    Text(LocalizedStringKey(text))
                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .heading(let text, let level):
                    Text(LocalizedStringKey(text))
                        .font(fontForHeading(level))
                        .bold()
                }
            }
        }
    }
}
```

This approach works but is fragile — you'd need to write a Markdown block splitter that correctly handles fenced code blocks (including nested backticks), lists, blockquotes, and tables. For an MVP, it's not worth the effort. Use MarkdownUI.

### Option 3: Textual (Successor to MarkdownUI)

The new `Textual` library by the same author provides two view types: `InlineText` for inline content and `StructuredText` for full block-level Markdown with syntax highlighting. It has better text selection support and is actively developed.

```swift
import Textual

StructuredText(markdown: message.content)
    .structuredTextStyle(chatStyle)
```

Worth watching as it matures, but for a v1 ship, MarkdownUI is the safer bet due to its larger user base and proven stability.

---

## Code Blocks

Code blocks are the most complex rendering element in an LLM chat. They need:

1. A monospaced font in a distinct container
2. Syntax highlighting (nice-to-have for v1)
3. A language label (when specified in the fence)
4. A **Copy** button
5. Horizontal scrolling for long lines

### Code Block View

```swift
struct CodeBlockView: View {
    let code: String
    let language: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar with language label and copy button
            HStack {
                Text(language?.capitalized ?? "Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray4))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
```

### Syntax Highlighting

For v1, monospaced text with a dark background is sufficient — it's immediately recognizable as code. For v2, two options:

**Splash** by John Sundell — a Swift syntax highlighter that integrates with MarkdownUI directly. Limited to Swift.

**Regex-based highlighting** — write simple regex patterns to color keywords, strings, and comments for common languages. Cheap to implement, looks good enough.

**TreeSitter** — professional-grade parsing for many languages, but heavy and complex to integrate. Overkill for v1.

---

## Copy Button on Individual Messages

Beyond code blocks, users want to copy entire messages. A long-press context menu or a dedicated button works well:

```swift
struct MessageActions: View {
    let message: Message
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = message.content
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Regenerate button (only on last assistant message)
            // Share button, etc.
        }
    }
}
```

Place this below the message bubble for assistant messages. It stays hidden until the user hovers (on iPad/Mac) or appears on tap (on iPhone). You can also use `.contextMenu` for a long-press approach:

```swift
.contextMenu {
    Button {
        UIPasteboard.general.string = message.content
    } label: {
        Label("Copy", systemImage: "doc.on.doc")
    }

    ShareLink(item: message.content)

    if isLastAssistantMessage {
        Button {
            // regenerate
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
        }
    }
}
```

---

## Scrolling Behavior

Chat interfaces have specific scrolling requirements that differ from standard lists.

### Bottom Anchoring

The scroll view should start anchored to the bottom (newest messages visible) and stay there as new content arrives. SwiftUI provides `.defaultScrollAnchor(.bottom)` for this:

```swift
ScrollView {
    LazyVStack(alignment: .leading, spacing: 12) {
        // messages...
    }
    .padding()
}
.defaultScrollAnchor(.bottom)
```

This handles two cases automatically: the initial scroll position starts at the bottom, and when content size changes (keyboard appears, new messages added), the scroll position stays anchored to the bottom — unless the user has manually scrolled up.

### Auto-Scroll During Streaming

During token generation, new text appends to the streaming message, growing its height. You need to keep scrolling to the bottom so the user can see new tokens arriving.

```swift
ScrollViewReader { proxy in
    ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(chat.sortedMessages) { message in
                MessageBubble(message: message, isStreaming: false)
                    .id(message.id)
            }

            if isStreaming && !streamingText.isEmpty {
                MessageBubble(
                    message: Message(role: "assistant", content: streamingText),
                    isStreaming: true
                )
                .id("streaming")
            }
        }
        .padding()
    }
    .defaultScrollAnchor(.bottom)
    .onScrollGeometryChange(for: CGSize.self, of: { $0.contentSize }) { _, _ in
        if isStreaming {
            withAnimation(.easeOut(duration: 0.05)) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
    }
}
```

### User Override: Don't Fight the Scroll

If the user scrolls up while generation is happening (to re-read something), the auto-scroll should stop. This requires tracking whether the user has manually disengaged from the bottom.

```swift
@State private var isNearBottom = true

ScrollView {
    // messages...
}
.onScrollGeometryChange(for: Bool.self, of: { geometry in
    let distanceFromBottom = geometry.contentSize.height
        - geometry.contentOffset.y
        - geometry.containerSize.height
    return distanceFromBottom < 100  // Within 100pt of bottom
}) { _, isNear in
    isNearBottom = isNear
}
```

Then only auto-scroll when `isNearBottom` is true:

```swift
.onScrollGeometryChange(for: CGSize.self, of: { $0.contentSize }) { _, _ in
    if isStreaming && isNearBottom {
        proxy.scrollTo("streaming", anchor: .bottom)
    }
}
```

### Scroll-to-Bottom FAB

When the user has scrolled up and new content arrives, show a floating button to jump back to the bottom:

```swift
if !isNearBottom {
    VStack {
        Spacer()
        HStack {
            Spacer()
            Button {
                withAnimation {
                    proxy.scrollTo(
                        isStreaming ? "streaming" : chat.sortedMessages.last?.id,
                        anchor: .bottom
                    )
                }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.blue)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
            .padding(.trailing)
            .padding(.bottom, 8)
        }
    }
    .transition(.move(edge: .bottom).combined(with: .opacity))
}
```

---

## Keyboard Management

### Automatic Avoidance

SwiftUI handles keyboard avoidance automatically when a `TextField` or `TextEditor` is inside a view hierarchy. When the keyboard appears, SwiftUI adjusts the safe area insets, which pushes the input bar up. Since the message list is in a `ScrollView` above the input bar, the entire layout responds correctly.

The key is structuring the view as a `VStack` with the `ScrollView` taking flexible space and the input bar at the bottom:

```swift
VStack(spacing: 0) {
    ScrollView {
        // messages
    }

    Divider()

    InputBar(text: $inputText, onSend: sendMessage, ...)
        // This stays above the keyboard automatically
}
```

SwiftUI's default keyboard avoidance works here because the `VStack` adjusts its bottom safe area when the keyboard appears, shrinking the `ScrollView` and keeping the `InputBar` visible.

### Dismiss on Scroll

Use `.scrollDismissesKeyboard(.interactively)` on the `ScrollView` to let users drag the keyboard down by scrolling — the same behavior as iMessage:

```swift
ScrollView {
    // messages
}
.scrollDismissesKeyboard(.interactively)
```

The `.interactively` option lets the user partially dismiss the keyboard by dragging, which feels much more natural than `.immediately` (which dismisses on any scroll).

### Dismiss on Send

After sending a message, you might want to keep the keyboard open (so the user can continue typing) or dismiss it. Most chat apps keep it open. If you want to dismiss:

```swift
@FocusState private var isInputFocused: Bool

TextField("Message", text: $inputText)
    .focused($isInputFocused)

// In send action:
func sendMessage() {
    // ... send logic
    // isInputFocused = false  // Uncomment to dismiss keyboard
}
```

---

## The Input Bar

The input bar needs to handle multi-line text, expand vertically as the user types, and switch between Send and Stop buttons based on streaming state.

```swift
struct InputBar: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .focused($isFocused)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))

            actionButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
        } else {
            Button(action: {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onSend()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? .gray
                            : .blue
                    )
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
```

### Design Details

**`.lineLimit(1...6)`** — The `TextField` starts as a single line and expands up to 6 lines as the user types. Beyond 6 lines, it scrolls internally. This prevents the input bar from consuming too much screen space.

**`axis: .vertical`** — This is what enables multi-line expansion in `TextField`. Without it, the field stays single-line.

**Rounded pill shape** — The `.clipShape(RoundedRectangle(cornerRadius: 20))` gives the input field a Messages-style pill appearance. This is purely aesthetic but matches user expectations for a chat app.

**Send button coloring** — The button is gray when the input is empty (disabled state) and blue when there's text. This provides clear visual feedback about whether sending is possible.

---

## Streaming Text Performance

As discussed in the SSE guide, fast models can produce 50+ tokens per second, each triggering a `@Published` update and a SwiftUI view re-render. Here's the performance strategy:

### During Streaming: Use Plain `Text`

SwiftUI's `Text` view is highly optimized for string updates. Appending to a string and re-rendering a `Text` view is nearly free.

```swift
if isStreaming {
    Text(streamingText)
        .font(.body)
        .textSelection(.enabled)
}
```

Do **not** pass the streaming text through a Markdown parser on every update. `Markdown(streamingText)` would re-parse the entire string on every token, which is expensive.

### After Streaming: Switch to Full Markdown

Once generation completes, the message is saved to SwiftData and rendered via the standard `MessageBubble` with full Markdown.

### Optional: Token Batching

If you observe jank even with plain `Text` (unlikely but possible with very fast models or complex view hierarchies), batch token updates:

```swift
@MainActor
class StreamingBuffer: ObservableObject {
    @Published var displayText: String = ""
    private var buffer: String = ""
    private var flushTimer: Timer?

    func start() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.buffer.isEmpty else { return }
                self.displayText += self.buffer
                self.buffer = ""
            }
        }
    }

    func append(_ token: String) {
        buffer += token
    }

    func stop() -> String {
        flushTimer?.invalidate()
        displayText += buffer
        buffer = ""
        return displayText
    }
}
```

This caps view updates at ~20/second (every 50ms) regardless of token rate.

---

## Typing Indicator

While waiting for the first token (time-to-first-token can be significant for local models), show a typing indicator:

```swift
struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(index) * 0.2),
                        value: animating
                    )
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { animating = true }
    }
}
```

Show it in the message list between when the user sends a message and when the first token arrives:

```swift
if isStreaming && streamingText.isEmpty {
    HStack {
        TypingIndicator()
        Spacer()
    }
    .id("typing")
}
```

---

## Text Selection

SwiftUI's `.textSelection(.enabled)` modifier lets users select and copy text from `Text` views. Apply it to the message content:

```swift
Text(attributedContent)
    .textSelection(.enabled)
```

Note: `.textSelection(.enabled)` works well on individual `Text` views. When using MarkdownUI, text selection is supported natively within the `Markdown` view. The newer Textual library has improved text selection support as one of its main differentiators.

---

## Empty State

When a chat has no messages, show a welcoming empty state instead of a blank screen:

```swift
if chat.sortedMessages.isEmpty && !isStreaming {
    ContentUnavailableView {
        Label("Start a Conversation", systemImage: "bubble.left.and.text.bubble.right")
    } description: {
        Text("Send a message to begin chatting with \(chat.modelIdentifier)")
    }
}
```

Or use it as an opportunity to show prompt suggestions — tappable pills that pre-fill the input:

```swift
VStack(spacing: 12) {
    Text("Try asking...")
        .font(.headline)
        .foregroundStyle(.secondary)

    ForEach(suggestions, id: \.self) { suggestion in
        Button {
            inputText = suggestion
        } label: {
            Text(suggestion)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
```

---

## Haptics

Subtle haptic feedback improves the feel of interactions:

```swift
// On message send
UIImpactFeedbackGenerator(style: .light).impactOccurred()

// On copy
UINotificationFeedbackGenerator().notificationOccurred(.success)

// On stop generation
UIImpactFeedbackGenerator(style: .medium).impactOccurred()
```

Keep it minimal — haptics on every token would be awful.

---

## Dark Mode / Theming

SwiftUI handles dark mode automatically when you use semantic colors like `Color(.systemGray6)`, `Color.primary`, etc. The message bubbles, code blocks, and input bar will all adapt.

For the user message bubble, `.blue` works in both modes. For the assistant bubble, `Color(.systemGray6)` provides appropriate contrast in both light and dark.

Code blocks should use a slightly darker background than the assistant bubble to create visual separation: `Color(.systemGray5)` in the light mode, which automatically adapts.

---

## Accessibility

### Dynamic Type

Use semantic font styles (`.body`, `.caption`, `.title2`) instead of fixed sizes. SwiftUI automatically scales these with the user's Dynamic Type setting.

### VoiceOver

- Message bubbles should include role information: `.accessibilityLabel("\(message.role == "user" ? "You" : "Assistant") said: \(message.content)")`
- The send button: `.accessibilityLabel("Send message")`
- The stop button: `.accessibilityLabel("Stop generating")`
- The copy button: `.accessibilityLabel("Copy message")`

### Reduce Motion

Respect the user's Reduce Motion setting for the typing indicator animation:

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

// In TypingIndicator:
if reduceMotion {
    Text("...")
        .font(.title2)
} else {
    // animated circles
}
```

---

## Full View Composition

Putting it all together, here's how the pieces compose in the `ChatDetailView`:

```swift
struct ChatDetailView: View {
    @Bindable var chat: Chat
    @Environment(\.modelContext) private var modelContext

    @State private var inputText = ""
    @State private var streamingText = ""
    @State private var isStreaming = false
    @State private var isNearBottom = true
    @State private var error: String?
    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                messageList
                if let error { errorBanner(error) }
                Divider()
                InputBar(
                    text: $inputText,
                    isStreaming: isStreaming,
                    onSend: sendMessage,
                    onStop: stopGenerating
                )
            }

            // Scroll-to-bottom FAB
            if !isNearBottom {
                scrollToBottomButton
                    .padding(.bottom, 80) // Above input bar
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .animation(.easeOut(duration: 0.2), value: isNearBottom)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Empty state
                    if chat.sortedMessages.isEmpty && !isStreaming {
                        emptyState
                    }

                    // Persisted messages (full Markdown)
                    ForEach(chat.sortedMessages) { message in
                        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                            MessageBubble(message: message, isStreaming: false)
                                .id(message.id)

                            if message.role == "assistant" {
                                MessageActions(message: message)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
                    }

                    // Typing indicator (waiting for first token)
                    if isStreaming && streamingText.isEmpty {
                        HStack {
                            TypingIndicator()
                            Spacer()
                        }
                    }

                    // Streaming message (plain text, live)
                    if isStreaming && !streamingText.isEmpty {
                        HStack {
                            MessageBubble(
                                message: Message(role: "assistant", content: streamingText),
                                isStreaming: true
                            )
                            Spacer(minLength: 48)
                        }
                        .id("streaming")
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self, of: { geo in
                let distance = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distance < 100
            }) { _, isNear in
                isNearBottom = isNear
            }
            .onScrollGeometryChange(for: CGSize.self, of: { $0.contentSize }) { _, _ in
                if isStreaming && isNearBottom {
                    withAnimation(.easeOut(duration: 0.05)) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
        }
    }
}
```

---

## Dependency Summary

| Component | Source | Required? |
|---|---|---|
| MarkdownUI | SPM: `gonzalezreal/swift-markdown-ui` | Recommended |
| Splash | SPM: `JohnSundell/Splash` | Optional (syntax highlighting) |
| Everything else | SwiftUI + Foundation | Built-in |

The only external dependency for the chat interface is MarkdownUI (and optionally Splash for syntax highlighting). All scrolling, keyboard handling, haptics, text selection, and theming use native SwiftUI APIs.

---

## Testing Strategy

### Snapshot Tests

The visual nature of the chat interface makes snapshot testing valuable. MarkdownUI itself uses `swift-snapshot-testing` for this. You can do the same:

- Render a `MessageBubble` with various content types (plain text, markdown with code blocks, long messages, short messages) and snapshot the result.
- Test both light and dark mode snapshots.
- Test Dynamic Type at various sizes.

### Unit Tests

- `parseBlocks()` (if using native rendering): Pure function, test with various Markdown inputs.
- `StreamingBuffer`: Test that batching works correctly — append tokens, verify `displayText` updates on flush.
- Copy button: Verify `UIPasteboard.general.string` is set correctly.

### Manual Testing Checklist

- Send a message and verify it appears as a user bubble on the right
- Verify streaming text appears token-by-token in an assistant bubble on the left
- Verify Markdown renders correctly after generation completes (bold, code blocks, lists, headers)
- Tap Copy on a code block — verify clipboard content
- Scroll up during generation — verify auto-scroll stops
- Tap scroll-to-bottom FAB — verify it jumps to the latest content
- Open keyboard — verify input bar stays visible and messages don't get obscured
- Drag to dismiss keyboard — verify interactive dismissal works
- Send a very long message — verify the input bar expands and then contracts after send
- Test with Dynamic Type at largest accessibility size

---

## File Checklist

```
Views/ChatDetail/
├── ChatDetailView.swift          # Main composition (messageList + inputBar + FAB)
├── MessageBubble.swift           # Role-aware bubble with streaming/rendered modes
├── MarkdownMessageView.swift     # MarkdownUI wrapper with custom theme
├── CodeBlockView.swift           # Fenced code block with copy button
├── MessageActions.swift          # Copy/regenerate/share buttons below messages
├── InputBar.swift                # Multi-line text field + send/stop button
├── TypingIndicator.swift         # Animated dots for TTFT wait
└── ScrollToBottomButton.swift    # FAB for jumping back to latest content

Theme/
├── MarkdownTheme+Chat.swift      # Custom MarkdownUI theme for chat bubbles
└── Colors.swift                  # Semantic color constants
```
