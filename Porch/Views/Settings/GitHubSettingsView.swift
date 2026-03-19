import SwiftUI
import SwiftData

struct GitHubSettingsView: View {
    let settings: AppSettings
    let keychain: KeychainStoreProtocol

    @State private var token: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var didLoadToken = false

    private let keychainAccount = "github-pat"

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                Text("Connect your GitHub account to let the AI search repositories, read files, browse issues and pull requests, and prepare branch-and-commit changes that still require your approval before anything is written.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Personal Access Token") {
                SecureField("ghp_...", text: $token)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .onChange(of: token) { _, newValue in
                        saveToken(newValue)
                    }

                Text("Create a token at GitHub Settings > Developer settings > Personal access tokens. For private repos, classic 'repo' scope works. For fine-grained tokens, grant repository contents write access if you want Porch to create branches and push approved commits.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Connection") {
                Toggle("Enable GitHub Connector", isOn: Binding(
                    get: { settings.isGitHubConnectorEnabled },
                    set: { newValue in
                        settings.isGitHubConnectorEnabled = newValue
                        settings.markUpdated()
                    }
                ))

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                            Text("Testing...")
                        } else {
                            Label("Test Connection", systemImage: "network")
                        }
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if let testResult {
                    HStack {
                        switch testResult {
                        case .success(let username):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected as \(username)")
                                .foregroundStyle(.primary)
                        case .failure(let message):
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
            }

            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Button(role: .destructive) {
                        token = ""
                        saveToken("")
                        testResult = nil
                        settings.isGitHubConnectorEnabled = false
                        settings.markUpdated()
                    } label: {
                        Label("Remove Token", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !didLoadToken else { return }
            didLoadToken = true
            token = (try? keychain.read(account: keychainAccount)) ?? ""
        }
    }

    private func saveToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? keychain.delete(account: keychainAccount)
        } else {
            try? keychain.save(trimmed, account: keychainAccount)
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            testResult = .failure("No token provided.")
            return
        }

        let client = GitHubAPIClient(token: trimmed)
        do {
            let user = try await client.getAuthenticatedUser()
            testResult = .success(user.login)
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
