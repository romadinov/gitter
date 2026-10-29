import SwiftUI
import UniformTypeIdentifiers

struct CloneSheet: View {
    let model: WindowModel
    @State private var url = ""
    @State private var destination = FileManager.default.urls(for: .developerDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
    @State private var name = ""
    @State private var cloning = false
    @Environment(\.dismiss) private var dismiss

    private var effectiveName: String {
        if !name.isEmpty { return name }
        var last = url.split(separator: "/").last.map(String.init) ?? ""
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        if let colon = last.lastIndex(of: ":") { last = String(last[last.index(after: colon)...]) }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Repository").font(.title3.weight(.semibold))
            Form {
                TextField("Remote URL", text: $url, prompt: Text("https://github.com/user/repo.git or git@host:user/repo.git"))
                HStack {
                    TextField("Destination", text: .constant(destination.path)).disabled(true)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let u = panel.url { destination = u }
                    }
                }
                TextField("Folder Name", text: $name, prompt: Text(effectiveName.isEmpty ? "repository" : effectiveName))
            }
            .formStyle(.columns)
            Text("Cloning runs in the background; you can keep using the app. SSH keys, credential helpers and 1Password SSH agent are used automatically.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if cloning { ProgressView().controlSize(.small); Text("Cloning…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(cloning)
                Button("Clone") {
                    cloning = true
                    let remote = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    let folder = effectiveName
                    Task {
                        await model.clone(url: remote, into: destination, name: folder)
                        cloning = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(url.isEmpty || effectiveName.isEmpty || cloning)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct NewBranchSheet: View {
    let repo: Repository
    let startPoint: String?
    @State private var name = ""
    @State private var start: String = ""
    @State private var checkout = true

    private var startOptions: [String] {
        var options = ["HEAD"] + repo.localBranches.map(\.name) + repo.remoteBranches.map(\.name) + repo.tags.map(\.name)
        if let startPoint, !options.contains(startPoint) { options.insert(startPoint, at: 0) }
        return options
    }

    var body: some View {
        SheetForm(title: "New Branch", confirm: "Create", disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
            Task { await repo.createBranch(name.trimmingCharacters(in: .whitespaces), from: start == "HEAD" ? nil : start, checkout: checkout) }
        } content: {
            TextField("Name", text: $name, prompt: Text("feature/my-branch"))
            Picker("Starting Point", selection: $start) {
                ForEach(startOptions, id: \.self) { Text($0.count == 40 ? String($0.prefix(7)) : $0).tag($0) }
            }
            Toggle("Check out the new branch", isOn: $checkout)
        }
        .onAppear { start = startPoint ?? "HEAD" }
    }
}

struct NewTagSheet: View {
    let repo: Repository
    let ref: String?
    @State private var name = ""
    @State private var message = ""
    @State private var push = false

    var body: some View {
        SheetForm(title: "New Tag", confirm: "Create", disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) {
            let tagName = name.trimmingCharacters(in: .whitespaces)
            Task {
                await repo.createTag(tagName, at: ref, message: message)
                if push, let remote = repo.remotes.first {
                    await repo.perform("Pushing tag") { try await repo.run(["push", remote.name, "refs/tags/\(tagName)"]) }
                }
            }
        } content: {
            TextField("Name", text: $name, prompt: Text("v1.0.0"))
            TextField("Message (annotated tag)", text: $message)
            LabeledContent("At") { Text(ref.map { $0.count == 40 ? String($0.prefix(7)) : $0 } ?? "HEAD").foregroundStyle(.secondary) }
            if let remote = repo.remotes.first {
                Toggle("Push tag to \(remote.name)", isOn: $push)
            }
        }
    }
}

struct NewRemoteSheet: View {
    let repo: Repository
    @State private var name = "origin"
    @State private var url = ""

    var body: some View {
        SheetForm(title: "Add Remote", confirm: "Add", disabled: name.isEmpty || url.isEmpty) {
            Task { await repo.addRemote(name: name, url: url) }
        } content: {
            TextField("Name", text: $name)
            TextField("URL", text: $url, prompt: Text("git@github.com:user/repo.git"))
        }
        .onAppear { if repo.remotes.contains(where: { $0.name == "origin" }) { name = "" } }
    }
}

struct StashSheet: View {
    let repo: Repository
    let paths: [String]
    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false

    var body: some View {
        SheetForm(title: paths.isEmpty ? "Stash Changes" : "Stash \(paths.count) File\(paths.count == 1 ? "" : "s")", confirm: "Stash") {
            Task { await repo.stash(message: message, includeUntracked: includeUntracked, keepIndex: keepIndex, paths: paths) }
        } content: {
            TextField("Message", text: $message, prompt: Text("WIP on \(repo.status.branch ?? "HEAD")"))
            Toggle("Include untracked files", isOn: $includeUntracked)
            Toggle("Keep staged changes in the index", isOn: $keepIndex)
            if !paths.isEmpty {
                LabeledContent("Files") {
                    Text(paths.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                }
            }
        }
    }
}

/// Interactive rebase: reorder, pick, reword-free squash/fixup/drop by drag and drop.
struct InteractiveRebaseSheet: View {
    let repo: Repository
    let base: String?

    struct TodoItem: Identifiable, Hashable {
        let id: String
        let shortHash: String
        let subject: String
        var action: Action = .pick
        enum Action: String, CaseIterable { case pick, squash, fixup, drop }
    }

    @State private var items: [TodoItem] = []
    @State private var baseRef = ""
    @State private var loading = true
    @State private var selection: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    private var baseOptions: [String] {
        var options = repo.localBranches.map(\.name) + repo.remoteBranches.map(\.name) + repo.tags.map(\.name)
        if let base, !options.contains(base) { options.insert(base, at: 0) }
        return options.filter { $0 != repo.status.branch }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Rebase").font(.title3.weight(.semibold))
            HStack {
                Text("Rebase \(repo.status.branch ?? "HEAD") onto")
                Picker("", selection: $baseRef) {
                    ForEach(baseOptions, id: \.self) { Text($0.count == 40 ? String($0.prefix(7)) : $0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 280)
                Spacer()
                Text("\(items.count) commit\(items.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            Text("Drag commits to reorder (oldest at top). Squash and fixup fold a commit into the one above it; drop removes it.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach($items) { $item in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Picker("", selection: $item.action) {
                            ForEach(TodoItem.Action.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 90)
                        Text(item.shortHash).font(.body.monospaced()).foregroundStyle(.secondary)
                        Text(item.subject).lineLimit(1).strikethrough(item.action == .drop)
                            .foregroundStyle(item.action == .drop ? .secondary : .primary)
                        Spacer()
                    }
                    .tag(item.id)
                    .contextMenu {
                        ForEach(TodoItem.Action.allCases, id: \.self) { action in
                            Button(action.rawValue.capitalized) { item.action = action }
                        }
                    }
                }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
            }
            .frame(minHeight: 260)
            .overlay {
                if loading { ProgressView() }
                else if items.isEmpty { Text("No commits to rebase").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Rebase") {
                    let todo = items.map { "\($0.action.rawValue) \($0.id) \($0.subject)" }.joined(separator: "\n") + "\n"
                    let target = baseRef
                    Task { await repo.interactiveRebase(onto: target, todo: todo) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(items.isEmpty || items.first?.action == .squash || items.first?.action == .fixup || baseRef.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
        .onAppear {
            baseRef = base ?? repo.currentBranch?.upstream ?? baseOptions.first ?? ""
        }
        .task(id: baseRef) {
            guard !baseRef.isEmpty else { return }
            loading = true
            defer { loading = false }
            let commits = (try? await GitQueries.log(GitQueries.LogQuery(ref: nil, limit: 200, range: "\(baseRef)..HEAD"), in: repo.url)) ?? []
            items = commits.reversed().map { TodoItem(id: $0.hash, shortHash: $0.shortHash, subject: $0.subject) }
        }
    }
}

/// Command palette: switch branches, run commands, jump to commits.
struct QuickActionsView: View {
    let repo: Repository
    let model: WindowModel
    @State private var query = ""
    @State private var commits: [Commit] = []
    @State private var selected: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    struct Action: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let run: () -> Void
    }

    private var actions: [Action] {
        var list: [Action] = []
        let q = query.lowercased()
        func matches(_ s: String) -> Bool { q.isEmpty || s.lowercased().contains(q) }

        for b in repo.localBranches where matches(b.name) {
            list.append(Action(id: "branch:\(b.fullRef)", title: b.isCurrent ? "\(b.name) (current)" : "Checkout \(b.name)", subtitle: b.subject, icon: "arrow.triangle.branch") {
                if !b.isCurrent { Task { await repo.checkout(b.name) } }
                model.selection = .branch(b.fullRef)
            })
        }
        for b in repo.remoteBranches where matches(b.name) {
            list.append(Action(id: "remote:\(b.fullRef)", title: "Checkout \(b.name)", subtitle: "Create a tracking branch", icon: "cloud") {
                Task { await repo.checkout(b.name, createTracking: true) }
            })
        }
        for t in repo.tags.prefix(30) where matches(t.name) {
            list.append(Action(id: "tag:\(t.name)", title: "Show tag \(t.name)", subtitle: t.subject, icon: "tag") { model.selection = .tag(t.name) })
        }
        let commands: [(String, String, String, () -> Void)] = [
            ("Fetch", "Fetch all remotes", "arrow.triangle.2.circlepath", { Task { await repo.fetch() } }),
            ("Pull", "Pull from upstream", "arrow.down.to.line", { Task { await repo.pull() } }),
            ("Push", "Push to upstream", "arrow.up.to.line", { Task { await repo.push(setUpstream: repo.status.upstream == nil) } }),
            ("Sync", "Pull, then push", "arrow.up.arrow.down", { Task { await repo.sync() } }),
            ("Stash Changes", "Save the working copy to a stash", "tray.and.arrow.down", { model.stashPaths = []; model.showStash = true }),
            ("New Branch", "Create a branch from HEAD", "plus", { model.newBranchStart = nil; model.showNewBranch = true }),
            ("New Tag", "Tag HEAD", "tag", { model.newTagRef = nil; model.showNewTag = true }),
            ("Interactive Rebase", "Reorder, squash or drop commits", "list.number", { model.interactiveRebaseBase = nil; model.showInteractiveRebase = true }),
            ("Working Copy", "Show local changes", "doc.text", { model.selection = .workingCopy }),
            ("History", "Show all branches", "clock", { model.selection = .history }),
            ("Reflog", "Recover lost commits", "arrow.uturn.backward.circle", { model.selection = .reflog }),
            ("Browse Files at HEAD", "Explore the tree", "folder", { model.routes.append(.browse(revision: "HEAD")) }),
            ("Compare Branches", "Diff two refs", "arrow.left.arrow.right", { model.routes.append(.compare(base: repo.remoteBranches.first?.name ?? "HEAD", target: repo.status.branch ?? "HEAD")) }),
            ("Open in Terminal", repo.url.path, "terminal", { repo.openInTerminal() }),
            ("Reveal in Finder", repo.url.path, "folder.badge.gearshape", { repo.revealInFinder(nil) }),
            ("Undo", repo.undoStack.undoTitle ?? "Nothing to undo", "arrow.uturn.backward", { Task { await repo.undo() } }),
        ]
        for c in commands where matches(c.0) || matches(c.1) {
            list.append(Action(id: "cmd:\(c.0)", title: c.0, subtitle: c.1, icon: c.2, run: c.3))
        }
        for c in commits.prefix(25) {
            list.append(Action(id: "commit:\(c.hash)", title: c.subject, subtitle: "\(c.shortHash) · \(c.author) · \(c.date.gitRelativeDescription)", icon: "circle.fill") {
                model.selection = .history
                model.routes.append(.commit(hash: c.hash))
            })
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Switch branch, run a command, or search commits…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { runSelected() }
            }
            .padding(14)
            Divider()
            let list = actions
            List(list, selection: $selected) { action in
                HStack(spacing: 10) {
                    Image(systemName: action.icon).frame(width: 20).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.title).lineLimit(1)
                        Text(action.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(action.id)
                .contentShape(Rectangle())
                .onTapGesture { action.run(); dismiss() }
            }
            .listStyle(.plain)
            .onChange(of: list.map(\.id)) { _, ids in
                if selected == nil || !ids.contains(selected!) { selected = ids.first }
            }
            .onAppear { selected = list.first?.id }
        }
        .frame(width: 620, height: 440)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2 else { commits = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            commits = (try? await GitQueries.log(GitQueries.LogQuery(ref: nil, search: term, limit: 25), in: repo.url)) ?? []
        }
    }

    private func move(_ delta: Int) {
        let ids = actions.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selected.flatMap { ids.firstIndex(of: $0) } ?? -1
        selected = ids[max(0, min(ids.count - 1, index + delta))]
    }

    private func runSelected() {
        let list = actions
        guard let action = list.first(where: { $0.id == selected }) ?? list.first else { return }
        action.run()
        dismiss()
    }
}

/// Repository switcher listing recent repositories with groups.
struct RepositoryListView: View {
    let model: WindowModel
    @State private var recents = RecentRepositories.shared
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private var groups: [(String, [String])] {
        let paths = recents.paths.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
        var dict: [String: [String]] = [:]
        for p in paths { dict[recents.groups[p] ?? "", default: []].append(p) }
        return dict.keys.sorted { a, b in a.isEmpty ? false : (b.isEmpty ? true : a < b) }.map { ($0.isEmpty ? "Repositories" : $0, dict[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Repositories").font(.title3.weight(.semibold))
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Open…") { dismiss(); model.openRepositoryPanel() }
                Button("Clone…") { dismiss(); model.showClone = true }
            }
            .padding(14)
            Divider()
            List {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { path in
                            RecentRepositoryRow(path: path, recents: recents) {
                                dismiss()
                                Task { await model.open(url: URL(fileURLWithPath: path)) }
                            }
                            .contextMenu {
                                Button("Open in New Window") { openWindow(id: "repo", value: URL(fileURLWithPath: path)) }
                            }
                        }
                    }
                }
            }
            HStack {
                Text("Double-click to open. Right-click to group, open in a new window, or remove.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 480)
    }
}
