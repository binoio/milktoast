import Foundation

public enum RemuxEvent: Sendable {
    case analyzing
    case planned(RemuxPlan)
    /// A finished movie for this exact source and settings was already in place.
    case reusedExisting(URL)
    case started(command: String)
    case progress(RemuxProgress, fraction: Double?)
    case finished(URL)
}

public enum RemuxError: Error, CustomStringConvertible {
    case sourceUnreadable(URL)
    case noAvailableOutputName(URL)
    case probeFailed(String)
    case probeUndecodable(String)
    case planning(RemuxPlannerError)
    case ffmpegFailed(exitCode: Int32, standardError: String)
    case outputMissing

    public var description: String {
        switch self {
        case .sourceUnreadable(let url):
            return "Cannot read \(url.lastPathComponent)."
        case .noAvailableOutputName(let url):
            return """
            Could not find a free name next to \(url.lastPathComponent). \
            Milktoast will not overwrite a file it did not create.
            """
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
    public let outputLocation: OutputLocation

    public init(
        tools: ToolPaths,
        cache: RemuxCacheStore,
        capabilities: PlaybackCapabilities,
        options: RemuxOptions = .default,
        cacheLimits: CacheLimits = .default,
        outputLocation: OutputLocation = .besideSource
    ) {
        self.tools = tools
        self.cache = cache
        self.capabilities = capabilities
        self.options = options
        self.cacheLimits = cacheLimits
        self.outputLocation = outputLocation
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

    /// Produces a QuickTime-playable movie for `source` and returns its URL.
    public func remux(
        source: URL,
        emit: @escaping @Sendable (RemuxEvent) -> Void
    ) async throws -> URL {
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw RemuxError.sourceUnreadable(source)
        }

        let fingerprint = try cache.fingerprint(of: source)
        let stamp = RemuxCacheKey.digest(source: fingerprint, options: options)
        let folder = source.deletingLastPathComponent()

        // A movie can live on a read-only disc, a locked share, or someone else's
        // home directory. Fall back rather than fail.
        var placement = outputLocation
        var placementWarning: String?
        if placement == .besideSource, !FileManager.default.isWritableFile(atPath: folder.path) {
            placement = .cache
            placementWarning = "\(folder.lastPathComponent) is not writable — kept the prepared movie in Milktoast's cache instead."
        }

        // Fast path: a finished movie for this exact source and these exact
        // settings is already sitting where we would put one.
        if let existing = existingOutput(source: source, fingerprint: fingerprint, stamp: stamp, placement: placement) {
            if placement == .cache {
                cache.touch(directory: cache.directory(for: fingerprint, options: options))
            }
            emit(.reusedExisting(existing))
            emit(.finished(existing))
            return existing
        }

        emit(.analyzing)
        let probeResult = try await probe(source)
        var remuxPlan = try plan(for: probeResult)
        if let placementWarning {
            remuxPlan.warnings.append(.init(.warning, placementWarning))
        }
        emit(.planned(remuxPlan))

        let destination = try makeDestination(
            source: source,
            fingerprint: fingerprint,
            stamp: stamp,
            placement: placement,
            container: remuxPlan.container
        )

        let arguments = FFmpegCommand.remuxArguments(
            input: source.path,
            output: destination.workURL.path,
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
            destination.discard()
            throw error
        }

        guard result.succeeded else {
            destination.discard()
            throw RemuxError.ffmpegFailed(exitCode: result.exitCode, standardError: result.standardError)
        }
        guard FileManager.default.fileExists(atPath: destination.workURL.path) else {
            destination.discard()
            throw RemuxError.outputMissing
        }

        try destination.finalize(stamp: stamp, sourcePath: source.path, cache: cache)
        emit(.finished(destination.finalURL))
        return destination.finalURL
    }

    // MARK: - Destinations

    /// Where ffmpeg writes, where the result ends up, and how to tidy up either way.
    struct Destination {
        var workURL: URL
        var finalURL: URL
        /// Set when the cache owns this result; nil for a sidecar.
        var cacheDirectory: URL?

        func discard() {
            if let cacheDirectory {
                try? FileManager.default.removeItem(at: cacheDirectory)
            } else {
                try? FileManager.default.removeItem(at: workURL)
            }
        }

        func finalize(stamp: String, sourcePath: String, cache: RemuxCacheStore) throws {
            guard let cacheDirectory else {
                // Same-directory rename is atomic, so the finished name never
                // exists in a half-written state.
                if workURL != finalURL {
                    try? FileManager.default.removeItem(at: finalURL)
                    try FileManager.default.moveItem(at: workURL, to: finalURL)
                }
                FileStamp.write(stamp, at: finalURL.path)
                return
            }
            try cache.markComplete(directory: cacheDirectory, sourcePath: sourcePath)
        }
    }

    private func makeDestination(
        source: URL,
        fingerprint: SourceFingerprint,
        stamp: String,
        placement: OutputLocation,
        container: OutputContainer
    ) throws -> Destination {
        switch placement {
        case .besideSource:
            let folder = source.deletingLastPathComponent()
            let decision = SidecarPlanner.decide(
                sourceName: source.lastPathComponent,
                container: container,
                expectedStamp: stamp,
                inspect: { inspectSidecar(folder.appendingPathComponent($0)) }
            )
            switch decision {
            case .noRoom:
                throw RemuxError.noAvailableOutputName(source)
            case .reuse(let name), .write(let name):
                let finalURL = folder.appendingPathComponent(name)
                let workURL = folder.appendingPathComponent(SidecarNaming.partial(for: name))
                try? FileManager.default.removeItem(at: workURL)
                return Destination(workURL: workURL, finalURL: finalURL, cacheDirectory: nil)
            }

        case .cache:
            let directoryName = RemuxCacheKey.directoryName(source: fingerprint, options: options)
            cache.evict(limits: cacheLimits, protecting: [directoryName])
            let directory = try cache.prepareDirectory(for: fingerprint, options: options)
            let output = cache.outputURL(for: fingerprint, options: options, container: container)
            return Destination(workURL: output, finalURL: output, cacheDirectory: directory)
        }
    }

    /// A finished movie already in the right place for this source and settings.
    private func existingOutput(
        source: URL,
        fingerprint: SourceFingerprint,
        stamp: String,
        placement: OutputLocation
    ) -> URL? {
        switch placement {
        case .cache:
            return cache.completedOutput(for: fingerprint, options: options)
        case .besideSource:
            // The container is not known until the source is probed, so check the
            // names both containers would have produced.
            let folder = source.deletingLastPathComponent()
            for container in [OutputContainer.mp4, .mov] {
                let decision = SidecarPlanner.decide(
                    sourceName: source.lastPathComponent,
                    container: container,
                    expectedStamp: stamp,
                    inspect: { inspectSidecar(folder.appendingPathComponent($0)) }
                )
                if case .reuse(let name) = decision {
                    return folder.appendingPathComponent(name)
                }
            }
            return nil
        }
    }

    private func inspectSidecar(_ url: URL) -> SidecarFileState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let stamp = FileStamp.read(at: url.path) else { return .foreign }
        return .ours(stamp: stamp)
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
