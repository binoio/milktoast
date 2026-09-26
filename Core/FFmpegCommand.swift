import Foundation

/// Builds the ffprobe and ffmpeg argument vectors. Pure string work: the app and
/// the CLI both go through here, and the tests assert on the exact argv.
public enum FFmpegCommand {

    /// Full stream/chapter/format dump as JSON.
    public static func probeArguments(input: String) -> [String] {
        [
            "-hide_banner",
            "-loglevel", "error",
            "-show_streams",
            "-show_chapters",
            "-show_format",
            "-print_format", "json",
            input,
        ]
    }

    /// The remux command.
    ///
    /// Notes on the choices here:
    /// - No `-movflags +faststart`: that rewrites the whole file a second time to
    ///   move `moov` to the front, which only matters for HTTP streaming. For a
    ///   local handoff it would roughly double the I/O for zero benefit.
    /// - `-progress pipe:1` gives machine-readable progress on stdout while
    ///   diagnostics stay on stderr.
    /// - The container comes from the plan; see `OutputContainer`.
    /// - Audio dispositions are written out explicitly so QuickTime starts on the
    ///   track the source marked default rather than simply the first one.
    /// - `-nostdin` matters because the process is spawned without a terminal.
    public static func remuxArguments(
        input: String,
        output: String,
        plan: RemuxPlan,
        options: RemuxOptions = .default
    ) -> [String] {
        var args = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-progress", "pipe:1",
            "-y",
            "-i", input,
        ]

        for planned in plan.video {
            args += ["-map", "0:\(planned.stream.inputIndex)"]
            let ordinal = planned.stream.outputOrdinal
            switch planned.action {
            case .copy(let tag):
                args += ["-c:v:\(ordinal)", "copy"]
                if let tag { args += ["-tag:v:\(ordinal)", tag] }
            case .transcode(let encoder, let bitrateKbps):
                args += ["-c:v:\(ordinal)", encoder]
                if let bitrateKbps {
                    args += ["-b:v:\(ordinal)", "\(bitrateKbps)k"]
                }
                args += videoEncoderTuning(encoder: encoder, ordinal: ordinal)
                // Apple decoders need the 4:2:0 8-bit path for H.264.
                if encoder.hasPrefix("h264") {
                    args += ["-pix_fmt:v:\(ordinal)", "yuv420p"]
                }
            case .drop:
                continue
            }
        }

        // If the source flagged no audio track as default, the first one wins —
        // otherwise every track would come out disabled.
        let defaultAudioOrdinal = plan.audio.first(where: { $0.stream.isDefault })?.stream.outputOrdinal
            ?? plan.audio.first?.stream.outputOrdinal

        for planned in plan.audio {
            args += ["-map", "0:\(planned.stream.inputIndex)"]
            let ordinal = planned.stream.outputOrdinal
            args += ["-disposition:a:\(ordinal)", ordinal == defaultAudioOrdinal ? "default" : "0"]
            switch planned.action {
            case .copy:
                args += ["-c:a:\(ordinal)", "copy"]
            case .transcode(let codec, let bitrateKbps, let channels):
                args += ["-c:a:\(ordinal)", codec]
                if let bitrateKbps { args += ["-b:a:\(ordinal)", "\(bitrateKbps)k"] }
                if let channels { args += ["-ac:a:\(ordinal)", "\(channels)"] }
            case .drop:
                continue
            }
        }

        for planned in plan.subtitles {
            args += ["-map", "0:\(planned.stream.inputIndex)"]
            let ordinal = planned.stream.outputOrdinal
            switch planned.action {
            case .timedText:
                args += ["-c:s:\(ordinal)", "mov_text"]
                // No `-disposition:s:` here: the MP4/MOV muxer always writes
                // subtitle tracks as enabled and ignores the flag. What keeps
                // QuickTime from burning them over the picture is the container
                // choice — MP4's `sbtl` tracks go in the Subtitles menu, MOV's
                // legacy `text` tracks do not. See `OutputContainer`.
                // tx3g has no language field of its own; the track header carries it.
                if let language = planned.stream.language {
                    args += ["-metadata:s:s:\(ordinal)", "language=\(language)"]
                }
            case .drop:
                continue
            }
        }

        args += ["-map_chapters", plan.includeChapters ? "0" : "-1"]
        args += ["-map_metadata", "0"]
        // Matroska can start at a negative DTS (open GOP, delay-compensated
        // audio); MOV has no room for that, so shift the whole timeline.
        args += ["-avoid_negative_ts", "make_zero"]
        args += ["-f", plan.container.ffmpegFormatName, output]
        return args
    }

    private static func videoEncoderTuning(encoder: String, ordinal: Int) -> [String] {
        switch encoder {
        case "h264_videotoolbox", "hevc_videotoolbox":
            // Hardware encoders: let the ASIC run at its natural pace and allow
            // frame reordering for better quality at the same bitrate.
            return ["-allow_sw:v:\(ordinal)", "1", "-realtime:v:\(ordinal)", "0"]
        case "libx264", "libx265":
            return ["-preset:v:\(ordinal)", "veryfast", "-crf:v:\(ordinal)", "20"]
        default:
            return []
        }
    }

    /// Human-readable one-liner for logs and the UI's detail disclosure.
    public static func describe(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map { arg in
            arg.contains(" ") ? "'\(arg)'" : arg
        }.joined(separator: " ")
    }
}
