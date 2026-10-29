import Foundation
import Observation
import AppKit
import SwiftUI

/// Persisted list of recently opened repositories, shared by all windows.
@MainActor
@Observable
final class RecentRepositories {
    static let shared = RecentRepositories()

    private(set) var paths: [String]
    var groups: [String: String]  // path -> group name

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
        groups = UserDefaults.standard.dictionary(forKey: "repositoryGroups") as? [String: String] ?? [:]
    }

    func add(_ url: URL) {
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > 40 { paths = Array(paths.prefix(40)) }
        UserDefaults.standard.set(paths, forKey: "recentRepositories")
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        groups[path] = nil
        UserDefaults.standard.set(paths, forKey: "recentRepositories")
        UserDefaults.standard.set(groups, forKey: "repositoryGroups")
    }

    func setGroup(_ group: String?, for path: String) {
        if let group, !group.isEmpty { groups[path] = group } else { groups[path] = nil }
        UserDefaults.standard.set(groups, forKey: "repositoryGroups")
    }
}

/// Per-window state: which repository is open and what is selected.
@MainActor
@Observable
final class WindowModel {
    var repository: Repository?
    var selection: SidebarItem? = .workingCopy
    var routes: [DetailRoute] = []
    var errorMessage: String?

    // Sheets
    var showClone = false
    var showNewBranch = false
    var newBranchStart: String?
    var showStash = false
    var stashPaths: [String] = []
    var showNewTag = false
    var newTagRef: String?
    var showNewRemote = false
    var showQuickActions = false
    var showSettings = false
    var showInteractiveRebase = false
    var interactiveRebaseBase: String?
    var showRepositoryList = false
    var showApplyPatch = false
    var showCompare = false
    var showAddSubmodule = false

    func open(url: URL) async {
        guard let top = await GitQueries.topLevel(of: url) else {
            errorMessage = "\(url.path) is not a Git repository."
            return
        }
        let repo = Repository(url: top)
        repository = repo
        selection = .workingCopy
        routes = []
        RecentRepositories.shared.add(top)
        await repo.refresh()
        applyDebugView()
    }

    /// Debug aid: GITTER_DEBUG_VIEW=history|reflog|commit|browse|compare|blame:<path>|filehistory:<path> preselects a view after opening.
    private func applyDebugView() {
        guard let value = ProcessInfo.processInfo.environment["GITTER_DEBUG_VIEW"] else { return }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "history": selection = .history
        case "stashes": selection = .stashes
        case "review": selection = .branchesReview
        case "settings": selection = .settings
        case "reflog": selection = .reflog
        case "commit": selection = .history; if let oid = repository?.status.oid { routes = [.commit(hash: oid)] }
        case "browse": routes = [.browse(revision: "HEAD")]
        case "compare": routes = [.compare(base: repository?.remoteBranches.first?.name ?? "HEAD", target: repository?.status.branch ?? "HEAD")]
        case "blame" where parts.count == 2: routes = [.blame(path: parts[1], revision: "HEAD")]
        case "filehistory" where parts.count == 2: routes = [.fileHistory(path: parts[1])]
        default: break
        }
    }

    func openRepositoryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.open(url: url) }
        }
    }

    func createRepositoryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Initialize"
        panel.message = "Choose a folder to initialize as a Git repository"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await GitRunner.run(["init"], in: url)
                    await self?.open(url: url)
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clone(url remote: String, into parent: URL, name: String) async {
        let destination = parent.appendingPathComponent(name)
        let repoURL = destination
        do {
            try await GitRunner.run(["clone", "--recurse-submodules", remote, destination.path], in: parent)
            await open(url: repoURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close() {
        repository = nil
        routes = []
    }

    func showCommit(_ hash: String) {
        routes.append(.commit(hash: hash))
    }
}

extension FocusedValues {
    @Entry var windowModel: WindowModel?
}
