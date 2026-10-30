import Foundation
import Observation
import AppKit

/// Observable model for a single open repository. All git operations go through here.
@MainActor
@Observable
final class Repository {
    let url: URL
    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }

    // Snapshot state
    var status = WorkingStatus()
    var operationState: RepositoryOperationState = .none
    var localBranches: [Branch] = []
    var remoteBranches: [Branch] = []
    var currentBranch: Branch?
    var tags: [Tag] = []
    var remotes: [Remote] = []
    var stashes: [Stash] = []
    var submodules: [Submodule] = []
    var unpushed: Set<String> = []
    var unpulled: Set<String> = []
    var userName = ""
    var userEmail = ""
    var signingKey = ""

    /// Increments after each successful refresh so dependent views can reload.
    var revision = 0
    /// Bumped only when branches, tags, stashes or HEAD change, so history views can skip
    /// reloading on plain working-copy edits.
    var refsRevision = 0
    private var refsSignature = 0
    var isBusy = false
    var busyMessage: String?
    var errorMessage: String?
    var infoMessage: String?
    var lastFetch: Date?
    var isCloning = false

    let undoStack = UndoStack()

    private var watcher: FileWatcher?
    private var pendingRefresh: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var autoFetchTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        watcher = FileWatcher(path: url.path) { [weak self] paths in
            Task { @MainActor [weak self] in self?.fileSystemChanged(paths) }
        }
        startAutoFetch()
    }

    // MARK: - Refresh

    private func fileSystemChanged(_ paths: [String]) {
        let relevant = paths.contains { path in
            if path.contains("/.git/") {
                // Ignore noise from transient lock files and object writes; refs/index/HEAD matter.
                if path.hasSuffix(".lock") { return false }
                if path.contains("/.git/objects/") { return false }
                return true
            }
            return true
        }
        guard relevant else { return }
        scheduleRefresh()
    }

    func scheduleRefresh(delay: Duration = .milliseconds(350)) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Reloads all repository state. If a refresh is already running (e.g. triggered by the
    /// file watcher), waits for it and then reloads again so callers never observe state
    /// captured before their own git operation finished.
    func refresh() async {
        if let inFlight = refreshTask {
            await inFlight.value
            if let newer = refreshTask, newer != inFlight {
                await newer.value
                return
            }
        }
        let task = Task<Void, Never> { @MainActor [weak self] in await self?.loadState() }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    private func loadState() async {
        Perf.log("repository refresh start")
        defer { Perf.log("repository refresh done (revision \(revision))") }
        let url = self.url
        do {
            async let statusTask = GitQueries.status(in: url)
            async let refsTask = GitQueries.refs(in: url)
            async let stashTask = GitQueries.stashes(in: url)
            async let remotesTask = GitQueries.remotes(in: url)
            async let subsTask = GitQueries.submodules(in: url)
            async let identityTask = GitQueries.userIdentity(in: url)
            async let unpushedTask = GitQueries.unpushedHashes(in: url)
            async let unpulledTask = GitQueries.unpulledHashes(in: url)

            let newStatus = try await statusTask
            let refs = try await refsTask
            let newStashes = try await stashTask
            let newRemotes = try await remotesTask
            let newSubs = try await subsTask
            let identity = await identityTask
            let newUnpushed = await unpushedTask
            let newUnpulled = await unpulledTask

            status = newStatus
            localBranches = refs.branches.filter { !$0.isRemote }
            remoteBranches = refs.branches.filter(\.isRemote)
            currentBranch = localBranches.first(where: \.isCurrent)
            tags = refs.tags
            stashes = newStashes
            remotes = newRemotes
            submodules = newSubs
            unpushed = newUnpushed
            unpulled = newUnpulled
            userName = identity.name
            userEmail = identity.email
            signingKey = identity.signingKey
            operationState = GitQueries.operationState(in: url)
            revision += 1
            var hasher = Hasher()
            hasher.combine(refs.branches); hasher.combine(refs.tags); hasher.combine(newStashes)
            hasher.combine(newStatus.branch); hasher.combine(newUnpushed); hasher.combine(newUnpulled)
            let signature = hasher.finalize()
            if signature != refsSignature { refsSignature = signature; refsRevision += 1 }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startAutoFetch() {
        autoFetchTask?.cancel()
        autoFetchTask = Task { [weak self] in
            while !Task.isCancelled {
                let settings = AppSettings.shared
                let minutes = max(1, settings.autoFetchMinutes)
                try? await Task.sleep(for: .seconds(60 * minutes))
                guard !Task.isCancelled, let self, settings.autoFetchEnabled, !self.remotes.isEmpty, !self.isBusy else { continue }
                _ = try? await self.run(["fetch", "--all", "--prune"])
                self.lastFetch = Date()
                await self.refresh()
            }
        }
    }

    // MARK: - Running commands

    @discardableResult
    nonisolated func run(_ args: [String], stdin: Data? = nil, check: Bool = true) async throws -> GitResult {
        try await GitRunner.run(args, in: url, stdin: stdin, check: check)
    }

    /// Runs a mutating operation, shows progress, surfaces errors and refreshes afterwards.
    func perform(_ title: String, refreshAfter: Bool = true, _ work: @escaping @MainActor () async throws -> Void) async {
        isBusy = true
        busyMessage = title
        defer { isBusy = false; busyMessage = nil }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
        if refreshAfter { await refresh() }
    }

    private func headHash() async -> String? {
        guard let result = try? await run(["rev-parse", "HEAD"], check: false), result.succeeded else { return nil }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func headName() async -> String? {
        // branch name, or detached hash
        if let branch = status.branch { return branch }
        return await headHash()
    }

    // MARK: - Undo

    func undo() async {
        guard let action = undoStack.popUndo() else { return }
        await perform("Undo \(action.title)") { try await action.undo() }
    }

    func redo() async {
        guard let action = undoStack.popRedo() else { return }
        await perform("Redo \(action.title)") { try await action.redo() }
    }

    // MARK: - Staging

    func stage(_ files: [FileChange]) async {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return }
        await perform("Staging") { [self] in
            try await run(["add", "-A", "--"] + paths)
            undoStack.push(UndoableAction(title: "Stage", undo: { [self] in try await unstagePaths(paths) }, redo: { [self] in try await run(["add", "-A", "--"] + paths) }))
        }
    }

    func unstage(_ files: [FileChange]) async {
        let paths = files.map(\.path) + files.compactMap(\.originalPath)
        guard !paths.isEmpty else { return }
        await perform("Unstaging") { [self] in
            try await unstagePaths(paths)
            undoStack.push(UndoableAction(title: "Unstage", undo: { [self] in try await run(["add", "-A", "--"] + paths) }, redo: { [self] in try await unstagePaths(paths) }))
        }
    }

    private func unstagePaths(_ paths: [String]) async throws {
        if status.hasHEAD {
            try await run(["reset", "-q", "HEAD", "--"] + paths)
        } else {
            try await run(["rm", "-r", "-q", "--cached", "--"] + paths, check: false)
        }
    }

    func stageAll() async {
        await perform("Staging all") { [self] in
            try await run(["add", "-A"])
            undoStack.push(UndoableAction(title: "Stage All", undo: { [self] in try await unstagePaths(["."]) }, redo: { [self] in try await run(["add", "-A"]) }))
        }
    }

    func unstageAll() async {
        await perform("Unstaging all") { [self] in
            try await unstagePaths(["."])
            undoStack.push(UndoableAction(title: "Unstage All", undo: { [self] in try await run(["add", "-A"]) }, redo: { [self] in try await unstagePaths(["."]) }))
        }
    }

    /// Discards working-copy changes. Tracked changes are saved as a patch so the action can be undone.
    func discard(_ files: [FileChange]) async {
        let tracked = files.filter { $0.kind != .untracked }.map(\.path)
        let untracked = files.filter { $0.kind == .untracked }.map(\.path)
        await perform("Discarding changes") { [self] in
            var patch = Data()
            if !tracked.isEmpty {
                patch = try await run(["diff", "--binary", "--"] + tracked).stdoutData
            }
            var untrackedContents: [(String, Data)] = []
            for path in untracked {
                let fileURL = url.appendingPathComponent(path)
                if let data = try? Data(contentsOf: fileURL) { untrackedContents.append((path, data)) }
            }
            if !tracked.isEmpty { try await run(["checkout", "--"] + tracked) }
            if !untracked.isEmpty { try await run(["clean", "-f", "-d", "--"] + untracked) }
            let repoURL = url
            undoStack.push(UndoableAction(title: "Discard", undo: { [self] in
                if !patch.isEmpty { try await run(["apply", "--whitespace=nowarn", "-"], stdin: patch) }
                for (path, data) in untrackedContents {
                    let fileURL = repoURL.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: fileURL)
                }
            }, redo: { [self] in
                if !tracked.isEmpty { try await run(["checkout", "--"] + tracked) }
                if !untracked.isEmpty { try await run(["clean", "-f", "-d", "--"] + untracked) }
            }))
        }
    }

    func applyPatch(_ patch: String, cached: Bool, reverse: Bool, title: String) async {
        var args = ["apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("--reverse") }
        args.append("-")
        let data = Data(patch.utf8)
        var inverse = ["apply", "--whitespace=nowarn"]
        if cached { inverse.append("--cached") }
        if !reverse { inverse.append("--reverse") }
        inverse.append("-")
        await perform(title) { [self] in
            try await run(args, stdin: data)
            undoStack.push(UndoableAction(title: title, undo: { [self] in try await run(inverse, stdin: data) }, redo: { [self] in try await run(args, stdin: data) }))
        }
    }

    func ignore(_ files: [FileChange]) async {
        await perform("Ignoring") { [self] in
            let ignoreURL = url.appendingPathComponent(".gitignore")
            var text = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            for file in files { text += file.path + "\n" }
            try text.write(to: ignoreURL, atomically: true, encoding: .utf8)
        }
    }

    func untrack(_ files: [FileChange]) async {
        let paths = files.map(\.path)
        await perform("Untracking") { [self] in
            try await run(["rm", "-r", "--cached", "--"] + paths)
            undoStack.push(UndoableAction(title: "Untrack", undo: { [self] in try await run(["add", "--"] + paths) }, redo: { [self] in try await run(["rm", "-r", "--cached", "--"] + paths) }))
        }
    }

    func deleteFromDisk(_ files: [FileChange]) async {
        await perform("Deleting") { [self] in
            for file in files {
                let fileURL = url.appendingPathComponent(file.path)
                try? FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            }
        }
    }

    func renameFile(_ file: FileChange, to newPath: String) async {
        await perform("Renaming") { [self] in
            if file.kind == .untracked {
                try FileManager.default.moveItem(at: url.appendingPathComponent(file.path), to: url.appendingPathComponent(newPath))
            } else {
                try await run(["mv", file.path, newPath])
            }
        }
    }

    func savePatch(of files: [FileChange], to destination: URL) async {
        await perform("Saving patch", refreshAfter: false) { [self] in
            var data = Data()
            let staged = files.filter(\.staged).map(\.path)
            let unstaged = files.filter { !$0.staged && $0.kind != .untracked }.map(\.path)
            let untracked = files.filter { $0.kind == .untracked }.map(\.path)
            if !staged.isEmpty { data += try await run(["diff", "--cached", "--binary", "--"] + staged).stdoutData }
            if !unstaged.isEmpty { data += try await run(["diff", "--binary", "--"] + unstaged).stdoutData }
            for path in untracked { data += try await run(["diff", "--binary", "--no-index", "--", "/dev/null", path], check: false).stdoutData }
            try data.write(to: destination)
        }
    }

    func applyPatchFile(_ fileURL: URL) async {
        await perform("Applying patch") { [self] in
            let data = try Data(contentsOf: fileURL)
            let isMailbox = String(decoding: data.prefix(5), as: UTF8.self) == "From "
            if isMailbox {
                try await run(["am", "--3way", fileURL.path])
            } else {
                try await run(["apply", "--whitespace=nowarn", "-"], stdin: data)
            }
        }
    }

    // MARK: - Commit

    func commit(message: String, amend: Bool, sign: Bool, skipHooks: Bool = false) async {
        await perform(amend ? "Amending" : "Committing") { [self] in
            let before = await headHash()
            var args = ["commit", "-F", "-"]
            if amend { args.append("--amend") }
            if sign { args.append("-S") }
            if skipHooks { args.append("--no-verify") }
            try await run(args, stdin: Data(message.utf8))
            let after = await headHash()
            undoStack.push(UndoableAction(title: amend ? "Amend" : "Commit", undo: { [self] in
                if amend, let before { try await run(["reset", "--soft", before]) }
                else { try await run(["reset", "--soft", "HEAD~1"]) }
            }, redo: { [self] in
                if let after { try await run(["reset", "--soft", after]) }
            }))
            infoMessage = amend ? "Commit amended" : "Committed \(after?.prefix(7) ?? "")"
        }
    }

    // MARK: - Remote operations

    func fetch(remote: String? = nil, prune: Bool = true) async {
        await perform("Fetching") { [self] in
            var args = ["fetch"]
            if let remote { args.append(remote) } else { args.append("--all") }
            if prune { args.append("--prune") }
            args.append("--tags")
            try await run(args)
            lastFetch = Date()
        }
    }

    func pull(rebase: Bool = false) async {
        await perform("Pulling") { [self] in
            let before = await headHash()
            var args = ["pull"]
            if rebase { args.append("--rebase") }
            try await run(args)
            let after = await headHash()
            if let before, let after, before != after {
                undoStack.push(UndoableAction(title: "Pull", undo: { [self] in try await run(["reset", "--hard", before]) }, redo: { [self] in try await run(["reset", "--hard", after]) }))
            }
        }
    }

    func push(force: Bool = false, setUpstream: Bool = false, remote: String? = nil, tags: Bool = false) async {
        await perform("Pushing") { [self] in
            var args = ["push"]
            if force { args.append("--force-with-lease") }
            if tags { args.append("--tags") }
            if setUpstream, let branch = status.branch {
                args.append(contentsOf: ["-u", remote ?? remotes.first?.name ?? "origin", branch])
            } else if let remote {
                args.append(remote)
            }
            try await run(args)
            infoMessage = "Pushed"
        }
    }

    func pushBranch(_ branch: Branch, to remote: String, force: Bool = false) async {
        await perform("Pushing \(branch.name)") { [self] in
            var args = ["push", "-u"]
            if force { args.append("--force-with-lease") }
            args.append(contentsOf: [remote, "\(branch.name):\(branch.name)"])
            try await run(args)
        }
    }

    func sync() async {
        await perform("Syncing") { [self] in
            try await run(["pull"])
            if status.upstream == nil, let branch = status.branch {
                try await run(["push", "-u", remotes.first?.name ?? "origin", branch])
            } else {
                try await run(["push"])
            }
        }
    }

    // MARK: - Branches

    func checkout(_ ref: String, createTracking: Bool = false) async {
        await perform("Checking out \(ref)") { [self] in
            let previous = await headName()
            if createTracking {
                let local = ref.split(separator: "/", maxSplits: 1).last.map(String.init) ?? ref
                if localBranches.contains(where: { $0.name == local }) {
                    try await run(["checkout", local])
                } else {
                    try await run(["checkout", "-b", local, "--track", ref])
                }
            } else {
                try await run(["checkout", ref])
            }
            if let previous {
                undoStack.push(UndoableAction(title: "Checkout", undo: { [self] in try await run(["checkout", previous]) }, redo: { [self] in try await run(["checkout", ref]) }))
            }
        }
    }

    func createBranch(_ name: String, from start: String?, checkout: Bool) async {
        await perform("Creating branch \(name)") { [self] in
            var args = checkout ? ["checkout", "-b", name] : ["branch", name]
            if let start { args.append(start) }
            let previous = await headName()
            try await run(args)
            let hash = await headHash()
            undoStack.push(UndoableAction(title: "Create Branch", undo: { [self] in
                if checkout, let previous { try await run(["checkout", previous]) }
                try await run(["branch", "-D", name])
            }, redo: { [self] in
                var a = checkout ? ["checkout", "-b", name] : ["branch", name]
                if let start { a.append(start) } else if let hash { a.append(hash) }
                try await run(a)
            }))
        }
    }

    func deleteBranch(_ branch: Branch, force: Bool = false) async {
        await perform("Deleting \(branch.name)") { [self] in
            if branch.isRemote {
                guard let remote = branch.remoteName else { return }
                try await run(["push", remote, "--delete", branch.nameWithoutRemote])
            } else {
                let hash = try await run(["rev-parse", branch.fullRef]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let upstream = branch.upstream
                try await run(["branch", force ? "-D" : "-d", branch.name])
                undoStack.push(UndoableAction(title: "Delete Branch", undo: { [self] in
                    try await run(["branch", branch.name, hash])
                    if let upstream { try? await run(["branch", "--set-upstream-to=\(upstream)", branch.name]) }
                }, redo: { [self] in try await run(["branch", "-D", branch.name]) }))
            }
        }
    }

    func renameBranch(_ branch: Branch, to newName: String) async {
        await perform("Renaming branch") { [self] in
            try await run(["branch", "-m", branch.name, newName])
            undoStack.push(UndoableAction(title: "Rename Branch", undo: { [self] in try await run(["branch", "-m", newName, branch.name]) }, redo: { [self] in try await run(["branch", "-m", branch.name, newName]) }))
        }
    }

    func setUpstream(_ branch: Branch, to upstream: String?) async {
        await perform("Setting tracking") { [self] in
            if let upstream { try await run(["branch", "--set-upstream-to=\(upstream)", branch.name]) }
            else { try await run(["branch", "--unset-upstream", branch.name]) }
        }
    }

    func merge(_ ref: String, noFastForward: Bool = false, squash: Bool = false) async {
        await perform("Merging \(ref)") { [self] in
            let before = await headHash()
            var args = ["merge"]
            if noFastForward { args.append("--no-ff") }
            if squash { args.append("--squash") }
            args.append(ref)
            let result = try await run(args, check: false)
            if !result.succeeded {
                if result.stdout.contains("CONFLICT") || result.stderr.contains("CONFLICT") || result.stdout.contains("Automatic merge failed") {
                    infoMessage = "Merge has conflicts. Resolve them in the Working Copy."
                } else {
                    throw GitError(command: "merge", message: result.stderr + result.stdout, exitCode: result.exitCode)
                }
            }
            let after = await headHash()
            if let before, let after, before != after {
                undoStack.push(UndoableAction(title: "Merge", undo: { [self] in try await run(["reset", "--hard", before]) }, redo: { [self] in try await run(["reset", "--hard", after]) }))
            }
        }
    }

    func rebase(onto ref: String) async {
        await perform("Rebasing onto \(ref)") { [self] in
            let before = await headHash()
            let result = try await run(["rebase", ref], check: false)
            if !result.succeeded {
                if result.stdout.contains("CONFLICT") || result.stderr.contains("CONFLICT") || result.stderr.contains("could not apply") {
                    infoMessage = "Rebase stopped with conflicts. Resolve them in the Working Copy."
                    return
                }
                throw GitError(command: "rebase", message: result.stderr + result.stdout, exitCode: result.exitCode)
            }
            let after = await headHash()
            if let before, let after, before != after {
                undoStack.push(UndoableAction(title: "Rebase", undo: { [self] in try await run(["reset", "--hard", before]) }, redo: { [self] in try await run(["reset", "--hard", after]) }))
            }
        }
    }

    /// Runs `git rebase -i` non-interactively with a prepared todo list.
    func interactiveRebase(onto base: String, todo: String) async {
        await perform("Rebasing interactively") { [self] in
            let before = await headHash()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitter-rebase-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let todoURL = dir.appendingPathComponent("todo")
            try todo.write(to: todoURL, atomically: true, encoding: .utf8)
            let editorURL = dir.appendingPathComponent("sequence-editor.sh")
            try "#!/bin/sh\ncp \"\(todoURL.path)\" \"$1\"\n".write(to: editorURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editorURL.path)
            let result = try await run(["-c", "sequence.editor=\(editorURL.path)", "-c", "core.editor=true", "rebase", "-i", base], check: false)
            try? FileManager.default.removeItem(at: dir)
            if !result.succeeded {
                if result.stdout.contains("CONFLICT") || result.stderr.contains("CONFLICT") || result.stderr.contains("could not apply") {
                    infoMessage = "Rebase stopped with conflicts. Resolve them in the Working Copy."
                    return
                }
                throw GitError(command: "rebase -i", message: result.stderr + result.stdout, exitCode: result.exitCode)
            }
            let after = await headHash()
            if let before, let after, before != after {
                undoStack.push(UndoableAction(title: "Interactive Rebase", undo: { [self] in try await run(["reset", "--hard", before]) }, redo: { [self] in try await run(["reset", "--hard", after]) }))
            }
        }
    }

    func continueOperation() async {
        await perform("Continuing") { [self] in
            switch operationState {
            case .rebasing: try await run(["-c", "core.editor=true", "rebase", "--continue"])
            case .merging: try await run(["-c", "core.editor=true", "commit", "--no-edit"])
            case .cherryPicking: try await run(["-c", "core.editor=true", "cherry-pick", "--continue"])
            case .reverting: try await run(["-c", "core.editor=true", "revert", "--continue"])
            default: break
            }
        }
    }

    func abortOperation() async {
        await perform("Aborting") { [self] in
            switch operationState {
            case .rebasing: try await run(["rebase", "--abort"])
            case .merging: try await run(["merge", "--abort"])
            case .cherryPicking: try await run(["cherry-pick", "--abort"])
            case .reverting: try await run(["revert", "--abort"])
            case .bisecting: try await run(["bisect", "reset"])
            default: break
            }
        }
    }

    func resolveConflict(_ file: FileChange, using side: String) async {
        await perform("Resolving") { [self] in
            try await run(["checkout", side, "--", file.path])
            try await run(["add", "--", file.path])
        }
    }

    func markResolved(_ file: FileChange) async {
        await perform("Marking resolved") { [self] in try await run(["add", "--", file.path]) }
    }

    func openMergeTool(_ file: FileChange) async {
        await perform("Opening merge tool", refreshAfter: true) { [self] in
            try await run(["mergetool", "--no-prompt", "--", file.path])
        }
    }

    // MARK: - Commits

    func cherryPick(_ hash: String) async {
        await perform("Cherry-picking") { [self] in
            let before = await headHash()
            let result = try await run(["cherry-pick", hash], check: false)
            if !result.succeeded {
                if result.stdout.contains("CONFLICT") || result.stderr.contains("CONFLICT") { infoMessage = "Cherry-pick has conflicts."; return }
                throw GitError(command: "cherry-pick", message: result.stderr, exitCode: result.exitCode)
            }
            let after = await headHash()
            if let before, let after {
                undoStack.push(UndoableAction(title: "Cherry-pick", undo: { [self] in try await run(["reset", "--hard", before]) }, redo: { [self] in try await run(["reset", "--hard", after]) }))
            }
        }
    }

    func revert(_ hash: String) async {
        await perform("Reverting") { [self] in
            let before = await headHash()
            let result = try await run(["revert", "--no-edit", hash], check: false)
            if !result.succeeded {
                if result.stdout.contains("CONFLICT") || result.stderr.contains("CONFLICT") { infoMessage = "Revert has conflicts."; return }
                throw GitError(command: "revert", message: result.stderr, exitCode: result.exitCode)
            }
            let after = await headHash()
            if let before, let after {
                undoStack.push(UndoableAction(title: "Revert", undo: { [self] in try await run(["reset", "--hard", before]) }, redo: { [self] in try await run(["reset", "--hard", after]) }))
            }
        }
    }

    func reset(to hash: String, mode: String) async {
        await perform("Resetting") { [self] in
            let before = await headHash()
            try await run(["reset", "--\(mode)", hash])
            if let before {
                undoStack.push(UndoableAction(title: "Reset", undo: { [self] in try await run(["reset", "--\(mode == "hard" ? "hard" : "soft")", before]) }, redo: { [self] in try await run(["reset", "--\(mode)", hash]) }))
            }
        }
    }

    func createTag(_ name: String, at ref: String?, message: String?) async {
        await perform("Creating tag") { [self] in
            var args = ["tag"]
            if let message, !message.isEmpty { args.append(contentsOf: ["-a", name, "-m", message]) } else { args.append(name) }
            if let ref { args.append(ref) }
            try await run(args)
            undoStack.push(UndoableAction(title: "Create Tag", undo: { [self] in try await run(["tag", "-d", name]) }, redo: { [self] in try await run(args) }))
        }
    }

    func deleteTag(_ tag: Tag, onRemote remote: String? = nil) async {
        await perform("Deleting tag") { [self] in
            if let remote {
                try await run(["push", remote, "--delete", "refs/tags/\(tag.name)"])
            } else {
                let hash = try await run(["rev-parse", tag.fullRef]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                try await run(["tag", "-d", tag.name])
                undoStack.push(UndoableAction(title: "Delete Tag", undo: { [self] in try await run(["tag", tag.name, hash]) }, redo: { [self] in try await run(["tag", "-d", tag.name]) }))
            }
        }
    }

    func pushTag(_ tag: Tag, to remote: String) async {
        await perform("Pushing tag") { [self] in try await run(["push", remote, "refs/tags/\(tag.name)"]) }
    }

    func exportArchive(ref: String, to destination: URL) async {
        await perform("Exporting", refreshAfter: false) { [self] in
            try await run(["archive", "--format=zip", "-o", destination.path, ref])
        }
    }

    func saveCommitPatch(_ hash: String, to destination: URL) async {
        await perform("Saving patch", refreshAfter: false) { [self] in
            try await run(["format-patch", "-1", hash, "--output=\(destination.path)"])
        }
    }

    func applyCommittedFile(_ hash: String, path: String) async {
        await perform("Applying file changes") { [self] in
            let patch = try await run(["show", "--format=", "--binary", hash, "--", path]).stdoutData
            try await run(["apply", "--3way", "--whitespace=nowarn", "-"], stdin: patch)
        }
    }

    // MARK: - Remotes

    func addRemote(name: String, url remoteURL: String) async {
        await perform("Adding remote") { [self] in
            try await run(["remote", "add", name, remoteURL])
            _ = try? await run(["fetch", name], check: false)
        }
    }

    func removeRemote(_ remote: Remote) async {
        await perform("Removing remote") { [self] in
            try await run(["remote", "remove", remote.name])
            undoStack.push(UndoableAction(title: "Remove Remote", undo: { [self] in try await run(["remote", "add", remote.name, remote.fetchURL]) }, redo: { [self] in try await run(["remote", "remove", remote.name]) }))
        }
    }

    func renameRemote(_ remote: Remote, to newName: String) async {
        await perform("Renaming remote") { [self] in try await run(["remote", "rename", remote.name, newName]) }
    }

    func setRemoteURL(_ remote: Remote, url newURL: String) async {
        await perform("Updating remote") { [self] in try await run(["remote", "set-url", remote.name, newURL]) }
    }

    // MARK: - Stashes

    func stash(message: String, includeUntracked: Bool, keepIndex: Bool, paths: [String] = []) async {
        await perform("Stashing") { [self] in
            var args = ["stash", "push"]
            if includeUntracked { args.append("--include-untracked") }
            if keepIndex { args.append("--keep-index") }
            if !message.isEmpty { args.append(contentsOf: ["-m", message]) }
            if !paths.isEmpty { args.append("--"); args.append(contentsOf: paths) }
            try await run(args)
            if let hash = try? await run(["rev-parse", "refs/stash"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
                undoStack.push(UndoableAction(title: "Stash", undo: { [self] in
                    try await run(["stash", "pop", hash])
                }, redo: { [self] in try await run(args) }))
            }
        }
    }

    func applyStash(_ stash: Stash, pop: Bool) async {
        await perform(pop ? "Popping stash" : "Applying stash") { [self] in
            let result = try await run(["stash", pop ? "pop" : "apply", stash.ref], check: false)
            if !result.succeeded {
                if result.stdout.contains("CONFLICT") || result.stderr.contains("CONFLICT") { infoMessage = "Stash applied with conflicts."; return }
                throw GitError(command: "stash", message: result.stderr, exitCode: result.exitCode)
            }
            let hash = stash.hash
            let message = stash.message
            undoStack.push(UndoableAction(title: pop ? "Pop Stash" : "Apply Stash", undo: { [self] in
                let patch = try await run(["diff", "--binary", "\(hash)^1", hash]).stdoutData
                try await run(["apply", "--reverse", "--whitespace=nowarn", "-"], stdin: patch)
                if pop { try await run(["stash", "store", "-m", message, hash]) }
            }, redo: { [self] in try await run(["stash", "apply", hash]) }))
        }
    }

    func applyStashFile(_ stash: Stash, path: String) async {
        await perform("Applying stashed file") { [self] in
            try await run(["checkout", stash.hash, "--", path])
            try? await run(["reset", "-q", "HEAD", "--", path], check: false)
        }
    }

    func dropStash(_ stash: Stash) async {
        await perform("Dropping stash") { [self] in
            try await run(["stash", "drop", stash.ref])
            let hash = stash.hash
            let message = stash.message
            undoStack.push(UndoableAction(title: "Drop Stash", undo: { [self] in try await run(["stash", "store", "-m", message, hash]) }, redo: { [self] in
                if let idx = try? await run(["stash", "list", "--format=%gd %H"]).stdout.split(separator: "\n").first(where: { $0.hasSuffix(hash) })?.split(separator: " ").first {
                    try await run(["stash", "drop", String(idx)])
                }
            }))
        }
    }

    // MARK: - Submodules

    func updateSubmodules(initialize: Bool) async {
        await perform("Updating submodules") { [self] in
            var args = ["submodule", "update", "--recursive"]
            if initialize { args.append("--init") }
            try await run(args)
        }
    }

    func addSubmodule(url remoteURL: String, path: String) async {
        await perform("Adding submodule") { [self] in try await run(["submodule", "add", remoteURL, path]) }
    }

    // MARK: - Identity

    func applyProfile(_ profile: UserProfile) async {
        await perform("Switching profile") { [self] in
            try await run(["config", "user.name", profile.name])
            try await run(["config", "user.email", profile.email])
            if profile.signingKey.isEmpty {
                _ = try? await run(["config", "--unset", "user.signingkey"], check: false)
            } else {
                try await run(["config", "user.signingkey", profile.signingKey])
            }
        }
    }

    // MARK: - External tools

    func openExternalDiff(for file: FileChange) async {
        await perform("Opening diff tool", refreshAfter: false) { [self] in
            var args = ["difftool", "--no-prompt"]
            let tool = AppSettings.shared.externalDiffTool
            if !tool.isEmpty { args.append("--tool=\(tool)") }
            if file.staged { args.append("--cached") }
            args.append(contentsOf: ["--", file.path])
            try await run(args)
        }
    }

    func revealInFinder(_ path: String?) {
        let target = path.map { url.appendingPathComponent($0) } ?? url
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openInTerminal() {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"cd \" & quoted form of \"\(url.path)\"\nend tell"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    func openInEditor(_ path: String) {
        NSWorkspace.shared.open(url.appendingPathComponent(path))
    }
}
