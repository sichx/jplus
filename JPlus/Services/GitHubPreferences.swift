import Foundation

/// Non-secret preferences. The caller supplies the current Jira account's defaults.
nonisolated struct GitHubPreferences {
    let defaults: UserDefaults

    func rememberRepository(_ repository: GitHubRepository) {
        defaults.set(repository.webURL.absoluteString, forKey: repositoryKey(repository.organization))
    }

    /// A remembered choice is restored only if it is still in the authenticated repository list.
    func preferredRepository(in organization: GitHubOrganization, available: [GitHubRepository]) -> GitHubRepository? {
        guard let url = defaults.string(forKey: repositoryKey(organization)),
              let saved = try? GitHubRepository(url: url), organization.contains(saved) else { return nil }
        return available.first {
            organization.contains($0) && $0.fullName.caseInsensitiveCompare(saved.fullName) == .orderedSame
        }
    }

    func savedBase(for repository: GitHubRepository) -> String? {
        defaults.string(forKey: baseKey(repository))
    }

    func rememberBase(_ branch: String, for repository: GitHubRepository) {
        defaults.set(branch, forKey: baseKey(repository))
    }

    private func repositoryKey(_ organization: GitHubOrganization) -> String {
        "githubRepository.\(organization.host).\(organization.name.lowercased())"
    }

    private func baseKey(_ repository: GitHubRepository) -> String {
        "githubBaseBranch.\(repository.host).\(repository.fullName)"
    }
}
