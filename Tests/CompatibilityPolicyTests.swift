import XCTest
@testable import MilktoastCore

final class CompatibilityPolicyTests: XCTestCase {
    private func policy(
        _ capabilities: PlaybackCapabilities = Fixtures.macOS14,
        _ options: RemuxOptions = .default
    ) -> CompatibilityPolicy {
        CompatibilityPolicy(capabilities: capabilities, options: options)
    }

    private func video(_ codec: String, pixFmt: String? = "yuv420p", profile: String? = nil, bitRate: String? = nil) -> ProbeStream {
        ProbeStream(index: 0, codecName: codec, codecType: "video", profile: profile, pixFmt: pixFmt, width: 1920, height: 1080, bitRate: bitRate)
    }

    private func audio(_ codec: String, channels: Int = 2) -> ProbeStream {
        ProbeStream(index: 1, codecName: codec, codecType: "audio", channels: channels)
    }

    private func subtitle(_ codec: String) -> ProbeStream {
        ProbeStream(index: 2, codecName: codec, codecType: "subtitle")
    }

    // MARK: - Video

    func testHEVCIsCopiedWithHVC1Tag() {
        // The single most important decision in the app: `hev1` plays black in
        // QuickTime, `hvc1` plays correctly.
        XCTAssertEqual(policy().action(forVideo: video("hevc", pixFmt: "yuv420p10le")), .copy(tag: "hvc1"))
    }

    func testEightBitH264IsCopiedUntagged() {
        XCTAssertEqual(policy().action(forVideo: video("h264")), .copy(tag: nil))
    }

    func testTenBitH264IsReencodedBecauseAppleCannotDecodeHigh10() {
        let action = policy().action(forVideo: video("h264", pixFmt: "yuv420p10le", profile: "High 10"))
        guard case .transcode(let encoder, _) = action else {
            return XCTFail("expected a re-encode, got \(action)")
        }
        XCTAssertEqual(encoder, "hevc_videotoolbox")
    }

    func testVP9AlwaysNeedsReencoding() {
        let action = policy().action(forVideo: video("vp9"))
        guard case .transcode(let encoder, _) = action else {
            return XCTFail("expected a re-encode, got \(action)")
        }
        XCTAssertEqual(encoder, "h264_videotoolbox")
    }

    func testAV1IsCopiedOnMacOS14AndReencodedBefore() {
        XCTAssertEqual(policy(Fixtures.macOS14).action(forVideo: video("av1")), .copy(tag: "av01"))
        guard case .transcode = policy(Fixtures.macOS13).action(forVideo: video("av1")) else {
            return XCTFail("macOS 13 has no AV1 decoder")
        }
    }

    func testProResAndMJPEGAreCopied() {
        XCTAssertEqual(policy().action(forVideo: video("prores")), .copy(tag: nil))
        XCTAssertEqual(policy().action(forVideo: video("mjpeg")), .copy(tag: nil))
    }

    func testSoftwareEncoderIsUsedWhenVideoToolboxIsUnavailable() {
        let action = policy(Fixtures.noHardware).action(forVideo: video("vp9"))
        guard case .transcode(let encoder, _) = action else {
            return XCTFail("expected a re-encode")
        }
        XCTAssertEqual(encoder, "libx264")
    }

    func testHardwareEncodingCanBeDisabledByPreference() {
        var options = RemuxOptions.default
        options.preferHardwareEncoding = false
        let action = policy(Fixtures.macOS14, options).action(forVideo: video("vp9"))
        guard case .transcode(let encoder, _) = action else {
            return XCTFail("expected a re-encode")
        }
        XCTAssertEqual(encoder, "libx264")
    }

    func testReencodeBitrateFollowsSourceAndRespectsCeiling() {
        let subject = policy()
        XCTAssertEqual(subject.targetVideoBitrateKbps(for: video("vp9", bitRate: "6000000")), 6000)
        // A 60 Mbps source is clamped to the 20 Mbps default ceiling.
        XCTAssertEqual(subject.targetVideoBitrateKbps(for: video("vp9", bitRate: "60000000")), 20000)
    }

    func testReencodeBitrateFallsBackToResolutionHeuristic() {
        let stream = ProbeStream(index: 0, codecName: "vp9", codecType: "video", width: 3840, height: 2160)
        XCTAssertEqual(policy().targetVideoBitrateKbps(for: stream), 16000)
    }

    // MARK: - Audio

    func testQuickTimeNativeAudioIsCopied() {
        for codec in ["aac", "ac3", "eac3", "alac", "mp3", "pcm_s16le"] {
            XCTAssertEqual(policy().action(forAudio: audio(codec)), .copy, "\(codec) should be copied")
        }
    }

    func testSurroundDTSBecomesAC3AtFullRate() {
        XCTAssertEqual(
            policy().action(forAudio: audio("dts", channels: 6)),
            .transcode(codec: "ac3", bitrateKbps: 640, channels: nil)
        )
    }

    func testSevenPointOneFallsBackToEAC3BecauseAC3CapsAtSixChannels() {
        guard case .transcode(let codec, _, _) = policy().action(forAudio: audio("dts", channels: 8)) else {
            return XCTFail("expected a conversion")
        }
        XCTAssertEqual(codec, "eac3")
    }

    func testStereoOpusBecomesAACAtThePreferredBitrate() {
        var options = RemuxOptions.default
        options.stereoBitrateKbps = 192
        XCTAssertEqual(
            policy(Fixtures.macOS14, options).action(forAudio: audio("opus")),
            .transcode(codec: "aac", bitrateKbps: 192, channels: nil)
        )
    }

    func testLosslessSourcesStayLosslessAsALAC() {
        XCTAssertEqual(
            policy().action(forAudio: audio("flac", channels: 2)),
            .transcode(codec: "alac", bitrateKbps: nil, channels: nil)
        )
        XCTAssertEqual(
            policy().action(forAudio: audio("truehd", channels: 6)),
            .transcode(codec: "alac", bitrateKbps: nil, channels: nil)
        )
    }

    func testLosslessPreservationCanBeTurnedOff() {
        var options = RemuxOptions.default
        options.preserveLosslessAudioAsALAC = false
        guard case .transcode(let codec, _, _) = policy(Fixtures.macOS14, options).action(forAudio: audio("flac", channels: 6)) else {
            return XCTFail("expected a conversion")
        }
        XCTAssertEqual(codec, "ac3")
    }

    func testMoreThanEightChannelsCannotUseALAC() {
        guard case .transcode(let codec, _, _) = policy().action(forAudio: audio("truehd", channels: 10)) else {
            return XCTFail("expected a conversion")
        }
        XCTAssertEqual(codec, "eac3")
    }

    func testSurroundTargetPreferenceIsHonoured() {
        var options = RemuxOptions.default
        options.surroundTarget = .aac
        guard case .transcode(let codec, let bitrate, _) = policy(Fixtures.macOS14, options).action(forAudio: audio("dts", channels: 6)) else {
            return XCTFail("expected a conversion")
        }
        XCTAssertEqual(codec, "aac")
        XCTAssertEqual(bitrate, 576)
    }

    // MARK: - Subtitles

    func testTextSubtitlesBecomeTimedText() {
        for codec in ["subrip", "ass", "ssa", "webvtt", "mov_text"] {
            XCTAssertEqual(policy().action(forSubtitle: subtitle(codec)), .timedText, "\(codec) should convert")
        }
    }

    func testBitmapSubtitlesAreDroppedWithAnExplanation() {
        guard case .drop(let reason) = policy().action(forSubtitle: subtitle("hdmv_pgs_subtitle")) else {
            return XCTFail("PGS cannot be stored in a .mov")
        }
        XCTAssertTrue(reason.contains("bitmap"), reason)
    }

    func testSubtitlesCanBeDisabledEntirely() {
        var options = RemuxOptions.default
        options.includeSubtitles = false
        guard case .drop = policy(Fixtures.macOS14, options).action(forSubtitle: subtitle("subrip")) else {
            return XCTFail("expected subtitles to be skipped")
        }
    }
}
