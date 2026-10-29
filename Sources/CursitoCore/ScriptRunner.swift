import Foundation

public struct ScriptResult: Sendable {
    public let exitCode: Int32
    public let output: String

    public var succeeded: Bool { exitCode == 0 }
}

/// Runs one of the bundled shell scripts, which do all the actual work; the app only drives them.
public struct ScriptRunner: Sendable {
    public let scriptURL: URL

    public init(scriptURL: URL) {
        self.scriptURL = scriptURL
    }

    /// Runs the script with `arguments` off the main thread, with stdout and stderr combined.
    public func run(_ arguments: [String]) async -> ScriptResult {
        let arguments = [scriptURL.path] + arguments
        return await Task.detached(priority: .userInitiated) {
            Self.runBlocking(arguments)
        }.value
    }

    private static func runBlocking(_ arguments: [String]) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        // Apps opened from Finder get a minimal PATH without the `cursor` CLI
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:"
            + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ScriptResult(exitCode: -1, output: "error: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
