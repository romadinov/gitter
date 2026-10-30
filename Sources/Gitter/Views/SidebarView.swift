import SwiftUI
import UniformTypeIdentifiers

/// Payload for sidebar / history drag and drop, encoded as a string.
enum DragPayload {
    static func branch(_ ref: String) -> String { "branch:" + ref }
    static func commit(_ hash: String) -> String { "commit:" + hash }
    static func files(_ paths: [String]) -> String { "files:" + paths.joined(separator: "\n") }
    static func stash(_ hash: String) -> String { "stash:" + hash }
    static func commitFile(_ hash: String, _ path: String) -> String { "commitfile:\(hash)\n\(path)" }

    static func decode(_ s: String) -> (kind: String, value: String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        return (String(s[..<colon]), String(s[s.index(after: colon)...]))
    }

    static var optionPressed: Bool { NSEvent.modifierFlags.contains(.option) }
}

struct BranchNode: Identifiable, Hashable {
    let id: String
    let name: String
    let branch: Branch?
    var children: [BranchNode]?

    static func tree(from branches: [Branch], stripRemote: Bool = false) -> [BranchNode] {
        final class Builder {
            var children: [String: Builder] = [:]
            var order: [String] = []
            var branch: Branch?
            func node(id: String, name: String) -> BranchNode {
                var kids: [BranchNode] = []
                for key in order.sorted(by: { a, b in
                    let fa = children[a]!.branch == nil, fb = children[b]!.branch == nil
                    if fa != fb { return fa }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }) {
                    kids.append(children[key]!.node(id: id + "/" + key, name: key))
                }
                return BranchNode(id: id, name: name, branch: branch, children: branch == nil ? kids : nil)
            }
        }
        let root = Builder()
        for b in branches {
            let display = stripRemote ? b.nameWithoutRemote : b.name
            var cursor = root
            let parts = display.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                if cursor.children[part] == nil { cursor.children[part] = Builder(); cursor.order.append(part) }
                cursor = cursor.children[part]!
                if i == parts.count - 1 { cursor.branch = b }
            }
        }
        return root.node(id: "root", name: "").children ?? []
    }
}

struct SidebarView: View {
    let repo: Repository
    let model: WindowModel
    @State private var branchToDelete: Branch?
    @State private var remoteToRemove: Remote?
    @State private var tagToDelete: Tag?
    @State private var stashToDrop: Stash?
    @State private var renameTarget: Branch?
    @State private var renameText = ""
    @State private var filter = ""
    @AppStorage("sidebarShowHashes") private var showHashes = false
    @AppStorage("sidebarHideStale") private var hideStale = false
    @AppStorage("sidebarHideMergedRemotes") private var hideMergedRemotes = false

    private var localTree: [BranchNode] { BranchNode.tree(from: filtered(repo.localBranches)) }

    private func filtered(_ branches: [Branch]) -> [Branch] {
        var result = branches
        if !filter.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
        if hideStale { result = result.filter { $0.isCurrent || Date().timeIntervalSince($0.date) <= 60 * 86_400 } }
        return result
    }

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { newValue in
            if let newValue { select(newValue) }
        })) {
            Section("Workspace") {
                SidebarRow(title: "Working Copy", systemImage: "folder.fill", color: .blue, badge: repo.status.changeCount)
                    .tag(SidebarItem.workingCopy)
                    .dropDestination(for: String.self) { items, _ in handleWorkingCopyDrop(items) }
                SidebarRow(title: "History", systemImage: "clock.arrow.circlepath", color: .primary)
                    .tag(SidebarItem.history)
                SidebarRow(title: "Stashes", systemImage: "tray.full", color: .primary, badge: repo.stashes.count)
                    .tag(SidebarItem.stashes)
                    .dropDestination(for: String.self) { items, _ in
                        guard let item = items.first, let payload = DragPayload.decode(item), payload.kind == "files" else { return false }
                        model.stashPaths = payload.value.split(separator: "\n").map(String.init)
                        model.showStash = true
                        return true
                    }
                SidebarRow(title: "Branches Review", systemImage: "checklist", color: .primary)
                    .tag(SidebarItem.branchesReview)
                SidebarRow(title: "Reflog", systemImage: "book.closed", color: .primary)
                    .tag(SidebarItem.reflog)
                if !repo.submodules.isEmpty {
                    SidebarRow(title: "Submodules", systemImage: "shippingbox", color: .primary, badge: repo.submodules.count)
                        .tag(SidebarItem.submodules)
                }
                SidebarRow(title: "Settings", systemImage: "gearshape", color: .primary)
                    .tag(SidebarItem.settings)
            }

            Section {
                OutlineGroup(localTree, children: \.children) { node in
                    if let branch = node.branch {
                        BranchRow(branch: branch, repo: repo, model: model, showHash: showHashes)
                            .tag(SidebarItem.branch(branch.fullRef))
                            .onTapGesture { select(.branch(branch.fullRef)) }
                            .draggable(DragPayload.branch(branch.name))
                            .dropDestination(for: String.self) { items, _ in handleBranchDrop(items, onto: branch) }
                            .contextMenu { branchMenu(branch) }
                    } else {
                        Label(node.name, systemImage: "folder.fill")
                    }
                }
            } header: {
                HStack {
                    Text("Branches")
                    Spacer()
                    Button { model.newBranchStart = nil; model.showNewBranch = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New Branch")
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, let payload = DragPayload.decode(item) else { return false }
                    model.newBranchStart = payload.value
                    model.showNewBranch = true
                    return true
                }
            }

            Section {
                ForEach(repo.remotes) { remote in
                    DisclosureGroup {
                        OutlineGroup(BranchNode.tree(from: filtered(repo.remoteBranches.filter { $0.remoteName == remote.name }), stripRemote: true), children: \.children) { node in
                            if let branch = node.branch {
                                RemoteBranchRow(branch: branch)
                                    .tag(SidebarItem.remoteBranch(branch.fullRef))
                                    .onTapGesture { select(.remoteBranch(branch.fullRef)) }
                                    .draggable(DragPayload.branch(branch.name))
                                    .dropDestination(for: String.self) { items, _ in handleRemoteBranchDrop(items, onto: branch, remote: remote) }
                                    .contextMenu { remoteBranchMenu(branch, remote: remote) }
                            } else {
                                Label(node.name, systemImage: "folder")
                            }
                        }
                    } label: {
                        Label(remote.name, systemImage: "cloud")
                            .contextMenu { remoteMenu(remote) }
                            .dropDestination(for: String.self) { items, _ in
                                guard let item = items.first, let payload = DragPayload.decode(item), payload.kind == "branch",
                                      let branch = repo.localBranches.first(where: { $0.name == payload.value }) else { return false }
                                Task { await repo.pushBranch(branch, to: remote.name) }
                                return true
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Remotes")
                    Spacer()
                    Button { model.showNewRemote = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Add Remote")
                }
            }

            Section {
                ForEach(filteredTags) { tag in
                    Label {
                        HStack {
                            Text(tag.name)
                            Spacer()
                            Text(tag.shortHash).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    } icon: { Image(systemName: "tag") }
                    .tag(SidebarItem.tag(tag.name))
                    .onTapGesture { select(.tag(tag.name)) }
                    .draggable(DragPayload.branch(tag.name))
                    .contextMenu { tagMenu(tag) }
                }
            } header: {
                HStack {
                    Text("Tags")
                    Spacer()
                    Button { model.newTagRef = nil; model.showNewTag = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New Tag")
                }
            }

        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Menu {
                    Button("Create New Branch…") { model.newBranchStart = nil; model.showNewBranch = true }
                    Button("Create New Tag…") { model.newTagRef = nil; model.showNewTag = true }
                    Divider()
                    Button("Add Remote Repository…") { model.showNewRemote = true }
                    Button("Add Submodule…") { model.showAddSubmodule = true }
                    Divider()
                    Button("Stash Changes…") { model.stashPaths = []; model.showStash = true }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Menu {
                    Toggle("Show Commit Hashes", isOn: $showHashes)
                    Toggle("Hide Stale Branches", isOn: $hideStale)
                    Toggle("Hide Remote Branches Merged into HEAD", isOn: $hideMergedRemotes)
                } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("View Settings")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .contextMenu(forSelectionType: SidebarItem.self) { _ in } primaryAction: { items in
            guard let item = items.first else { return }
            switch item {
            case .branch(let ref):
                if let b = repo.localBranches.first(where: { $0.fullRef == ref }), !b.isCurrent { Task { await repo.checkout(b.name) } }
            case .remoteBranch(let ref):
                if let b = repo.remoteBranches.first(where: { $0.fullRef == ref }) { Task { await repo.checkout(b.name, createTracking: true) } }
            default: break
            }
        }
        .confirmationDialog("Delete branch \"\(branchToDelete?.name ?? "")\"?", isPresented: Binding(get: { branchToDelete != nil }, set: { if !$0 { branchToDelete = nil } }), presenting: branchToDelete) { branch in
            Button("Delete", role: .destructive) { Task { await repo.deleteBranch(branch, force: true) } }
        } message: { branch in
            Text(branch.isRemote ? "The branch will be deleted on the remote." : "Unmerged commits on this branch will be lost (you can undo with ⌘Z).")
        }
        .confirmationDialog("Remove remote \"\(remoteToRemove?.name ?? "")\"?", isPresented: Binding(get: { remoteToRemove != nil }, set: { if !$0 { remoteToRemove = nil } }), presenting: remoteToRemove) { remote in
            Button("Remove", role: .destructive) { Task { await repo.removeRemote(remote) } }
        }
        .confirmationDialog("Delete tag \"\(tagToDelete?.name ?? "")\"?", isPresented: Binding(get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } }), presenting: tagToDelete) { tag in
            Button("Delete Locally", role: .destructive) { Task { await repo.deleteTag(tag) } }
            ForEach(repo.remotes) { remote in
                Button("Delete on \(remote.name)", role: .destructive) { Task { await repo.deleteTag(tag, onRemote: remote.name) } }
            }
        }
        .confirmationDialog("Drop stash?", isPresented: Binding(get: { stashToDrop != nil }, set: { if !$0 { stashToDrop = nil } }), presenting: stashToDrop) { stash in
            Button("Drop", role: .destructive) { Task { await repo.dropStash(stash) } }
        } message: { stash in Text(stash.message) }
        .alert("Rename Branch", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }), presenting: renameTarget) { branch in
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await repo.renameBranch(branch, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var filteredTags: [Tag] {
        filter.isEmpty ? repo.tags : repo.tags.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    // MARK: Drops

    private func handleWorkingCopyDrop(_ items: [String]) -> Bool {
        guard let item = items.first, let payload = DragPayload.decode(item) else { return false }
        switch payload.kind {
        case "stash":
            guard let stash = repo.stashes.first(where: { $0.hash == payload.value }) else { return false }
            Task { await repo.applyStash(stash, pop: DragPayload.optionPressed) }
            return true
        case "commitfile":
            let parts = payload.value.split(separator: "\n", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            Task { await repo.applyCommittedFile(parts[0], path: parts[1]) }
            return true
        case "commit":
            Task { await repo.cherryPick(payload.value) }
            return true
        default: return false
        }
    }

    /// Single-click selection. Rows that are also `.draggable` need an explicit tap handler on
    /// macOS because the drag gesture otherwise swallows the mouse-down that would select them.
    private func select(_ item: SidebarItem) {
        if item != model.selection { model.routes = [] }
        model.selection = item
    }

    private func handleBranchDrop(_ items: [String], onto target: Branch) -> Bool {
        guard let item = items.first, let payload = DragPayload.decode(item) else { return false }
        switch payload.kind {
        case "branch":
            guard payload.value != target.name else { return false }
            if target.isCurrent {
                // Drop a branch onto HEAD: merge, ⌥ to rebase
                if DragPayload.optionPressed { Task { await repo.rebase(onto: payload.value) } }
                else { Task { await repo.merge(payload.value) } }
                return true
            }
            if let source = repo.remoteBranches.first(where: { $0.name == payload.value }) {
                // remote branch dropped onto local: pull into it (fast-forward via fetch)
                Task { await repo.perform("Updating \(target.name)") {
                    try await repo.run(["fetch", source.remoteName ?? "origin", "\(source.nameWithoutRemote):\(target.name)"])
                } }
                return true
            }
            return false
        case "commit":
            guard target.isCurrent else { return false }
            if DragPayload.optionPressed { Task { await repo.revert(payload.value) } }
            else { Task { await repo.cherryPick(payload.value) } }
            return true
        default: return false
        }
    }

    private func handleRemoteBranchDrop(_ items: [String], onto target: Branch, remote: Remote) -> Bool {
        guard let item = items.first, let payload = DragPayload.decode(item), payload.kind == "branch",
              let local = repo.localBranches.first(where: { $0.name == payload.value }) else { return false }
        if DragPayload.optionPressed {
            Task { await repo.setUpstream(local, to: target.name) }
        } else {
            Task { await repo.perform("Pushing \(local.name)") {
                try await repo.run(["push", remote.name, "\(local.name):\(target.nameWithoutRemote)"])
            } }
        }
        return true
    }

    // MARK: Menus

    @ViewBuilder
    private func branchMenu(_ branch: Branch) -> some View {
        if !branch.isCurrent {
            Button("Checkout \(branch.name)") { Task { await repo.checkout(branch.name) } }
            Button("Merge \(branch.name) into \(repo.status.branch ?? "HEAD")") { Task { await repo.merge(branch.name) } }
            Button("Merge (no fast-forward)") { Task { await repo.merge(branch.name, noFastForward: true) } }
            Button("Squash Merge") { Task { await repo.merge(branch.name, squash: true) } }
            Button("Rebase \(repo.status.branch ?? "HEAD") onto \(branch.name)") { Task { await repo.rebase(onto: branch.name) } }
            Button("Interactive Rebase onto \(branch.name)…") { model.interactiveRebaseBase = branch.name; model.showInteractiveRebase = true }
            Divider()
        } else {
            Button("Interactive Rebase…") { model.interactiveRebaseBase = nil; model.showInteractiveRebase = true }
            Divider()
        }
        Button("Compare with \(repo.status.branch ?? "HEAD")…") { model.routes.append(.compare(base: branch.name, target: repo.status.branch ?? "HEAD")) }
        Button("New Branch from \(branch.name)…") { model.newBranchStart = branch.name; model.showNewBranch = true }
        Button("New Tag at \(branch.name)…") { model.newTagRef = branch.name; model.showNewTag = true }
        Button("Browse Files") { model.routes.append(.browse(revision: branch.name)) }
        Divider()
        Menu("Push to") {
            ForEach(repo.remotes) { remote in
                Button(remote.name) { Task { await repo.pushBranch(branch, to: remote.name) } }
            }
        }
        if branch.isCurrent, repo.status.upstream != nil {
            Button("Pull") { Task { await repo.pull() } }
        }
        Menu("Track Remote Branch") {
            Button("None") { Task { await repo.setUpstream(branch, to: nil) } }
            ForEach(repo.remoteBranches) { rb in
                Button(rb.name) { Task { await repo.setUpstream(branch, to: rb.name) } }
            }
        }
        Divider()
        Button("Export as ZIP…") { exportArchive(ref: branch.name) }
        Button("Copy Branch Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(branch.name, forType: .string) }
        Button("Rename…") { renameText = branch.name; renameTarget = branch }
        Button("Delete…", role: .destructive) { branchToDelete = branch }.disabled(branch.isCurrent)
    }

    @ViewBuilder
    private func remoteBranchMenu(_ branch: Branch, remote: Remote) -> some View {
        Button("Checkout as Local Branch") { Task { await repo.checkout(branch.name, createTracking: true) } }
        Button("Merge \(branch.name) into \(repo.status.branch ?? "HEAD")") { Task { await repo.merge(branch.name) } }
        Button("Rebase onto \(branch.name)") { Task { await repo.rebase(onto: branch.name) } }
        Button("Compare with \(repo.status.branch ?? "HEAD")…") { model.routes.append(.compare(base: branch.name, target: repo.status.branch ?? "HEAD")) }
        Button("New Branch from \(branch.name)…") { model.newBranchStart = branch.name; model.showNewBranch = true }
        Button("Browse Files") { model.routes.append(.browse(revision: branch.name)) }
        Divider()
        if let current = repo.currentBranch {
            Button("Set as Upstream of \(current.name)") { Task { await repo.setUpstream(current, to: branch.name) } }
        }
        Button("Fetch \(remote.name)") { Task { await repo.fetch(remote: remote.name) } }
        Button("Copy Branch Name") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(branch.name, forType: .string) }
        Divider()
        Button("Delete on Remote…", role: .destructive) { branchToDelete = branch }
    }

    @ViewBuilder
    private func remoteMenu(_ remote: Remote) -> some View {
        Button("Fetch") { Task { await repo.fetch(remote: remote.name) } }
        Button("Prune Stale Branches") { Task { await repo.perform("Pruning") { try await repo.run(["remote", "prune", remote.name]) } } }
        if let web = remote.webURL { Button("Open on Web") { NSWorkspace.shared.open(web) } }
        Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(remote.fetchURL, forType: .string) }
        Divider()
        Button("Remove…", role: .destructive) { remoteToRemove = remote }
    }

    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
        Button("Checkout (detached)") { Task { await repo.checkout(tag.name) } }
        Button("New Branch from \(tag.name)…") { model.newBranchStart = tag.name; model.showNewBranch = true }
        Button("Browse Files") { model.routes.append(.browse(revision: tag.name)) }
        Button("Export as ZIP…") { exportArchive(ref: tag.name) }
        Menu("Push to") {
            ForEach(repo.remotes) { remote in Button(remote.name) { Task { await repo.pushTag(tag, to: remote.name) } } }
        }
        Divider()
        Button("Delete…", role: .destructive) { tagToDelete = tag }
    }

    @ViewBuilder
    private func stashMenu(_ stash: Stash) -> some View {
        Button("Apply") { Task { await repo.applyStash(stash, pop: false) } }
        Button("Pop (apply and drop)") { Task { await repo.applyStash(stash, pop: true) } }
        Button("New Branch from Stash…") { model.newBranchStart = stash.hash; model.showNewBranch = true }
        Divider()
        Button("Drop…", role: .destructive) { stashToDrop = stash }
    }

    private func exportArchive(ref: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(repo.name)-\(ref.replacingOccurrences(of: "/", with: "-")).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await repo.exportArchive(ref: ref, to: url) }
        }
    }
}

struct SidebarRow: View {
    let title: String
    let systemImage: String
    let color: Color
    var badge: Int = 0

    var body: some View {
        Label {
            HStack {
                Text(title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(badge > 9_999 ? "9999+" : "\(badge)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }
}

struct BranchRow: View {
    let branch: Branch
    let repo: Repository
    let model: WindowModel
    var showHash = false

    private var isStale: Bool { Date().timeIntervalSince(branch.date) > 60 * 86_400 }

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(branch.name.split(separator: "/").last.map(String.init) ?? branch.name)
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if branch.upstreamGone {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Upstream branch is gone")
                } else if isStale && !branch.isCurrent {
                    Image(systemName: "zzz").foregroundStyle(.tertiary).help("Stale: last commit \(branch.date.gitRelativeDescription)")
                }
                if branch.ahead > 0 || branch.behind > 0 {
                    Text((branch.ahead > 0 ? "↑\(branch.ahead)" : "") + (branch.behind > 0 ? " ↓\(branch.behind)" : ""))
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
                if showHash {
                    Text(branch.shortHash).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                if branch.isCurrent {
                    Text("HEAD")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.primary)
        }
        .help("\(branch.name) · \(branch.shortHash) · \(branch.subject)")
    }
}

struct RemoteBranchRow: View {
    let branch: Branch
    var body: some View {
        Label {
            HStack {
                Text(branch.nameWithoutRemote.split(separator: "/").last.map(String.init) ?? branch.nameWithoutRemote).lineLimit(1)
                Spacer()
                Text(branch.shortHash).font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        } icon: { Image(systemName: "arrow.triangle.branch").foregroundStyle(.primary) }
        
        .help("\(branch.name) · \(branch.subject)")
    }
}
