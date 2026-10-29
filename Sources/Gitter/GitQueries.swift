import Foundation

/// Read-only git queries with output parsing. All functions are nonisolated and safe to run concurrently.
enum GitQueries {
    private static let unit = "\u{1f}"
    private static let record = "\u{1e}"

    // MARK: Status

    static func status(in url: URL) async throws -> WorkingStatus {
        let result = try await GitRunner.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], in: url)
        return parseStatus(result.stdoutData)
    }

    static func parseStatus(_ data: Data) -> WorkingStatus {
        var status = WorkingStatus()
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < tokens.count {
            let line = tokens[i]
            i += 1
            if line.isEmpty { continue }
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": status.oid = parts[1]
                case "branch.head":
                    if parts[1] == "(detached)" { status.detached = true } else { status.branch = parts[1] }
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    let ab = parts[1].split(separator: " ")
                    if ab.count == 2 {
                        status.ahead = Int(ab[0].dropFirst()) ?? 0
                        status.behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
                continue
            }
            if line.hasPrefix("1 ") {
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 9 else { continue }
                appendOrdinary(xy: parts[1], path: parts[8], original: nil, into: &status)
            } else if line.hasPrefix("2 ") {
                let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 10 else { continue }
                let original = i < tokens.count ? tokens[i] : nil
                i += 1
                appendOrdinary(xy: parts[1], path: parts[9], original: original, into: &status)
            } else if line.hasPrefix("u ") {
                let parts = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 11 else { continue }
                status.unstaged.append(FileChange(path: parts[10], originalPath: nil, kind: .unmerged, staged: false))
            } else if line.hasPrefix("? ") {
                status.unstaged.append(FileChange(path: String(line.dropFirst(2)), originalPath: nil, kind: .untracked, staged: false))
            }
        }
        status.staged.sort { $0.path < $1.path }
        status.unstaged.sort { $0.path < $1.path }
        return status
    }

    private static func appendOrdinary(xy: String, path: String, original: String?, into status: inout WorkingStatus) {
        let chars = Array(xy)
        guard chars.count == 2 else { return }
        if chars[0] != "." {
            status.staged.append(FileChange(path: path, originalPath: original, kind: FileStatusKind(code: chars[0]), staged: true))
        }
        if chars[1] != "." {
            status.unstaged.append(FileChange(path: path, originalPath: nil, kind: FileStatusKind(code: chars[1]), staged: false))
        }
    }

    static func operationState(in url: URL) -> RepositoryOperationState {
        let gitDir = url.appendingPathComponent(".git")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var dir = gitDir
        if fm.fileExists(atPath: gitDir.path, isDirectory: &isDir), !isDir.boolValue,
           let content = try? String(contentsOf: gitDir, encoding: .utf8),
           content.hasPrefix("gitdir: ") {
            let p = content.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            dir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : url.appendingPathComponent(p)
        }
        if fm.fileExists(atPath: dir.appendingPathComponent("rebase-merge").path) || fm.fileExists(atPath: dir.appendingPathComponent("rebase-apply").path) { return .rebasing }
        if fm.fileExists(atPath: dir.appendingPathComponent("MERGE_HEAD").path) { return .merging }
        if fm.fileExists(atPath: dir.appendingPathComponent("CHERRY_PICK_HEAD").path) { return .cherryPicking }
        if fm.fileExists(atPath: dir.appendingPathComponent("REVERT_HEAD").path) { return .reverting }
        if fm.fileExists(atPath: dir.appendingPathComponent("BISECT_LOG").path) { return .bisecting }
        return .none
    }

    // MARK: Refs

    static func refs(in url: URL) async throws -> (branches: [Branch], tags: [Tag]) {
        let format = ["%(refname)", "%(refname:short)", "%(objectname:short)", "%(upstream:short)", "%(upstream:track)", "%(HEAD)", "%(creatordate:unix)", "%(subject)"].joined(separator: "%1f")
        let result = try await GitRunner.run(["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes", "refs/tags"], in: url)
        var branches: [Branch] = []
        var tags: [Tag] = []
        for line in result.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: unit)
            guard f.count == 8 else { continue }
            let full = f[0]
            let date = Date(timeIntervalSince1970: TimeInterval(f[6]) ?? 0)
            if full.hasPrefix("refs/tags/") {
                tags.append(Tag(name: String(full.dropFirst("refs/tags/".count)), shortHash: f[2], date: date, subject: f[7]))
                continue
            }
            let isRemote = full.hasPrefix("refs/remotes/")
            if isRemote && full.hasSuffix("/HEAD") { continue }
            let name = isRemote ? String(full.dropFirst("refs/remotes/".count)) : String(full.dropFirst("refs/heads/".count))
            let track = f[4]
            branches.append(Branch(
                fullRef: full,
                name: name,
                shortHash: f[2],
                isRemote: isRemote,
                isCurrent: f[5] == "*",
                upstream: f[3].isEmpty ? nil : f[3],
                upstreamGone: track.contains("gone"),
                ahead: captureInt(after: "ahead ", in: track),
                behind: captureInt(after: "behind ", in: track),
                date: date,
                subject: f[7]
            ))
        }
        return (branches, tags.sorted { $0.date > $1.date })
    }

    private static func captureInt(after prefix: String, in text: String) -> Int {
        guard let range = text.range(of: prefix) else { return 0 }
        let rest = text[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    static func remotes(in url: URL) async throws -> [Remote] {
        let result = try await GitRunner.run(["remote", "-v"], in: url)
        var map: [String: (fetch: String, push: String)] = [:]
        var order: [String] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0]
            let urlAndKind = parts[1].components(separatedBy: " (")
            let remoteURL = urlAndKind[0]
            let kind = urlAndKind.count > 1 ? urlAndKind[1].replacingOccurrences(of: ")", with: "") : "fetch"
            if map[name] == nil { order.append(name); map[name] = ("", "") }
            if kind == "fetch" { map[name]?.fetch = remoteURL } else { map[name]?.push = remoteURL }
        }
        return order.map { Remote(name: $0, fetchURL: map[$0]?.fetch ?? "", pushURL: map[$0]?.push ?? "") }
    }

    static func stashes(in url: URL) async throws -> [Stash] {
        let result = try await GitRunner.run(["stash", "list", "--format=%gd%x1f%H%x1f%gs%x1f%at"], in: url)
        var stashes: [Stash] = []
        for line in result.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: unit)
            guard f.count == 4 else { continue }
            let index = Int(f[0].replacingOccurrences(of: "stash@{", with: "").replacingOccurrences(of: "}", with: "")) ?? stashes.count
            stashes.append(Stash(index: index, hash: f[1], message: f[2], date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0)))
        }
        return stashes
    }

    static func submodules(in url: URL) async throws -> [Submodule] {
        let result = try await GitRunner.run(["submodule", "status"], in: url, check: false)
        var subs: [Submodule] = []
        for line in result.stdout.split(separator: "\n") {
            guard let state = line.first else { continue }
            let rest = line.dropFirst().split(separator: " ", maxSplits: 2).map(String.init)
            guard rest.count >= 2 else { continue }
            let describe = rest.count > 2 ? rest[2].trimmingCharacters(in: CharacterSet(charactersIn: "()")) : ""
            subs.append(Submodule(path: rest[1], hash: rest[0], describe: describe, state: state))
        }
        return subs
    }

    static func userIdentity(in url: URL) async -> (name: String, email: String, signingKey: String) {
        async let n = GitRunner.run(["config", "user.name"], in: url, check: false)
        async let e = GitRunner.run(["config", "user.email"], in: url, check: false)
        async let k = GitRunner.run(["config", "user.signingkey"], in: url, check: false)
        let name = (try? await n.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let email = (try? await e.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let key = (try? await k.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        return (name, email, key)
    }

    // MARK: Log

    static let logFormat = "--format=%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%P%x1f%D%x1f%s%x1e"

    struct LogQuery: Hashable, Sendable {
        var ref: String?          // nil = --all
        var path: String?
        var search: String = ""
        var limit: Int = 1500
        var firstParent = false
        var topoOrder = false
        var range: String?        // e.g. "main..feature"
        var since: Date?
        var until: Date?
        var author: String = ""
    }

    static func log(_ query: LogQuery, in url: URL) async throws -> [Commit] {
        var args = ["log", query.topoOrder ? "--topo-order" : "--date-order", logFormat, "-n", "\(query.limit)"]
        if query.firstParent { args.append("--first-parent") }
        let dateFilters: [String] = (query.since.map { ["--since=\(Int($0.timeIntervalSince1970))"] } ?? []) + (query.until.map { ["--until=\(Int($0.timeIntervalSince1970))"] } ?? []) + (query.author.isEmpty ? [] : ["--author=\(query.author)", "-i"])
        args.append(contentsOf: dateFilters)
        if let range = query.range {
            args.append(range)
        } else if let ref = query.ref {
            args.append(ref)
        } else {
            args.append(contentsOf: ["--branches", "--remotes", "--tags"])
        }
        let term = query.search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            if term.count >= 7, term.allSatisfy(\.isHexDigit) {
                args.append(contentsOf: ["--grep=\(term)", "--all-match"])
                // also match by hash prefix below
            }
            args.append(contentsOf: ["-i", "--grep=\(term)", "--author=\(term)", "--regexp-ignore-case"])
            // git ORs --grep and --author only with --all-match absent; we want OR semantics: emulate with two queries.
            args.removeAll { $0 == "--all-match" || $0 == "--author=\(term)" }
        }
        if let path = query.path {
            args.append("--follow")
            args.append("--")
            args.append(path)
        }
        let result = try await GitRunner.run(args, in: url, check: false)
        if !result.succeeded {
            if result.stderr.contains("does not have any commits") || result.stderr.contains("bad default revision") { return [] }
            throw GitError(command: args.joined(separator: " "), message: result.stderr, exitCode: result.exitCode)
        }
        var commits = parseLog(result.stdout)
        if !term.isEmpty {
            // Author search (OR'd with the message search above).
            var authorArgs = ["log", "--date-order", logFormat, "-n", "\(query.limit)", "-i", "--author=\(term)"] + dateFilters
            if let range = query.range { authorArgs.append(range) } else if let ref = query.ref { authorArgs.append(ref) } else { authorArgs.append(contentsOf: ["--branches", "--remotes", "--tags"]) }
            if let path = query.path { authorArgs.append(contentsOf: ["--", path]) }
            if let authorResult = try? await GitRunner.run(authorArgs, in: url, check: false), authorResult.succeeded {
                let existing = Set(commits.map(\.hash))
                commits += parseLog(authorResult.stdout).filter { !existing.contains($0.hash) }
            }
            if term.count >= 4, term.allSatisfy(\.isHexDigit), !commits.contains(where: { $0.hash.hasPrefix(term.lowercased()) }) {
                if let byHash = try? await GitRunner.run(["log", logFormat, "-n", "1", term], in: url, check: false), byHash.succeeded {
                    commits += parseLog(byHash.stdout)
                }
            }
            commits.sort { $0.date > $1.date }
        }
        return commits
    }

    static func parseLog(_ output: String) -> [Commit] {
        var commits: [Commit] = []
        for rec in output.components(separatedBy: record) {
            let trimmed = rec.trimmingCharacters(in: .newlines)
            if trimmed.isEmpty { continue }
            let f = trimmed.components(separatedBy: unit)
            guard f.count >= 8 else { continue }
            let refs = parseRefs(f[6])
            commits.append(Commit(
                hash: f[0], shortHash: f[1], author: f[2], email: f[3],
                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                parents: f[5].split(separator: " ").map(String.init),
                refs: refs,
                subject: f[7...].joined(separator: unit)
            ))
        }
        return commits
    }

    private static func parseRefs(_ text: String) -> [CommitRef] {
        guard !text.isEmpty else { return [] }
        var refs: [CommitRef] = []
        for part in text.components(separatedBy: ", ") {
            var name = part
            var isHeadTarget = false
            if name.hasPrefix("HEAD -> ") {
                name = String(name.dropFirst(8))
                isHeadTarget = true
            }
            if name == "HEAD" { refs.append(CommitRef(name: "HEAD", kind: .head, isHEADTarget: true)); continue }
            if name.hasPrefix("tag: ") { refs.append(CommitRef(name: String(name.dropFirst(5)), kind: .tag, isHEADTarget: false)); continue }
            if name.hasPrefix("refs/stash") || name == "stash" { refs.append(CommitRef(name: "stash", kind: .stash, isHEADTarget: false)); continue }
            let kind: CommitRef.Kind = name.contains("/") ? .remote : .local
            refs.append(CommitRef(name: name, kind: kind, isHEADTarget: isHeadTarget))
        }
        return refs
    }

    // MARK: Commit detail

    static func commitDetail(_ hash: String, in url: URL) async throws -> CommitDetail {
        let format = "%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%P%x1f%D%x1f%s%x1f%cn%x1f%ct%x1f%G?%x1f%B"
        let result = try await GitRunner.run(["show", "-s", "--format=\(format)", hash], in: url)
        let f = result.stdout.components(separatedBy: unit)
        guard f.count >= 12 else { throw GitError(command: "show", message: "Unexpected output", exitCode: 1) }
        let commit = parseLog(f[0...7].joined(separator: unit) + record).first!
        var body = f[11...].joined(separator: unit).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix(commit.subject) {
            body = String(body.dropFirst(commit.subject.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let files = try await changedFiles(hash, parents: commit.parents, in: url)
        let sig = f[10]
        let signature: String? = switch sig {
        case "G": "Good signature"
        case "B": "Bad signature"
        case "U": "Good signature, unknown validity"
        case "X", "Y": "Expired signature"
        case "R": "Revoked key"
        case "E": "Signature cannot be checked"
        default: nil
        }
        return CommitDetail(commit: commit, body: body, committer: f[8], committerDate: Date(timeIntervalSince1970: TimeInterval(f[9]) ?? 0), files: files, signature: signature)
    }

    static func changedFiles(_ hash: String, parents: [String], in url: URL) async throws -> [FileChange] {
        let args: [String]
        if let parent = parents.first {
            args = ["diff", "--name-status", "-z", "-M", parent, hash]
        } else {
            args = ["show", "--format=", "--name-status", "-z", "-M", "--root", hash]
        }
        let result = try await GitRunner.run(args, in: url)
        return parseNameStatus(result.stdoutData)
    }

    static func parseNameStatus(_ data: Data) -> [FileChange] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var files: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let first = code.first, i < tokens.count else { continue }
            let kind = FileStatusKind(code: first)
            if kind == .renamed || kind == .copied {
                let original = tokens[i]; i += 1
                guard i < tokens.count else { break }
                let path = tokens[i]; i += 1
                files.append(FileChange(path: path, originalPath: original, kind: kind, staged: true))
            } else {
                let path = tokens[i]; i += 1
                files.append(FileChange(path: path, originalPath: nil, kind: kind, staged: true))
            }
        }
        return files
    }

    static func commitDiff(_ hash: String, parents: [String], path: String?, ignoreWhitespace: Bool = false, context: Int = 3, in url: URL) async throws -> [FileDiff] {
        var args: [String]
        if let parent = parents.first {
            args = ["diff", "--no-color", "-M", "-U\(context)", parent, hash]
        } else {
            args = ["show", "--format=", "--no-color", "-M", "-U\(context)", "--root", hash]
        }
        if ignoreWhitespace { args.append("-w") }
        if let path { args.append(contentsOf: ["--", path]) }
        let result = try await GitRunner.run(args, in: url)
        return DiffParser.parse(result.stdout)
    }

    static func rangeDiff(_ base: String, _ target: String, path: String?, in url: URL) async throws -> [FileDiff] {
        var args = ["diff", "--no-color", "-M", "\(base)...\(target)"]
        if let path { args.append(contentsOf: ["--", path]) }
        let result = try await GitRunner.run(args, in: url)
        return DiffParser.parse(result.stdout)
    }

    static func rangeFiles(_ base: String, _ target: String, in url: URL) async throws -> [FileChange] {
        let result = try await GitRunner.run(["diff", "--name-status", "-z", "-M", "\(base)...\(target)"], in: url)
        return parseNameStatus(result.stdoutData)
    }

    // MARK: Working copy diff

    static func workingDiff(for file: FileChange, ignoreWhitespace: Bool = false, context: Int = 3, in url: URL) async throws -> [FileDiff] {
        var args: [String]
        let ws = (ignoreWhitespace ? ["-w"] : []) + ["-U\(context)"]
        if file.kind == .untracked {
            args = ["diff", "--no-color", "--no-index", "--", "/dev/null", file.path]
            let result = try await GitRunner.run(args, in: url, check: false)
            return DiffParser.parse(result.stdout)
        }
        if file.staged {
            args = ["diff", "--cached", "--no-color", "-M"] + ws + ["--", file.path]
            if let original = file.originalPath { args.append(original) }
        } else {
            args = ["diff", "--no-color"] + ws + ["--", file.path]
        }
        let result = try await GitRunner.run(args, in: url)
        return DiffParser.parse(result.stdout)
    }

    // MARK: Misc

    static func reflog(in url: URL) async throws -> [ReflogEntry] {
        let result = try await GitRunner.run(["reflog", "show", "--format=%H%x1f%h%x1f%gd%x1f%gs%x1f%at", "-n", "500"], in: url, check: false)
        var entries: [ReflogEntry] = []
        for line in result.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: unit)
            guard f.count == 5 else { continue }
            entries.append(ReflogEntry(hash: f[0], shortHash: f[1], selector: f[2], action: f[3], date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0)))
        }
        return entries
    }

    static func tree(revision: String, path: String, in url: URL) async throws -> [TreeEntry] {
        var args = ["ls-tree", "-z", revision]
        if !path.isEmpty { args.append(path.hasSuffix("/") ? path : path + "/") }
        let result = try await GitRunner.run(args, in: url)
        var entries: [TreeEntry] = []
        for token in result.stdoutData.split(separator: 0) {
            let line = String(decoding: token, as: UTF8.self)
            // "<mode> <type> <hash>\t<path>"
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let meta = line[..<tab].split(separator: " ")
            let p = String(line[line.index(after: tab)...])
            guard meta.count == 3 else { continue }
            entries.append(TreeEntry(path: p, name: (p as NSString).lastPathComponent, isDirectory: meta[1] == "tree" || meta[1] == "commit", hash: String(meta[2])))
        }
        return entries.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    static func fileContents(revision: String, path: String, in url: URL) async throws -> Data {
        try await GitRunner.run(["show", "\(revision):\(path)"], in: url).stdoutData
    }

    static func blame(path: String, revision: String?, in url: URL) async throws -> [BlameLine] {
        var args = ["blame", "--porcelain"]
        if let revision { args.append(revision) }
        args.append(contentsOf: ["--", path])
        let result = try await GitRunner.run(args, in: url)
        var lines: [BlameLine] = []
        var authors: [String: String] = [:]
        var dates: [String: Date] = [:]
        var summaries: [String: String] = [:]
        var currentHash = ""
        var currentLine = 0
        for raw in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                lines.append(BlameLine(lineNumber: currentLine, hash: currentHash, author: authors[currentHash] ?? "", date: dates[currentHash] ?? Date(timeIntervalSince1970: 0), summary: summaries[currentHash] ?? "", text: String(line.dropFirst())))
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                currentHash = key
                let nums = (parts.count > 1 ? parts[1] : "").split(separator: " ")
                if nums.count >= 2 { currentLine = Int(nums[1]) ?? 0 }
            } else if key == "author", parts.count > 1 { authors[currentHash] = parts[1] }
            else if key == "author-time", parts.count > 1 { dates[currentHash] = Date(timeIntervalSince1970: TimeInterval(parts[1]) ?? 0) }
            else if key == "summary", parts.count > 1 { summaries[currentHash] = parts[1] }
        }
        return lines
    }

    static func mergedBranches(into base: String, in url: URL) async -> Set<String> {
        guard let result = try? await GitRunner.run(["branch", "--format=%(refname)", "--merged", base], in: url, check: false), result.succeeded else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    static func unpushedHashes(in url: URL) async -> Set<String> {
        guard let result = try? await GitRunner.run(["rev-list", "@{upstream}..HEAD"], in: url, check: false), result.succeeded else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    static func unpulledHashes(in url: URL) async -> Set<String> {
        guard let result = try? await GitRunner.run(["rev-list", "HEAD..@{upstream}"], in: url, check: false), result.succeeded else { return [] }
        return Set(result.stdout.split(separator: "\n").map(String.init))
    }

    static func topLevel(of url: URL) async -> URL? {
        guard let result = try? await GitRunner.run(["rev-parse", "--show-toplevel"], in: url, check: false), result.succeeded else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static func lastCommitMessage(in url: URL) async -> String {
        (try? await GitRunner.run(["log", "-1", "--format=%B"], in: url, check: false).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }
}
