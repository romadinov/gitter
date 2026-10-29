import SwiftUI
import UniformTypeIdentifiers

// MARK: - Blame

struct BlameView: View {
    let repo: Repository
    let model: WindowModel
    let path: String
    let revision: String
    @State private var lines: [BlameLine] = []
    @State private var error: String?
    @State private var settings = AppSettings.shared

    private var commitColors: [String: Color] {
        let hashes = Array(Set(lines.map(\.hash))).sorted { a, b in
            (lines.first { $0.hash == a }?.date ?? .distantPast) > (lines.first { $0.hash == b }?.date ?? .distantPast)
        }
        var map: [String: Color] = [:]
        for (i, h) in hashes.enumerated() {
            map[h] = Color.accentColor.opacity(max(0.05, 0.35 - Double(i) * 0.03))
        }
        return map
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "person.text.rectangle")
                Text(path).font(.headline).lineLimit(1)
                Text("at \(revision.count == 40 ? String(revision.prefix(7)) : revision)").foregroundStyle(.secondary)
                Spacer()
                Button("File History") { model.routes.append(.fileHistory(path: path)) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()
            if let error {
                ContentUnavailableView("Blame Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if lines.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let colors = commitColors
                let language = SyntaxHighlighter.language(for: path)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            let showMeta = index == 0 || lines[index - 1].hash != line.hash
                            HStack(alignment: .top, spacing: 0) {
                                HStack(spacing: 6) {
                                    if showMeta {
                                        Text(String(line.hash.prefix(7))).font(.caption.monospaced())
                                        Text(line.author).font(.caption).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Text(line.date.formatted(date: .numeric, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 260, alignment: .leading)
                                .padding(.horizontal, 8)
                                .frame(maxHeight: .infinity)
                                .background(colors[line.hash] ?? .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { model.routes.append(.commit(hash: line.hash)) }
                                .help("\(line.summary)\n\(line.author), \(line.date.formatted())")
                                Text("\(line.lineNumber)").frame(width: 44, alignment: .trailing).foregroundStyle(.secondary).padding(.trailing, 8)
                                Text(settings.syntaxHighlighting ? SyntaxHighlighter.highlight(line.text.replacingOccurrences(of: "\t", with: "    "), language: language) : AttributedString(line.text))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: settings.diffFontSize, design: .monospaced))
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(path)@\(revision)") {
            do { lines = try await GitQueries.blame(path: path, revision: revision == "HEAD" ? nil : revision, in: repo.url) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Browse revision

struct BrowseView: View {
    let repo: Repository
    let model: WindowModel
    let revision: String
    @State private var nodes: [TreeNode] = []
    @State private var selected: String?
    @State private var content: String?
    @State private var isBinary = false
    @State private var settings = AppSettings.shared

    struct TreeNode: Identifiable, Hashable {
        let id: String
        let name: String
        let isDirectory: Bool
        var children: [TreeNode]?
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "folder")
                    Text("Files at \(revision.count == 40 ? String(revision.prefix(7)) : revision)").font(.headline)
                    Spacer()
                    Button("Export ZIP…") { exportArchive() }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
                Divider()
                List(selection: $selected) {
                    OutlineGroup(nodes, children: \.children) { node in
                        Label(node.name, systemImage: node.isDirectory ? "folder" : "doc")
                            .tag(node.id)
                            .contextMenu {
                                if !node.isDirectory {
                                    Button("File History") { model.routes.append(.fileHistory(path: node.id)) }
                                    Button("Blame") { model.routes.append(.blame(path: node.id, revision: revision)) }
                                    Button("Export File…") { exportFile(node.id) }
                                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.id, forType: .string) }
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 520, maxHeight: .infinity)

            Group {
                if let selected, let content {
                    VStack(spacing: 0) {
                        HStack {
                            Text(selected).font(.callout).lineLimit(1)
                            Spacer()
                            Button("History") { model.routes.append(.fileHistory(path: selected)) }
                            Button("Blame") { model.routes.append(.blame(path: selected, revision: revision)) }
                            Button("Export…") { exportFile(selected) }
                        }
                        .controlSize(.small)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.bar)
                        Divider()
                        if isBinary {
                            ContentUnavailableView("Binary File", systemImage: "doc.zipper", description: Text("Export the file to view it."))
                        } else {
                            let language = SyntaxHighlighter.language(for: selected)
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, line in
                                        HStack(alignment: .top, spacing: 0) {
                                            Text("\(index + 1)").frame(width: 50, alignment: .trailing).foregroundStyle(.secondary).padding(.trailing, 10)
                                            Text(settings.syntaxHighlighting ? SyntaxHighlighter.highlight(String(line).replacingOccurrences(of: "\t", with: "    "), language: language) : AttributedString(String(line)))
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .font(.system(size: settings.diffFontSize, design: .monospaced))
                                        .padding(.vertical, 1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                } else {
                    ContentUnavailableView("Select a File", systemImage: "doc.text", description: Text("File contents at this revision appear here."))
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: revision) { await loadTree() }
        .task(id: selected) {
            guard let selected, let node = find(selected, in: nodes), !node.isDirectory else { content = nil; return }
            guard let data = try? await GitQueries.fileContents(revision: revision, path: selected, in: repo.url) else { content = nil; return }
            if data.prefix(8000).contains(0) { isBinary = true; content = "" } else { isBinary = false; content = String(decoding: data, as: UTF8.self) }
        }
    }

    private func find(_ id: String, in nodes: [TreeNode]) -> TreeNode? {
        for n in nodes {
            if n.id == id { return n }
            if let kids = n.children, let found = find(id, in: kids) { return found }
        }
        return nil
    }

    private func loadTree() async {
        guard let result = try? await repo.run(["ls-tree", "-r", "-t", "-z", revision], check: false), result.succeeded else { return }
        final class Builder {
            var children: [String: Builder] = [:]
            var isDirectory = false
            func node(id: String, name: String) -> TreeNode {
                let kids = children.keys.sorted { a, b in
                    let da = children[a]!.isDirectory, db = children[b]!.isDirectory
                    if da != db { return da }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }.map { children[$0]!.node(id: id.isEmpty ? $0 : id + "/" + $0, name: $0) }
                return TreeNode(id: id, name: name, isDirectory: isDirectory, children: isDirectory ? kids : nil)
            }
        }
        let root = Builder()
        root.isDirectory = true
        for token in result.stdoutData.split(separator: 0) {
            let line = String(decoding: token, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let meta = line[..<tab].split(separator: " ")
            let path = String(line[line.index(after: tab)...])
            guard meta.count == 3 else { continue }
            var cursor = root
            let parts = path.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                if cursor.children[part] == nil { cursor.children[part] = Builder() }
                cursor = cursor.children[part]!
                if i == parts.count - 1 { cursor.isDirectory = meta[1] == "tree" } else { cursor.isDirectory = true }
            }
        }
        nodes = root.node(id: "", name: "").children ?? []
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(repo.name)-\(revision.prefix(7)).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await repo.exportArchive(ref: revision, to: url) }
        }
    }

    private func exportFile(_ path: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                if let data = try? await GitQueries.fileContents(revision: revision, path: path, in: repo.url) {
                    try? data.write(to: url)
                }
            }
        }
    }
}

// MARK: - Reflog

struct ReflogView: View {
    let repo: Repository
    let model: WindowModel
    @State private var entries: [ReflogEntry] = []
    @State private var selected: String?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle")
                    Text("Reflog").font(.headline)
                    Text("Every position HEAD has pointed to — recover lost commits and branches here.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
                Divider()
                Table(entries, selection: $selected) {
                    TableColumn("Ref") { e in Text(e.selector).font(.body.monospaced()).foregroundStyle(.secondary) }.width(110)
                    TableColumn("Action") { e in Text(e.action).lineLimit(1) }.width(min: 200, ideal: 520)
                    TableColumn("Date") { e in Text(e.date.gitRelativeDescription) }.width(130)
                    TableColumn("Hash") { e in Text(e.shortHash).font(.body.monospaced()) }.width(70)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                        Button("Show Commit") { model.routes.append(.commit(hash: entry.hash)) }
                        Button("Checkout (detached)") { Task { await repo.checkout(entry.hash) } }
                        Button("New Branch from Here…") { model.newBranchStart = entry.hash; model.showNewBranch = true }
                        Divider()
                        Button("Reset \(repo.status.branch ?? "HEAD") to Here (hard)", role: .destructive) { Task { await repo.reset(to: entry.hash, mode: "hard") } }
                        Button("Copy SHA") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.hash, forType: .string) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let entry = entries.first(where: { $0.id == id }) { model.routes.append(.commit(hash: entry.hash)) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            if let selected, let entry = entries.first(where: { $0.id == selected }) {
                CommitDetailView(repo: repo, model: model, hash: entry.hash, stash: nil).frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select an Entry", systemImage: "arrow.uturn.backward", description: Text("Reflog entries point to commits you can inspect or restore.")).frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: repo.revision) { entries = (try? await GitQueries.reflog(in: repo.url)) ?? [] }
    }
}

// MARK: - Compare branches

struct CompareView: View {
    let repo: Repository
    let model: WindowModel
    @State var base: String
    @State var target: String
    @State private var files: [FileChange] = []
    @State private var diffs: [FileDiff] = []
    @State private var selectedFile: String?
    @State private var ahead = 0
    @State private var behind = 0

    private var refs: [String] {
        var all = repo.localBranches.map(\.name) + repo.remoteBranches.map(\.name) + repo.tags.map(\.name)
        if !all.contains("HEAD") { all.insert("HEAD", at: 0) }
        for r in [base, target] where !all.contains(r) { all.append(r) }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right")
                Picker("Base", selection: $base) { ForEach(refs, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 260)
                Button { swap(&base, &target) } label: { Image(systemName: "arrow.left.arrow.right.circle") }.buttonStyle(.borderless).help("Swap")
                Picker("Compare", selection: $target) { ForEach(refs, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 260)
                Spacer()
                Text("\(target) is \(ahead) ahead, \(behind) behind \(base)").font(.caption).foregroundStyle(.secondary)
                Button("Merge \(target) into \(repo.status.branch ?? "HEAD")") { Task { await repo.merge(target) } }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()
            VSplitView {
                HistoryView(repo: repo, model: model, query: GitQueries.LogQuery(ref: nil, range: "\(base)..\(target)"), title: "Commits in \(target) not in \(base)")
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
                HSplitView {
                    List(files, selection: $selectedFile) { file in
                        HStack(spacing: 8) {
                            StatusBadge(kind: file.kind)
                            Text(file.path).lineLimit(1).truncationMode(.head)
                        }
                        .tag(file.path)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 480)
                    .overlay { if files.isEmpty { Text("No file differences").foregroundStyle(.tertiary) } }
                    Group {
                        if diffs.isEmpty { ContentUnavailableView("Diff \(base)…\(target)", systemImage: "doc.text", description: Text("Select a file to see its changes.")) }
                        else { DiffView(files: diffs, showFileHeaders: true) }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(base)...\(target)#\(repo.revision)") {
            files = (try? await GitQueries.rangeFiles(base, target, in: repo.url)) ?? []
            if let counts = try? await repo.run(["rev-list", "--left-right", "--count", "\(base)...\(target)"], check: false), counts.succeeded {
                let parts = counts.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" })
                if parts.count == 2 { behind = Int(parts[0]) ?? 0; ahead = Int(parts[1]) ?? 0 }
            }
            selectedFile = nil
        }
        .task(id: "\(base)...\(target)/\(selectedFile ?? "")") {
            diffs = (try? await GitQueries.rangeDiff(base, target, path: selectedFile, in: repo.url)) ?? []
        }
    }
}

// MARK: - Submodules

struct SubmodulesView: View {
    let repo: Repository
    let model: WindowModel
    @State private var showAdd = false
    @State private var newURL = ""
    @State private var newPath = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "shippingbox")
                Text("Submodules").font(.headline)
                Spacer()
                Button("Initialize & Update All") { Task { await repo.updateSubmodules(initialize: true) } }
                Button("Update All") { Task { await repo.updateSubmodules(initialize: false) } }
                Button("Add…") { showAdd = true }
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()
            if repo.submodules.isEmpty {
                ContentUnavailableView("No Submodules", systemImage: "shippingbox", description: Text("This repository has no submodules."))
            } else {
                List(repo.submodules) { sub in
                    HStack {
                        Image(systemName: sub.state == "-" ? "circle.dashed" : (sub.state == "+" ? "exclamationmark.circle" : (sub.state == "U" ? "exclamationmark.triangle" : "checkmark.circle")))
                            .foregroundStyle(sub.state == " " ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(sub.path).fontWeight(.medium)
                            Text("\(sub.hash.prefix(7)) \(sub.describe)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { Task { await model.open(url: repo.url.appendingPathComponent(sub.path)) } }
                        Button("Update") { Task { await repo.perform("Updating submodule") { try await repo.run(["submodule", "update", "--init", "--", sub.path]) } } }
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showAdd) {
            SheetForm(title: "Add Submodule", confirm: "Add", disabled: newURL.isEmpty || newPath.isEmpty) {
                Task { await repo.addSubmodule(url: newURL, path: newPath) }
            } content: {
                TextField("Repository URL", text: $newURL)
                TextField("Path", text: $newPath)
            }
        }
    }
}

/// Generic sheet layout used by the small forms.
struct SheetForm<Content: View>: View {
    let title: String
    let confirm: String
    var disabled = false
    var destructive = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            Form { content() }
                .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, role: destructive ? .destructive : nil) { action(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
