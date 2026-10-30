import Foundation

/// Opt-in timing log (`GITTER_PERF=1`) written to stderr for diagnosing UI stalls.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["GITTER_PERF"] != nil
    private static let start = Date()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let t = String(format: "%8.3f", Date().timeIntervalSince(start))
        FileHandle.standardError.write(Data("[perf \(t)] \(message())\n".utf8))
    }

    static func measure<T>(_ label: String, _ work: () async throws -> T) async rethrows -> T {
        let t0 = Date()
        let value = try await work()
        log("\(label) took \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        return value
    }
}
