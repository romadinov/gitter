import SwiftUI
import AppKit

@main
struct GitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(initialURL: nil)
                .frame(minWidth: 960, minHeight: 600)
        }
        WindowGroup(id: "repo", for: URL.self) { $url in
            ContentView(initialURL: url)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 860)
        .commands { GitterCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Debug aid: GITTER_SNAPSHOT=/path/file.png renders the main window to a PNG a few seconds after launch.
        if let path = ProcessInfo.processInfo.environment["GITTER_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["GITTER_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.snapshotMainWindow(to: path)
            }
        }
    }

    static func snapshotMainWindow(to path: String) {
        FileHandle.standardError.write(Data("snapshot: \(NSApp.windows.count) windows, visible: \(NSApp.windows.filter(\.isVisible).count)\n".utf8))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) ?? NSApp.windows.first, let view = window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            do { try data.write(to: URL(fileURLWithPath: path)); FileHandle.standardError.write(Data("snapshot written \(view.bounds)\n".utf8)) }
            catch { FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8)) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct GitterCommands: Commands {
    @FocusedValue(\.windowModel) private var model
    @Environment(\.openWindow) private var openWindow

    private var repo: Repository? { model?.repository }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n")
            Divider()
            Button("Open Repository…") { model?.openRepositoryPanel() }
                .keyboardShortcut("o")
            Button("Clone Repository…") { model?.showClone = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Create New Repository…") { model?.createRepositoryPanel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu("Open Recent") {
                ForEach(RecentRepositories.shared.paths, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) {
                        Task { await model?.open(url: URL(fileURLWithPath: path)) }
                    }
                }
            }
            Divider()
            Button("Close Repository") { model?.close() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(repo == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(repo?.undoStack.undoTitle.map { "Undo \($0)" } ?? "Undo") { Task { await repo?.undo() } }
                .keyboardShortcut("z")
                .disabled(repo?.undoStack.canUndo != true)
            Button(repo?.undoStack.redoTitle.map { "Redo \($0)" } ?? "Redo") { Task { await repo?.redo() } }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(repo?.undoStack.canRedo != true)
        }

        CommandMenu("Repository") {
            Button("Quick Actions…") { model?.showQuickActions = true }
                .keyboardShortcut("k")
                .disabled(repo == nil)
            Divider()
            Button("Fetch") { Task { await repo?.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(repo == nil)
            Button("Pull") { Task { await repo?.pull() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(repo == nil)
            Button("Pull with Rebase") { Task { await repo?.pull(rebase: true) } }
                .disabled(repo == nil)
            Button("Push") { Task { await repo?.push(setUpstream: repo?.status.upstream == nil) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(repo == nil)
            Button("Force Push with Lease") { Task { await repo?.push(force: true) } }
                .disabled(repo == nil)
            Button("Sync (Pull then Push)") { Task { await repo?.sync() } }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(repo == nil)
            Divider()
            Button("New Branch…") { model?.newBranchStart = nil; model?.showNewBranch = true }
                .keyboardShortcut("b")
                .disabled(repo == nil)
            Button("New Tag…") { model?.newTagRef = nil; model?.showNewTag = true }
                .disabled(repo == nil)
            Button("Add Remote…") { model?.showNewRemote = true }
                .disabled(repo == nil)
            Button("Compare Branches…") { model?.routes.append(.compare(base: repo?.remoteBranches.first(where: { $0.name.hasSuffix("/main") || $0.name.hasSuffix("/master") })?.name ?? "HEAD", target: repo?.status.branch ?? "HEAD")) }
                .disabled(repo == nil)
            Button("Interactive Rebase…") { model?.interactiveRebaseBase = nil; model?.showInteractiveRebase = true }
                .disabled(repo == nil)
            Divider()
            Button("Stash Changes…") { model?.stashPaths = []; model?.showStash = true }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(repo == nil)
            Button("Apply Patch…") { model?.showApplyPatch = true }
                .disabled(repo == nil)
            Divider()
            Button("Refresh") { Task { await repo?.refresh() } }
                .keyboardShortcut("r")
                .disabled(repo == nil)
            Button("Reveal in Finder") { repo?.revealInFinder(nil) }
                .disabled(repo == nil)
            Button("Open in Terminal") { repo?.openInTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(repo == nil)
        }

        CommandMenu("View") {
            Button("Working Copy") { model?.selection = .workingCopy; model?.routes = [] }
                .keyboardShortcut("1")
                .disabled(repo == nil)
            Button("History") { model?.selection = .history; model?.routes = [] }
                .keyboardShortcut("2")
                .disabled(repo == nil)
            Button("Stashes") { model?.selection = .stashes; model?.routes = [] }
                .keyboardShortcut("3")
                .disabled(repo == nil)
            Button("Branches Review") { model?.selection = .branchesReview; model?.routes = [] }
                .keyboardShortcut("4")
                .disabled(repo == nil)
            Button("Reflog") { model?.selection = .reflog; model?.routes = [] }
                .keyboardShortcut("5")
                .disabled(repo == nil)
            Button("Submodules") { model?.selection = .submodules; model?.routes = [] }
                .keyboardShortcut("6")
                .disabled(repo == nil)
            Button("Repository Settings") { model?.selection = .settings; model?.routes = [] }
                .keyboardShortcut("7")
                .disabled(repo == nil)
            Divider()
            Button("Repositories…") { model?.showRepositoryList.toggle() }
                .keyboardShortcut("0")
        }
    }
}
