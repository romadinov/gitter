import SwiftUI

struct CommitDetailView: View {
    let repo: Repository
    let model: WindowModel
    let hash: String
    let stash: Stash?
    var filePath: String? = nil

    @State private var detail: CommitDetail?
    @State private var selectedFile: String?
    @State private var diffs: [FileDiff] = []
    @State private var loadError: String?
    @State private var settings = AppSettings.shared

    var body: some View {
        let _ = Perf.log("CommitDetailView body \(hash.prefix(7)) detail=\(detail != nil) diffs=\(diffs.count)")
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if let detail {
                    CommitHeader(detail: detail, repo: repo, model: model, stash: stash)
                    Divider()
                    List(detail.files, selection: $selectedFile) { file in
                        HStack(spacing: 10) {
                            StatusBadge(kind: file.kind)
                            FileIcon(path: file.path)
                            Text(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.vertical, 2)
                        .tag(file.path)
                        .onTapGesture { selectedFile = file.path }
                        .draggable(DragPayload.commitFile(hash, file.path))
                        .contextMenu {
                            Button("File History") { model.routes.append(.fileHistory(path: file.path)) }
                            Button("Blame at This Revision") { model.routes.append(.blame(path: file.path, revision: hash)) }
                            Button("Apply Changes to Working Copy") { Task { await repo.applyCommittedFile(hash, path: file.path) } }
                            if let stash {
                                Button("Apply Stashed File") { Task { await repo.applyStashFile(stash, path: file.path) } }
                            }
                            Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
                        }
                    }
                    .listStyle(.plain)
                    .overlay(alignment: .top) {
                        if selectedFile != nil {
                            HStack {
                                Spacer()
                                Button("Show All Files") { selectedFile = nil }.controlSize(.mini).padding(6)
                            }
                        }
                    }
                } else if let loadError {
                    ContentUnavailableView("Unable to Load Commit", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 520, maxHeight: .infinity)

            Group {
                if diffs.isEmpty, detail != nil {
                    ContentUnavailableView("No Changes", systemImage: "doc.text", description: Text("This commit has no textual changes."))
                } else {
                    DiffView(files: diffs, showFileHeaders: true)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: hash) {
            detail = nil
            loadError = nil
            selectedFile = filePath
            do {
                detail = try await Perf.measure("commitDetail \(hash.prefix(7))") { try await GitQueries.commitDetail(hash, in: repo.url) }
            } catch {
                loadError = error.localizedDescription
            }
        }
        .task(id: DiffKey(hash: hash, file: selectedFile, parents: detail?.commit.parents ?? [], whitespace: settings.showWhitespaceChanges, context: settings.contextLines)) {
            guard let detail else { return }
            diffs = await Perf.measure("commitDiff \(hash.prefix(7))") { (try? await GitQueries.commitDiff(hash, parents: detail.commit.parents, path: selectedFile, ignoreWhitespace: !settings.showWhitespaceChanges, context: settings.contextLines, in: repo.url)) ?? [] }
            Perf.log("diff has \(diffs.count) files, \(diffs.reduce(0) { $0 + $1.hunks.reduce(0) { $0 + $1.lines.count } }) lines")
        }
    }

    private struct DiffKey: Hashable { let hash: String; let file: String?; let parents: [String]; let whitespace: Bool; let context: Int }
}

struct CommitHeader: View {
    let detail: CommitDetail
    let repo: Repository
    let model: WindowModel
    let stash: Stash?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.commit.subject).font(.headline).textSelection(.enabled)
            if !detail.body.isEmpty {
                Text(detail.body).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8)
            }
            HStack(spacing: 6) {
                ForEach(detail.commit.refs, id: \.self) { RefBadge(ref: $0) }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Author").foregroundStyle(.secondary)
                    Text("\(detail.commit.author) <\(detail.commit.email)>").textSelection(.enabled).lineLimit(1)
                }
                if detail.committer != detail.commit.author {
                    GridRow {
                        Text("Committer").foregroundStyle(.secondary)
                        Text(detail.committer).lineLimit(1)
                    }
                }
                GridRow {
                    Text("Date").foregroundStyle(.secondary)
                    Text(detail.commit.date.formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    Text("SHA").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(detail.commit.hash).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(detail.commit.hash, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).controlSize(.mini)
                    }
                }
                if !detail.commit.parents.isEmpty {
                    GridRow {
                        Text(detail.commit.parents.count > 1 ? "Parents" : "Parent").foregroundStyle(.secondary)
                        HStack {
                            ForEach(detail.commit.parents, id: \.self) { parent in
                                Button(String(parent.prefix(7))) { model.routes.append(.commit(hash: parent)) }
                                    .buttonStyle(.link).font(.caption.monospaced())
                            }
                        }
                    }
                }
                if let signature = detail.signature {
                    GridRow {
                        Text("Signature").foregroundStyle(.secondary)
                        Label(signature, systemImage: signature.hasPrefix("Good") ? "checkmark.seal" : "xmark.seal").foregroundStyle(signature.hasPrefix("Good") ? .green : .orange)
                    }
                }
            }
            .font(.caption)

            HStack {
                if let stash {
                    Button("Apply") { Task { await repo.applyStash(stash, pop: false) } }
                    Button("Pop") { Task { await repo.applyStash(stash, pop: true) } }
                    Button("Drop", role: .destructive) { Task { await repo.dropStash(stash) } }
                } else {
                    Button("Browse Files") { model.routes.append(.browse(revision: detail.commit.hash)) }
                    Menu("Actions") {
                        Button("Checkout (detached)") { Task { await repo.checkout(detail.commit.hash) } }
                        Button("New Branch from Here…") { model.newBranchStart = detail.commit.hash; model.showNewBranch = true }
                        Button("New Tag Here…") { model.newTagRef = detail.commit.hash; model.showNewTag = true }
                        Divider()
                        Button("Cherry-pick") { Task { await repo.cherryPick(detail.commit.hash) } }
                        Button("Revert") { Task { await repo.revert(detail.commit.hash) } }
                    }
                    .fixedSize()
                }
                Spacer()
                Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(12)
    }
}
