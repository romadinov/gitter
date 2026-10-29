import Testing
import Foundation
@testable import Gitter

/// Exercises line and hunk staging patches against a real git repository.
@Suite struct PatchTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await GitRunner.run(["init", "-q", "-b", "main"], in: dir)
        try await GitRunner.run(["config", "user.name", "Test"], in: dir)
        try await GitRunner.run(["config", "user.email", "t@example.com"], in: dir)
        let file = dir.appendingPathComponent("f.txt")
        try (1...10).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        try await GitRunner.run(["add", "."], in: dir)
        try await GitRunner.run(["commit", "-q", "-m", "init"], in: dir)
        // Modify: change line 2, add after line 5, delete line 9
        var lines = (1...10).map { "line \($0)" }
        lines[1] = "LINE 2"
        lines.insert("inserted", at: 5)
        lines.remove(at: 9) // removes "line 9"
        try lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        return dir
    }

    @Test func stagesSelectedLinesOnly() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let change = FileChange(path: "f.txt", originalPath: nil, kind: .modified, staged: false)
        let diffs = try await GitQueries.workingDiff(for: change, context: 3, in: dir)
        #expect(diffs.count == 1)
        let file = diffs[0]
        #expect(file.hunks.count >= 1)
        // Select only the "inserted" addition
        let inserted = file.hunks.flatMap(\.lines).first { $0.kind == .addition && $0.text == "inserted" }
        let hunk = file.hunks.first { $0.lines.contains { $0.id == inserted?.id } }
        #expect(inserted != nil && hunk != nil)
        let patch = file.patch(for: hunk!, selectedLineIDs: [inserted!.id], reverse: false)
        #expect(patch != nil)
        try await GitRunner.run(["apply", "--cached", "--check", "-"], in: dir, stdin: Data(patch!.utf8))
        try await GitRunner.run(["apply", "--cached", "-"], in: dir, stdin: Data(patch!.utf8))
        let staged = try await GitRunner.run(["diff", "--cached"], in: dir).stdout
        #expect(staged.contains("+inserted"))
        #expect(!staged.contains("+LINE 2"))
        #expect(!staged.contains("-line 9"))
        // Unstage it again via the reverse patch
        let stagedChange = FileChange(path: "f.txt", originalPath: nil, kind: .modified, staged: true)
        let stagedDiffs = try await GitQueries.workingDiff(for: stagedChange, in: dir)
        let sHunk = stagedDiffs[0].hunks[0]
        let sLine = sHunk.lines.first { $0.kind == .addition }!
        let reverse = stagedDiffs[0].patch(for: sHunk, selectedLineIDs: [sLine.id], reverse: true)!
        try await GitRunner.run(["apply", "--cached", "--reverse", "-"], in: dir, stdin: Data(reverse.utf8))
        let after = try await GitRunner.run(["diff", "--cached"], in: dir).stdout
        #expect(after.isEmpty)
    }

    @Test func stagesWholeHunk() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let change = FileChange(path: "f.txt", originalPath: nil, kind: .modified, staged: false)
        let diffs = try await GitQueries.workingDiff(for: change, context: 1, in: dir)
        let file = diffs[0]
        #expect(file.hunks.count == 3)
        let patch = file.patch(for: file.hunks[2])
        try await GitRunner.run(["apply", "--cached", "-"], in: dir, stdin: Data(patch.utf8))
        let staged = try await GitRunner.run(["diff", "--cached"], in: dir).stdout
        #expect(staged.contains("-line 9"))
        #expect(!staged.contains("+inserted"))
    }

    @Test func discardsSelectedDeletionOnly() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let change = FileChange(path: "f.txt", originalPath: nil, kind: .modified, staged: false)
        let file = try await GitQueries.workingDiff(for: change, context: 1, in: dir)[0]
        let deletion = file.hunks.flatMap(\.lines).first { $0.kind == .deletion && $0.text == "line 9" }!
        let hunk = file.hunks.first { $0.lines.contains { $0.id == deletion.id } }!
        // Discard = apply --reverse to the worktree with the selected lines only (reverse: true semantics)
        let patch = file.patch(for: hunk, selectedLineIDs: [deletion.id], reverse: true)!
        try await GitRunner.run(["apply", "--reverse", "-"], in: dir, stdin: Data(patch.utf8))
        let content = try String(contentsOf: dir.appendingPathComponent("f.txt"), encoding: .utf8)
        #expect(content.contains("line 9"))
        #expect(content.contains("LINE 2") && content.contains("inserted"))
    }
}
