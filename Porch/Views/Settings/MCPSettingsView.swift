import SwiftUI

struct MCPSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var isAddingServer = false
    @State private var showInvalidURLError = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newAuthHeader = ""

    var body: some View {
        DisclosureGroup("MCP Servers") {
            if settings.mcpServerConfigs.isEmpty {
                Text("No MCP servers configured.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(settings.mcpServerConfigs) { config in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name)
                            .font(.subheadline.weight(.medium))
                        Text(config.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Toggle("", isOn: binding(for: config.id, keyPath: \.isEnabled))
                        .labelsHidden()
                }
            }
            .onDelete(perform: deleteServers)

            Button("Add MCP Server") {
                newName = ""
                newURL = ""
                newAuthHeader = ""
                isAddingServer = true
            }
        }
        .alert("Add MCP Server", isPresented: $isAddingServer) {
            TextField("Name", text: $newName)
            TextField("Server URL (http://...)", text: $newURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Authorization header (optional)", text: $newAuthHeader)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Add") {
                let trimmedURL = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedURL.isEmpty, URL(string: trimmedURL) != nil else {
                if !trimmedURL.isEmpty {
                    showInvalidURLError = true
                }
                return
            }

                let config = MCPServerConfig(
                    name: trimmedName.isEmpty ? "MCP Server" : trimmedName,
                    url: trimmedURL,
                    authorizationHeader: newAuthHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : newAuthHeader.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                var configs = settings.mcpServerConfigs
                configs.append(config)
                settings.mcpServerConfigs = configs
            }

            Button("Cancel", role: .cancel) {}
        }
        .alert("Invalid URL", isPresented: $showInvalidURLError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter a valid server URL (e.g. http://localhost:3000/mcp).")
        }
    }

    private func deleteServers(at offsets: IndexSet) {
        var configs = settings.mcpServerConfigs
        configs.remove(atOffsets: offsets)
        settings.mcpServerConfigs = configs
    }

    private func binding(for configID: UUID, keyPath: WritableKeyPath<MCPServerConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                settings.mcpServerConfigs.first { $0.id == configID }?[keyPath: keyPath] ?? false
            },
            set: { newValue in
                var configs = settings.mcpServerConfigs
                if let index = configs.firstIndex(where: { $0.id == configID }) {
                    configs[index][keyPath: keyPath] = newValue
                    settings.mcpServerConfigs = configs
                }
            }
        )
    }
}
