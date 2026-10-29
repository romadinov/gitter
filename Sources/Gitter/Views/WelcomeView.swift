import SwiftUI

struct WelcomeView: View {
    let model: WindowModel
    @State private var recents = RecentRepositories.shared
    @State private var filter = ""

    private var filteredPaths: [String] {
        guard !filter.isEmpty else { return recents.paths }
        return recents.paths.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    private var groupedPaths: [(group: String, paths: [String])] {
        var groups: [String: [String]] = [:]
        for path in filteredPaths {
            groups[recents.groups[path] ?? "", default: []].append(path)
        }
        return groups.keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a < b
        }.map { ($0.isEmpty ? "Repositories" : $0, groups[$0] ?? []) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("Gitter").font(.system(size: 34, weight: .bold))
                        Text("A free Git client for macOS").foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 10)

                WelcomeButton(title: "Open Repository…", subtitle: "Browse to a local Git repository", systemImage: "folder") {
                    model.openRepositoryPanel()
                }
                WelcomeButton(title: "Clone Repository…", subtitle: "Clone from a remote URL", systemImage: "arrow.down.circle") {
                    model.showClone = true
                }
                WelcomeButton(title: "Create New Repository…", subtitle: "Initialize a folder as a Git repository", systemImage: "plus.square") {
                    model.createRepositoryPanel()
                }
                Spacer()
                Text("Tip: drag a folder onto this window to open it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(.background)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Repositories").font(.headline)
                    Spacer()
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                .padding()
                if recents.paths.isEmpty {
                    ContentUnavailableView("No Recent Repositories", systemImage: "clock", description: Text("Repositories you open will appear here."))
                } else {
                    List {
                        ForEach(groupedPaths, id: \.group) { group in
                            Section(group.group) {
                                ForEach(group.paths, id: \.self) { path in
                                    RecentRepositoryRow(path: path, recents: recents) {
                                        Task { await model.open(url: URL(fileURLWithPath: path)) }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RecentRepositoryRow: View {
    let path: String
    let recents: RecentRepositories
    let open: () -> Void
    @State private var groupName = ""
    @State private var isEditingGroup = false

    var body: some View {
        HStack {
            Image(systemName: FileManager.default.fileExists(atPath: path) ? "shippingbox" : "questionmark.folder")
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text((path as NSString).lastPathComponent).fontWeight(.medium)
                Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Open", action: open)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("Set Group…") { groupName = recents.groups[path] ?? ""; isEditingGroup = true }
            Divider()
            Button("Remove from Recents", role: .destructive) { recents.remove(path) }
        }
        .alert("Group Name", isPresented: $isEditingGroup) {
            TextField("Group", text: $groupName)
            Button("Save") { recents.setGroup(groupName, for: path) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct WelcomeButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(title).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
