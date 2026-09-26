import XCTest
@testable import MilktoastCore

/// End-to-end tests against the real ffmpeg/ffprobe pair: a tiny Matroska file is
/// synthesized, run through `RemuxService`, and the result is probed back.
///
/// Every test skips itself when the tools (or the specific encoder it needs) are
/// missing, so the suite stays green on a machine without ffmpeg while still doing
/// real work in the container image, which installs it.
final class RemuxServiceIntegrationTests: XCTestCase {
    private var workspace: URL!
    private var tools: ToolPaths?

    override func setUpWithError() throws {
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("milktoast-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        tools = try? ToolLocator(
            extraDirectories: ToolLocator.directories(
                fromPATH: ProcessInfo.processInfo.environment["PATH"]
            ),
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        ).locate()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: - Tests

    func testH264AndAACAreCopiedStraightThrough() async throws {
        let tools = try requireTools()
        try await requireEncoders(["libx264", "aac"], tools)

        let source = try await makeMatroska(
            named: "copy.mkv",
            videoEncoder: "libx264",
            audioEncoder: "aac",
            tools: tools
        )
        let service = makeService(tools)

        var sawPlan: RemuxPlan?
        let output = try await service.remux(source: source) { event in
            if case .planned(let plan) = event { sawPlan = plan }
        }

        let plan = try XCTUnwrap(sawPlan)
        XCTAssertTrue(plan.isPureRemux, "H.264 + AAC needs no encoding at all")

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(output.pathExtension, "mp4")

        let result = try await probe(output, tools: tools)
        XCTAssertEqual(result.format?.formatName?.contains("mp4"), true)
        XCTAssertEqual(result.streams(of: .video).first?.codec, "h264")
        XCTAssertEqual(result.streams(of: .audio).first?.codec, "aac")
        XCTAssertEqual(result.streams(of: .video).first?.codecTagString, "avc1")
    }

    func testHEVCComesOutTaggedHVC1() async throws {
        let tools = try requireTools()
        try await requireEncoders(["libx265", "aac"], tools)

        let source = try await makeMatroska(
            named: "hevc.mkv",
            videoEncoder: "libx265",
            audioEncoder: "aac",
            tools: tools
        )
        let output = try await makeService(tools).remux(source: source) { _ in }

        let result = try await probe(output, tools: tools)
        let video = try XCTUnwrap(result.streams(of: .video).first)
        XCTAssertEqual(video.codec, "hevc")
        // This is the fix that makes HEVC Matroska play instead of showing black.
        XCTAssertEqual(video.codecTagString, "hvc1")
    }

    func testFLACIsRewrappedAsALACRatherThanLosingQualityToAAC() async throws {
        let tools = try requireTools()
        try await requireEncoders(["libx264", "flac", "alac"], tools)

        let source = try await makeMatroska(
            named: "lossless.mkv",
            videoEncoder: "libx264",
            audioEncoder: "flac",
            tools: tools
        )
        let output = try await makeService(tools).remux(source: source) { _ in }

        let result = try await probe(output, tools: tools)
        XCTAssertEqual(result.streams(of: .audio).first?.codec, "alac")
        XCTAssertEqual(result.streams(of: .video).first?.codec, "h264", "video is untouched")
    }

    func testTextSubtitlesSurviveAsQuickTimeTimedText() async throws {
        let tools = try requireTools()
        try await requireEncoders(["libx264", "aac"], tools)

        let subtitles = workspace.appendingPathComponent("subs.srt")
        try """
        1
        00:00:00,200 --> 00:00:01,000
        Hello from Milktoast.

        """.write(to: subtitles, atomically: true, encoding: .utf8)

        let source = workspace.appendingPathComponent("subbed.mkv")
        try await runFFmpeg([
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=15:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-i", subtitles.path,
            "-map", "0:v", "-map", "1:a", "-map", "2:s",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-c:s", "srt",
            "-f", "matroska", source.path,
        ], tools: tools)

        let output = try await makeService(tools).remux(source: source) { _ in }
        let result = try await probe(output, tools: tools)
        let subtitle = try XCTUnwrap(result.streams(of: .subtitle).first)
        XCTAssertEqual(subtitle.codec, "mov_text")
        // tx3g inside MP4 is a real `sbtl` track, which QuickTime offers in its
        // Subtitles menu. The MOV muxer would write the same samples as a legacy
        // `text` track and burn them over the picture.
        XCTAssertEqual(subtitle.codecTagString, "tx3g")
        XCTAssertEqual(output.pathExtension, "mp4")
    }

    func testProgressRunsToCompletionAndIsMonotonic() async throws {
        let tools = try requireTools()
        try await requireEncoders(["libx264", "aac"], tools)

        let source = try await makeMatroska(
            named: "progress.mkv",
            videoEncoder: "libx264",
            audioEncoder: "aac",
            seconds: 6,
            tools: tools
        )

        let collector = ProgressCollector()
        _ = try await makeService(tools).remux(source: source) { event in
            if case .progress(let progress, _) = event { collector.record(progress) }
        }

        let positions = collector.positions()
        XCTAssertFalse(positions.isEmpty, "ffmpeg -progress produced no blocks")
        XCTAssertEqual(positions, positions.sorted(), "progress must never run backwards")
        XCTAssertTrue(collector.sawFinish(), "the final progress=end block was missed")
    }

    func testSecondOpenOfTheSameFileReusesTheCachedRemux() async throws {
        let tools = try requireTools()
        try await requireEncoders(["libx264", "aac"], tools)

        let source = try await makeMatroska(
            named: "cached.mkv",
            videoEncoder: "libx264",
            audioEncoder: "aac",
            tools: tools
        )
        let service = makeService(tools)

        let first = try await service.remux(source: source) { _ in }

        var reused = false
        var analyzedAgain = false
        let second = try await service.remux(source: source) { event in
            switch event {
            case .reusedCache: reused = true
            case .analyzing: analyzedAgain = true
            default: break
            }
        }

        XCTAssertEqual(first, second)
        XCTAssertTrue(reused, "the completed remux should be served from cache")
        XCTAssertFalse(analyzedAgain, "a cache hit must not even re-probe the source")
    }

    func testEditingTheSourceInvalidatesTheCachedRemux() async throws {
        let tools = try requireTools()
        try await requireEncoders(["libx264", "aac"], tools)

        let source = try await makeMatroska(
            named: "changing.mkv",
            videoEncoder: "libx264",
            audioEncoder: "aac",
            tools: tools
        )
        let service = makeService(tools)
        let first = try await service.remux(source: source) { _ in }

        // Replace the file with a different (longer) movie at the same path.
        try FileManager.default.removeItem(at: source)
        _ = try await makeMatroska(
            named: "changing.mkv",
            videoEncoder: "libx264",
            audioEncoder: "aac",
            seconds: 4,
            tools: tools
        )

        var reused = false
        let second = try await service.remux(source: source) { event in
            if case .reusedCache = event { reused = true }
        }
        XCTAssertFalse(reused, "a replaced source must be re-remuxed")
        XCTAssertNotEqual(first, second, "the new content hashes to a different cache slot")
    }

    func testAMissingSourceFailsBeforeSpawningFFmpeg() async throws {
        let tools = try requireTools()
        let service = makeService(tools)
        let missing = workspace.appendingPathComponent("nope.mkv")

        do {
            _ = try await service.remux(source: missing) { _ in }
            XCTFail("expected a failure")
        } catch let error as RemuxError {
            guard case .sourceUnreadable = error else {
                return XCTFail("expected sourceUnreadable, got \(error)")
            }
        }
    }

    func testAFileWithNoVideoTrackIsRejectedWithAClearMessage() async throws {
        let tools = try requireTools()
        try await requireEncoders(["aac"], tools)

        let source = workspace.appendingPathComponent("audio-only.mka")
        try await runFFmpeg([
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:a", "aac", "-f", "matroska", source.path,
        ], tools: tools)

        do {
            _ = try await makeService(tools).remux(source: source) { _ in }
            XCTFail("expected a failure")
        } catch let error as RemuxError {
            XCTAssertTrue(error.description.contains("no video track"), error.description)
        }
    }

    func testAPartialOutputIsNotLeftBehindWhenFFmpegFails() async throws {
        let tools = try requireTools()

        // A .mkv that is not actually Matroska: ffprobe rejects it.
        let source = workspace.appendingPathComponent("broken.mkv")
        try Data(repeating: 0x42, count: 4096).write(to: source)

        let cacheRoot = workspace.appendingPathComponent("cache", isDirectory: true)
        let service = RemuxService(
            tools: tools,
            cache: RemuxCacheStore(root: cacheRoot),
            capabilities: HostCapabilities.current()
        )

        do {
            _ = try await service.remux(source: source) { _ in }
            XCTFail("expected a failure")
        } catch {
            // Expected.
        }
        XCTAssertTrue(
            RemuxCacheStore(root: cacheRoot).entries().allSatisfy(\.isComplete),
            "a failed job must not leave a playable-looking cache entry"
        )
    }

    // MARK: - Helpers

    private func requireTools() throws -> ToolPaths {
        try XCTUnwrap(tools, "ffmpeg/ffprobe not on PATH — skipping integration coverage")
    }

    private func makeService(_ tools: ToolPaths) -> RemuxService {
        RemuxService(
            tools: tools,
            cache: RemuxCacheStore(root: workspace.appendingPathComponent("cache", isDirectory: true)),
            capabilities: HostCapabilities.current()
        )
    }

    private func makeMatroska(
        named name: String,
        videoEncoder: String,
        audioEncoder: String,
        seconds: Int = 2,
        tools: ToolPaths
    ) async throws -> URL {
        let url = workspace.appendingPathComponent(name)
        var arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=15:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:v", videoEncoder,
        ]
        if videoEncoder.hasPrefix("libx") {
            arguments += ["-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        }
        arguments += ["-c:a", audioEncoder, "-f", "matroska", url.path]
        try await runFFmpeg(arguments, tools: tools)
        return url
    }

    private func runFFmpeg(_ arguments: [String], tools: ToolPaths) async throws {
        let result = try await ProcessRunner.run(executable: tools.ffmpeg, arguments: arguments)
        guard result.succeeded else {
            throw XCTSkip("ffmpeg could not build the fixture: \(result.standardError)")
        }
    }

    private func probe(_ url: URL, tools: ToolPaths) async throws -> ProbeResult {
        let lines = LineBox()
        let result = try await ProcessRunner.run(
            executable: tools.ffprobe,
            arguments: FFmpegCommand.probeArguments(input: url.path),
            onStandardOutputLine: { lines.append($0) }
        )
        XCTAssertTrue(result.succeeded, result.standardError)
        return try ProbeResult.decode(Data(lines.text().utf8))
    }

    /// Skips the test when ffmpeg was built without one of the encoders it needs.
    private func requireEncoders(_ names: [String], _ tools: ToolPaths) async throws {
        let lines = LineBox()
        _ = try await ProcessRunner.run(
            executable: tools.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-encoders"],
            onStandardOutputLine: { lines.append($0) }
        )
        let available = lines.text()
        for name in names where !available.contains(name) {
            throw XCTSkip("this ffmpeg has no \(name) encoder")
        }
    }
}

private final class LineBox: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private var snapshots: [RemuxProgress] = []
    private let lock = NSLock()

    func record(_ progress: RemuxProgress) {
        lock.lock(); snapshots.append(progress); lock.unlock()
    }

    func positions() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        return snapshots.map(\.outTimeSeconds)
    }

    func sawFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return snapshots.contains(where: \.isFinished)
    }
}
