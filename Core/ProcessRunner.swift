import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    /// Tail of stderr, capped so a chatty failure cannot balloon memory.
    public var standardError: String

    public init(exitCode: Int32, standardError: String) {
        self.exitCode = exitCode
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case launchFailed(executable: String, underlying: String)
    case cancelled

    public var description: String {
        switch self {
        case .launchFailed(let executable, let underlying):
            return "Could not launch \(executable): \(underlying)"
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Runs a child process, streaming stdout line-by-line while collecting stderr.
///
/// Cancelling the surrounding `Task` terminates the child, which is how the UI's
/// cancel button aborts an in-flight ffmpeg without leaving an orphan.
public enum ProcessRunner {
    /// Retain at most this much stderr; ffmpeg errors are short, but a broken
    /// file can produce one warning per frame.
    static let maxStandardErrorBytes = 64 * 1024

    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onStandardOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // ffmpeg reads stdin for interactive keys; without this it can steal the
        // terminal or block when launched detached.
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(onLine: onStandardOutputLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.appendStandardOutput(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.appendStandardError(data)
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in
                        continuation.resume()
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(
                            throwing: ProcessRunnerError.launchFailed(
                                executable: executable,
                                underlying: error.localizedDescription
                            )
                        )
                    }
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        // Drain whatever the readability handlers had not picked up yet.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let remaining = try? stdoutPipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
            collector.appendStandardOutput(remaining)
        }
        if let remaining = try? stderrPipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
            collector.appendStandardError(remaining)
        }
        collector.flushStandardOutput()

        if Task.isCancelled { throw ProcessRunnerError.cancelled }

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardError: collector.standardErrorText()
        )
    }
}

/// Thread-safe accumulator shared between the two readability handlers (which
/// run on separate dispatch queues) and the awaiting task.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutRemainder = Data()
    private var stderrBuffer = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func appendStandardOutput(_ data: Data) {
        guard let onLine else { return }
        var lines: [String] = []
        lock.lock()
        stdoutRemainder.append(data)
        while let newline = stdoutRemainder.firstIndex(of: 0x0A) {
            let lineData = stdoutRemainder[stdoutRemainder.startIndex..<newline]
            stdoutRemainder.removeSubrange(stdoutRemainder.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) { lines.append(line) }
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    func flushStandardOutput() {
        guard let onLine else { return }
        lock.lock()
        let remainder = stdoutRemainder
        stdoutRemainder = Data()
        lock.unlock()
        if !remainder.isEmpty, let line = String(data: remainder, encoding: .utf8), !line.isEmpty {
            onLine(line)
        }
    }

    func appendStandardError(_ data: Data) {
        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > ProcessRunner.maxStandardErrorBytes {
            stderrBuffer.removeFirst(stderrBuffer.count - ProcessRunner.maxStandardErrorBytes)
        }
        lock.unlock()
    }

    func standardErrorText() -> String {
        lock.lock()
        let data = stderrBuffer
        lock.unlock()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
