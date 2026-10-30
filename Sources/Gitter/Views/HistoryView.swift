import SwiftUI

/// Lane layout for the commit graph.
struct GraphRow: Hashable {
    struct Line: Hashable { let fromLane: Int; let toLane: Int; let color: Int }
    let lane: Int
    let color: Int
    let lines: [Line]
    let laneCount: Int
    /// True when this commit's lane was already open above it (a child drew a line down to it).
    let hasIncoming: Bool
}

enum CommitGraph {
    static func layout(_ commits: [Commit]) -> [GraphRow] {
        var active: [String] = []       // expected hash per lane
        var colors: [Int] = []          // color per lane
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            var lane = active.firstIndex(of: commit.hash)
            let hasIncoming = lane != nil
            if lane == nil {
                active.append(commit.hash)
                colors.append(nextColor); nextColor += 1
                lane = active.count - 1
            }
            let i = lane!
            let before = active
            let beforeColors = colors
            var after = active
            var afterColors = colors

            // Replace this lane with first parent, or close it.
            if let first = commit.parents.first {
                if let existing = after.firstIndex(of: first), existing != i {
                    after.remove(at: i); afterColors.remove(at: i)
                } else {
                    after[i] = first
                }
            } else {
                after.remove(at: i); afterColors.remove(at: i)
            }
            for parent in commit.parents.dropFirst() where !after.contains(parent) {
                after.append(parent); afterColors.append(nextColor); nextColor += 1
            }

            var lines: [GraphRow.Line] = []
            for (k, hash) in before.enumerated() where k != i {
                if let target = after.firstIndex(of: hash) {
                    lines.append(GraphRow.Line(fromLane: k, toLane: target, color: beforeColors[k]))
                }
            }
            for parent in commit.parents {
                if let target = after.firstIndex(of: parent) {
                    lines.append(GraphRow.Line(fromLane: i, toLane: target, color: parent == commit.parents.first ? beforeColors[i] : afterColors[target]))
                }
            }
            rows.append(GraphRow(lane: i, color: beforeColors[i], lines: lines, laneCount: max(before.count, after.count), hasIncoming: hasIncoming))
            active = after
            colors = afterColors
        }
        return rows
    }

    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo, .mint, .brown, .cyan, .yellow]
    static func color(_ index: Int) -> Color { palette[index % palette.count] }
}

struct GraphCell: View {
    let row: GraphRow
    let isMerge: Bool
    static let laneWidth: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let h = size.height
            let mid = h / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2 }
            if row.hasIncoming {
                var incoming = Path()
                incoming.move(to: CGPoint(x: x(row.lane), y: 0))
                incoming.addLine(to: CGPoint(x: x(row.lane), y: mid))
                context.stroke(incoming, with: .color(CommitGraph.color(row.color)), lineWidth: 2)
            }
            for line in row.lines {
                var path = Path()
                if line.fromLane == row.lane {
                    path.move(to: CGPoint(x: x(row.lane), y: mid))
                    if line.toLane == row.lane {
                        path.addLine(to: CGPoint(x: x(row.lane), y: h))
                    } else {
                        path.addCurve(to: CGPoint(x: x(line.toLane), y: h), control1: CGPoint(x: x(row.lane), y: h), control2: CGPoint(x: x(line.toLane), y: mid))
                    }
                } else {
                    path.move(to: CGPoint(x: x(line.fromLane), y: 0))
                    if line.fromLane == line.toLane {
                        path.addLine(to: CGPoint(x: x(line.toLane), y: h))
                    } else {
                        path.addCurve(to: CGPoint(x: x(line.toLane), y: h), control1: CGPoint(x: x(line.fromLane), y: h), control2: CGPoint(x: x(line.toLane), y: mid))
                    }
                }
                context.stroke(path, with: .color(CommitGraph.color(line.color)), lineWidth: 2)
            }
            let r: CGFloat = isMerge ? 3.5 : 4.5
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - r, y: mid - r, width: r * 2, height: r * 2))
            context.fill(dot, with: .color(CommitGraph.color(row.color)))
            if isMerge {
                context.stroke(dot, with: .color(.white), lineWidth: 1.5)
            }
        }
        // Draw taller than the cell and pull the layout back in with negative padding so
        // consecutive rows' lane segments overlap across the table's row spacing.
        .frame(width: CGFloat(max(row.laneCount, 1)) * Self.laneWidth, height: Self.cellHeight + 2 * Self.overflow)
        .padding(.vertical, -Self.overflow)
    }

    static let cellHeight: CGFloat = 24
    static let overflow: CGFloat = 12
}

struct HistoryView: View {
    let repo: Repository
    let model: WindowModel
    let query: GitQueries.LogQuery
    let title: String

    @State private var commits: [Commit] = []
    @State private var rows: [GraphRow] = []
    @State private var rowIndex: [Commit.ID: Int] = [:]
    @State private var selected: Commit.ID?
    @State private var search = ""
    @State private var debouncedSearch = ""
    @State private var loading = false
    @State private var topoOrder = false
    @State private var firstParent = false
    @State private var compact = false
    @State private var showGraph = true
    @State private var resetTarget: Commit?
    @State private var filterAfter: Date?
    @State private var filterBefore: Date?
    @State private var filterAuthor = ""
    @State private var showFilters = false

    private var hasDateFilter: Bool { filterAfter != nil || filterBefore != nil || !filterAuthor.isEmpty }

    private var isFileHistory: Bool { query.path != nil }

    var body: some View {
        let _ = Perf.log("HistoryView body (selected: \(selected?.prefix(7) ?? "none"))")
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: isFileHistory ? "doc.text.magnifyingglass" : "clock")
                    Text(title).font(.headline).lineLimit(1)
                    Text("\(commits.count)").foregroundStyle(.secondary).font(.caption)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Graph", isOn: $showGraph).toggleStyle(.checkbox).disabled(isFileHistory)
                    Toggle("Compact", isOn: $compact).toggleStyle(.checkbox)
                    Menu {
                        Toggle("Topological Order", isOn: $topoOrder)
                        Toggle("First Parent Only", isOn: $firstParent)
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize().help("Sorting")
                    TextField("Search message, author or hash", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Button { showFilters.toggle() } label: {
                        Image(systemName: hasDateFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Filter by author and date")
                    .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                        HistoryFilterPopover(after: $filterAfter, before: $filterBefore, author: $filterAuthor)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
                Divider()

                Table(of: Commit.self, selection: $selected) {
                    TableColumn("") { commit in
                        if showGraph && !isFileHistory, let index = rowIndex[commit.id], index < rows.count {
                            GraphCell(row: rows[index], isMerge: commit.isMerge)
                        }
                    }
                    .width(min: showGraph && !isFileHistory ? 24 : 0, ideal: showGraph && !isFileHistory ? graphWidth : 0, max: showGraph && !isFileHistory ? 240 : 0)

                    TableColumn("Summary") { commit in
                        CommitSummaryCell(commit: commit, isUnpushed: repo.unpushed.contains(commit.hash), isUnpulled: repo.unpulled.contains(commit.hash), compact: compact)
                    }
                    .width(min: 200, ideal: 520)

                    TableColumn("Author") { commit in
                        Text(commit.author).lineLimit(1).help(commit.email)
                    }
                    .width(min: 80, ideal: 140)

                    TableColumn("Date") { commit in
                        Text(commit.date.gitRelativeDescription).lineLimit(1).help(commit.date.formatted())
                    }
                    .width(min: 80, ideal: 130)

                    TableColumn("Hash") { commit in
                        Text(commit.shortHash).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                    .width(70)
                } rows: {
                    // Row-level dragging keeps single-click selection intact; a cell-level
                    // `.draggable` competes with the table's selection gesture on macOS.
                    ForEach(commits) { commit in
                        TableRow(commit)
                            .draggable(DragPayload.commit(commit.hash))
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: Commit.ID.self) { ids in
                    if let hash = ids.first, let commit = commits.first(where: { $0.id == hash }) {
                        commitMenu(commit)
                    }
                } primaryAction: { ids in
                    if let hash = ids.first { model.routes.append(.commit(hash: hash)) }
                }
                .overlay {
                    if commits.isEmpty && !loading {
                        ContentUnavailableView(search.isEmpty ? "No Commits" : "No Matches", systemImage: "clock", description: Text(search.isEmpty ? "This repository has no commits yet." : "No commits match \"\(search)\"."))
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)

            if let selected {
                CommitDetailView(repo: repo, model: model, hash: selected, stash: nil, filePath: query.path)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a Commit", systemImage: "square.and.pencil", description: Text("Commit details and changed files appear here."))
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: TaskKey(query: query, revision: repo.refsRevision, search: debouncedSearch, topo: topoOrder, firstParent: firstParent, after: filterAfter, before: filterBefore, author: filterAuthor)) {
            await load()
        }
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { debouncedSearch = search }
        }
        .confirmationDialog("Reset \(repo.status.branch ?? "HEAD") to \(resetTarget?.shortHash ?? "")?", isPresented: Binding(get: { resetTarget != nil }, set: { if !$0 { resetTarget = nil } }), presenting: resetTarget) { commit in
            Button("Soft (keep changes staged)") { Task { await repo.reset(to: commit.hash, mode: "soft") } }
            Button("Mixed (keep changes unstaged)") { Task { await repo.reset(to: commit.hash, mode: "mixed") } }
            Button("Hard (discard changes)", role: .destructive) { Task { await repo.reset(to: commit.hash, mode: "hard") } }
        } message: { commit in Text(commit.subject) }
    }

    private struct TaskKey: Hashable { let query: GitQueries.LogQuery; let revision: Int; let search: String; let topo: Bool; let firstParent: Bool; let after: Date?; let before: Date?; let author: String }

    private var graphWidth: CGFloat {
        CGFloat(max(rows.map(\.laneCount).max() ?? 1, 1)) * GraphCell.laneWidth + 8
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var q = query
        q.search = debouncedSearch
        q.firstParent = firstParent
        q.topoOrder = topoOrder
        q.since = filterAfter
        q.until = filterBefore
        q.author = filterAuthor
        do {
            let result = try await Perf.measure("history log (revision \(repo.revision))") { try await GitQueries.log(q, in: repo.url) }
            guard !Task.isCancelled else { return }
            commits = result
            rows = (showGraph && !isFileHistory) ? CommitGraph.layout(result) : []
            rowIndex = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
            Perf.log("history loaded \(result.count) commits")
            if let selected, !result.contains(where: { $0.id == selected }) { self.selected = nil }
            if selected == nil, let wanted = ProcessInfo.processInfo.environment["GITTER_DEBUG_SELECT_COMMIT"],
               let match = result.first(where: { $0.hash.hasPrefix(wanted) }) {
                selected = match.id
            }
        } catch {
            repo.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func commitMenu(_ commit: Commit) -> some View {
        Button("Show Details") { model.routes.append(.commit(hash: commit.hash)) }
        Button("Checkout (detached HEAD)") { Task { await repo.checkout(commit.hash) } }
        Button("New Branch from Here…") { model.newBranchStart = commit.hash; model.showNewBranch = true }
        Button("New Tag Here…") { model.newTagRef = commit.hash; model.showNewTag = true }
        Divider()
        Button("Cherry-pick into \(repo.status.branch ?? "HEAD")") { Task { await repo.cherryPick(commit.hash) } }
        Button("Revert Commit") { Task { await repo.revert(commit.hash) } }
        Button("Reset \(repo.status.branch ?? "HEAD") to Here…") { resetTarget = commit }
        Button("Interactive Rebase from Here…") {
            model.interactiveRebaseBase = commit.parents.first ?? commit.hash
            model.showInteractiveRebase = true
        }
        Divider()
        Button("Browse Files at This Revision") { model.routes.append(.browse(revision: commit.hash)) }
        if let path = query.path {
            Button("Blame at This Revision") { model.routes.append(.blame(path: path, revision: commit.hash)) }
        }
        Button("Export as ZIP…") { exportArchive(commit) }
        Button("Save as Patch…") { savePatch(commit) }
        Divider()
        Button("Copy SHA") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) }
        Button("Copy Summary") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.subject, forType: .string) }
    }

    private func exportArchive(_ commit: Commit) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(repo.name)-\(commit.shortHash).zip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await repo.exportArchive(ref: commit.hash, to: url) }
        }
    }

    private func savePatch(_ commit: Commit) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(commit.shortHash).patch"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await repo.saveCommitPatch(commit.hash, to: url) }
        }
    }
}

struct HistoryFilterPopover: View {
    @Binding var after: Date?
    @Binding var before: Date?
    @Binding var author: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter Commits").font(.headline)
            TextField("Author contains", text: $author).textFieldStyle(.roundedBorder)
            Toggle("Date is after", isOn: Binding(get: { after != nil }, set: { after = $0 ? Calendar.current.date(byAdding: .month, value: -1, to: Date()) : nil }))
            if let a = after {
                DatePicker("", selection: Binding(get: { a }, set: { after = $0 }), displayedComponents: .date).labelsHidden()
            }
            Toggle("Date is before", isOn: Binding(get: { before != nil }, set: { before = $0 ? Date() : nil }))
            if let b = before {
                DatePicker("", selection: Binding(get: { b }, set: { before = $0 }), displayedComponents: .date).labelsHidden()
            }
            HStack {
                Spacer()
                Button("Clear") { after = nil; before = nil; author = "" }
            }
        }
        .padding(16)
        .frame(width: 260)
    }
}

struct CommitSummaryCell: View {
    let commit: Commit
    let isUnpushed: Bool
    let isUnpulled: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isUnpushed {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green).help("Not yet pushed")
            }
            if isUnpulled {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue).help("Not yet pulled")
            }
            ForEach(commit.refs, id: \.self) { ref in
                RefBadge(ref: ref)
            }
            Text(commit.subject).lineLimit(1)
                .fontWeight(commit.refs.contains(where: \.isHEADTarget) ? .semibold : .regular)
        }
        .padding(.vertical, compact ? 0 : 2)
    }
}

struct RefBadge: View {
    let ref: CommitRef

    private var color: Color {
        switch ref.kind {
        case .head: .green
        case .local: ref.isHEADTarget ? .green : .blue
        case .remote: .orange
        case .tag: .yellow
        case .stash: .purple
        case .other: .gray
        }
    }

    private var icon: String {
        switch ref.kind {
        case .tag: "tag"
        case .remote: "cloud"
        case .stash: "tray"
        default: "arrow.triangle.branch"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(ref.name).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.5)))
        .lineLimit(1)
    }
}
