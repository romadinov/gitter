import Foundation

enum FileStatusKind: String, Hashable, Sendable {
    case added = "A"
    case modified = "M"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unmerged = "U"
    case untracked = "?"
    case ignored = "!"

    init(code: Character) {
        self = FileStatusKind(rawValue: String(code)) ?? .modified
    }

    var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .unmerged: "Conflict"
        case .untracked: "Untracked"
        case .ignored: "Ignored"
        }
    }
}

struct FileChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let kind: FileStatusKind
    let staged: Bool

    var id: String { (staged ? "S:" : "W:") + path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
}

struct WorkingStatus: Equatable, Sendable {
    var branch: String?
    var oid: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var detached = false
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []

    var hasHEAD: Bool { oid != nil && oid != "(initial)" }
    var allFiles: [FileChange] { unstaged + staged }
    var conflicted: [FileChange] { unstaged.filter { $0.kind == .unmerged } }
    var changeCount: Int { staged.count + unstaged.count }
}

enum RepositoryOperationState: Equatable, Sendable {
    case none
    case merging
    case rebasing
    case cherryPicking
    case reverting
    case bisecting

    var title: String? {
        switch self {
        case .none: nil
        case .merging: "Merge in progress"
        case .rebasing: "Rebase in progress"
        case .cherryPicking: "Cherry-pick in progress"
        case .reverting: "Revert in progress"
        case .bisecting: "Bisect in progress"
        }
    }
}

struct Commit: Identifiable, Hashable, Sendable {
    let hash: String
    let shortHash: String
    let author: String
    let email: String
    let date: Date
    let parents: [String]
    let refs: [CommitRef]
    let subject: String

    var id: String { hash }
    var isMerge: Bool { parents.count > 1 }
}

struct CommitRef: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case head, local, remote, tag, stash, other }
    let name: String
    let kind: Kind
    let isHEADTarget: Bool
}

struct CommitDetail: Sendable {
    let commit: Commit
    let body: String
    let committer: String
    let committerDate: Date
    let files: [FileChange]
    let signature: String?
}

struct Branch: Identifiable, Hashable, Sendable {
    let fullRef: String
    let name: String
    let shortHash: String
    let isRemote: Bool
    let isCurrent: Bool
    let upstream: String?
    let upstreamGone: Bool
    let ahead: Int
    let behind: Int
    let date: Date
    let subject: String

    var id: String { fullRef }
    var remoteName: String? {
        guard isRemote else { return nil }
        return name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }
    var nameWithoutRemote: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

struct Tag: Identifiable, Hashable, Sendable {
    let name: String
    let shortHash: String
    let date: Date
    let subject: String
    var id: String { name }
    var fullRef: String { "refs/tags/\(name)" }
}

struct Remote: Identifiable, Hashable, Sendable {
    let name: String
    let fetchURL: String
    let pushURL: String
    var id: String { name }

    var webURL: URL? {
        var s = fetchURL
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if s.hasPrefix("git@") {
            let body = s.dropFirst(4).replacingOccurrences(of: ":", with: "/")
            return URL(string: "https://" + body)
        }
        if s.hasPrefix("ssh://") {
            s = s.replacingOccurrences(of: "ssh://", with: "https://")
            if let at = s.range(of: "@") { s.removeSubrange(s.index(s.startIndex, offsetBy: 8)..<at.upperBound) }
            return URL(string: s)
        }
        if s.hasPrefix("http") { return URL(string: s) }
        return nil
    }
}

struct Stash: Identifiable, Hashable, Sendable {
    let index: Int
    let hash: String
    let message: String
    let date: Date
    var ref: String { "stash@{\(index)}" }
    var id: String { hash }
}

struct Submodule: Identifiable, Hashable, Sendable {
    let path: String
    let hash: String
    let describe: String
    let state: Character  // ' ' ok, '-' uninitialized, '+' different commit, 'U' conflicts
    var id: String { path }
}

struct ReflogEntry: Identifiable, Hashable, Sendable {
    let hash: String
    let shortHash: String
    let selector: String
    let action: String
    let date: Date
    var id: String { selector }
}

struct TreeEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let hash: String
    var id: String { path }
}

struct BlameLine: Identifiable, Hashable, Sendable {
    let lineNumber: Int
    let hash: String
    let author: String
    let date: Date
    let summary: String
    let text: String
    var id: Int { lineNumber }
}

struct UserProfile: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var label: String
    var name: String
    var email: String
    var signingKey: String = ""
}

struct CommitTemplate: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var subject: String
    var body: String
}

enum SidebarItem: Hashable, Sendable {
    case workingCopy
    case history
    case stashes
    case branchesReview
    case reflog
    case submodules
    case settings
    case branch(String)      // full ref
    case remoteBranch(String) // full ref
    case tag(String)          // tag name
    case stash(String)        // stash hash
}

enum DetailRoute: Hashable, Sendable {
    case fileHistory(path: String)
    case blame(path: String, revision: String)
    case browse(revision: String)
    case compare(base: String, target: String)
    case commit(hash: String)
}

extension Date {
    var gitRelativeDescription: String {
        let interval = Date().timeIntervalSince(self)
        if interval < 60 { return "just now" }
        if interval < 7 * 86_400 {
            return formatted(.relative(presentation: .named))
        }
        return formatted(date: .abbreviated, time: .shortened)
    }
}
