import SwiftUI
import UniformTypeIdentifiers

struct RepositoryView: View {
    let repo: Repository
    let model: WindowModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showAbortConfirm = false
    @State private var showStashPicker = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(repo: repo, model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            NavigationStack(path: Bindable(model).routes) {
                VStack(spacing: 0) {
                    if let title = repo.operationState.title {
                        OperationBanner(title: title, repo: repo)
                    }
                    detailRoot
                }
                .navigationDestination(for: DetailRoute.self) { route in
                    routeView(route)
                }
            }
        }
        .navigationTitle(repo.name)
        .navigationSubtitle(subtitle)
        .toolbar { RepositoryToolbar(repo: repo, model: model) }
        .alert("Git Error", isPresented: Binding(get: { repo.errorMessage != nil }, set: { if !$0 { repo.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repo.errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let info = repo.infoMessage {
                Text(info)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        if repo.infoMessage == info { repo.infoMessage = nil }
                    }
            }
        }
        .animation(.default, value: repo.infoMessage)
        .sheet(isPresented: Bindable(model).showNewBranch) { NewBranchSheet(repo: repo, startPoint: model.newBranchStart) }
        .sheet(isPresented: Bindable(model).showStash) { StashSheet(repo: repo, paths: model.stashPaths) }
        .sheet(isPresented: Bindable(model).showNewTag) { NewTagSheet(repo: repo, ref: model.newTagRef) }
        .sheet(isPresented: Bindable(model).showNewRemote) { NewRemoteSheet(repo: repo) }
        .sheet(isPresented: Bindable(model).showQuickActions) { QuickActionsView(repo: repo, model: model) }
        .sheet(isPresented: Bindable(model).showInteractiveRebase) { InteractiveRebaseSheet(repo: repo, base: model.interactiveRebaseBase) }
        .sheet(isPresented: Bindable(model).showAddSubmodule) { AddSubmoduleSheet(repo: repo) }
        .fileImporter(isPresented: Bindable(model).showApplyPatch, allowedContentTypes: [.data, .plainText, UTType(filenameExtension: "patch") ?? .plainText, UTType(filenameExtension: "diff") ?? .plainText]) { result in
            if case .success(let url) = result {
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    await repo.applyPatchFile(url)
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    private var subtitle: String {
        if repo.status.detached { return "Detached HEAD at \(repo.status.oid?.prefix(7) ?? "")" }
        var s = repo.status.branch ?? "No commits yet"
        if let upstream = repo.status.upstream { s += "  →  \(upstream)" }
        return s
    }

    @ViewBuilder
    private var detailRoot: some View {
        switch model.selection ?? .workingCopy {
        case .workingCopy:
            WorkingCopyView(repo: repo, model: model)
        case .history:
            HistoryView(repo: repo, model: model, query: GitQueries.LogQuery(ref: nil), title: "All Branches")
        case .branch(let ref), .remoteBranch(let ref):
            HistoryView(repo: repo, model: model, query: GitQueries.LogQuery(ref: ref), title: ref.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: ""))
        case .tag(let name):
            HistoryView(repo: repo, model: model, query: GitQueries.LogQuery(ref: "refs/tags/\(name)"), title: name)
        case .stash(let hash):
            CommitDetailView(repo: repo, model: model, hash: hash, stash: repo.stashes.first { $0.hash == hash })
        case .stashes:
            StashesView(repo: repo, model: model)
        case .branchesReview:
            BranchesReviewView(repo: repo, model: model)
        case .reflog:
            ReflogView(repo: repo, model: model)
        case .submodules:
            SubmodulesView(repo: repo, model: model)
        case .settings:
            RepositorySettingsView(repo: repo, model: model)
        }
    }

    @ViewBuilder
    private func routeView(_ route: DetailRoute) -> some View {
        switch route {
        case .fileHistory(let path):
            HistoryView(repo: repo, model: model, query: GitQueries.LogQuery(ref: "HEAD", path: path), title: path)
        case .blame(let path, let revision):
            BlameView(repo: repo, model: model, path: path, revision: revision)
        case .browse(let revision):
            BrowseView(repo: repo, model: model, revision: revision)
        case .compare(let base, let target):
            CompareView(repo: repo, model: model, base: base, target: target)
        case .commit(let hash):
            CommitDetailView(repo: repo, model: model, hash: hash, stash: nil)
        }
    }
}

struct OperationBanner: View {
    let title: String
    let repo: Repository
    @State private var confirmAbort = false

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(title).fontWeight(.medium)
            if !repo.status.conflicted.isEmpty {
                Text("\(repo.status.conflicted.count) conflicted file(s)").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Continue") { Task { await repo.continueOperation() } }
                .disabled(!repo.status.conflicted.isEmpty)
            Button("Abort", role: .destructive) { confirmAbort = true }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
        .confirmationDialog("Abort the current operation?", isPresented: $confirmAbort) {
            Button("Abort", role: .destructive) { Task { await repo.abortOperation() } }
        } message: {
            Text("The repository will be restored to the state before the operation started.")
        }
    }
}

struct RepositoryToolbar: ToolbarContent {
    let repo: Repository
    let model: WindowModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showRepositoryList.toggle() } label: {
                Label("Repositories", systemImage: "square.grid.2x2")
            }
            .help("Repositories (⌘0)")
        }
        ToolbarItem(placement: .principal) {
            if repo.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(repo.busyMessage ?? "Working…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let fetched = repo.lastFetch {
                Text("Fetched \(fetched.gitRelativeDescription)").font(.caption).foregroundStyle(.tertiary)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showQuickActions = true } label: {
                Label("Quick Actions", systemImage: "wand.and.stars")
            }
            .help("Quick Actions (⌘K)")

            Button { Task { await repo.undo() } } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .help(repo.undoStack.undoTitle.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)")
            .disabled(!repo.undoStack.canUndo)

            Button { Task { await repo.redo() } } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .help(repo.undoStack.redoTitle.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo (⇧⌘Z)")
            .disabled(!repo.undoStack.canRedo)

            Button { Task { await repo.fetch() } } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Fetch all remotes (⇧⌘F)")
            .disabled(repo.remotes.isEmpty)

            Menu {
                Button("Pull") { Task { await repo.pull() } }
                Button("Pull with Rebase") { Task { await repo.pull(rebase: true) } }
            } label: {
                Label("Pull", systemImage: "arrow.down.to.line")
            } primaryAction: {
                Task { await repo.pull() }
            }
            .help(repo.status.behind > 0 ? "Pull \(repo.status.behind) commit(s) (⇧⌘L)" : "Pull (⇧⌘L)")
            .badge(repo.status.behind)
            .disabled(repo.remotes.isEmpty)

            Menu {
                Button(repo.status.upstream == nil ? "Publish Branch" : "Push") { Task { await repo.push(setUpstream: repo.status.upstream == nil) } }
                Button("Force Push with Lease") { Task { await repo.push(force: true) } }
                Button("Push Tags") { Task { await repo.push(tags: true) } }
                if repo.remotes.count > 1 {
                    Divider()
                    ForEach(repo.remotes) { remote in
                        Button("Push to \(remote.name)") { Task { await repo.push(setUpstream: true, remote: remote.name) } }
                    }
                }
            } label: {
                Label("Push", systemImage: "arrow.up.to.line")
            } primaryAction: {
                Task { await repo.push(setUpstream: repo.status.upstream == nil) }
            }
            .help(repo.status.ahead > 0 ? "Push \(repo.status.ahead) commit(s) (⇧⌘P)" : "Push (⇧⌘P)")
            .badge(repo.status.ahead)
            .disabled(repo.remotes.isEmpty)

            Button { Task { await repo.sync() } } label: {
                Label("Sync", systemImage: "arrow.up.arrow.down")
            }
            .help("Pull, then push (⇧⌘Y)")
            .disabled(repo.remotes.isEmpty)

            Button { model.stashPaths = []; model.showStash = true } label: {
                Label("Stash", systemImage: "tray.and.arrow.down")
            }
            .help("Stash changes (⇧⌘S)")
            .disabled(repo.status.changeCount == 0)

            Button { model.newBranchStart = nil; model.showNewBranch = true } label: {
                Label("Branch", systemImage: "arrow.triangle.branch")
            }
            .help("New branch (⌘B)")

            Menu {
                Button("Reveal in Finder") { repo.revealInFinder(nil) }
                Button("Open in Terminal") { repo.openInTerminal() }
                if let web = repo.remotes.first?.webURL {
                    Button("Open on Web") { NSWorkspace.shared.open(web) }
                }
                Divider()
                Button("Stashes") { model.selection = .stashes; model.routes = [] }
                Button("Branches Review") { model.selection = .branchesReview; model.routes = [] }
                Button("Reflog") { model.selection = .reflog; model.routes = [] }
                Button("Submodules") { model.selection = .submodules; model.routes = [] }
                Button("Repository Settings") { model.selection = .settings; model.routes = [] }
                Button("Browse Files at HEAD") { model.routes.append(.browse(revision: "HEAD")) }
                Button("Compare Branches…") { model.routes.append(.compare(base: repo.remoteBranches.first(where: { $0.name.hasSuffix("/main") || $0.name.hasSuffix("/master") })?.name ?? "HEAD", target: repo.status.branch ?? "HEAD")) }
                Divider()
                Button("Apply Patch…") { model.showApplyPatch = true }
                Button("Refresh") { Task { await repo.refresh() } }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}
