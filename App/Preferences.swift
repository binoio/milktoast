import Foundation
import Observation
import MilktoastCore

/// What happens once a movie has been prepared.
enum PlayerChoice: Equatable {
    case quickTimePlayer
    case systemDefault
    case custom(bundleIdentifier: String)
    /// Prepare the movie and stop. The job row offers Reveal in Finder, and the
    /// user opens it whenever and however they like.
    case prepareOnly

    static let quickTimeBundleIdentifier = "com.apple.QuickTimePlayerX"

    var opensAPlayer: Bool { self != .prepareOnly }

    var storedValue: String {
        switch self {
        case .quickTimePlayer: return "quicktime"
        case .systemDefault: return "default"
        case .prepareOnly: return "none"
        case .custom(let identifier): return "custom:" + identifier
        }
    }

    init(storedValue: String) {
        switch storedValue {
        case "default":
            self = .systemDefault
        case "none":
            self = .prepareOnly
        default:
            if storedValue.hasPrefix("custom:") {
                let identifier = String(storedValue.dropFirst("custom:".count))
                self = identifier.isEmpty ? .quickTimePlayer : .custom(bundleIdentifier: identifier)
            } else {
                self = .quickTimePlayer
            }
        }
    }
}

/// UserDefaults-backed settings. Kept as a single observable object so the
/// settings window and the job runner read the same values.
@Observable
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.includeAllAudioTracks: true,
            Keys.includeSubtitles: true,
            Keys.includeChapters: true,
            Keys.preferHardwareEncoding: true,
            Keys.stereoBitrateKbps: 256,
            Keys.surroundTarget: RemuxOptions.SurroundTarget.ac3.rawValue,
            Keys.preserveLosslessAudioAsALAC: true,
            Keys.maxVideoBitrateMbps: 20,
            Keys.player: PlayerChoice.quickTimePlayer.storedValue,
            Keys.quitAfterHandoff: true,
            Keys.outputLocation: OutputLocation.besideSource.rawValue,
            Keys.automaticCacheCleanup: true,
            Keys.cacheSizeGB: 20,
            Keys.cacheMaxAgeDays: 7,
        ])
        includeAllAudioTracks = defaults.bool(forKey: Keys.includeAllAudioTracks)
        includeSubtitles = defaults.bool(forKey: Keys.includeSubtitles)
        includeChapters = defaults.bool(forKey: Keys.includeChapters)
        preferHardwareEncoding = defaults.bool(forKey: Keys.preferHardwareEncoding)
        stereoBitrateKbps = defaults.integer(forKey: Keys.stereoBitrateKbps)
        surroundTarget = RemuxOptions.SurroundTarget(
            rawValue: defaults.string(forKey: Keys.surroundTarget) ?? ""
        ) ?? .ac3
        preserveLosslessAudioAsALAC = defaults.bool(forKey: Keys.preserveLosslessAudioAsALAC)
        maxVideoBitrateMbps = defaults.integer(forKey: Keys.maxVideoBitrateMbps)
        player = PlayerChoice(storedValue: defaults.string(forKey: Keys.player) ?? "")
        quitAfterHandoff = defaults.bool(forKey: Keys.quitAfterHandoff)
        outputLocation = OutputLocation(
            rawValue: defaults.string(forKey: Keys.outputLocation) ?? ""
        ) ?? .besideSource
        automaticCacheCleanup = defaults.bool(forKey: Keys.automaticCacheCleanup)
        cacheSizeGB = defaults.integer(forKey: Keys.cacheSizeGB)
        cacheMaxAgeDays = defaults.integer(forKey: Keys.cacheMaxAgeDays)
    }

    enum Keys {
        static let includeAllAudioTracks = "includeAllAudioTracks"
        static let includeSubtitles = "includeSubtitles"
        static let includeChapters = "includeChapters"
        static let preferHardwareEncoding = "preferHardwareEncoding"
        static let stereoBitrateKbps = "stereoBitrateKbps"
        static let surroundTarget = "surroundTarget"
        static let preserveLosslessAudioAsALAC = "preserveLosslessAudioAsALAC"
        static let maxVideoBitrateMbps = "maxVideoBitrateMbps"
        static let player = "player"
        static let quitAfterHandoff = "quitAfterHandoff"
        static let outputLocation = "outputLocation"
        static let automaticCacheCleanup = "automaticCacheCleanup"
        static let cacheSizeGB = "cacheSizeGB"
        static let cacheMaxAgeDays = "cacheMaxAgeDays"
    }

    var includeAllAudioTracks: Bool { didSet { defaults.set(includeAllAudioTracks, forKey: Keys.includeAllAudioTracks) } }
    var includeSubtitles: Bool { didSet { defaults.set(includeSubtitles, forKey: Keys.includeSubtitles) } }
    var includeChapters: Bool { didSet { defaults.set(includeChapters, forKey: Keys.includeChapters) } }
    var preferHardwareEncoding: Bool { didSet { defaults.set(preferHardwareEncoding, forKey: Keys.preferHardwareEncoding) } }
    var stereoBitrateKbps: Int { didSet { defaults.set(stereoBitrateKbps, forKey: Keys.stereoBitrateKbps) } }
    var surroundTarget: RemuxOptions.SurroundTarget { didSet { defaults.set(surroundTarget.rawValue, forKey: Keys.surroundTarget) } }
    var preserveLosslessAudioAsALAC: Bool { didSet { defaults.set(preserveLosslessAudioAsALAC, forKey: Keys.preserveLosslessAudioAsALAC) } }
    var maxVideoBitrateMbps: Int { didSet { defaults.set(maxVideoBitrateMbps, forKey: Keys.maxVideoBitrateMbps) } }
    var player: PlayerChoice { didSet { defaults.set(player.storedValue, forKey: Keys.player) } }
    var quitAfterHandoff: Bool { didSet { defaults.set(quitAfterHandoff, forKey: Keys.quitAfterHandoff) } }
    var outputLocation: OutputLocation { didSet { defaults.set(outputLocation.rawValue, forKey: Keys.outputLocation) } }
    var automaticCacheCleanup: Bool { didSet { defaults.set(automaticCacheCleanup, forKey: Keys.automaticCacheCleanup) } }
    var cacheSizeGB: Int { didSet { defaults.set(cacheSizeGB, forKey: Keys.cacheSizeGB) } }
    var cacheMaxAgeDays: Int { didSet { defaults.set(cacheMaxAgeDays, forKey: Keys.cacheMaxAgeDays) } }

    var remuxOptions: RemuxOptions {
        RemuxOptions(
            includeAllAudioTracks: includeAllAudioTracks,
            includeSubtitles: includeSubtitles,
            includeChapters: includeChapters,
            preferHardwareEncoding: preferHardwareEncoding,
            stereoBitrateKbps: stereoBitrateKbps,
            surroundTarget: surroundTarget,
            preserveLosslessAudioAsALAC: preserveLosslessAudioAsALAC,
            maxVideoBitrateMbps: maxVideoBitrateMbps
        )
    }

    /// The budget actually applied.
    ///
    /// Cleanup can only be switched off while the cache is in use; with the
    /// default sidecar output there is no cache to manage, so the standard
    /// budget still applies and copies left over from cache mode age out.
    var cacheLimits: CacheLimits {
        guard outputLocation == .cache else { return .default }
        guard automaticCacheCleanup else { return .retainEverything }
        return CacheLimits(
            maxTotalBytes: Int64(max(1, cacheSizeGB)) * 1024 * 1024 * 1024,
            maxAge: TimeInterval(max(1, cacheMaxAgeDays)) * 24 * 60 * 60
        )
    }
}
