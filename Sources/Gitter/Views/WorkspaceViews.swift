import SwiftUI

// MARK: - Stashes

struct StashesView: View {
    let repo: Repository
    let model: WindowModel
    @State private var selected: String?
    @State private var stashToDrop: Stash?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Stashes").font(.headline)
                    Spacer()
                    Button { model.stashPaths = []; model.showStash = true } label: { Label("Stash Changes", systemImage: "plus") }
                        .disabled(repo.status.changeCount == 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                List(repo.stashes, selection: $selected) { stash in
                    HStack(spacing: 12) {
                        Image(systemName: "tray.full").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stash.message).lineLimit(2)
                            Text("\(stash.ref) · \(stash.date.gitRelativeDescription)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(stash.hash)
                    .draggable(DragPayload.stash(stash.hash))
                    .contextMenu {
                        Button("Apply") { Task { await repo.applyStash(stash, pop: false) } }
                        Button("Pop (apply and drop)") { Task { await repo.applyStash(stash, pop: true) } }
                        Button("New Branch from Stash…") { model.newBranchStart = stash.hash; model.showNewBranch = true }
                        Divider()
                        Button("Drop…", role: .destructive) { stashToDrop = stash }
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if repo.stashes.isEmpty {
                        ContentUnavailableView("No Stashes", systemImage: "tray", description: Text("Stash local changes to set them aside without committing. Drag files from the Working Copy onto “Stashes” to stash only those."))
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 520, maxHeight: .infinity)

            if let selected, let stash = repo.stashes.first(where: { $0.hash == selected }) {
                CommitDetailView(repo: repo, model: model, hash: stash.hash, stash: stash)
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a Stash", systemImage: "tray", description: Text("Inspect stashed changes, then apply, pop or drop them."))
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Drop stash?", isPresented: Binding(get: { stashToDrop != nil }, set: { if !$0 { stashToDrop = nil } }), presenting: stashToDrop) { stash in
            Button("Drop", role: .destructive) { Task { await repo.dropStash(stash) } }
        } message: { stash in Text(stash.message) }
    }
}

// MARK: - Branches Review

struct BranchesReviewView: View {
    let repo: Repository
    let model: WindowModel
    @State private var base = ""
    @State private var merged: Set<String> = []
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var staleDays = 60

    private struct ReviewRow: Identifiable {
        let branch: Branch
        let isMerged: Bool
        let isStale: Bool
        var id: String { branch.fullRef }
    }

    private var rows: [ReviewRow] {
        repo.localBranches.map { ReviewRow(branch: $0, isMerged: merged.contains($0.fullRef) && !$0.isCurrent, isStale: Date().timeIntervalSince($0.date) > Double(staleDays) * 86_400) }
    }

    private var baseOptions: [String] {
        repo.localBranches.map(\.name) + repo.remoteBranches.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Branches Review").font(.headline)
                Spacer()
                Text("Compare local branches to:").foregroundStyle(.secondary)
                Picker("", selection: $base) { ForEach(baseOptions, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(maxWidth: 220)
                Stepper("Stale after \(staleDays) days", value: $staleDays, in: 7...365, step: 7)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            Table(rows, selection: $selected) {
                TableColumn("Branch") { row in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                        Text(row.branch.name).fontWeight(row.branch.isCurrent ? .semibold : .regular)
                        if row.branch.isCurrent { Text("HEAD").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()).fixedSize() }
                    }
                }
                .width(min: 160, ideal: 260)
                TableColumn("Merged into \(base)") { row in
                    if row.branch.isCurrent { Text("—").foregroundStyle(.tertiary) }
                    else { Label(row.isMerged ? "Merged" : "Not merged", systemImage: row.isMerged ? "checkmark.circle.fill" : "circle").foregroundStyle(row.isMerged ? .green : .secondary) }
                }
                .width(min: 120, ideal: 160)
                TableColumn("Last Commit") { row in
                    HStack {
                        if row.isStale { Image(systemName: "zzz").foregroundStyle(.orange).help("Stale") }
                        Text(row.branch.date.gitRelativeDescription).foregroundStyle(row.isStale ? .orange : .primary)
                    }
                }
                .width(min: 120, ideal: 160)
                TableColumn("Tracking") { row in
                    if let up = row.branch.upstream {
                        HStack(spacing: 4) {
                            Text(up).foregroundStyle(row.branch.upstreamGone ? .orange : .secondary)
                            if row.branch.ahead > 0 { Text("↑\(row.branch.ahead)").font(.caption) }
                            if row.branch.behind > 0 { Text("↓\(row.branch.behind)").font(.caption) }
                            if row.branch.upstreamGone { Text("(gone)").font(.caption).foregroundStyle(.orange) }
                        }
                    } else { Text("No tracking").foregroundStyle(.tertiary) }
                }
                .width(min: 160, ideal: 240)
                TableColumn("Subject") { row in Text(row.branch.subject).lineLimit(1).foregroundStyle(.secondary) }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { ids in
                let branches = repo.localBranches.filter { ids.contains($0.fullRef) }
                if branches.count == 1, let b = branches.first {
                    Button("Checkout") { Task { await repo.checkout(b.name) } }.disabled(b.isCurrent)
                    Button("Compare with \(base)…") { model.routes.append(.compare(base: base, target: b.name)) }
                    Button("Show History") { model.selection = .branch(b.fullRef) }
                    Divider()
                }
                Button("Delete \(branches.count) Branch\(branches.count == 1 ? "" : "es")…", role: .destructive) { selected = ids; confirmDelete = true }
                    .disabled(branches.contains(where: \.isCurrent) || branches.isEmpty)
            }
            Divider()
            HStack {
                let mergedCount = rows.filter(\.isMerged).count
                let staleCount = rows.filter { $0.isStale && !$0.branch.isCurrent }.count
                Text("\(repo.localBranches.count) local branches · \(mergedCount) merged into \(base) · \(staleCount) stale").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Select Merged") { selected = Set(rows.filter(\.isMerged).map(\.id)) }.disabled(rows.filter(\.isMerged).isEmpty)
                Button("Delete Selected…", role: .destructive) { confirmDelete = true }
                    .disabled(selected.isEmpty || repo.localBranches.contains { selected.contains($0.fullRef) && $0.isCurrent })
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .onAppear {
            if base.isEmpty { base = repo.currentBranch?.upstream ?? repo.localBranches.first(where: { $0.name == "main" || $0.name == "master" })?.name ?? repo.status.branch ?? baseOptions.first ?? "" }
        }
        .task(id: "\(base)#\(repo.revision)") {
            guard !base.isEmpty else { return }
            merged = await GitQueries.mergedBranches(into: base, in: repo.url)
        }
        .confirmationDialog("Delete \(selected.count) branch(es)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let branches = repo.localBranches.filter { selected.contains($0.fullRef) && !$0.isCurrent }
                Task { for b in branches { await repo.deleteBranch(b, force: true) } }
                selected = []
            }
        } message: {
            Text("Branches are deleted locally. Each deletion can be undone with ⌘Z.")
        }
    }
}

// MARK: - Repository settings

struct RepositorySettingsView: View {
    let repo: Repository
    let model: WindowModel
    @State private var name = ""
    @State private var email = ""
    @State private var remoteToRemove: Remote?
    @State private var editingRemote: Remote?
    @State private var remoteURL = ""
    @State private var remoteName = ""
    @State private var gitignore = ""
    @State private var gitignoreDirty = false
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Committer Identity (this repository)") {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
                HStack {
                    Spacer()
                    if !settings.profiles.isEmpty {
                        Menu("Use Profile") {
                            ForEach(settings.profiles) { profile in
                                Button(profile.label) { name = profile.name; email = profile.email }
                            }
                        }
                        .fixedSize()
                    }
                    Button("Save Identity") {
                        Task { await repo.applyProfile(UserProfile(label: "", name: name, email: email, signingKey: repo.signingKey)) }
                    }
                    .disabled(name == repo.userName && email == repo.userEmail)
                }
            }
            Section("Remotes") {
                ForEach(repo.remotes) { remote in
                    HStack {
                        Image(systemName: "cloud")
                        VStack(alignment: .leading) {
                            Text(remote.name).fontWeight(.medium)
                            Text(remote.fetchURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Edit…") { editingRemote = remote; remoteName = remote.name; remoteURL = remote.fetchURL }
                        Button("Remove", role: .destructive) { remoteToRemove = remote }
                    }
                }
                Button("Add Remote…") { model.showNewRemote = true }
            }
            Section("Ignored Files (.gitignore)") {
                TextEditor(text: $gitignore)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 160)
                    .onChange(of: gitignore) { _, _ in gitignoreDirty = true }
                HStack {
                    Spacer()
                    Button("Save .gitignore") {
                        try? gitignore.write(to: repo.url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
                        gitignoreDirty = false
                    }
                    .disabled(!gitignoreDirty)
                }
            }
            Section("Repository") {
                LabeledContent("Path") { Text(repo.url.path).textSelection(.enabled) }
                LabeledContent("Current branch") { Text(repo.status.branch ?? "—") }
                LabeledContent("Tracking") { Text(repo.status.upstream ?? "No tracking") }
                HStack {
                    Button("Reveal in Finder") { repo.revealInFinder(nil) }
                    Button("Open in Terminal") { repo.openInTerminal() }
                    Button("Run Garbage Collection") { Task { await repo.perform("Optimizing repository") { try await repo.run(["gc", "--auto"]) } } }
                    Button("Verify Integrity (fsck)") { Task { await repo.perform("Verifying") {
                        let result = try await repo.run(["fsck", "--no-progress"], check: false)
                        repo.infoMessage = result.stdout.isEmpty && result.stderr.isEmpty ? "Repository is healthy" : (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    } } }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .onChange(of: repo.revision) { _, _ in if !gitignoreDirty { load() } }
        .confirmationDialog("Remove remote \"\(remoteToRemove?.name ?? "")\"?", isPresented: Binding(get: { remoteToRemove != nil }, set: { if !$0 { remoteToRemove = nil } }), presenting: remoteToRemove) { remote in
            Button("Remove", role: .destructive) { Task { await repo.removeRemote(remote) } }
        }
        .sheet(item: $editingRemote) { remote in
            SheetForm(title: "Edit Remote", confirm: "Save", disabled: remoteName.isEmpty || remoteURL.isEmpty) {
                Task {
                    if remoteURL != remote.fetchURL { await repo.setRemoteURL(remote, url: remoteURL) }
                    if remoteName != remote.name { await repo.renameRemote(remote, to: remoteName) }
                }
            } content: {
                TextField("Name", text: $remoteName)
                TextField("URL", text: $remoteURL)
            }
        }
    }

    private func load() {
        name = repo.userName
        email = repo.userEmail
        gitignore = (try? String(contentsOf: repo.url.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
        gitignoreDirty = false
    }
}
