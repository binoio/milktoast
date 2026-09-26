import AppKit
import MilktoastCore

/// Hands a finished `.mov` to the playback app.
///
/// This is the whole reason the launcher model is worth it: QuickTime Player
/// already has the native transport controls, AirPlay routing, Picture in
/// Picture, audio/subtitle track menus, HDR handling, and media-key support.
/// Milktoast's job ends the moment the file is playable.
enum PlayerHandoff {
    enum HandoffError: Error, CustomStringConvertible {
        case playerNotFound(String)
        case openFailed(String)

        var description: String {
            switch self {
            case .playerNotFound(let name):
                return "Could not find \(name). Choose a different player in Settings."
            case .openFailed(let message):
                return "Could not start playback: \(message)"
            }
        }
    }

    static func applicationURL(for choice: PlayerChoice) -> URL? {
        switch choice {
        case .systemDefault, .prepareOnly:
            return nil
        case .quickTimePlayer:
            return NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: PlayerChoice.quickTimeBundleIdentifier
            )
        case .custom(let identifier):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
    }

    static func displayName(for choice: PlayerChoice) -> String {
        switch choice {
        case .prepareOnly:
            return "no player"
        case .systemDefault:
            return "the default player"
        case .quickTimePlayer:
            return "QuickTime Player"
        case .custom(let identifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                return identifier
            }
            return FileManager.default.displayName(atPath: url.path)
        }
    }

    @MainActor
    static func open(_ movie: URL, with choice: PlayerChoice) async throws {
        // Resolve the target app first so "no such player" reads as itself
        // rather than as a generic launch failure.
        let application: URL
        switch choice {
        case .prepareOnly:
            // The caller is responsible for not reaching here; see
            // PlayerChoice.opensAPlayer.
            return
        case .systemDefault:
            guard let url = NSWorkspace.shared.urlForApplication(toOpen: movie) else {
                throw HandoffError.playerNotFound("an app that opens \(movie.pathExtension) files")
            }
            application = url
        case .quickTimePlayer, .custom:
            guard let url = applicationURL(for: choice) else {
                throw HandoffError.playerNotFound(displayName(for: choice))
            }
            application = url
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = true

        do {
            _ = try await NSWorkspace.shared.open(
                [movie],
                withApplicationAt: application,
                configuration: configuration
            )
        } catch {
            throw HandoffError.openFailed(error.localizedDescription)
        }
    }
}
