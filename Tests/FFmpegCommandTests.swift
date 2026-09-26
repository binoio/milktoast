import XCTest
@testable import MilktoastCore

final class FFmpegCommandTests: XCTestCase {
    func testProbeArgumentsRequestEverythingAsJSON() {
        let args = FFmpegCommand.probeArguments(input: "/movies/a.mkv")
        XCTAssertEqual(args.last, "/movies/a.mkv")
        XCTAssertTrue(args.contains("-show_streams"))
        XCTAssertTrue(args.contains("-show_chapters"))
        XCTAssertTrue(args.contains("-show_format"))
        XCTAssertEqual(args[args.firstIndex(of: "-print_format")! + 1], "json")
    }

    func testPureRemuxCommand() throws {
        let plan = try RemuxPlanner(capabilities: Fixtures.macOS14)
            .makePlan(from: try Fixtures.probe("h264-aac-srt"))
        let args = FFmpegCommand.remuxArguments(input: "in.mkv", output: "out.mov", plan: plan)

        XCTAssertEqual(Array(args[0..<9]), [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-progress", "pipe:1", "-y", "-i", "in.mkv",
        ])
        assertAdjacent(args, "-c:v:0", "copy")
        assertAdjacent(args, "-c:a:0", "copy")
        assertAdjacent(args, "-c:s:0", "mov_text")
        assertAdjacent(args, "-metadata:s:s:0", "language=eng")
        assertAdjacent(args, "-f", "mp4")
        XCTAssertEqual(args.last, "out.mov")
        XCTAssertFalse(args.contains("-tag:v:0"), "8-bit H.264 needs no sample-entry override")
    }

    func testHEVCGetsTheHVC1Tag() throws {
        let plan = try RemuxPlanner(capabilities: Fixtures.macOS14)
            .makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        let args = FFmpegCommand.remuxArguments(input: "in.mkv", output: "out.mov", plan: plan)
        assertAdjacent(args, "-c:v:0", "copy")
        assertAdjacent(args, "-tag:v:0", "hvc1")
    }

    func testMultipleAudioTracksGetIndependentCodecFlags() throws {
        let plan = try RemuxPlanner(capabilities: Fixtures.macOS14)
            .makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        let args = FFmpegCommand.remuxArguments(input: "in.mkv", output: "out.mov", plan: plan)
        assertAdjacent(args, "-c:a:0", "ac3")
        assertAdjacent(args, "-b:a:0", "640k")
        assertAdjacent(args, "-c:a:1", "copy")
        // The maps name input stream indices, not output ordinals.
        XCTAssertEqual(mapArguments(args), ["0:0", "0:1", "0:2", "0:4"])
    }

    func testChaptersAreExplicitlyMappedOrSuppressed() throws {
        let planner = RemuxPlanner(capabilities: Fixtures.macOS14)
        let withChapters = try planner.makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        assertAdjacent(
            FFmpegCommand.remuxArguments(input: "i", output: "o", plan: withChapters),
            "-map_chapters", "0"
        )

        var options = RemuxOptions.default
        options.includeChapters = false
        let without = try RemuxPlanner(capabilities: Fixtures.macOS14, options: options)
            .makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        assertAdjacent(
            FFmpegCommand.remuxArguments(input: "i", output: "o", plan: without),
            "-map_chapters", "-1"
        )
    }

    func testDefaultAudioTrackIsMarkedAndOthersCleared() throws {
        let plan = try RemuxPlanner(capabilities: Fixtures.macOS14)
            .makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        let args = FFmpegCommand.remuxArguments(input: "i", output: "o", plan: plan)
        assertAdjacent(args, "-disposition:a:0", "default")
        assertAdjacent(args, "-disposition:a:1", "0")
    }

    func testTheFirstAudioTrackBecomesDefaultWhenTheSourceFlaggedNone() {
        let plan = RemuxPlan(
            video: [PlannedVideo(
                stream: PlannedStream(inputIndex: 0, outputOrdinal: 0, kind: .video, sourceCodec: "h264"),
                action: .copy(tag: nil)
            )],
            audio: [
                PlannedAudio(
                    stream: PlannedStream(inputIndex: 1, outputOrdinal: 0, kind: .audio, sourceCodec: "aac"),
                    action: .copy
                ),
                PlannedAudio(
                    stream: PlannedStream(inputIndex: 2, outputOrdinal: 1, kind: .audio, sourceCodec: "aac"),
                    action: .copy
                ),
            ]
        )
        let args = FFmpegCommand.remuxArguments(input: "i", output: "o", plan: plan)
        assertAdjacent(args, "-disposition:a:0", "default")
        assertAdjacent(args, "-disposition:a:1", "0")
    }

    func testNoFaststartPassBecauseThePlaybackIsLocal() throws {
        let plan = try RemuxPlanner(capabilities: Fixtures.macOS14)
            .makePlan(from: try Fixtures.probe("h264-aac-srt"))
        let args = FFmpegCommand.remuxArguments(input: "i", output: "o", plan: plan)
        XCTAssertFalse(args.joined(separator: " ").contains("faststart"),
                       "faststart would rewrite the whole file for no local benefit")
    }

    func testNegativeTimestampsAreShiftedForMOV() throws {
        let plan = try RemuxPlanner(capabilities: Fixtures.macOS14)
            .makePlan(from: try Fixtures.probe("h264-aac-srt"))
        assertAdjacent(
            FFmpegCommand.remuxArguments(input: "i", output: "o", plan: plan),
            "-avoid_negative_ts", "make_zero"
        )
    }

    func testVideoReencodeCarriesBitrateAndPixelFormat() throws {
        let plan = try RemuxPlanner(capabilities: Fixtures.macOS14)
            .makePlan(from: try Fixtures.probe("vp9-opus-attached-pic"))
        let args = FFmpegCommand.remuxArguments(input: "i", output: "o", plan: plan)
        assertAdjacent(args, "-c:v:0", "h264_videotoolbox")
        assertAdjacent(args, "-pix_fmt:v:0", "yuv420p")
        XCTAssertTrue(args.contains("-allow_sw:v:0"))
    }

    func testSoftwareEncoderGetsPresetAndCRF() {
        let plan = RemuxPlan(video: [
            PlannedVideo(
                stream: PlannedStream(inputIndex: 0, outputOrdinal: 0, kind: .video, sourceCodec: "vp9"),
                action: .transcode(encoder: "libx264", bitrateKbps: nil)
            )
        ])
        let args = FFmpegCommand.remuxArguments(input: "i", output: "o", plan: plan)
        assertAdjacent(args, "-preset:v:0", "veryfast")
        assertAdjacent(args, "-crf:v:0", "20")
    }

    func testTheOutputFormatFollowsThePlansContainer() {
        let stream = PlannedStream(inputIndex: 0, outputOrdinal: 0, kind: .video, sourceCodec: "prores")
        let plan = RemuxPlan(
            container: .mov,
            video: [PlannedVideo(stream: stream, action: .copy(tag: nil))]
        )
        assertAdjacent(FFmpegCommand.remuxArguments(input: "i", output: "o", plan: plan), "-f", "mov")
    }

    func testDescribeQuotesArgumentsContainingSpaces() {
        let text = FFmpegCommand.describe("/usr/bin/ffmpeg", ["-i", "/Movies/My Film.mkv"])
        XCTAssertEqual(text, "/usr/bin/ffmpeg -i '/Movies/My Film.mkv'")
    }

    // MARK: - Helpers

    private func mapArguments(_ args: [String]) -> [String] {
        var values: [String] = []
        for (index, argument) in args.enumerated() where argument == "-map" {
            values.append(args[index + 1])
        }
        return values
    }

    private func assertAdjacent(
        _ args: [String],
        _ flag: String,
        _ value: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let index = args.firstIndex(of: flag) else {
            return XCTFail("missing \(flag) in \(args.joined(separator: " "))", file: file, line: line)
        }
        XCTAssertEqual(args[index + 1], value, "\(flag) value", file: file, line: line)
    }
}
