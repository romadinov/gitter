import Testing
import Foundation
@testable import Gitter

@Suite struct RepositoryTests {
    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitter-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await GitRunner.run(["init", "-q", "-b", "main"], in: dir)
        try await GitRunner.run(["config", "user.name", "Test"], in: dir)
        try await GitRunner.run(["config", "user.email", "t@example.com"], in: dir)
        try "hello\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await GitRunner.run(["add", "."], in: dir)
        try await GitRunner.run(["commit", "-q", "-m", "init"], in: dir)
        return dir
    }

    @MainActor @Test func stageCommitAndUndo() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = Repository(url: dir)
        try "hello\nworld\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        await repo.refresh()
        #expect(repo.status.unstaged.count == 2)
        #expect(repo.status.staged.isEmpty)

        await repo.stage(repo.status.unstaged)
        #expect(repo.status.staged.count == 2)
        #expect(repo.undoStack.canUndo)

        await repo.undo()
        #expect(repo.status.staged.isEmpty)
        await repo.redo()
        #expect(repo.status.staged.count == 2)

        await repo.commit(message: "second", amend: false, sign: false)
        #expect(repo.errorMessage == nil)
        #expect(repo.status.changeCount == 0)
        let head = try await GitRunner.run(["log", "-1", "--format=%s"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == "second")

        await repo.undo() // undo commit: changes return to the index
        let afterUndo = try await GitRunner.run(["log", "-1", "--format=%s"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(afterUndo == "init")
        #expect(repo.status.staged.count == 2)
    }

    @MainActor @Test func branchStashAndUndo() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = Repository(url: dir)
        await repo.refresh()

        await repo.createBranch("feature/x", from: nil, checkout: true)
        #expect(repo.status.branch == "feature/x")
        await repo.undo()
        #expect(repo.status.branch == "main")
        #expect(!repo.localBranches.contains { $0.name == "feature/x" })

        try "changed\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await repo.refresh()
        await repo.stash(message: "wip", includeUntracked: true, keepIndex: false)
        #expect(repo.stashes.count == 1)
        #expect(repo.status.changeCount == 0)
        await repo.applyStash(repo.stashes[0], pop: true)
        #expect(repo.stashes.isEmpty)
        #expect(repo.status.unstaged.count == 1)

        await repo.discard(repo.status.unstaged)
        #expect(repo.status.changeCount == 0)
        await repo.undo()
        #expect(repo.status.unstaged.count == 1)
        let content = try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(content == "changed\n")
    }

    @MainActor @Test func interactiveRebaseSquashes() async throws {
        let dir = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...3 {
            try "v\(i)\n".write(to: dir.appendingPathComponent("c\(i).txt"), atomically: true, encoding: .utf8)
            try await GitRunner.run(["add", "."], in: dir)
            try await GitRunner.run(["commit", "-q", "-m", "commit \(i)"], in: dir)
        }
        let repo = Repository(url: dir)
        await repo.refresh()
        let base = try await GitRunner.run(["rev-parse", "HEAD~3"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commits = try await GitQueries.log(GitQueries.LogQuery(ref: nil, range: "\(base)..HEAD"), in: dir).reversed()
        #expect(commits.count == 3)
        var todo = ""
        for (i, c) in commits.enumerated() {
            todo += (i == 0 ? "pick" : "fixup") + " \(c.hash) \(c.subject)\n"
        }
        await repo.interactiveRebase(onto: base, todo: todo)
        #expect(repo.errorMessage == nil)
        let count = try await GitRunner.run(["rev-list", "--count", "HEAD"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(count == "2")
        await repo.undo()
        let restored = try await GitRunner.run(["rev-list", "--count", "HEAD"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(restored == "4")
    }
}
