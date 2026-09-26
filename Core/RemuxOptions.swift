import Foundation

/// User-tunable knobs that influence the plan. Any change here that alters output
/// bytes must bump `policyVersion`, which is folded into the cache key.
public struct RemuxOptions: Codable, Sendable, Equatable {
    /// Bump whenever the planner's output for the same input could change.
    public static let policyVersion = 4

    public enum SurroundTarget: String, Codable, Sendable, CaseIterable {
        case ac3, eac3, aac

        public var displayName: String {
            switch self {
            case .ac3: return "Dolby Digital (AC-3)"
            case .eac3: return "Dolby Digital Plus (E-AC-3)"
            case .aac: return "AAC"
            }
        }
    }

    public var includeAllAudioTracks: Bool
    public var includeSubtitles: Bool
    public var includeChapters: Bool
    public var preferHardwareEncoding: Bool
    /// Target bitrate for stereo/mono lossy re-encodes.
    public var stereoBitrateKbps: Int
    /// Codec used when a surround track must be re-encoded.
    public var surroundTarget: SurroundTarget
    /// Re-wrap lossless sources (FLAC, TrueHD, PCM) as ALAC instead of a lossy codec.
    public var preserveLosslessAudioAsALAC: Bool
    /// Ceiling for video re-encodes, in megabits per second.
    public var maxVideoBitrateMbps: Int

    public init(
        includeAllAudioTracks: Bool = true,
        includeSubtitles: Bool = true,
        includeChapters: Bool = true,
        preferHardwareEncoding: Bool = true,
        stereoBitrateKbps: Int = 256,
        surroundTarget: SurroundTarget = .ac3,
        preserveLosslessAudioAsALAC: Bool = true,
        maxVideoBitrateMbps: Int = 20
    ) {
        self.includeAllAudioTracks = includeAllAudioTracks
        self.includeSubtitles = includeSubtitles
        self.includeChapters = includeChapters
        self.preferHardwareEncoding = preferHardwareEncoding
        self.stereoBitrateKbps = stereoBitrateKbps
        self.surroundTarget = surroundTarget
        self.preserveLosslessAudioAsALAC = preserveLosslessAudioAsALAC
        self.maxVideoBitrateMbps = maxVideoBitrateMbps
    }

    public static let `default` = RemuxOptions()

    /// Stable, order-independent fingerprint for cache keying.
    public var fingerprint: String {
        [
            "v\(RemuxOptions.policyVersion)",
            "aa\(includeAllAudioTracks ? 1 : 0)",
            "sub\(includeSubtitles ? 1 : 0)",
            "ch\(includeChapters ? 1 : 0)",
            "hw\(preferHardwareEncoding ? 1 : 0)",
            "st\(stereoBitrateKbps)",
            "sr\(surroundTarget.rawValue)",
            "al\(preserveLosslessAudioAsALAC ? 1 : 0)",
            "mv\(maxVideoBitrateMbps)",
        ].joined(separator: "|")
    }
}
