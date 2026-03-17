# Local LLM Chat Client — Technical Requirements Brainstorm

## Concept

A free, native iOS chat client that connects to any OpenAI-compatible API endpoint on a user's local network (or remotely via VPN/tunnel). Zero backend infrastructure — users bring their own LLM server (LM Studio, llama.cpp, Ollama, vLLM, etc.). Zero hosting costs for the developer.

---

## Target API Spec

The app targets the OpenAI-compatible API, which is the de facto standard across local LLM servers.

### Endpoints to Support

| Endpoint | Purpose | Priority |
|---|---|---|
| `GET /v1/models` | Auto-discover loaded models for model picker | P0 |
| `POST /v1/chat/completions` | Core chat functionality | P0 |
| `POST /v1/completions` | Legacy completions (raw prompt mode) | P2 |
| `POST /v1/embeddings` | Embeddings (future RAG features) | P3 |
| `POST /v1/responses` | OpenAI's newer stateful API (LM Studio 0.3.29+) | P2 |

### Compatible Servers (Out of the Box)

- LM Studio
- llama.cpp / llama-server
- Ollama (via its OpenAI compatibility layer)
- vLLM
- LocalAI
- Text Generation WebUI (with OpenAI extension)
- Any server implementing the OpenAI chat completions spec

---

## Core Architecture

### Networking Layer

- HTTP client targeting OpenAI-compatible API spec
- **SSE (Server-Sent Events) streaming** — essential for real-time token-by-token rendering; this is how `/v1/chat/completions` streams responses when `"stream": true`
- Non-streaming fallback for servers or configurations that don't support SSE
- Configurable base URL (e.g., `http://192.168.1.100:1234/v1`)
- Generous timeout handling — local models can have slow time-to-first-token (TTFT) due to prompt processing and cold starts; a 60–120s TTFT timeout is reasonable
- Reachability detection — differentiate between server unreachable, model loading, and actively generating
- Optional TLS support for users connecting through Tailscale, Cloudflare Tunnel, ngrok, etc.
- Optional API key / Bearer token field for servers that require authentication

### Platform & Language

- **SwiftUI** — native iOS, modern declarative UI
- Minimum target: iOS 17 (balances modern APIs with device coverage)
- URLSession for networking (native, no dependencies needed for SSE parsing)
- Swift Concurrency (async/await, AsyncSequence for streaming)
- No required third-party dependencies for the core app — keep it lean

### Data Persistence

- **SwiftData** (or Core Data) for local chat history, server configurations, and preferences
- All data stored on-device only
- No cloud requirement for core functionality
- Optional iCloud sync via CloudKit for chat history across devices (P2)

---

## MVP Feature Set (v1.0)

### Server Connection

- Add/edit/delete server configurations (name, URL, optional API key)
- Server health check / connectivity indicator (green/red dot)
- Auto-discover available models via `GET /v1/models`
- Model picker dropdown populated from the models endpoint
- Support multiple saved server profiles (e.g., "MacBook - LM Studio", "Desktop - llama.cpp")

### Chat Interface

- Clean, conversational UI (messages list with user/assistant bubbles)
- Real-time streaming token display as the model generates
- Markdown rendering in responses (code blocks, bold, italic, lists, tables)
- Syntax-highlighted code blocks
- Copy button on individual messages and code blocks
- Stop generation button (cancel the in-flight request)
- Auto-scroll during generation with manual scroll override (don't fight the user)
- Keyboard management — smooth text input experience

### Chat Management

- Multiple concurrent chat threads
- Chat list / history sidebar or tab
- Rename and delete chats
- New chat button that clears context

### Message Features

- System prompt field (per-chat or global default)
- Edit and resend previous user messages
- Regenerate last assistant response
- Message timestamps

### Model Parameters

- Temperature slider
- Max tokens
- Top-p
- Frequency / presence penalty
- Stop sequences
- Expose these in a collapsible settings panel per chat or globally

---

## Post-MVP Features (v1.x+)

### Enhanced Chat

- Conversation forking / branching (edit a message mid-conversation, keep both branches)
- Search across chat history
- Export chat as markdown, JSON, or plain text
- Share individual responses via iOS share sheet
- Image input for multimodal models (send photos to vision models via the API's image_url content type)
- Voice input via iOS Speech framework → transcribe → send as text

### Server Management

- Bonjour/mDNS auto-discovery of local LLM servers on the network (if servers advertise themselves)
- Server stats display — tokens/second, TTFT, context window usage
- Model info display (quantization, parameter count, context length) from the models endpoint metadata
- Pull/load/unload models on servers that support it (Ollama API, LM Studio native API)

### Personalization

- Custom themes / dark mode / OLED black mode
- Adjustable font size (accessibility)
- Configurable chat bubble styles
- Prompt templates / saved system prompts library
- Quick-action prompt shortcuts (e.g., "Summarize this", "Explain like I'm 5")

### Sync & Backup

- iCloud sync for chat history and server configs via CloudKit
- Local export/import of all data (JSON backup)

### iPad & Mac Support

- iPad layout with sidebar navigation
- Mac Catalyst or native macOS target
- Keyboard shortcuts on iPad/Mac

### Advanced Networking

- Tailscale / WireGuard integration guidance or deep links
- Connection profiles that remember which network → which server
- Background generation with local notifications when complete (within iOS limits)

---

## Technical Considerations

### SSE Streaming Implementation

This is the most critical technical piece. Options:

1. **URLSession with `bytes` async sequence** — parse SSE manually from the raw byte stream. No dependencies. Each line starting with `data: ` contains a JSON chunk. Stream ends with `data: [DONE]`.
2. **Third-party SSE library** — e.g., LDSwiftEventSource. Adds a dependency but handles reconnection and edge cases.
3. Recommendation: Start with option 1 to keep dependencies at zero. The SSE format from OpenAI-compatible servers is simple enough to parse manually.

```
data: {"id":"chatcmpl-xxx","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"},"index":0}]}

data: {"id":"chatcmpl-xxx","object":"chat.completion.chunk","choices":[{"delta":{"content":" world"},"index":0}]}

data: [DONE]
```

### Conversation Context Management

- The client is responsible for maintaining the messages array and sending the full conversation history with each request
- Need to track token usage and warn when approaching the model's context window limit
- Implement context window strategies: truncate oldest messages, summarize, or let the user manage manually
- Token counting is tricky without knowing the exact tokenizer — approximate with a character-based heuristic or use tiktoken if bundling a tokenizer is feasible

### Error Handling

- Server unreachable (network error)
- Model not loaded / no models available
- Context length exceeded
- Generation timeout
- Malformed responses from non-standard servers
- Rate limiting (unlikely for local but possible)
- Present all errors clearly in the UI, not just silently fail

### Privacy & Security

- Zero analytics, zero telemetry, zero data collection
- All data on-device
- No outbound network calls except to the user's configured server
- API keys stored in iOS Keychain, not in plain UserDefaults
- App Transport Security (ATS) — local HTTP connections will need ATS exceptions for non-TLS local IPs; handle this cleanly in Info.plist
- Clear privacy nutrition label on the App Store: "No Data Collected"

---

## App Store Strategy

### Positioning

- Free, open-source (optional — builds trust in this community)
- Privacy-first messaging
- "Works with LM Studio, llama.cpp, Ollama, vLLM, and any OpenAI-compatible server"
- Keywords: local LLM, self-hosted AI, private AI chat, OpenAI compatible

### Monetization Options (All Optional)

- Tip jar (like Pal Chat's model)
- One-time paid "Pro" unlock for cosmetic features (themes, icons)
- Keep core functionality entirely free to differentiate from Pal Chat
- No subscriptions, no ads — this is a differentiator

### Costs

| Item | Cost |
|---|---|
| Apple Developer Program | $99/year |
| Backend infrastructure | $0 |
| API costs | $0 |
| Scaling costs | $0 |

---

## Project Structure (Suggested)

```
LocalChat/
├── App/
│   ├── LocalChatApp.swift          # App entry point
│   └── ContentView.swift           # Root navigation
├── Models/
│   ├── ServerConfig.swift          # Server connection model
│   ├── Chat.swift                  # Chat thread model
│   ├── Message.swift               # Individual message model
│   └── LLMModel.swift              # Model info from /v1/models
├── Services/
│   ├── OpenAIClient.swift          # API client (chat completions, models)
│   ├── SSEParser.swift             # Server-Sent Events stream parser
│   └── ServerDiscovery.swift       # Reachability & model discovery
├── ViewModels/
│   ├── ChatViewModel.swift         # Chat screen logic & streaming state
│   ├── ServerListViewModel.swift   # Server management
│   └── SettingsViewModel.swift     # App-wide settings
├── Views/
│   ├── Chat/
│   │   ├── ChatView.swift          # Main chat interface
│   │   ├── MessageBubble.swift     # Individual message rendering
│   │   ├── StreamingText.swift     # Animated token-by-token text
│   │   └── CodeBlockView.swift     # Syntax-highlighted code
│   ├── Servers/
│   │   ├── ServerListView.swift    # List of saved servers
│   │   └── ServerFormView.swift    # Add/edit server
│   ├── Settings/
│   │   └── SettingsView.swift      # Global preferences
│   └── Components/
│       ├── ModelPicker.swift       # Dropdown from /v1/models
│       ├── ParameterSliders.swift  # Temperature, top-p, etc.
│       └── StatusIndicator.swift   # Server connectivity dot
├── Utilities/
│   ├── MarkdownRenderer.swift      # Markdown → AttributedString
│   └── TokenEstimator.swift        # Approximate token counting
└── Resources/
    └── Assets.xcassets
```

---

## Open Questions

- **Name?** Needs to be discoverable in App Store search for "local LLM", "OpenAI compatible", etc.
- **Open source?** The local LLM community strongly favors open-source tools. Going open source on GitHub could drive adoption and contributions, but gives competitors a head start on cloning.
- **Ollama-native support too?** Ollama's API is slightly different from OpenAI-compatible (different endpoints for model management, pull, etc.). Supporting both API flavors would make this a universal client and directly compete with Reins/Enchanted.
- **How to handle the context window problem?** Without knowing the tokenizer, accurate context tracking is hard. Could query model metadata if the server exposes max_context_length.
- **watchOS / visionOS?** Stretch goals, but visionOS especially could be interesting for the local AI crowd.
