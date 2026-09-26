import Foundation
import MilktoastCore

/// Finds the ffmpeg/ffprobe pair for the running app.
enum BundledTools {
    /// `Milktoast.app/Contents/Helpers`, where `Scripts/build.sh` puts the signed
    /// copies of ffmpeg and ffprobe along with their dylibs.
    static var bundledHelpersDirectory: String? {
        guard let contents = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true) as URL?
        else { return nil }
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        return FileManager.default.fileExists(atPath: helpers.path) ? helpers.path : nil
    }

    static func locate() throws -> ToolPaths {
        // A Finder-launched app inherits launchd's minimal PATH, so the user's
        // shell PATH is not available here — the home-relative Homebrew
        // prefixes have to be searched explicitly.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ToolLocator.directories(fromPATH: ProcessInfo.processInfo.environment["PATH"])
            + ToolLocator.userHomebrewDirectories(home: home)

        let locator = ToolLocator(
            bundledDirectory: bundledHelpersDirectory,
            extraDirectories: extras,
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
        return try locator.locate()
    }
}
