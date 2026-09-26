import Foundation

/// One output stream, resolved back to the input stream it came from.
public struct PlannedStream: Sendable, Equatable {
    public var inputIndex: Int
    /// Position among output streams of the same kind (the `N` in `-c:a:N`).
    public var outputOrdinal: Int
    public var kind: MediaKind
    public var sourceCodec: String
    public var language: String?
    public var title: String?
    public var isDefault: Bool

    public init(
        inputIndex: Int,
        outputOrdinal: Int,
        kind: MediaKind,
        sourceCodec: String,
        language: String? = nil,
        title: String? = nil,
        isDefault: Bool = false
    ) {
        self.inputIndex = inputIndex
        self.outputOrdinal = outputOrdinal
        self.kind = kind
        self.sourceCodec = sourceCodec
        self.language = language
        self.title = title
        self.isDefault = isDefault
    }
}

public struct PlannedVideo: Sendable, Equatable {
    public var stream: PlannedStream
    public var action: VideoAction
}

public struct PlannedAudio: Sendable, Equatable {
    public var stream: PlannedStream
    public var action: AudioAction
}

public struct PlannedSubtitle: Sendable, Equatable {
    public var stream: PlannedStream
    public var action: SubtitleAction
}

/// The container the remux is written into.
///
/// MP4 is the default because its subtitle tracks are real `sbtl` tracks, which
/// QuickTime lists in its Subtitles menu and leaves switched off until asked. The
/// MOV muxer writes the same timed text as a legacy `text` track, which QuickTime
/// burns over the picture whether or not the source had it enabled. QuickTime
/// Player opens both containers natively, so MOV is kept only for the codecs MP4
/// has no sample entry for.
public enum OutputContainer: String, Sendable, Equatable {
    case mp4
    case mov

    public var fileExtension: String { rawValue }
    public var ffmpegFormatName: String { rawValue }
}

public struct RemuxWarning: Sendable, Equatable {
    public enum Severity: String, Sendable { case info, warning }
    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// The complete recipe for turning one Matroska file into a QuickTime-playable
/// `.mov`. Produced without touching the filesystem, so it is fully testable.
public struct RemuxPlan: Sendable, Equatable {
    public var container: OutputContainer
    public var video: [PlannedVideo]
    public var audio: [PlannedAudio]
    public var subtitles: [PlannedSubtitle]
    public var includeChapters: Bool
    public var durationSeconds: Double?
    public var warnings: [RemuxWarning]
    public var sourceTitle: String?

    public init(
        container: OutputContainer = .mp4,
        video: [PlannedVideo] = [],
        audio: [PlannedAudio] = [],
        subtitles: [PlannedSubtitle] = [],
        includeChapters: Bool = false,
        durationSeconds: Double? = nil,
        warnings: [RemuxWarning] = [],
        sourceTitle: String? = nil
    ) {
        self.container = container
        self.video = video
        self.audio = audio
        self.subtitles = subtitles
        self.includeChapters = includeChapters
        self.durationSeconds = durationSeconds
        self.warnings = warnings
        self.sourceTitle = sourceTitle
    }

    /// True when every kept stream is a bitstream copy, i.e. the job is I/O bound
    /// and will finish at disk speed. This is the common case and what makes the
    /// launcher model viable.
    public var isPureRemux: Bool {
        let videoCopies = video.allSatisfy {
            if case .copy = $0.action { return true }
            return false
        }
        let audioCopies = audio.allSatisfy {
            if case .copy = $0.action { return true }
            return false
        }
        // Timed-text conversion is a cheap text rewrite, not a media re-encode.
        return videoCopies && audioCopies
    }

    public var requiresVideoEncode: Bool {
        video.contains {
            if case .transcode = $0.action { return true }
            return false
        }
    }

    public var requiresAudioEncode: Bool {
        audio.contains {
            if case .transcode = $0.action { return true }
            return false
        }
    }

    public var hasPlayableVideo: Bool { !video.isEmpty }
}

public enum RemuxPlannerError: Error, Equatable, CustomStringConvertible {
    case noVideoStream
    case noPlayableStreams

    public var description: String {
        switch self {
        case .noVideoStream:
            return "The file contains no video track."
        case .noPlayableStreams:
            return "Nothing in the file can be played by QuickTime."
        }
    }
}

/// Turns a probe result into a `RemuxPlan` using a `CompatibilityPolicy`.
public struct RemuxPlanner: Sendable {
    public let policy: CompatibilityPolicy
    public var options: RemuxOptions { policy.options }

    public init(policy: CompatibilityPolicy) {
        self.policy = policy
    }

    public init(capabilities: PlaybackCapabilities, options: RemuxOptions = .default) {
        self.policy = CompatibilityPolicy(capabilities: capabilities, options: options)
    }

    public func makePlan(from probe: ProbeResult) throws -> RemuxPlan {
        var warnings: [RemuxWarning] = []

        // MARK: Video — keep exactly one track. QuickTime shows only the first
        // enabled video track anyway, and extra tracks (cover art, thumbnails)
        // confuse the picker.
        let videoCandidates = probe.streams(of: .video).filter { !isCoverArt($0) }
        guard let source = videoCandidates.first(where: { $0.isDefault }) ?? videoCandidates.first else {
            throw RemuxPlannerError.noVideoStream
        }
        if videoCandidates.count > 1 {
            warnings.append(.init(.info, "Kept the first of \(videoCandidates.count) video tracks."))
        }

        let videoAction = policy.action(forVideo: source)
        switch videoAction {
        case .copy(let tag):
            if tag == "hvc1" {
                warnings.append(.init(.info, "Re-tagged HEVC as hvc1 so QuickTime renders it."))
            }
            if source.hasDolbyVision {
                warnings.append(.init(.warning, "Dolby Vision metadata is carried through; HDR mapping depends on your display."))
            }
        case .transcode(let encoder, _):
            warnings.append(.init(.warning, "\(source.codec.uppercased()) is not playable in QuickTime — re-encoding with \(encoder). This takes much longer than a remux."))
        case .drop:
            throw RemuxPlannerError.noVideoStream
        }

        let plannedVideo = [
            PlannedVideo(
                stream: PlannedStream(
                    inputIndex: source.index,
                    outputOrdinal: 0,
                    kind: .video,
                    sourceCodec: source.codec,
                    language: source.language,
                    title: source.title,
                    isDefault: true
                ),
                action: videoAction
            )
        ]

        // MARK: Audio — keep every track so QuickTime's audio-track menu still
        // offers commentary and alternate languages.
        var audioSources = probe.streams(of: .audio)
        if !options.includeAllAudioTracks, !audioSources.isEmpty {
            let preferred = audioSources.first(where: { $0.isDefault }) ?? audioSources[0]
            audioSources = [preferred]
        }

        var plannedAudio: [PlannedAudio] = []
        for candidate in audioSources {
            let action = policy.action(forAudio: candidate)
            if case .drop(let reason) = action {
                warnings.append(.init(.warning, "Dropped audio track \(candidate.index): \(reason)."))
                continue
            }
            if case .transcode(let codec, _, _) = action {
                warnings.append(.init(.info, "Converted \(describe(candidate)) to \(codec.uppercased())."))
            }
            plannedAudio.append(
                PlannedAudio(
                    stream: PlannedStream(
                        inputIndex: candidate.index,
                        outputOrdinal: plannedAudio.count,
                        kind: .audio,
                        sourceCodec: candidate.codec,
                        language: candidate.language,
                        title: candidate.title,
                        isDefault: candidate.isDefault
                    ),
                    action: action
                )
            )
        }
        if plannedAudio.isEmpty && !audioSources.isEmpty {
            warnings.append(.init(.warning, "No audio track could be carried over; the movie will be silent."))
        }

        // MARK: Subtitles — text tracks become tx3g, which QuickTime's
        // subtitle menu picks up. Bitmap tracks have nowhere to go.
        var plannedSubtitles: [PlannedSubtitle] = []
        if options.includeSubtitles {
            var droppedBitmaps = 0
            for candidate in probe.streams(of: .subtitle) {
                let action = policy.action(forSubtitle: candidate)
                switch action {
                case .timedText:
                    plannedSubtitles.append(
                        PlannedSubtitle(
                            stream: PlannedStream(
                                inputIndex: candidate.index,
                                outputOrdinal: plannedSubtitles.count,
                                kind: .subtitle,
                                sourceCodec: candidate.codec,
                                language: candidate.language,
                                title: candidate.title,
                                // A forced track exists precisely to be shown.
                                isDefault: candidate.isDefault || candidate.isForced
                            ),
                            action: action
                        )
                    )
                case .drop:
                    droppedBitmaps += 1
                }
            }
            if droppedBitmaps > 0 {
                warnings.append(.init(.info, "Skipped \(droppedBitmaps) image-based subtitle track\(droppedBitmaps == 1 ? "" : "s") (PGS/VobSub cannot be stored in a .mov)."))
            }
        }

        return RemuxPlan(
            container: Self.container(video: plannedVideo, audio: plannedAudio),
            video: plannedVideo,
            audio: plannedAudio,
            subtitles: plannedSubtitles,
            includeChapters: options.includeChapters && !probe.chapters.isEmpty,
            durationSeconds: probe.duration,
            warnings: warnings,
            sourceTitle: probe.format?.title
        )
    }

    /// MP4 has no sample entry for ProRes, motion JPEG, DV, or raw PCM. When a
    /// stream copy would carry one of those, the output has to be MOV instead.
    static func container(video: [PlannedVideo], audio: [PlannedAudio]) -> OutputContainer {
        let movOnlyVideo: Set<String> = ["prores", "mjpeg", "png", "dvvideo"]
        for entry in video {
            if case .copy = entry.action, movOnlyVideo.contains(entry.stream.sourceCodec) {
                return .mov
            }
        }
        for entry in audio {
            if case .copy = entry.action, entry.stream.sourceCodec.hasPrefix("pcm_") {
                return .mov
            }
        }
        return .mp4
    }

    /// Matroska sometimes carries poster art as a still video stream.
    private func isCoverArt(_ stream: ProbeStream) -> Bool {
        if (stream.disposition?["attached_pic"] ?? 0) == 1 { return true }
        return ["mjpeg", "png", "bmp", "gif"].contains(stream.codec) && stream.isDefault == false
            && (stream.tags?.keys.contains { $0.lowercased() == "filename" } ?? false)
    }

    private func describe(_ stream: ProbeStream) -> String {
        var parts = [stream.codec.uppercased()]
        if let channels = stream.channels {
            parts.append(channels > 2 ? "\(channels)ch" : (channels == 2 ? "stereo" : "mono"))
        }
        if let language = stream.language { parts.append("[\(language)]") }
        return parts.joined(separator: " ")
    }
}
