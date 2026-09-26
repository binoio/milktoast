import Foundation

/// What the *host* QuickTime/AVFoundation stack can decode from a `.mov` container.
///
/// Kept as injected data rather than queried inline so the planner stays pure and
/// testable, and so a newer OS only needs a change in one factory method.
public struct PlaybackCapabilities: Sendable, Equatable, Codable {
    public var supportsHEVC: Bool
    public var supportsHEVC10Bit: Bool
    public var supportsAV1: Bool
    public var supportsVP9: Bool
    public var supportsMPEG4Part2: Bool
    public var supportsH264High10: Bool
    public var supportsFLACInMOV: Bool
    public var supportsOpusInMOV: Bool
    public var videoToolboxEncoders: Set<String>

    public init(
        supportsHEVC: Bool,
        supportsHEVC10Bit: Bool,
        supportsAV1: Bool,
        supportsVP9: Bool,
        supportsMPEG4Part2: Bool,
        supportsH264High10: Bool,
        supportsFLACInMOV: Bool,
        supportsOpusInMOV: Bool,
        videoToolboxEncoders: Set<String>
    ) {
        self.supportsHEVC = supportsHEVC
        self.supportsHEVC10Bit = supportsHEVC10Bit
        self.supportsAV1 = supportsAV1
        self.supportsVP9 = supportsVP9
        self.supportsMPEG4Part2 = supportsMPEG4Part2
        self.supportsH264High10 = supportsH264High10
        self.supportsFLACInMOV = supportsFLACInMOV
        self.supportsOpusInMOV = supportsOpusInMOV
        self.videoToolboxEncoders = videoToolboxEncoders
    }

    /// Capabilities for a given macOS major version.
    ///
    /// - AV1 decode landed in AVFoundation with macOS 14 (software on Intel/M1-M2,
    ///   hardware on M3 and later).
    /// - VP9 is decodable by Safari but is not a supported AVFoundation `.mov`
    ///   sample type, so it always needs transcoding.
    /// - FLAC and Opus have no QuickTime-blessed `.mov` sample entry; FLAC is
    ///   re-wrapped losslessly as ALAC instead.
    /// - H.264 High 10 (10-bit AVC) has never been supported by Apple's decoder.
    public static func forMacOS(majorVersion: Int, hasVideoToolbox: Bool = true) -> PlaybackCapabilities {
        PlaybackCapabilities(
            supportsHEVC: true,
            supportsHEVC10Bit: true,
            supportsAV1: majorVersion >= 14,
            supportsVP9: false,
            supportsMPEG4Part2: true,
            supportsH264High10: false,
            supportsFLACInMOV: false,
            supportsOpusInMOV: false,
            videoToolboxEncoders: hasVideoToolbox ? ["h264_videotoolbox", "hevc_videotoolbox"] : []
        )
    }

    /// Conservative baseline used when the host version cannot be determined.
    public static let conservative = PlaybackCapabilities.forMacOS(majorVersion: 13, hasVideoToolbox: false)
}
