import Foundation

enum DiffLineKind: Hashable, Sendable {
    case context, addition, deletion, hunkHeader, meta
}

struct DiffLine: Identifiable, Hashable, Sendable {
    let id: Int
    let kind: DiffLineKind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    /// Raw line as it appeared in the patch, including the leading +/-/space.
    let raw: String

    var isChange: Bool { kind == .addition || kind == .deletion }
}

struct DiffHunk: Identifiable, Hashable, Sendable {
    let id: Int
    let header: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [DiffLine] = []

    var changeLineIDs: [Int] { lines.filter(\.isChange).map(\.id) }

    /// Patch text for this hunk (header + raw body lines), without the file header.
    var rawPatch: String {
        lines.filter { $0.kind != .hunkHeader }.map(\.raw).joined(separator: "\n") + "\n"
    }
}

struct FileDiff: Identifiable, Hashable, Sendable {
    var headerLines: [String]
    var hunks: [DiffHunk] = []
    var isBinary = false
    var oldPath: String?
    var newPath: String?

    var id: String { (newPath ?? oldPath ?? headerLines.first ?? "") }
    var displayPath: String { newPath ?? oldPath ?? "" }
    var isNewFile: Bool { headerLines.contains { $0.hasPrefix("new file mode") } }
    var isDeletedFile: Bool { headerLines.contains { $0.hasPrefix("deleted file mode") } }
    var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }

    var headerText: String { headerLines.joined(separator: "\n") + "\n" }

    /// Builds an applicable patch containing only the given hunk.
    func patch(for hunk: DiffHunk) -> String {
        headerText + "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n" + hunk.rawPatch
    }

    /// Builds a patch that contains only the selected change lines of a hunk.
    /// Unselected additions are dropped, unselected deletions become context.
    /// - Parameter reverse: when true, the patch is meant for `apply --reverse`, so the roles swap:
    ///   unselected deletions are dropped and unselected additions become context.
    func patch(for hunk: DiffHunk, selectedLineIDs: Set<Int>, reverse: Bool) -> String? {
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        for line in hunk.lines {
            switch line.kind {
            case .hunkHeader:
                continue
            case .context:
                body.append(line.raw); oldCount += 1; newCount += 1
            case .meta:
                body.append(line.raw)
            case .addition:
                if selectedLineIDs.contains(line.id) {
                    body.append(line.raw); newCount += 1
                } else if reverse {
                    body.append(" " + line.text); oldCount += 1; newCount += 1
                }
            case .deletion:
                if selectedLineIDs.contains(line.id) {
                    body.append(line.raw); oldCount += 1
                } else if !reverse {
                    body.append(" " + line.text); oldCount += 1; newCount += 1
                }
            }
        }
        guard body.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) else { return nil }
        let newStart = hunk.newStart
        return headerText + "@@ -\(hunk.oldStart),\(oldCount) +\(newStart),\(newCount) @@\n" + body.joined(separator: "\n") + "\n"
    }
}

enum DiffParser {
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: DiffHunk?
        var oldLine = 0
        var newLine = 0
        var lineID = 0
        var hunkID = 0

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = current { files.append(f) }
            current = nil
        }

        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, sub) in rawLines.enumerated() {
            let line = String(sub)
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                flushFile()
                current = FileDiff(headerLines: [line])
                let parts = line.components(separatedBy: " b/")
                if parts.count >= 2 {
                    current?.newPath = parts.last
                    if let aRange = parts[0].range(of: " a/") {
                        current?.oldPath = String(parts[0][aRange.upperBound...])
                    }
                }
                continue
            }
            guard current != nil else { continue }

            if hunk == nil, !line.hasPrefix("@@") {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                    current?.isBinary = true
                }
                if line.hasPrefix("--- ") {
                    let p = String(line.dropFirst(4))
                    current?.oldPath = p == "/dev/null" ? nil : stripPrefix(p)
                } else if line.hasPrefix("+++ ") {
                    let p = String(line.dropFirst(4))
                    current?.newPath = p == "/dev/null" ? nil : stripPrefix(p)
                }
                if index == rawLines.count - 1 && line.isEmpty { continue }
                current?.headerLines.append(line)
                continue
            }

            if line.hasPrefix("@@") {
                flushHunk()
                let (os, oc, ns, nc) = parseHunkHeader(line)
                oldLine = os
                newLine = ns
                hunkID += 1
                lineID += 1
                var h = DiffHunk(id: hunkID, header: line, oldStart: os, oldCount: oc, newStart: ns, newCount: nc)
                h.lines.append(DiffLine(id: lineID, kind: .hunkHeader, text: line, oldNumber: nil, newNumber: nil, raw: line))
                hunk = h
                continue
            }

            guard hunk != nil else { continue }
            if index == rawLines.count - 1 && line.isEmpty { continue }
            lineID += 1
            let first = line.first
            switch first {
            case "+":
                hunk?.lines.append(DiffLine(id: lineID, kind: .addition, text: String(line.dropFirst()), oldNumber: nil, newNumber: newLine, raw: line))
                newLine += 1
            case "-":
                hunk?.lines.append(DiffLine(id: lineID, kind: .deletion, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: nil, raw: line))
                oldLine += 1
            case "\\":
                hunk?.lines.append(DiffLine(id: lineID, kind: .meta, text: String(line.dropFirst(2)), oldNumber: nil, newNumber: nil, raw: line))
            default:
                let text = line.isEmpty ? "" : String(line.dropFirst())
                hunk?.lines.append(DiffLine(id: lineID, kind: .context, text: text, oldNumber: oldLine, newNumber: newLine, raw: line.isEmpty ? " " : line))
                oldLine += 1
                newLine += 1
            }
        }
        flushFile()
        return files
    }

    private static func stripPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    private static func parseHunkHeader(_ line: String) -> (Int, Int, Int, Int) {
        // @@ -a,b +c,d @@ ...
        var os = 0, oc = 1, ns = 0, nc = 1
        let scanner = Scanner(string: line)
        _ = scanner.scanString("@@")
        _ = scanner.scanString("-")
        if let a = scanner.scanInt() { os = a }
        if scanner.scanString(",") != nil, let b = scanner.scanInt() { oc = b }
        _ = scanner.scanString("+")
        if let c = scanner.scanInt() { ns = c }
        if scanner.scanString(",") != nil, let d = scanner.scanInt() { nc = d }
        return (os, oc, ns, nc)
    }
}
