import Foundation

public enum RemuxEvent: Sendable {
    case analyzing
    case planned(RemuxPlan)
    /// A finished remux for this exact source and settings already existed.
    case reusedCache(URL)
    case started(command: String)
    case progress(RemuxProgress, fraction: Double?)
    case finished(URL)
}

public enum RemuxError: Error, CustomStringConvertible {
    case sourceUnreadable(URL)
    case probeFailed(String)
    case probeUndecodable(String)
    case planning(RemuxPlannerError)
    case ffmpegFailed(exitCode: Int32, standardError: String)
    case outputMissing

    public var description: String {
        switch self {
        case .sourceUnreadable(let url):
            return "Cannot read \(url.lastPathComponent)."
        case .probeFailed(let message):
            return "ffprobe could not analyze the file.\n\(message)"
        case .probeUndecodable(let message):
            return "ffprobe returned output Milktoast could not read.\n\(message)"
        case .planning(let error):
            return error.description
        case .ffmpegFailed(let code, let message):
            return message.isEmpty
                ? "ffmpeg exited with code \(code)."
                : "ffmpeg exited with code \(code).\n\(message)"
        case .outputMissing:
            return "ffmpeg reported success but produced no output file."
        }
    }
}

/// Probe → plan → remux → cache, with progress callbacks.
///
/// This is the whole of the QTmkv idea, moved into typed Swift: build a
/// QuickTime-compatible `.mov` beside the original, then let QuickTime Player do
/// the playing. The overwhelmingly common path is a pure stream copy, so the cost
/// is one sequential read plus one sequential write.
public struct RemuxService: Sendable {
    public let tools: ToolPaths
    public let cache: RemuxCacheStore
    public let capabilities: PlaybackCapabilities
    public let options: RemuxOptions
    public let cacheLimits: CacheLimits

    public init(
        tools: ToolPaths,
        cache: RemuxCacheStore,
        capabilities: PlaybackCapabilities,
        options: RemuxOptions = .default,
        cacheLimits: CacheLimits = .default
    ) {
        self.tools = tools
        self.cache = cache
        self.capabilities = capabilities
        self.options = options
        self.cacheLimits = cacheLimits
    }

    public func probe(_ source: URL) async throws -> ProbeResult {
        // ffprobe's JSON goes to stdout as one document; collect it whole.
        let lines = LineAccumulator()
        let result = try await ProcessRunner.run(
            executable: tools.ffprobe,
            arguments: FFmpegCommand.probeArguments(input: source.path),
            onStandardOutputLine: { lines.append($0) }
        )
        let stdout = Data(lines.joined().utf8)

        guard result.succeeded else {
            throw RemuxError.probeFailed(result.standardError)
        }
        do {
            return try ProbeResult.decode(stdout)
        } catch {
            throw RemuxError.probeUndecodable(String(describing: error))
        }
    }

    public func plan(for probe: ProbeResult) throws -> RemuxPlan {
        let planner = RemuxPlanner(capabilities: capabilities, options: options)
        do {
            return try planner.makePlan(from: probe)
        } catch let error as RemuxPlannerError {
            throw RemuxError.planning(error)
        }
    }

    /// Produces a QuickTime-playable `.mov` for `source` and returns its URL.
    public func remux(
        source: URL,
        emit: @escaping @Sendable (RemuxEvent) -> Void
    ) async throws -> URL {
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw RemuxError.sourceUnreadable(source)
        }

        let fingerprint = try cache.fingerprint(of: source)

        if let existing = cache.completedOutput(for: fingerprint, options: options) {
            cache.touch(directory: cache.directory(for: fingerprint, options: options))
            emit(.reusedCache(existing))
            emit(.finished(existing))
            return existing
        }

        emit(.analyzing)
        let probeResult = try await probe(source)
        let remuxPlan = try plan(for: probeResult)
        emit(.planned(remuxPlan))

        // Make room before writing, but never evict the entry we are about to fill.
        let directoryName = RemuxCacheKey.directoryName(source: fingerprint, options: options)
        cache.evict(limits: cacheLimits, protecting: [directoryName])

        let directory = try cache.prepareDirectory(for: fingerprint, options: options)
        let output = cache.outputURL(
            for: fingerprint,
            options: options,
            container: remuxPlan.container
        )

        let arguments = FFmpegCommand.remuxArguments(
            input: source.path,
            output: output.path,
            plan: remuxPlan,
            options: options
        )
        emit(.started(command: FFmpegCommand.describe(tools.ffmpeg, arguments)))

        let duration = remuxPlan.durationSeconds
        let parser = ParserBox()
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: tools.ffmpeg,
                arguments: arguments,
                onStandardOutputLine: { line in
                    if let progress = parser.consume(line: line) {
                        emit(.progress(progress, fraction: progress.fraction(ofDuration: duration)))
                    }
                }
            )
        } catch {
            cache.discard(directory: directory)
            throw error
        }

        guard result.succeeded else {
            cache.discard(directory: directory)
            throw RemuxError.ffmpegFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            cache.discard(directory: directory)
            throw RemuxError.outputMissing
        }

        try cache.markComplete(directory: directory, sourcePath: source.path)
        emit(.finished(output))
        return output
    }
}

/// `ProgressParser` is a mutating value type; the stdout callback needs a
/// reference with its own lock.
private final class ParserBox: @unchecked Sendable {
    private var parser = ProgressParser()
    private let lock = NSLock()

    func consume(line: String) -> RemuxProgress? {
        lock.lock()
        defer { lock.unlock() }
        return parser.consume(line: line)
    }
}

/// Collects stdout lines from the process callback for one-shot consumers.
private final class LineAccumulator: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
