import XCTest
@testable import Gitter

final class GraphDumpTests: XCTestCase {
    func testDumpGraph() async throws {
        guard let path = ProcessInfo.processInfo.environment["GITTER_DUMP_REPO"] else { throw XCTSkip("set GITTER_DUMP_REPO") }
        let url = URL(fileURLWithPath: path)
        let commits = try await GitQueries.log(GitQueries.LogQuery(limit: 24), in: url)
        let rows = CommitGraph.layout(commits)
        for (row, commit) in zip(rows, commits) {
            var cells = Array(repeating: " ", count: max(row.laneCount, 1) * 3)
            for line in row.lines {
                let a = min(line.fromLane, line.toLane), b = max(line.fromLane, line.toLane)
                if a == b { cells[a * 3 + 1] = "|" } else { for l in a...b { cells[l * 3 + 1] = cells[l * 3 + 1] == " " ? "-" : "+" } }
            }
            cells[row.lane * 3 + 1] = "*"
            print(cells.joined(), " c\(row.color)", commit.shortHash, commit.subject.prefix(40), "parents:", commit.parents.map { String($0.prefix(7)) })
        }
    }
}
