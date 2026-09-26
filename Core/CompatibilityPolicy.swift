import Foundation

public enum VideoAction: Sendable, Equatable {
    /// Stream-copy the bitstream, optionally forcing a QuickTime-friendly sample tag.
    case copy(tag: String?)
    case transcode(encoder: String, bitrateKbps: Int?)
    case drop(reason: String)
}

public enum AudioAction: Sendable, Equatable {
    case copy
    case transcode(codec: String, bitrateKbps: Int?, channels: Int?)
    case drop(reason: String)
}

public enum SubtitleAction: Sendable, Equatable {
    /// Convert a text subtitle to 3GPP timed text (`tx3g`), which QuickTime renders.
    case timedText
    case drop(reason: String)
}

/// Codec-by-codec decisions about what a QuickTime-compatible `.mov` can hold.
public struct CompatibilityPolicy: Sendable {
    public let capabilities: PlaybackCapabilities
    public let options: RemuxOptions

    public init(capabilities: PlaybackCapabilities, options: RemuxOptions = .default) {
        self.capabilities = capabilities
        self.options = options
    }

    // MARK: - Video

    /// Codecs QuickTime plays from a `.mov` with no re-encode.
    static let copyableVideoCodecs: Set<String> = [
        "h264", "avc1", "hevc", "h265", "prores", "mjpeg", "png", "dvvideo",
    ]

    /// Text subtitle codecs that can be converted to `tx3g`.
    static let textSubtitleCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt", "subviewer",
        "subviewer1", "microdvd", "sami", "realtext", "stl", "mpl2", "vplayer", "pjs",
    ]

    /// Bitmap subtitle codecs; `.mov` has no sample entry for these.
    static let bitmapSubtitleCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "pgssub", "dvd_subtitle", "dvdsub",
        "dvb_subtitle", "dvbsub", "xsub", "hdmv_text_subtitle",
    ]

    public func action(forVideo stream: ProbeStream) -> VideoAction {
        switch stream.codec {
        case "hevc", "h265":
            guard capabilities.supportsHEVC else { return transcodeVideo(stream) }
            if stream.isHighBitDepth && !capabilities.supportsHEVC10Bit { return transcodeVideo(stream) }
            // QuickTime shows a black frame for `hev1` (in-band parameter sets).
            // Forcing `hvc1` is the single most important fix in the whole pipeline.
            return .copy(tag: "hvc1")

        case "h264", "avc1":
            // Apple's decoder has no High 10 support: 10-bit AVC opens but plays black.
            if stream.isHighBitDepth && !capabilities.supportsH264High10 { return transcodeVideo(stream) }
            return .copy(tag: nil)

        case "prores":
            return .copy(tag: nil)

        case "mjpeg", "png", "dvvideo":
            return .copy(tag: nil)

        case "av1":
            return capabilities.supportsAV1 ? .copy(tag: "av01") : transcodeVideo(stream)

        case "vp9":
            return capabilities.supportsVP9 ? .copy(tag: "vp09") : transcodeVideo(stream)

        case "mpeg4":
            // MPEG-4 Part 2 (DivX/XviD) rides along as `mp4v`.
            return capabilities.supportsMPEG4Part2 ? .copy(tag: nil) : transcodeVideo(stream)

        default:
            return transcodeVideo(stream)
        }
    }

    private func transcodeVideo(_ stream: ProbeStream) -> VideoAction {
        let wantsHEVC = stream.isHighBitDepth
        let hardware = wantsHEVC ? "hevc_videotoolbox" : "h264_videotoolbox"
        let encoder: String
        if options.preferHardwareEncoding, capabilities.videoToolboxEncoders.contains(hardware) {
            encoder = hardware
        } else {
            encoder = wantsHEVC ? "libx265" : "libx264"
        }
        return .transcode(encoder: encoder, bitrateKbps: targetVideoBitrateKbps(for: stream))
    }

    /// Picks a re-encode bitrate: follow the source when it is known, otherwise fall
    /// back to a pixel-count heuristic. Always clamped by `maxVideoBitrateMbps`.
    public func targetVideoBitrateKbps(for stream: ProbeStream) -> Int {
        let ceiling = max(1, options.maxVideoBitrateMbps) * 1000
        if let bps = stream.bitsPerSecond, bps > 0 {
            return min(ceiling, max(1000, bps / 1000))
        }
        let pixels = (stream.width ?? 1920) * (stream.height ?? 1080)
        let heuristic: Int
        switch pixels {
        case ...(640 * 480): heuristic = 1500
        case ...(1280 * 720): heuristic = 3000
        case ...(1920 * 1080): heuristic = 6000
        case ...(2560 * 1440): heuristic = 10000
        case ...(3840 * 2160): heuristic = 16000
        default: heuristic = 24000
        }
        return min(ceiling, heuristic)
    }

    // MARK: - Audio

    /// Codecs QuickTime plays from a `.mov` with no re-encode.
    static let copyableAudioCodecs: Set<String> = [
        "aac", "ac3", "eac3", "alac", "mp3", "mp2",
        "pcm_s16le", "pcm_s24le", "pcm_s16be", "pcm_s24be", "pcm_f32le",
    ]

    /// Lossless sources worth preserving bit-for-bit via ALAC.
    static let losslessAudioCodecs: Set<String> = [
        "flac", "truehd", "mlp", "wavpack", "tta", "als",
        "pcm_bluray", "pcm_dvd", "pcm_s32le", "pcm_s32be",
    ]

    public func action(forAudio stream: ProbeStream) -> AudioAction {
        let codec = stream.codec
        let channels = stream.channels ?? 2

        if CompatibilityPolicy.copyableAudioCodecs.contains(codec) { return .copy }
        if codec == "flac" && capabilities.supportsFLACInMOV { return .copy }
        if codec == "opus" && capabilities.supportsOpusInMOV { return .copy }

        // ALAC tops out at 8 channels; beyond that fall through to a lossy target.
        if options.preserveLosslessAudioAsALAC,
           CompatibilityPolicy.losslessAudioCodecs.contains(codec),
           channels <= 8 {
            return .transcode(codec: "alac", bitrateKbps: nil, channels: nil)
        }

        return lossyTarget(channels: channels)
    }

    /// Surround is preserved rather than folded down to stereo: a 5.1 DTS track
    /// becomes 5.1 AC-3, not 2.0 AAC.
    private func lossyTarget(channels: Int) -> AudioAction {
        guard channels > 2 else {
            return .transcode(codec: "aac", bitrateKbps: max(64, options.stereoBitrateKbps), channels: nil)
        }
        switch options.surroundTarget {
        case .aac:
            return .transcode(codec: "aac", bitrateKbps: 96 * channels, channels: nil)
        case .eac3:
            return .transcode(codec: "eac3", bitrateKbps: min(1024, 128 * channels), channels: nil)
        case .ac3:
            // ffmpeg's AC-3 encoder handles at most 6 channels; 7.1 goes to E-AC-3.
            if channels > 6 {
                return .transcode(codec: "eac3", bitrateKbps: min(1024, 128 * channels), channels: nil)
            }
            return .transcode(codec: "ac3", bitrateKbps: 640, channels: nil)
        }
    }

    // MARK: - Subtitles

    public func action(forSubtitle stream: ProbeStream) -> SubtitleAction {
        guard options.includeSubtitles else { return .drop(reason: "subtitles disabled in settings") }
        let codec = stream.codec
        if CompatibilityPolicy.textSubtitleCodecs.contains(codec) { return .timedText }
        if CompatibilityPolicy.bitmapSubtitleCodecs.contains(codec) {
            return .drop(reason: "\(codec) is a bitmap subtitle and has no QuickTime equivalent")
        }
        return .drop(reason: "unsupported subtitle codec \(codec.isEmpty ? "unknown" : codec)")
    }
}
