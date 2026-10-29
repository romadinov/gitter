import Foundation

struct GitResult: Sendable {
    let stdoutData: Data
    let stderr: String
    let exitCode: Int32

    var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    var succeeded: Bool { exitCode == 0 }
}

struct GitError: LocalizedError, Sendable {
    let command: String
    let message: String
    let exitCode: Int32

    var errorDescription: String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "git \(command) failed (exit code \(exitCode))" : trimmed
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs the system `git` binary asynchronously.
enum GitRunner {
    /// Extra environment variables merged into every git invocation (configured in Settings).
    nonisolated(unsafe) static var extraEnvironment: [String: String] = [:]

    static let gitPath: String = {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/git"
    }()

    @discardableResult
    static func run(_ args: [String], in directory: URL?, stdin: Data? = nil, check: Bool = true) async throws -> GitResult {
        let result = try await execute(args, in: directory, stdin: stdin)
        if check && !result.succeeded {
            throw GitError(command: args.joined(separator: " "), message: result.stderr, exitCode: result.exitCode)
        }
        return result
    }

    private static func execute(_ args: [String], in directory: URL?, stdin: Data?) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = ["--no-pager"] + args
            process.currentDirectoryURL = directory

            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GIT_PAGER"] = "cat"
            environment["LC_ALL"] = "en_US.UTF-8"
            if environment["SSH_ASKPASS"] == nil {
                environment["SSH_ASKPASS_REQUIRE"] = "never"
            }
            for (key, value) in extraEnvironment { environment[key] = value }
            process.environment = environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let inPipe: Pipe? = stdin == nil ? nil : Pipe()
            process.standardInput = inPipe ?? FileHandle.nullDevice

            let outBox = DataBox()
            let errBox = DataBox()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            process.terminationHandler = { finished in
                group.notify(queue: .global()) {
                    continuation.resume(returning: GitResult(
                        stdoutData: outBox.data,
                        stderr: String(decoding: errBox.data, as: UTF8.self),
                        exitCode: finished.terminationStatus
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            if let inPipe, let stdin {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }
    }
}
