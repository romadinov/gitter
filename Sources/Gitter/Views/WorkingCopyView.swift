import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

/// One row per path in the working copy, combining its staged and unstaged entries (Tower style).
struct WorkingFile: Identifiable, Hashable {
    let path: String
    let staged: FileChange?
    let unstaged: FileChange?

    var id: String { path }
    var kind: FileStatusKind { unstaged?.kind == .unmerged ? .unmerged : (staged?.kind ?? unstaged?.kind ?? .modified) }
    var isFullyStaged: Bool { staged != nil && unstaged == nil }
    var isPartiallyStaged: Bool { staged != nil && unstaged != nil }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var allChanges: [FileChange] { [staged, unstaged].compactMap { $0 } }

    static func rows(from status: WorkingStatus) -> [WorkingFile] {
        var map: [String: (FileChange?, FileChange?)] = [:]
        for f in status.staged { map[f.path, default: (nil, nil)].0 = f }
        for f in status.unstaged { map[f.path, default: (nil, nil)].1 = f }
        return map.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { WorkingFile(path: $0, staged: map[$0]!.0, unstaged: map[$0]!.1) }
    }
}

struct WorkingCopyView: View {
    let repo: Repository
    let model: WindowModel
    @State private var selection: Set<String> = []
    @State private var diffs: [FileDiff] = []
    @State private var showStagedDiff = true
    @State private var loadingDiff = false
    @State private var filesToDiscard: [FileChange] = []
    @State private var showDiscardConfirm = false
    @State private var viewMode: ViewMode = .changed
    @State private var renameFile: FileChange?
    @State private var renameText = ""
    @State private var showCompleteFile = false
    @State private var settings = AppSettings.shared

    enum ViewMode: String, CaseIterable { case changed = "Changed Files", all = "All Files" }

    private var rows: [WorkingFile] { WorkingFile.rows(from: repo.status) }

    private var selectedRow: WorkingFile? {
        guard selection.count == 1, let path = selection.first else { return nil }
        return rows.first { $0.path == path }
    }

    /// The concrete change whose diff is displayed (staged or unstaged side).
    private var displayedChange: FileChange? {
        guard let row = selectedRow else { return nil }
        if row.isPartiallyStaged { return showStagedDiff ? row.staged : row.unstaged }
        return row.staged ?? row.unstaged
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                WorkingCopyHeader(repo: repo, viewMode: $viewMode)
                Divider()
                if !repo.status.conflicted.isEmpty {
                    ConflictPanel(repo: repo, files: repo.status.conflicted)
                    Divider()
                }
                CommitBox(repo: repo, model: model)
                Divider()
                if viewMode == .changed {
                    HStack(spacing: 0) {
                        Text("Status").frame(width: 92, alignment: .leading)
                        Rectangle().fill(.quaternary).frame(width: 1, height: 14)
                        Text("Filename").padding(.leading, 10).fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.up").font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                    WorkingFileList(rows: rows, selection: $selection, repo: repo, onDoubleClick: { targets in Task { await toggle(targets) } }, dragPaths: pathsForDrag) { targets in
                        fileMenu(targets)
                    }
                    .overlay {
                        if rows.isEmpty {
                            ContentUnavailableView("No Local Changes", systemImage: "checkmark.circle", description: Text("Your working copy is clean."))
                        }
                    }
                } else {
                    AllFilesTree(repo: repo, model: model, selection: $selection, onDiscard: requestDiscard)
                }
            }
            .frame(minWidth: 340, idealWidth: 420, maxWidth: 700)

            VStack(spacing: 0) {
                if let row = selectedRow {
                    DiffHeader(row: row, showStaged: $showStagedDiff, repo: repo, model: model)
                    Divider()
                    HStack {
                        Text(DiffSummary.text(for: diffs)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                }
                if loadingDiff && diffs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let change = displayedChange {
                    if diffs.isEmpty {
                        ContentUnavailableView("No Differences", systemImage: "doc.text.magnifyingglass", description: Text(change.kind == .deleted ? "This file was deleted." : "The file has no textual changes to show."))
                    } else {
                        DiffView(files: diffs, actions: diffActions(for: change))
                    }
                } else if selection.count > 1 {
                    ContentUnavailableView("\(selection.count) Files Selected", systemImage: "doc.on.doc", description: Text("Use the context menu to stage, unstage, discard or stash the selection."))
                } else if repo.status.changeCount == 0 {
                    ContentUnavailableView("Working Copy Clean", systemImage: "checkmark.seal", description: Text("No local changes. Edit files in \(repo.name) and they will show up here."))
                } else {
                    ContentUnavailableView("Select a File", systemImage: "doc.text", description: Text("Select a changed file to review its diff."))
                }
                if selectedRow != nil {
                    Divider()
                    DiffFooter(diffs: diffs, change: displayedChange, repo: repo, showCompleteFile: $showCompleteFile)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: repo.revision, initial: true) { _, _ in
            // Debug aid: GITTER_DEBUG_FILE=<path> preselects a changed file.
            guard selection.isEmpty, let path = ProcessInfo.processInfo.environment["GITTER_DEBUG_FILE"], rows.contains(where: { $0.path == path }) else { return }
            selection = [path]
        }
        .onChange(of: selectedRow?.path) { _, _ in
            if let row = selectedRow { showStagedDiff = row.staged != nil }
        }
        .task(id: DiffTaskKey(changeID: displayedChange?.id, revision: repo.revision, whitespace: settings.showWhitespaceChanges, context: showCompleteFile ? 1_000_000 : settings.contextLines)) {
            guard let change = displayedChange else { diffs = []; return }
            loadingDiff = true
            defer { loadingDiff = false }
            let result = (try? await GitQueries.workingDiff(for: change, ignoreWhitespace: !settings.showWhitespaceChanges, context: showCompleteFile ? 1_000_000 : settings.contextLines, in: repo.url)) ?? []
            if !Task.isCancelled { diffs = result }
        }
        .confirmationDialog("Discard changes in \(filesToDiscard.count) file(s)?", isPresented: $showDiscardConfirm) {
            Button("Discard", role: .destructive) { Task { await repo.discard(filesToDiscard) } }
        } message: {
            Text("Local modifications will be reverted and untracked files deleted. You can undo this with ⌘Z.")
        }
        .alert("Rename File", isPresented: Binding(get: { renameFile != nil }, set: { if !$0 { renameFile = nil } }), presenting: renameFile) { file in
            TextField("Path", text: $renameText)
            Button("Rename") { Task { await repo.renameFile(file, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private struct DiffTaskKey: Hashable { let changeID: String?; let revision: Int; let whitespace: Bool; let context: Int }

    private func pathsForDrag(_ row: WorkingFile) -> [String] {
        selection.contains(row.path) ? Array(selection) : [row.path]
    }

    private func toggle(_ targets: [WorkingFile]) async {
        let toStage = targets.compactMap(\.unstaged).filter { $0.kind != .unmerged }
        if !toStage.isEmpty { await repo.stage(toStage) }
        else { await repo.unstage(targets.compactMap(\.staged)) }
    }

    private func requestDiscard(_ files: [FileChange]) {
        filesToDiscard = files
        showDiscardConfirm = true
    }

    private func diffActions(for file: FileChange) -> DiffActions? {
        guard file.kind != .untracked, file.kind != .unmerged else { return nil }
        if file.staged {
            return DiffActions(primaryTitle: "Unstage", primary: { patch in await repo.applyPatch(patch, cached: true, reverse: true, title: "Unstage Lines") }, secondaryTitle: nil, secondary: nil, reverseForSelection: true)
        }
        return DiffActions(primaryTitle: "Stage", primary: { patch in await repo.applyPatch(patch, cached: true, reverse: false, title: "Stage Lines") }, secondaryTitle: "Discard", secondary: { patch in await repo.applyPatch(patch, cached: false, reverse: true, title: "Discard Lines") }, reverseForSelection: false)
    }

    @ViewBuilder
    private func fileMenu(_ targets: [WorkingFile]) -> some View {
        let unstaged = targets.compactMap(\.unstaged).filter { $0.kind != .unmerged }
        let staged = targets.compactMap(\.staged)
        if !unstaged.isEmpty { Button("Stage") { Task { await repo.stage(unstaged) } } }
        if !staged.isEmpty { Button("Unstage") { Task { await repo.unstage(staged) } } }
        if !unstaged.isEmpty { Button("Discard Changes…", role: .destructive) { requestDiscard(unstaged) } }
        Button("Stash Selected Files…") { model.stashPaths = targets.map(\.path); model.showStash = true }
        Divider()
        if targets.count == 1, let row = targets.first, let file = row.unstaged ?? row.staged {
            Button("Open") { repo.openInEditor(file.path) }
            Button("Reveal in Finder") { repo.revealInFinder(file.path) }
            if file.kind != .untracked {
                Button("File History") { model.routes.append(.fileHistory(path: file.path)) }
                Button("Blame") { model.routes.append(.blame(path: file.path, revision: "HEAD")) }
                Button("Open in External Diff Tool") { Task { await repo.openExternalDiff(for: file) } }
            }
            Button("Rename…") { renameText = file.path; renameFile = file }
            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
            Divider()
        }
        let all = targets.flatMap(\.allChanges)
        Button("Ignore") { Task { await repo.ignore(all) } }
        if all.contains(where: { $0.kind != .untracked }) {
            Button("Stop Tracking") { Task { await repo.untrack(all) } }
        }
        Button("Save as Patch…") { savePatch(all) }
        Divider()
        Button("Move to Trash…", role: .destructive) { Task { await repo.deleteFromDisk(all) } }
    }

    private func savePatch(_ targets: [FileChange]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "changes.patch"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await repo.savePatch(of: targets, to: url) }
        }
    }
}

struct WorkingCopyHeader: View {
    let repo: Repository
    @Binding var viewMode: WorkingCopyView.ViewMode

    var body: some View {
        HStack(spacing: 6) {
            Text(repo.status.detached ? "Detached HEAD" : (repo.status.branch ?? "No commits"))
                .foregroundStyle(.primary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            Text(repo.status.upstream ?? "No Tracking").foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("View", selection: $viewMode) {
                    ForEach(WorkingCopyView.ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("View options")
        }
        
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct StatusBadge: View {
    let kind: FileStatusKind

    var color: Color {
        switch kind {
        case .added, .untracked: Color(red: 0.20, green: 0.66, blue: 0.33)
        case .modified, .typeChanged: Color(red: 0.07, green: 0.47, blue: 0.95)
        case .deleted: Color(red: 0.90, green: 0.25, blue: 0.22)
        case .renamed, .copied: Color(red: 0.55, green: 0.35, blue: 0.85)
        case .unmerged: Color(red: 0.95, green: 0.55, blue: 0.10)
        case .ignored: .gray
        }
    }

    var body: some View {
        Text(kind == .untracked ? "?" : kind.rawValue)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 5))
            .help(kind.title)
    }
}

/// Custom selectable list with Tower-style rounded highlight, multi-select (⌘/⇧-click) and double-click.
struct WorkingFileList<Menu: View>: View {
    let rows: [WorkingFile]
    @Binding var selection: Set<String>
    let repo: Repository
    let onDoubleClick: ([WorkingFile]) -> Void
    let dragPaths: (WorkingFile) -> [String]
    @ViewBuilder let menu: ([WorkingFile]) -> Menu
    @State private var anchor: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows) { row in
                    let isSelected = selection.contains(row.path)
                    WorkingFileRow(row: row, repo: repo, isSelected: isSelected)
                        .padding(.horizontal, 8)
                        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if !selection.contains(row.path) { selection = [row.path]; anchor = row.path }
                            onDoubleClick(rows.filter { selection.contains($0.path) })
                        }
                        .onTapGesture { select(row) }
                        .contextMenu {
                            let targets = selection.contains(row.path) ? rows.filter { selection.contains($0.path) } : [row]
                            menu(targets)
                        }
                        .draggable(DragPayload.files(dragPaths(row)))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func select(_ row: WorkingFile) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(row.path) { selection.remove(row.path) } else { selection.insert(row.path) }
            anchor = row.path
        } else if flags.contains(.shift), let anchor, let a = rows.firstIndex(where: { $0.path == anchor }), let b = rows.firstIndex(where: { $0.path == row.path }) {
            selection = Set(rows[min(a, b)...max(a, b)].map(\.path))
        } else {
            selection = [row.path]
            anchor = row.path
        }
    }
}

struct WorkingFileRow: View {
    let row: WorkingFile
    let repo: Repository
    var isSelected = false

    private var checkIcon: String {
        if row.isFullyStaged { return "checkmark.square.fill" }
        if row.isPartiallyStaged { return "minus.square.fill" }
        return "square"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if let unstaged = row.unstaged, unstaged.kind != .unmerged { await repo.stage([unstaged]) }
                    else if let staged = row.staged { await repo.unstage([staged]) }
                }
            } label: {
                Image(systemName: checkIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.white : (row.staged != nil ? Color.accentColor : Color.secondary.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .disabled(row.kind == .unmerged)
            StatusBadge(kind: row.kind)
            FileIcon(path: row.path).padding(.leading, 12)
            Text(row.staged?.originalPath.map { "\($0) → \(row.path)" } ?? row.path)
                
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.leading, 4)
    }
}

struct DiffHeader: View {
    let row: WorkingFile
    @Binding var showStaged: Bool
    let repo: Repository
    let model: WindowModel

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(path: row.path)
            Text(row.fileName).font(.headline)
            if !row.directory.isEmpty {
                Text(row.directory).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let file = row.unstaged ?? row.staged, file.kind != .untracked {
                Menu {
                    Button("File History") { model.routes.append(.fileHistory(path: file.path)) }
                    Button("Blame") { model.routes.append(.blame(path: file.path, revision: "HEAD")) }
                    Button("Open in External Diff Tool") { Task { await repo.openExternalDiff(for: file) } }
                    Button("Open in Editor") { repo.openInEditor(file.path) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Picker("", selection: $showStaged) {
                Text("Staged").tag(true)
                Text("Unstaged").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .disabled(!row.isPartiallyStaged)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct DiffFooter: View {
    let diffs: [FileDiff]
    let change: FileChange?
    let repo: Repository
    @Binding var showCompleteFile: Bool
    @State private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { !settings.showWhitespaceChanges }, set: { settings.showWhitespaceChanges = !$0 })) {
                Image(systemName: "textformat.abc.dottedunderline")
            }
            .toggleStyle(.button).buttonStyle(.borderless)
            .help("Show / Hide Whitespace Changes")
            Toggle(isOn: $showCompleteFile) { Image(systemName: "doc.plaintext") }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help("Display the Complete File")
            Toggle(isOn: $settings.syntaxHighlighting) { Image(systemName: "paintpalette") }
                .toggleStyle(.button).buttonStyle(.borderless)
                .help("Syntax coloring")
            if let change, change.kind != .untracked {
                Button { Task { await repo.openExternalDiff(for: change) } } label: { Image(systemName: "rectangle.split.2x1") }
                    .buttonStyle(.borderless).help("Open in external diff tool")
            }
            Spacer()
            Text(DiffSummary.text(for: diffs)).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Stepper(value: $settings.contextLines, in: 0...20) {
                Text("Context: \(settings.contextLines) line\(settings.contextLines == 1 ? "" : "s")").font(.callout)
            }
            .fixedSize()
            .disabled(showCompleteFile)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Full working tree with status overlays (Tower's "All Files" mode).
struct AllFilesTree: View {
    let repo: Repository
    let model: WindowModel
    @Binding var selection: Set<String>
    let onDiscard: ([FileChange]) -> Void
    @State private var nodes: [FileNode] = []

    struct FileNode: Identifiable, Hashable {
        let id: String
        let name: String
        let row: WorkingFile?
        var children: [FileNode]?
    }

    var body: some View {
        List(selection: $selection) {
            OutlineGroup(nodes, children: \.children) { node in
                if let row = node.row {
                    WorkingFileRow(row: row, repo: repo).tag(row.path)
                } else if node.children == nil {
                    HStack(spacing: 12) {
                        Image(systemName: "square").font(.system(size: 18)).foregroundStyle(.clear)
                        Color.clear.frame(width: 22, height: 22)
                        FileIcon(path: node.id).padding(.leading, 12)
                        Text(node.name).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4).padding(.leading, 4)
                } else {
                    Label(node.name, systemImage: "folder.fill").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .contextMenu(forSelectionType: String.self) { ids in
            let targets = WorkingFile.rows(from: repo.status).filter { ids.contains($0.path) }
            if !targets.isEmpty {
                Button("Stage") { Task { await repo.stage(targets.compactMap(\.unstaged)) } }
                Button("Unstage") { Task { await repo.unstage(targets.compactMap(\.staged)) } }
                Button("Discard Changes…", role: .destructive) { onDiscard(targets.compactMap(\.unstaged)) }
            }
        }
        .task(id: repo.revision) { await load() }
    }

    private func load() async {
        guard let result = try? await repo.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], check: false) else { return }
        let tracked = result.stdoutData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let rowsByPath = Dictionary(uniqueKeysWithValues: WorkingFile.rows(from: repo.status).map { ($0.path, $0) })
        let allPaths = Set(tracked).union(rowsByPath.keys)

        final class Builder {
            var children: [String: Builder] = [:]
            var row: WorkingFile?
            var isFile = false
            func node(id: String, name: String) -> FileNode {
                if isFile { return FileNode(id: id, name: name, row: row, children: nil) }
                let kids = children.keys.sorted { a, b in
                    let fa = children[a]!.isFile, fb = children[b]!.isFile
                    if fa != fb { return !fa }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }.map { children[$0]!.node(id: id.isEmpty ? $0 : id + "/" + $0, name: $0) }
                return FileNode(id: id, name: name, row: nil, children: kids)
            }
        }
        let root = Builder()
        for path in allPaths {
            var cursor = root
            let parts = path.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                if cursor.children[part] == nil { cursor.children[part] = Builder() }
                cursor = cursor.children[part]!
                if i == parts.count - 1 { cursor.isFile = true; cursor.row = rowsByPath[path] }
            }
        }
        nodes = root.node(id: "", name: "").children ?? []
    }
}

struct ConflictPanel: View {
    let repo: Repository
    let files: [FileChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(files.count) conflicted file(s)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.subheadline.weight(.semibold))
            ForEach(files) { file in
                HStack {
                    Text(file.path).lineLimit(1).font(.callout)
                    Spacer()
                    Menu("Resolve") {
                        Button("Use Mine (ours)") { Task { await repo.resolveConflict(file, using: "--ours") } }
                        Button("Use Theirs") { Task { await repo.resolveConflict(file, using: "--theirs") } }
                        Button("Open Merge Tool") { Task { await repo.openMergeTool(file) } }
                        Button("Open in Editor") { repo.openInEditor(file.path) }
                        Divider()
                        Button("Mark as Resolved") { Task { await repo.markResolved(file) } }
                    }
                    .controlSize(.small)
                    .frame(width: 90)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08))
    }
}

/// Gravatar avatar with initials fallback.
struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 44

    private var gravatarURL: URL? {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        let digest = Insecure.MD5.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(digest)?s=\(Int(size * 2))&d=404")
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        AsyncImage(url: gravatarURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.gradient)
                    Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.quaternary))
    }
}

struct CommitBox: View {
    let repo: Repository
    let model: WindowModel
    @State private var summary = ""
    @State private var body_ = ""
    @State private var amend = false
    @State private var signOff = false
    @State private var skipHooks = false
    @State private var settings = AppSettings.shared
    @FocusState private var summaryFocused: Bool

    private var canCommit: Bool {
        !summary.trimmingCharacters(in: .whitespaces).isEmpty && (!repo.status.staged.isEmpty || amend) && repo.operationState != .rebasing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .trailing) {
                TextField("Commit subject", text: $summary)
                    .textFieldStyle(.plain)
                    
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .padding(.trailing, 30)
                    .focused($summaryFocused)
                    .onSubmit { if canCommit { commit() } }
                Text("\(summary.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(summary.count > 72 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .padding(.trailing, 12)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $body_)
                        
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    if body_.isEmpty {
                        Text("Description").foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 9).allowsHitTesting(false)
                    }
                }
                .frame(height: 96)
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        ForEach(settings.commitTemplates) { template in
                            Button(template.name) { summary = template.subject; body_ = template.body }
                        }
                        if settings.commitTemplates.isEmpty { Text("No templates") }
                        Divider()
                        Button("Save Current as Template…") { saveTemplate() }
                        Button("Manage Templates…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                    } label: { Image(systemName: "doc.text") }
                    .menuStyle(.borderlessButton).fixedSize().help("Commit templates")
                    Divider().frame(height: 16)
                    Menu {
                        ForEach(Gitmoji.all, id: \.code) { g in
                            Button("\(g.emoji)  \(g.description)") { summary = g.emoji + " " + summary }
                        }
                    } label: { Image(systemName: "face.smiling") }
                    .menuStyle(.borderlessButton).fixedSize().help("Gitmoji")
                    Divider().frame(height: 16)
                    Button { body_ += (body_.isEmpty ? "" : "\n") + "Co-authored-by: " } label: { Image(systemName: "person.2") }
                        .buttonStyle(.borderless).help("Add co-author trailer")
                    Spacer()
                    Button { summary = ""; body_ = "" } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Clear message").disabled(summary.isEmpty && body_.isEmpty)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Amend", isOn: $amend).toggleStyle(.checkbox).disabled(!repo.status.hasHEAD)
                    Toggle("Sign Off", isOn: $signOff).toggleStyle(.checkbox).help("Add a Signed-off-by trailer")
                    Toggle("Skip Hooks", isOn: $skipHooks).toggleStyle(.checkbox).help("Bypass pre-commit and commit-msg hooks (--no-verify)")
                }
                
                Spacer()
                Menu {
                    ForEach(settings.profiles) { profile in
                        Button("\(profile.label) — \(profile.name) <\(profile.email)>") { Task { await repo.applyProfile(profile) } }
                    }
                    if settings.profiles.isEmpty { Text("No profiles configured") }
                    Divider()
                    Button("Manage Profiles…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(repo.userName.isEmpty ? "No committer identity" : repo.userName)
                        Text(repo.userEmail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                AvatarView(name: repo.userName, email: repo.userEmail, size: 36)
            }
            .padding(.top, 4)

            HStack {
                if repo.status.staged.isEmpty {
                    Button("Stage All") { Task { await repo.stageAll() } }.disabled(repo.status.unstaged.isEmpty)
                } else {
                    Button("Unstage All") { Task { await repo.unstageAll() } }
                }
                Spacer()
                Toggle("Sign", isOn: $settings.signCommits).toggleStyle(.checkbox).help("Sign the commit with GPG/SSH (git commit -S)").font(.callout)
                Button(amend ? "Amend" : "Commit") { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCommit)
                    .help("Commit staged changes (⌘↩)")
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(16)
        .onChange(of: amend) { _, isAmend in
            guard isAmend, summary.isEmpty else { return }
            Task {
                let message = await GitQueries.lastCommitMessage(in: repo.url)
                let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                summary = parts.first.map(String.init) ?? ""
                body_ = parts.count > 1 ? parts[1].trimmingCharacters(in: .newlines) : ""
            }
        }
    }

    private func commit() {
        var message = body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : summary + "\n\n" + body_
        if signOff, !repo.userName.isEmpty {
            message += "\n\nSigned-off-by: \(repo.userName) <\(repo.userEmail)>"
        }
        let isAmend = amend
        Task {
            await repo.commit(message: message, amend: isAmend, sign: settings.signCommits, skipHooks: skipHooks)
            if repo.errorMessage == nil {
                summary = ""
                body_ = ""
                amend = false
            }
        }
    }

    private func saveTemplate() {
        let alert = NSAlert()
        alert.messageText = "Template Name"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.isEmpty ? "Template \(settings.commitTemplates.count + 1)" : field.stringValue
            settings.commitTemplates.append(CommitTemplate(name: name, subject: summary, body: body_))
        }
    }
}
