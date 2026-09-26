import Foundation

public struct ToolPaths: Sendable, Equatable {
    public var ffmpeg: String
    public var ffprobe: String

    public init(ffmpeg: String, ffprobe: String) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }
}

public enum ToolLocatorError: Error, Equatable, CustomStringConvertible {
    case missing(tool: String, searched: [String])

    public var description: String {
        switch self {
        case .missing(let tool, let searched):
            return "Could not find \(tool). Looked in: \(searched.joined(separator: ", "))."
        }
    }
}

/// Resolves the ffmpeg/ffprobe pair.
///
/// Search order puts the copies inside the app bundle first, so a signed,
/// notarized Milktoast.app never depends on what the user has installed. Homebrew and
/// the standard prefixes are the fallback for a `swift run` development build.
public struct ToolLocator: Sendable {
    /// Directories searched after the bundle, in order.
    public static let systemSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
    ]

    private let candidateDirectories: [String]
    private let fileExists: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - bundledDirectory: `Contents/Helpers` of the running app, if any.
    ///   - extraDirectories: extra directories to try before the system ones,
    ///     typically the entries of `$PATH`.
    ///   - fileExists: injected for testing.
    public init(
        bundledDirectory: String? = nil,
        extraDirectories: [String] = [],
        fileExists: @escaping @Sendable (String) -> Bool
    ) {
        var directories: [String] = []
        if let bundledDirectory { directories.append(bundledDirectory) }
        directories += extraDirectories
        directories += ToolLocator.systemSearchPaths

        // De-duplicate while preserving order.
        var seen = Set<String>()
        self.candidateDirectories = directories.filter { seen.insert($0).inserted }
        self.fileExists = fileExists
    }

    public func locate() throws -> ToolPaths {
        ToolPaths(ffmpeg: try find("ffmpeg"), ffprobe: try find("ffprobe"))
    }

    public func find(_ tool: String) throws -> String {
        for directory in candidateDirectories {
            let path = directory.hasSuffix("/") ? directory + tool : directory + "/" + tool
            if fileExists(path) { return path }
        }
        throw ToolLocatorError.missing(tool: tool, searched: candidateDirectories)
    }

    /// Homebrew prefixes that live under the user's home directory.
    ///
    /// These matter because an app launched from Finder inherits launchd's
    /// minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), not the shell's — so a
    /// build without embedded helpers would otherwise miss a per-user Homebrew
    /// install that works perfectly well from a terminal.
    public static func userHomebrewDirectories(home: String) -> [String] {
        guard !home.isEmpty else { return [] }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return ["\(base)/.homebrew/bin", "\(base)/homebrew/bin"]
    }

    /// Splits a `PATH` value into directories.
    public static func directories(fromPATH path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }
}
