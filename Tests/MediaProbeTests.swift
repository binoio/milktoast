import XCTest
@testable import MilktoastCore

final class MediaProbeTests: XCTestCase {
    func testDecodesStreamsChaptersAndFormat() throws {
        let probe = try Fixtures.probe("hevc-dts-pgs")
        XCTAssertEqual(probe.streams.count, 6)
        XCTAssertEqual(probe.chapters.count, 2)
        XCTAssertEqual(probe.format?.formatName, "matroska,webm")
        XCTAssertEqual(probe.duration ?? 0, 1800.048, accuracy: 0.001)
        XCTAssertEqual(probe.format?.title, "Example Feature")
    }

    func testClassifiesStreamKinds() throws {
        let probe = try Fixtures.probe("hevc-dts-pgs")
        XCTAssertEqual(probe.streams(of: .video).count, 1)
        XCTAssertEqual(probe.streams(of: .audio).count, 2)
        XCTAssertEqual(probe.streams(of: .subtitle).count, 2)
        XCTAssertEqual(probe.streams(of: .attachment).count, 1)
    }

    func testTagLookupIsCaseInsensitive() throws {
        let probe = try Fixtures.probe("hevc-dts-pgs")
        // This stream carries LANGUAGE/TITLE in upper case, as mkvmerge writes them.
        let subtitle = try XCTUnwrap(probe.streams.first { $0.index == 4 })
        XCTAssertEqual(subtitle.language, "eng")
        XCTAssertEqual(subtitle.title, "English (SDH)")
    }

    func testHighBitDepthDetection() throws {
        let probe = try Fixtures.probe("hevc-dts-pgs")
        let video = try XCTUnwrap(probe.streams(of: .video).first)
        XCTAssertTrue(video.isHighBitDepth, "yuv420p10le is 10-bit")

        let eightBit = try Fixtures.probe("h264-aac-srt").streams(of: .video)[0]
        XCTAssertFalse(eightBit.isHighBitDepth)
    }

    func testDispositionAccessors() throws {
        let probe = try Fixtures.probe("hevc-dts-pgs")
        XCTAssertTrue(probe.streams[0].isDefault)
        XCTAssertFalse(probe.streams[2].isDefault)
        XCTAssertFalse(probe.streams[0].isForced)
    }

    func testBitRateParsing() throws {
        let video = try Fixtures.probe("hevc-dts-pgs").streams(of: .video)[0]
        XCTAssertEqual(video.bitsPerSecond, 18_500_000)
    }

    func testMissingSectionsDecodeToEmpty() throws {
        let probe = try ProbeResult.decode(Data(#"{"streams":[]}"#.utf8))
        XCTAssertTrue(probe.streams.isEmpty)
        XCTAssertTrue(probe.chapters.isEmpty)
        XCTAssertNil(probe.format)
        XCTAssertNil(probe.duration)
    }

    func testZeroDurationIsTreatedAsUnknown() throws {
        let probe = try ProbeResult.decode(Data(#"{"format":{"duration":"0.000000"}}"#.utf8))
        XCTAssertNil(probe.duration)
    }
}
