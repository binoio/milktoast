import XCTest
@testable import MilktoastCore

final class SidecarNamingTests: XCTestCase {
    func testPrimaryNameIsTheObviousOne() {
        XCTAssertEqual(SidecarNaming.primary(sourceName: "Episode.mkv", container: .mp4), "Episode.mp4")
        XCTAssertEqual(
            SidecarNaming.primary(sourceName: "S04E08.1080p.WEB.mkv", container: .mp4),
            "S04E08.1080p.WEB.mp4"
        )
        XCTAssertEqual(SidecarNaming.primary(sourceName: "NoExtension", container: .mov), "NoExtension.mov")
        XCTAssertEqual(SidecarNaming.primary(sourceName: ".hidden", container: .mp4), ".hidden.mp4")
    }

    func testAlternatesAreNumberedAfterTheFirst() {
        XCTAssertEqual(
            SidecarNaming.alternate(sourceName: "Episode.mkv", container: .mp4, index: 1),
            "Episode (Milktoast).mp4"
        )
        XCTAssertEqual(
            SidecarNaming.alternate(sourceName: "Episode.mkv", container: .mp4, index: 2),
            "Episode (Milktoast 2).mp4"
        )
    }

    func testScratchNameIsHiddenAndUnmistakable() {
        let partial = SidecarNaming.partial(for: "Episode.mp4")
        XCTAssertTrue(partial.hasPrefix("."), "a half-written file should not show up in Finder")
        XCTAssertTrue(partial.contains("milktoast-partial"))
        XCTAssertNotEqual(partial, "Episode.mp4")
    }
}

final class SidecarPlannerTests: XCTestCase {
    private let stamp = "abc123"

    private func decide(
        sourceName: String = "Episode.mkv",
        container: OutputContainer = .mp4,
        expected: String? = nil,
        files: [String: SidecarFileState]
    ) -> SidecarDecision {
        SidecarPlanner.decide(
            sourceName: sourceName,
            container: container,
            expectedStamp: expected ?? stamp,
            inspect: { files[$0] ?? .absent }
        )
    }

    func testEmptyFolderGetsTheObviousName() {
        XCTAssertEqual(decide(files: [:]), .write(fileName: "Episode.mp4"))
    }

    func testOurOwnCurrentOutputIsReused() {
        XCTAssertEqual(
            decide(files: ["Episode.mp4": .ours(stamp: stamp)]),
            .reuse(fileName: "Episode.mp4")
        )
    }

    func testOurOwnStaleOutputIsRebuiltInPlace() {
        // The source or the settings changed; the file is ours, so replace it
        // rather than littering the folder with a second copy.
        XCTAssertEqual(
            decide(files: ["Episode.mp4": .ours(stamp: "old")]),
            .write(fileName: "Episode.mp4")
        )
    }

    func testSomeoneElsesFileIsNeverOverwritten() {
        XCTAssertEqual(
            decide(files: ["Episode.mp4": .foreign]),
            .write(fileName: "Episode (Milktoast).mp4")
        )
    }

    func testDisambiguationKeepsCountingPastForeignFiles() {
        XCTAssertEqual(
            decide(files: [
                "Episode.mp4": .foreign,
                "Episode (Milktoast).mp4": .foreign,
                "Episode (Milktoast 2).mp4": .foreign,
            ]),
            .write(fileName: "Episode (Milktoast 3).mp4")
        )
    }

    func testAnEarlierAlternateOfOursIsReusedRatherThanAddingAnother() {
        XCTAssertEqual(
            decide(files: [
                "Episode.mp4": .foreign,
                "Episode (Milktoast).mp4": .ours(stamp: stamp),
            ]),
            .reuse(fileName: "Episode (Milktoast).mp4")
        )
    }

    func testTheSourceItselfIsNeverATarget() {
        // A `.mov` source would otherwise resolve to its own name — writing over
        // the file being read is the one unrecoverable mistake available here.
        XCTAssertEqual(
            decide(sourceName: "Clip.mov", container: .mov, files: [:]),
            .write(fileName: "Clip (Milktoast).mov")
        )
    }

    func testRunningOutOfNamesIsReportedRatherThanGuessed() {
        var crowded: [String: SidecarFileState] = ["Episode.mp4": .foreign]
        for index in 1...20 {
            crowded[SidecarNaming.alternate(sourceName: "Episode.mkv", container: .mp4, index: index)] = .foreign
        }
        XCTAssertEqual(decide(files: crowded), .noRoom)
    }

    func testContainerDrivesTheExtension() {
        XCTAssertEqual(decide(container: .mov, files: [:]), .write(fileName: "Episode.mov"))
    }
}
