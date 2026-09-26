import Foundation

/// Where a prepared movie is written.
public enum OutputLocation: String, Codable, Sendable, CaseIterable {
    /// Next to the source file, as `Episode.mp4` beside `Episode.mkv`.
    case besideSource
    /// In the app's cache folder, leaving the user's movie folders untouched.
    case cache
}

/// What is already sitting at a candidate sidecar path.
public enum SidecarFileState: Equatable, Sendable {
    case absent
    /// A file Milktoast did not create. Never overwritten, never reused.
    case foreign
    /// A file Milktoast wrote, carrying the stamp of the source and settings it
    /// was built from.
    case ours(stamp: String)
}

public enum SidecarDecision: Equatable, Sendable {
    case write(fileName: String)
    case reuse(fileName: String)
    /// Every candidate name is taken by a file that is not ours.
    case noRoom
}

public enum SidecarNaming {
    /// Appears in the disambiguated name when the obvious one is taken.
    public static let marker = "Milktoast"

    public static func stem(of fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return fileName
        }
        return String(fileName[fileName.startIndex..<dot])
    }

    /// `Episode.mkv` → `Episode.mp4`. The name a person would expect.
    public static func primary(sourceName: String, container: OutputContainer) -> String {
        stem(of: sourceName) + "." + container.fileExtension
    }

    /// `Episode.mkv` → `Episode (Milktoast).mp4`, `Episode (Milktoast 2).mp4`, …
    ///
    /// Only used when the obvious name belongs to someone else's file.
    public static func alternate(sourceName: String, container: OutputContainer, index: Int) -> String {
        let suffix = index <= 1 ? marker : "\(marker) \(index)"
        return "\(stem(of: sourceName)) (\(suffix))." + container.fileExtension
    }

    /// Hidden scratch name that ffmpeg writes to. The real name only ever appears
    /// via an atomic rename, so an interrupted job cannot leave something that
    /// looks finished.
    public static func partial(for fileName: String) -> String {
        "." + fileName + ".milktoast-partial"
    }
}

/// Chooses the sidecar file name, refusing to destroy anything Milktoast did not
/// write.
public enum SidecarPlanner {
    /// - Parameters:
    ///   - sourceName: the source's file name, e.g. `Episode.mkv`.
    ///   - expectedStamp: identity of this source plus the settings that affect
    ///     output; a match means the file on disk is already what we would build.
    ///   - inspect: what is at a candidate name, relative to the source's folder.
    public static func decide(
        sourceName: String,
        container: OutputContainer,
        expectedStamp: String,
        maximumAlternates: Int = 20,
        inspect: (String) -> SidecarFileState
    ) -> SidecarDecision {
        var candidates = [SidecarNaming.primary(sourceName: sourceName, container: container)]
        for index in 1...max(1, maximumAlternates) {
            candidates.append(
                SidecarNaming.alternate(sourceName: sourceName, container: container, index: index)
            )
        }

        for candidate in candidates {
            // A `.mov` source would otherwise resolve to its own name. Writing
            // over the thing we are reading is the one unrecoverable mistake
            // available here.
            guard candidate != sourceName else { continue }

            switch inspect(candidate) {
            case .absent:
                return .write(fileName: candidate)
            case .ours(let stamp):
                // Ours and current — hand it straight back. Ours but stale means
                // the source or the settings changed, so rebuild in place.
                return stamp == expectedStamp ? .reuse(fileName: candidate) : .write(fileName: candidate)
            case .foreign:
                continue
            }
        }
        return .noRoom
    }
}
