import XCTest
@testable import MilktoastCore

final class RemuxPlannerTests: XCTestCase {
    private func planner(
        _ capabilities: PlaybackCapabilities = Fixtures.macOS14,
        _ options: RemuxOptions = .default
    ) -> RemuxPlanner {
        RemuxPlanner(capabilities: capabilities, options: options)
    }

    func testPlansAFullFeatureFile() throws {
        let plan = try planner().makePlan(from: try Fixtures.probe("hevc-dts-pgs"))

        XCTAssertEqual(plan.video.count, 1)
        XCTAssertEqual(plan.video[0].action, .copy(tag: "hvc1"))

        // Both audio tracks survive; the DTS one is converted, the AC-3 copied.
        XCTAssertEqual(plan.audio.count, 2)
        XCTAssertEqual(plan.audio[0].action, .transcode(codec: "ac3", bitrateKbps: 640, channels: nil))
        XCTAssertEqual(plan.audio[1].action, .copy)
        XCTAssertEqual(plan.audio.map(\.stream.outputOrdinal), [0, 1])
        XCTAssertEqual(plan.audio.map(\.stream.language), ["eng", "fra"])

        // The SRT track converts; the PGS track cannot.
        XCTAssertEqual(plan.subtitles.count, 1)
        XCTAssertEqual(plan.subtitles[0].stream.inputIndex, 4)
        XCTAssertEqual(plan.subtitles[0].action, .timedText)

        XCTAssertTrue(plan.includeChapters)
        XCTAssertEqual(plan.sourceTitle, "Example Feature")
        XCTAssertFalse(plan.isPureRemux, "the DTS track forces an audio encode")
        XCTAssertFalse(plan.requiresVideoEncode)
        XCTAssertTrue(plan.requiresAudioEncode)
    }

    func testAPlainH264FileIsAPureStreamCopy() throws {
        let plan = try planner().makePlan(from: try Fixtures.probe("h264-aac-srt"))
        XCTAssertTrue(plan.isPureRemux)
        XCTAssertFalse(plan.requiresVideoEncode)
        XCTAssertFalse(plan.requiresAudioEncode)
        XCTAssertFalse(plan.includeChapters, "the fixture has no chapters")
        XCTAssertEqual(plan.durationSeconds ?? 0, 2645.312, accuracy: 0.001)
    }

    func testCoverArtIsNotMistakenForTheFeature() throws {
        let plan = try planner().makePlan(from: try Fixtures.probe("vp9-opus-attached-pic"))
        XCTAssertEqual(plan.video.count, 1)
        XCTAssertEqual(plan.video[0].stream.inputIndex, 0, "the VP9 track is the movie, not the cover JPEG")
        guard case .transcode = plan.video[0].action else {
            return XCTFail("VP9 needs a re-encode")
        }
    }

    func testOrdinaryFilesTargetMP4SoSubtitlesBecomeSelectableTracks() throws {
        XCTAssertEqual(try planner().makePlan(from: try Fixtures.probe("h264-aac-srt")).container, .mp4)
        XCTAssertEqual(try planner().makePlan(from: try Fixtures.probe("hevc-dts-pgs")).container, .mp4)
    }

    func testProResFallsBackToMOVBecauseMP4HasNoSampleEntryForIt() throws {
        let probe = ProbeResult(streams: [
            ProbeStream(index: 0, codecName: "prores", codecType: "video", disposition: ["default": 1]),
            ProbeStream(index: 1, codecName: "aac", codecType: "audio", channels: 2),
        ])
        XCTAssertEqual(try planner().makePlan(from: probe).container, .mov)
    }

    func testCopiedPCMAudioForcesMOV() throws {
        let probe = ProbeResult(streams: [
            ProbeStream(index: 0, codecName: "h264", codecType: "video", pixFmt: "yuv420p", disposition: ["default": 1]),
            ProbeStream(index: 1, codecName: "pcm_s24le", codecType: "audio", channels: 2),
        ])
        XCTAssertEqual(try planner().makePlan(from: probe).container, .mov)
    }

    func testStreamsBeingReencodedNeverForceTheOlderContainer() throws {
        // Only a *copied* MOV-only codec matters. Once a stream is being
        // re-encoded its output codec is MP4-compatible by construction.
        let probe = ProbeResult(streams: [
            ProbeStream(index: 0, codecName: "vp9", codecType: "video", pixFmt: "yuv420p", disposition: ["default": 1]),
            ProbeStream(index: 1, codecName: "dts", codecType: "audio", channels: 6),
        ])
        XCTAssertEqual(try planner().makePlan(from: probe).container, .mp4)
    }

    func testMissingVideoIsAnError() {
        let probe = ProbeResult(streams: [
            ProbeStream(index: 0, codecName: "flac", codecType: "audio", channels: 2)
        ])
        XCTAssertThrowsError(try planner().makePlan(from: probe)) { error in
            XCTAssertEqual(error as? RemuxPlannerError, .noVideoStream)
        }
    }

    func testFirstAudioOnlyKeepsTheDefaultTrack() throws {
        var options = RemuxOptions.default
        options.includeAllAudioTracks = false
        let plan = try planner(Fixtures.macOS14, options).makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        XCTAssertEqual(plan.audio.count, 1)
        XCTAssertEqual(plan.audio[0].stream.inputIndex, 1, "index 1 carries disposition default")
    }

    func testSubtitlesDisabledProducesNoSubtitleStreams() throws {
        var options = RemuxOptions.default
        options.includeSubtitles = false
        let plan = try planner(Fixtures.macOS14, options).makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        XCTAssertTrue(plan.subtitles.isEmpty)
    }

    func testChaptersCanBeSuppressed() throws {
        var options = RemuxOptions.default
        options.includeChapters = false
        let plan = try planner(Fixtures.macOS14, options).makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        XCTAssertFalse(plan.includeChapters)
    }

    func testWarningsExplainEveryLossyDecision() throws {
        let plan = try planner().makePlan(from: try Fixtures.probe("hevc-dts-pgs"))
        let messages = plan.warnings.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("hvc1"), messages)
        XCTAssertTrue(messages.contains("AC3"), messages)
        XCTAssertTrue(messages.lowercased().contains("image-based subtitle"), messages)
    }

    func testVideoReencodeIsFlaggedAsSlow() throws {
        let plan = try planner().makePlan(from: try Fixtures.probe("vp9-opus-attached-pic"))
        let warning = try XCTUnwrap(plan.warnings.first { $0.severity == .warning })
        XCTAssertTrue(warning.message.contains("re-encoding"), warning.message)
    }

    func testSilentResultIsCalledOut() throws {
        let probe = ProbeResult(streams: [
            ProbeStream(index: 0, codecName: "h264", codecType: "video", pixFmt: "yuv420p"),
        ])
        let plan = try planner().makePlan(from: probe)
        XCTAssertTrue(plan.audio.isEmpty)
        XCTAssertTrue(plan.isPureRemux)
    }
}
