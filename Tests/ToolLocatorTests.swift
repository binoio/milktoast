import XCTest
@testable import MilktoastCore

final class ToolLocatorTests: XCTestCase {
    func testBundledHelpersWinOverHomebrew() throws {
        let present: Set<String> = [
            "/Apps/Milktoast.app/Contents/Helpers/ffmpeg",
            "/Apps/Milktoast.app/Contents/Helpers/ffprobe",
            "/opt/homebrew/bin/ffmpeg",
            "/opt/homebrew/bin/ffprobe",
        ]
        let locator = ToolLocator(
            bundledDirectory: "/Apps/Milktoast.app/Contents/Helpers",
            fileExists: { present.contains($0) }
        )
        let tools = try locator.locate()
        XCTAssertEqual(tools.ffmpeg, "/Apps/Milktoast.app/Contents/Helpers/ffmpeg")
        XCTAssertEqual(tools.ffprobe, "/Apps/Milktoast.app/Contents/Helpers/ffprobe")
    }

    func testFallsBackThroughPATHThenSystemPrefixes() throws {
        let present: Set<String> = ["/Users/me/bin/ffmpeg", "/usr/local/bin/ffprobe"]
        let locator = ToolLocator(
            extraDirectories: ["/Users/me/bin"],
            fileExists: { present.contains($0) }
        )
        let tools = try locator.locate()
        XCTAssertEqual(tools.ffmpeg, "/Users/me/bin/ffmpeg")
        XCTAssertEqual(tools.ffprobe, "/usr/local/bin/ffprobe")
    }

    func testMissingToolReportsWhereItLooked() {
        let locator = ToolLocator(fileExists: { _ in false })
        XCTAssertThrowsError(try locator.locate()) { error in
            guard case .missing(let tool, let searched) = error as? ToolLocatorError else {
                return XCTFail("expected ToolLocatorError, got \(error)")
            }
            XCTAssertEqual(tool, "ffmpeg")
            XCTAssertTrue(searched.contains("/opt/homebrew/bin"))
        }
    }

    func testDuplicateDirectoriesAreSearchedOnce() throws {
        var probed: [String] = []
        let locator = ToolLocator(
            bundledDirectory: "/opt/homebrew/bin",
            extraDirectories: ["/opt/homebrew/bin", "/usr/bin"],
            fileExists: { path in
                probed.append(path)
                return false
            }
        )
        XCTAssertThrowsError(try locator.find("ffmpeg"))
        XCTAssertEqual(probed.filter { $0 == "/opt/homebrew/bin/ffmpeg" }.count, 1)
    }

    func testPATHSplitting() {
        XCTAssertEqual(
            ToolLocator.directories(fromPATH: "/a:/b::/c"),
            ["/a", "/b", "/c"]
        )
        XCTAssertTrue(ToolLocator.directories(fromPATH: nil).isEmpty)
        XCTAssertTrue(ToolLocator.directories(fromPATH: "").isEmpty)
    }

    func testPerUserHomebrewPrefixesAreSearchable() throws {
        // An app launched from Finder gets launchd's minimal PATH, so a Homebrew
        // install under the home directory has to be found without it.
        let present: Set<String> = ["/Users/me/.homebrew/bin/ffmpeg", "/Users/me/.homebrew/bin/ffprobe"]
        let locator = ToolLocator(
            extraDirectories: ToolLocator.userHomebrewDirectories(home: "/Users/me"),
            fileExists: { present.contains($0) }
        )
        XCTAssertEqual(try locator.locate().ffmpeg, "/Users/me/.homebrew/bin/ffmpeg")
    }

    func testUserHomebrewDirectoriesCoverBothConventions() {
        XCTAssertEqual(
            ToolLocator.userHomebrewDirectories(home: "/Users/me/"),
            ["/Users/me/.homebrew/bin", "/Users/me/homebrew/bin"]
        )
        XCTAssertTrue(ToolLocator.userHomebrewDirectories(home: "").isEmpty)
    }

    func testTrailingSlashesDoNotProduceDoubleSeparators() throws {
        let locator = ToolLocator(
            bundledDirectory: "/helpers/",
            fileExists: { $0 == "/helpers/ffmpeg" }
        )
        XCTAssertEqual(try locator.find("ffmpeg"), "/helpers/ffmpeg")
    }
}
