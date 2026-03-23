import Combine
import Foundation
import os

@MainActor
final class GitHubContextSelectionViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "com.porch.app", category: "GitHubContext")
    @Published var searchQuery = ""
    @Published private(set) var availableRepositories: [GitHubRepository] = []
    @Published var ownerInput = ""
    @Published var repoInput = ""
    @Published var expandedManualBranchInput = ""
    @Published private(set) var expandedRepositoryFullName: String?
    @Published private(set) var isLoadingAccessibleRepositories = false
    @Published private(set) var isLoadingRepository = false
    @Published private(set) var isValidatingBranch = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var repoListErrorMessage: String?
    @Published private(set) var expandedBranchValidationMessage: String?
    @Published private(set) var isExpandedBranchValid = false

    private let keychain: KeychainStoreProtocol
    private let session: URLSession
    private let initialContext: GitHubChatContext?
    private let keychainAccount = "github-pat"

    private var didLoadInitialContext = false
    private var didLoadAccessibleRepositories = false
    private var repositoryMetadataCache: [String: GitHubRepositoryMetadata] = [:]
    private var branchCache: [String: [GitHubBranchSummary]] = [:]
    private var branchLoadErrors: [String: String] = [:]
    private var branchLoadingRepositories = Set<String>()
    private var draftRepositoryMetadata: GitHubRepositoryMetadata?
    private var draftBranchName = ""
    private var isDraftBranchValid = false
    private var draftBranchValidationMessage: String?

    init(
        initialContext: GitHubChatContext?,
        keychain: KeychainStoreProtocol = KeychainStore(),
        session: URLSession = .shared
    ) {
        self.initialContext = initialContext
        self.keychain = keychain
        self.session = session
        if let initialContext {
            ownerInput = initialContext.owner
            repoInput = initialContext.repo
        }
    }

    var canSave: Bool {
        selectedContextDraft != nil
    }

    var hasDraftSelection: Bool {
        draftRepositoryMetadata != nil || !draftBranchName.isEmpty
    }

    var filteredAvailableRepositories: [GitHubRepository] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return availableRepositories
        }

        return availableRepositories.filter { repository in
            repository.full_name.localizedCaseInsensitiveContains(trimmedQuery) ||
            (repository.description?.localizedCaseInsensitiveContains(trimmedQuery) ?? false) ||
            (repository.language?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    var selectedContextDraft: GitHubChatContext? {
        guard
            let draftRepositoryMetadata,
            isDraftBranchValid
        else {
            return nil
        }

        let branch = draftBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            return nil
        }

        return GitHubChatContext(
            owner: draftRepositoryMetadata.owner.login,
            repo: draftRepositoryMetadata.name,
            fullName: draftRepositoryMetadata.full_name,
            branch: branch
        )
    }

    func loadAccessibleRepositoriesIfNeeded() async {
        guard !didLoadAccessibleRepositories else { return }
        await reloadAccessibleRepositories()
    }

    func reloadAccessibleRepositories() async {
        guard !isLoadingAccessibleRepositories else { return }

        isLoadingAccessibleRepositories = true
        repoListErrorMessage = nil
        defer { isLoadingAccessibleRepositories = false }

        do {
            let client = try makeClient()
            let perPage = 100
            var page = 1
            var mergedRepositories = availableRepositories

            while true {
                let repositories = try await client.listAccessibleRepositories(page: page, perPage: perPage)
                mergeAccessibleRepositories(repositories, into: &mergedRepositories)
                availableRepositories = mergedRepositories

                if repositories.count < perPage {
                    break
                }

                page += 1
            }

            Self.logger.info("[repoList] loaded repositoryCount=\(mergedRepositories.count)")
            didLoadAccessibleRepositories = true
        } catch {
            Self.logger.error("[repoList] error=\(error.localizedDescription, privacy: .public)")
            didLoadAccessibleRepositories = false
            repoListErrorMessage = error.localizedDescription
        }
    }

    func loadInitialContextIfNeeded() async {
        guard !didLoadInitialContext else { return }
        didLoadInitialContext = true

        guard let initialContext else { return }

        do {
            let details = try await fetchRepositoryDetails(owner: initialContext.owner, repo: initialContext.repo)
            storeRepositoryDetails(details)
            upsertAvailableRepository(from: details.metadata)
            ownerInput = details.metadata.owner.login
            repoInput = details.metadata.name
            expandedRepositoryFullName = details.metadata.full_name
            applyDraftSelection(
                metadata: details.metadata,
                branch: initialContext.branch,
                isValid: details.branches.contains(where: { $0.name == initialContext.branch }),
                validationMessage: nil
            )

            if !isDraftBranchValid {
                await validateBranchForExpandedRepository(
                    metadata: details.metadata,
                    branches: details.branches,
                    branch: initialContext.branch,
                    shouldMutateDraftOnFailure: true
                )
            } else {
                syncExpandedDraftState(for: details.metadata.full_name)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleRepositoryExpansion(_ repository: GitHubRepository) async {
        let fullName = repository.full_name

        if expandedRepositoryFullName == fullName {
            expandedRepositoryFullName = nil
            expandedManualBranchInput = ""
            expandedBranchValidationMessage = nil
            isExpandedBranchValid = false
            return
        }

        expandedRepositoryFullName = fullName
        syncExpandedDraftState(for: fullName)
        await ensureRepositoryDetailsLoaded(for: repository)
    }

    func retryExpandedRepositoryBranches() async {
        guard let repository = expandedRepository else { return }
        await ensureRepositoryDetailsLoaded(for: repository, forceReload: true)
    }

    func selectBranch(_ branch: GitHubBranchSummary, for repository: GitHubRepository) {
        guard
            let metadata = metadata(for: repository),
            let repositoryKey = repositoryKey(for: repository)
        else {
            errorMessage = "Load repository details before selecting a branch."
            return
        }

        applyDraftSelection(
            metadata: metadata,
            branch: branch.name,
            isValid: true,
            validationMessage: "Using branch \(branch.name)."
        )
        branchLoadErrors[repositoryKey] = nil
        syncExpandedDraftState(for: repository.full_name)
    }

    func validateExpandedManualBranch() async {
        guard
            let repository = expandedRepository,
            let metadata = metadata(for: repository)
        else {
            isExpandedBranchValid = false
            expandedBranchValidationMessage = "Expand a repository first."
            return
        }

        let branches = branches(for: repository)
        let trimmedBranch = expandedManualBranchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        await validateBranchForExpandedRepository(
            metadata: metadata,
            branches: branches,
            branch: trimmedBranch,
            shouldMutateDraftOnFailure: isRepositorySelected(repository)
        )
    }

    func loadManualRepository() async {
        let owner = ownerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = repoInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repo.isEmpty else {
            errorMessage = "Enter both an owner and repository name."
            return
        }

        Self.logger.info("[loadRepo] owner=\(owner, privacy: .public) repo=\(repo, privacy: .public)")
        isLoadingRepository = true
        errorMessage = nil
        defer { isLoadingRepository = false }

        do {
            let details = try await fetchRepositoryDetails(owner: owner, repo: repo)
            storeRepositoryDetails(details)
            upsertAvailableRepository(from: details.metadata)
            ownerInput = details.metadata.owner.login
            repoInput = details.metadata.name
            expandedRepositoryFullName = details.metadata.full_name
            Self.logger.info("[loadRepo] success fullName=\(details.metadata.full_name, privacy: .public) branchCount=\(details.branches.count) defaultBranch=\(details.metadata.default_branch, privacy: .public)")
            syncExpandedDraftState(for: details.metadata.full_name)
        } catch {
            Self.logger.error("[loadRepo] owner=\(owner, privacy: .public) repo=\(repo, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func clearSelection() {
        searchQuery = ""
        ownerInput = ""
        repoInput = ""
        expandedManualBranchInput = ""
        expandedRepositoryFullName = nil
        errorMessage = nil
        repoListErrorMessage = nil
        expandedBranchValidationMessage = nil
        isExpandedBranchValid = false
        draftRepositoryMetadata = nil
        draftBranchName = ""
        isDraftBranchValid = false
        draftBranchValidationMessage = nil
    }

    func isRepositoryExpanded(_ repository: GitHubRepository) -> Bool {
        expandedRepositoryFullName == repository.full_name
    }

    func isRepositorySelected(_ repository: GitHubRepository) -> Bool {
        normalizedRepositoryKey(repository.full_name) == normalizedRepositoryKey(draftRepositoryMetadata?.full_name)
    }

    func selectedBranchSummary(for repository: GitHubRepository) -> String? {
        guard isRepositorySelected(repository), !draftBranchName.isEmpty else {
            return nil
        }
        return draftBranchName
    }

    func selectedBranchNeedsAttention(for repository: GitHubRepository) -> Bool {
        isRepositorySelected(repository) && !isDraftBranchValid && !draftBranchName.isEmpty
    }

    func branches(for repository: GitHubRepository) -> [GitHubBranchSummary] {
        guard let key = repositoryKey(for: repository) else { return [] }
        return branchCache[key] ?? []
    }

    func isLoadingBranches(for repository: GitHubRepository) -> Bool {
        guard let key = repositoryKey(for: repository) else { return false }
        return branchLoadingRepositories.contains(key)
    }

    func branchLoadError(for repository: GitHubRepository) -> String? {
        guard let key = repositoryKey(for: repository) else { return nil }
        return branchLoadErrors[key]
    }

    func defaultBranchName(for repository: GitHubRepository) -> String? {
        metadata(for: repository)?.default_branch
    }

    func isBranchSelected(_ branch: GitHubBranchSummary, for repository: GitHubRepository) -> Bool {
        isRepositorySelected(repository) && isDraftBranchValid && draftBranchName == branch.name
    }

    private var expandedRepository: GitHubRepository? {
        guard let expandedRepositoryFullName else { return nil }
        return availableRepositories.first(where: { normalizedRepositoryKey($0.full_name) == normalizedRepositoryKey(expandedRepositoryFullName) })
    }

    private func ensureRepositoryDetailsLoaded(for repository: GitHubRepository, forceReload: Bool = false) async {
        guard let key = repositoryKey(for: repository) else {
            errorMessage = "Could not parse the selected repository."
            return
        }

        if !forceReload, repositoryMetadataCache[key] != nil, branchCache[key] != nil {
            syncExpandedDraftState(for: repository.full_name)
            return
        }

        guard !branchLoadingRepositories.contains(key) else { return }
        branchLoadingRepositories.insert(key)
        branchLoadErrors[key] = nil
        defer { branchLoadingRepositories.remove(key) }

        do {
            let details = try await fetchRepositoryDetails(for: repository)
            storeRepositoryDetails(details)
            syncExpandedDraftState(for: details.metadata.full_name)
        } catch {
            branchLoadErrors[key] = error.localizedDescription
            syncExpandedDraftState(for: repository.full_name)
        }
    }

    private func validateBranchForExpandedRepository(
        metadata: GitHubRepositoryMetadata,
        branches: [GitHubBranchSummary],
        branch: String,
        shouldMutateDraftOnFailure: Bool
    ) async {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            setExpandedBranchState(message: "Enter a branch name.", isValid: false)
            if shouldMutateDraftOnFailure {
                invalidateDraftSelection(metadata: metadata, branch: "", message: "Enter a branch name.")
            }
            return
        }

        if branches.contains(where: { $0.name == trimmedBranch }) {
            applyDraftSelection(
                metadata: metadata,
                branch: trimmedBranch,
                isValid: true,
                validationMessage: "Using branch \(trimmedBranch)."
            )
            return
        }

        isValidatingBranch = true
        errorMessage = nil
        defer { isValidatingBranch = false }

        do {
            let client = try makeClient()
            _ = try await client.getRef(
                owner: metadata.owner.login,
                repo: metadata.name,
                ref: "heads/\(trimmedBranch)"
            )
            applyDraftSelection(
                metadata: metadata,
                branch: trimmedBranch,
                isValid: true,
                validationMessage: "Using branch \(trimmedBranch)."
            )
        } catch let apiError as GitHubAPIError where apiError.statusCode == 404 {
            Self.logger.info("[validateBranch] repo=\(metadata.full_name, privacy: .public) branch=\(trimmedBranch, privacy: .public) result=notFound")
            let message = "Branch \(trimmedBranch) was not found."
            setExpandedBranchState(message: message, isValid: false)
            if shouldMutateDraftOnFailure {
                invalidateDraftSelection(metadata: metadata, branch: trimmedBranch, message: message)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDraftSelection(
        metadata: GitHubRepositoryMetadata,
        branch: String,
        isValid: Bool,
        validationMessage: String?
    ) {
        draftRepositoryMetadata = metadata
        draftBranchName = branch
        isDraftBranchValid = isValid
        draftBranchValidationMessage = validationMessage
        expandedRepositoryFullName = metadata.full_name
        syncExpandedDraftState(for: metadata.full_name)
    }

    private func invalidateDraftSelection(
        metadata: GitHubRepositoryMetadata,
        branch: String,
        message: String
    ) {
        draftRepositoryMetadata = metadata
        draftBranchName = branch
        isDraftBranchValid = false
        draftBranchValidationMessage = message
        syncExpandedDraftState(for: metadata.full_name)
    }

    private func syncExpandedDraftState(for repositoryFullName: String) {
        guard normalizedRepositoryKey(repositoryFullName) == normalizedRepositoryKey(expandedRepositoryFullName) else {
            expandedManualBranchInput = ""
            expandedBranchValidationMessage = nil
            isExpandedBranchValid = false
            return
        }

        if normalizedRepositoryKey(draftRepositoryMetadata?.full_name) == normalizedRepositoryKey(repositoryFullName) {
            expandedManualBranchInput = draftBranchName
            expandedBranchValidationMessage = draftBranchValidationMessage
            isExpandedBranchValid = isDraftBranchValid
        } else {
            expandedManualBranchInput = ""
            expandedBranchValidationMessage = nil
            isExpandedBranchValid = false
        }
    }

    private func setExpandedBranchState(message: String?, isValid: Bool) {
        expandedBranchValidationMessage = message
        isExpandedBranchValid = isValid
    }

    private func metadata(for repository: GitHubRepository) -> GitHubRepositoryMetadata? {
        guard let key = repositoryKey(for: repository) else { return nil }
        return repositoryMetadataCache[key]
    }

    private func repositoryKey(for repository: GitHubRepository) -> String? {
        guard let (owner, repo) = repositoryComponents(from: repository.full_name) else { return nil }
        return normalizedRepositoryKey("\(owner)/\(repo)")
    }

    private func repositoryComponents(from fullName: String) -> (owner: String, repo: String)? {
        let components = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        return (components[0], components[1])
    }

    private func fetchRepositoryDetails(for repository: GitHubRepository) async throws -> RepositoryDetails {
        guard let components = repositoryComponents(from: repository.full_name) else {
            throw ConnectorError.invalidArguments("Could not parse the selected repository.")
        }

        return try await fetchRepositoryDetails(owner: components.owner, repo: components.repo)
    }

    private func fetchRepositoryDetails(owner: String, repo: String) async throws -> RepositoryDetails {
        let client = try makeClient()
        async let repositoryTask = client.getRepository(owner: owner, repo: repo)
        async let branchesTask = client.listBranches(owner: owner, repo: repo, perPage: 100)
        let (metadata, branches) = try await (repositoryTask, branchesTask)
        return RepositoryDetails(
            metadata: metadata,
            branches: branches.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )
    }

    private func storeRepositoryDetails(_ details: RepositoryDetails) {
        let key = normalizedRepositoryKey(details.metadata.full_name)
        repositoryMetadataCache[key] = details.metadata
        branchCache[key] = details.branches
        branchLoadErrors[key] = nil
    }

    private func upsertAvailableRepository(from metadata: GitHubRepositoryMetadata) {
        let repository = GitHubRepository(
            full_name: metadata.full_name,
            description: nil,
            html_url: metadata.html_url,
            stargazers_count: 0,
            language: nil,
            updated_at: nil,
            open_issues_count: 0,
            fork: false,
            private: metadata.private
        )

        let key = normalizedRepositoryKey(metadata.full_name)
        if let existingIndex = availableRepositories.firstIndex(where: { normalizedRepositoryKey($0.full_name) == key }) {
            if availableRepositories[existingIndex].description == nil {
                availableRepositories[existingIndex] = repository
            }
        } else {
            availableRepositories.insert(repository, at: 0)
        }
    }

    private func makeClient() throws -> GitHubAPIClient {
        guard let token = try keychain.read(account: keychainAccount), !token.isEmpty else {
            throw ConnectorError.notConfigured("GitHub")
        }

        return GitHubAPIClient(token: token, session: session)
    }

    private func mergeAccessibleRepositories(_ repositories: [GitHubRepository], into target: inout [GitHubRepository]) {
        var indexesByName = Dictionary(uniqueKeysWithValues: target.enumerated().map { (normalizedRepositoryKey($0.element.full_name), $0.offset) })

        for repository in repositories {
            let key = normalizedRepositoryKey(repository.full_name)
            if let index = indexesByName[key] {
                target[index] = repository
            } else {
                target.append(repository)
                indexesByName[key] = target.count - 1
            }
        }
    }

    private func normalizedRepositoryKey(_ fullName: String?) -> String {
        (fullName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct RepositoryDetails {
    let metadata: GitHubRepositoryMetadata
    let branches: [GitHubBranchSummary]
}
