import XCTest
@testable import MilktoastCore

final class ProgressParserTests: XCTestCase {
    func testEmitsOnlyWhenABlockCloses() {
        var parser = ProgressParser()
        XCTAssertNil(parser.consume(line: "frame=120"))
        XCTAssertNil(parser.consume(line: "fps=240.5"))
        XCTAssertNil(parser.consume(line: "out_time_us=5000000"))
        XCTAssertNil(parser.consume(line: "speed=18.2x"))
        let snapshot = parser.consume(line: "progress=continue")
        XCTAssertEqual(snapshot?.outTimeSeconds, 5)
        XCTAssertEqual(snapshot?.frame, 120)
        XCTAssertEqual(snapshot?.fps ?? 0, 240.5, accuracy: 0.001)
        XCTAssertEqual(snapshot?.speed ?? 0, 18.2, accuracy: 0.001)
        XCTAssertEqual(snapshot?.isFinished, false)
    }

    func testEndBlockMarksCompletion() {
        var parser = ProgressParser()
        _ = parser.consume(line: "out_time_us=90000000")
        let snapshot = parser.consume(line: "progress=end")
        XCTAssertEqual(snapshot?.isFinished, true)
        XCTAssertEqual(snapshot?.fraction(ofDuration: 3600), 1)
    }

    func testFieldsDoNotLeakBetweenBlocks() {
        var parser = ProgressParser()
        _ = parser.consume(line: "speed=10.0x")
        _ = parser.consume(line: "out_time_us=1000000")
        _ = parser.consume(line: "progress=continue")

        _ = parser.consume(line: "out_time_us=2000000")
        let second = parser.consume(line: "progress=continue")
        XCTAssertNil(second?.speed, "speed was only reported in the first block")
    }

    func testChunkParsingHandlesMultipleBlocks() {
        var parser = ProgressParser()
        let chunk = """
        out_time_us=1000000
        speed=4.0x
        progress=continue
        out_time_us=2000000
        speed=4.5x
        progress=continue
        """
        let snapshots = parser.consume(chunk: chunk)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].outTimeSeconds, 1)
        XCTAssertEqual(snapshots[1].outTimeSeconds, 2)
    }

    func testSpeedOfNAIsIgnored() {
        var parser = ProgressParser()
        _ = parser.consume(line: "speed=N/A")
        _ = parser.consume(line: "out_time_us=0")
        XCTAssertNil(parser.consume(line: "progress=continue")?.speed)
    }

    func testOutTimeMillisKeyIsActuallyMicroseconds() {
        // ffmpeg's `out_time_ms` has carried microseconds for years despite the name.
        var parser = ProgressParser()
        _ = parser.consume(line: "out_time_ms=7500000")
        XCTAssertEqual(parser.consume(line: "progress=continue")?.outTimeSeconds, 7.5)
    }

    func testFallsBackToClockFormattedOutTime() {
        var parser = ProgressParser()
        _ = parser.consume(line: "out_time=00:01:30.500000")
        XCTAssertEqual(parser.consume(line: "progress=continue")?.outTimeSeconds ?? 0, 90.5, accuracy: 0.001)
    }

    func testClockParsing() {
        XCTAssertEqual(ProgressParser.parseClock("00:00:05.250") ?? 0, 5.25, accuracy: 0.0001)
        XCTAssertEqual(ProgressParser.parseClock("01:02:03") ?? 0, 3723, accuracy: 0.0001)
        XCTAssertEqual(ProgressParser.parseClock("42") ?? 0, 42, accuracy: 0.0001)
        XCTAssertNil(ProgressParser.parseClock("not a time"))
    }

    func testFractionIsClampedAndNilWithoutDuration() {
        let progress = RemuxProgress(outTimeSeconds: 120)
        XCTAssertEqual(progress.fraction(ofDuration: 60), 1, "never report more than 100%")
        XCTAssertNil(progress.fraction(ofDuration: nil))
        XCTAssertNil(progress.fraction(ofDuration: 0))
        XCTAssertEqual(progress.fraction(ofDuration: 240), 0.5)
    }

    func testEstimatedRemainingUsesFFmpegsSpeed() {
        let progress = RemuxProgress(outTimeSeconds: 100, speed: 10)
        // 900s of movie left at 10x realtime.
        XCTAssertEqual(progress.estimatedSecondsRemaining(duration: 1000) ?? 0, 90, accuracy: 0.001)
        XCTAssertNil(RemuxProgress(outTimeSeconds: 100).estimatedSecondsRemaining(duration: 1000))
        XCTAssertEqual(RemuxProgress(outTimeSeconds: 1000, speed: 5).estimatedSecondsRemaining(duration: 1000), 0)
    }

    func testMalformedLinesAreIgnored() {
        var parser = ProgressParser()
        XCTAssertNil(parser.consume(line: ""))
        XCTAssertNil(parser.consume(line: "garbage without equals"))
        _ = parser.consume(line: "out_time_us=1000000")
        XCTAssertNotNil(parser.consume(line: "progress=continue"))
    }
}
