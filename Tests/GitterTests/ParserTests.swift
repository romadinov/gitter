import Testing
import Foundation
@testable import Gitter

@Suite struct ParserTests {
    @Test func parsesPorcelainStatus() {
        var text = "# branch.oid abc123\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
        text += "1 .M N... 100644 100644 100644 h1 h2 Sources/main.swift\0"
        text += "1 MM N... 100644 100644 100644 h1 h2 README.md\0"
        text += "2 R. N... 100644 100644 100644 h1 h2 R100 new name.txt\0old name.txt\0"
        text += "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt\0"
        text += "? NOTES.txt\0"
        let status = GitQueries.parseStatus(Data(text.utf8))
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.staged.map(\.path) == ["README.md", "new name.txt"])
        #expect(status.staged.last?.originalPath == "old name.txt")
        #expect(status.staged.last?.kind == .renamed)
        #expect(status.unstaged.map(\.path) == ["NOTES.txt", "README.md", "Sources/main.swift", "conflict.txt"])
        #expect(status.unstaged.first { $0.path == "conflict.txt" }?.kind == .unmerged)
        #expect(status.unstaged.first { $0.path == "NOTES.txt" }?.kind == .untracked)
        #expect(status.hasHEAD)
    }

    @Test func parsesLogRecords() {
        let unit = "\u{1f}", record = "\u{1e}"
        let line = ["aaaa", "aaa", "Jane Doe", "jane@example.com", "1700000000", "bbbb cccc", "HEAD -> main, tag: v1.0, origin/main", "Merge things"].joined(separator: unit) + record + "\n"
        let commits = GitQueries.parseLog(line)
        #expect(commits.count == 1)
        let c = commits[0]
        #expect(c.parents == ["bbbb", "cccc"])
        #expect(c.isMerge)
        #expect(c.refs.map(\.name) == ["main", "v1.0", "origin/main"])
        #expect(c.refs[0].isHEADTarget && c.refs[0].kind == .local)
        #expect(c.refs[1].kind == .tag)
        #expect(c.refs[2].kind == .remote)
    }

    @Test func parsesNameStatusWithRename() {
        let data = Data("M\0a.txt\0R090\0old.txt\0new.txt\0A\0added.txt\0".utf8)
        let files = GitQueries.parseNameStatus(data)
        #expect(files.map(\.path) == ["a.txt", "new.txt", "added.txt"])
        #expect(files[1].kind == .renamed && files[1].originalPath == "old.txt")
    }

    @Test func parsesUnifiedDiff() {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,4 @@
         one
        -two
        +TWO
        +two-and-a-half
         three
        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        let f = files[0]
        #expect(f.displayPath == "f.txt")
        #expect(f.hunks.count == 1)
        #expect(f.additions == 2 && f.deletions == 1)
        let lines = f.hunks[0].lines.filter { $0.kind != .hunkHeader }
        #expect(lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context])
        #expect(lines[1].oldNumber == 2 && lines[1].newNumber == nil)
        #expect(lines[2].newNumber == 2 && lines[3].newNumber == 3)
        #expect(lines[4].oldNumber == 3 && lines[4].newNumber == 4)
    }

    @Test func commitGraphAssignsLanes() {
        func c(_ h: String, _ parents: [String]) -> Commit {
            Commit(hash: h, shortHash: h, author: "", email: "", date: Date(), parents: parents, refs: [], subject: "")
        }
        // merge M(a, b), a -> base, b -> base
        let rows = CommitGraph.layout([c("M", ["a", "b"]), c("a", ["base"]), c("b", ["base"]), c("base", [])])
        #expect(rows[0].lane == 0)
        #expect(rows[0].laneCount == 2)
        #expect(rows[1].lane == 0)
        #expect(rows[2].lane == 1)
        #expect(rows[3].lane == 0)
    }
}
