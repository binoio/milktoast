import Foundation
import MilktoastCore

// Headless driver for the same engine the SwiftUI app uses. Useful for scripting,
// for `--plan` (which prints the decisions without doing any work), and as the
// integration-test surface that needs no window server.

let usage = """
milktoast — rewrap Matroska files so QuickTime can play them, then open a player

USAGE:
  milktoast <file.mkv> [more files...]   remux and open in QuickTime Player
  milktoast --plan <file.mkv>            print the remux plan and exit (no work done)
  milktoast --remux-only <file.mkv>      prepare the movie and print its path
  milktoast --cache-info                 show cache location and size
  milktoast --clear-cache                delete every cached remux

OPTIONS:
  --player <name>        player app to open with (default: QuickTime Player)
  --no-open              alias for --remux-only
  --no-subtitles         skip subtitle conversion
  --first-audio-only     keep only the default audio track
  --surround <codec>     ac3 | eac3 | aac  (default: ac3)
  --no-hardware          use libx264/libx265 instead of VideoToolbox
  --quiet                suppress progress output
  -h, --help             show this message
"""

struct Invocation {
    enum Mode {
        case play
        case plan
        case remuxOnly
        case cacheInfo
        case clearCache
        case help
    }

    var mode: Mode = .play
    var files: [String] = []
    var player = "QuickTime Player"
    var options = RemuxOptions.default
    var quiet = false
}

func parse(_ arguments: [String]) throws -> Invocation {
    var invocation = Invocation()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            invocation.mode = .help
        case "--plan":
            invocation.mode = .plan
        case "--remux-only", "--no-open":
            invocation.mode = .remuxOnly
        case "--cache-info":
            invocation.mode = .cacheInfo
        case "--clear-cache":
            invocation.mode = .clearCache
        case "--quiet":
            invocation.quiet = true
        case "--no-subtitles":
            invocation.options.includeSubtitles = false
        case "--first-audio-only":
            invocation.options.includeAllAudioTracks = false
        case "--no-hardware":
            invocation.options.preferHardwareEncoding = false
        case "--player":
            index += 1
            guard index < arguments.count else { throw CLIError.missingValue(argument) }
            invocation.player = arguments[index]
        case "--surround":
            index += 1
            guard index < arguments.count,
                  let target = RemuxOptions.SurroundTarget(rawValue: arguments[index].lowercased())
            else { throw CLIError.missingValue(argument) }
            invocation.options.surroundTarget = target
        default:
            if argument.hasPrefix("-") { throw CLIError.unknownOption(argument) }
            invocation.files.append(argument)
        }
        index += 1
    }
    return invocation
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownOption(String)
    case noInput

    var description: String {
        switch self {
        case .missingValue(let option): return "\(option) needs a value."
        case .unknownOption(let option): return "Unknown option \(option)."
        case .noInput: return "No input file given.\n\n\(usage)"
        }
    }
}

func standardError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func makeTools() throws -> ToolPaths {
    // When this binary is the copy inside Milktoast.app/Contents/Helpers, the bundled
    // ffmpeg sits right next to it — prefer that over whatever is on PATH.
    let ownDirectory = Bundle.main.executableURL?
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
        .path

    let extras = ToolLocator.directories(fromPATH: ProcessInfo.processInfo.environment["PATH"])
        + ToolLocator.userHomebrewDirectories(
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )

    let locator = ToolLocator(
        bundledDirectory: ownDirectory,
        extraDirectories: extras,
        fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
    )
    return try locator.locate()
}

func describe(_ plan: RemuxPlan) -> String {
    var lines: [String] = []
    if let duration = plan.durationSeconds {
        lines.append(String(format: "Duration: %.1fs", duration))
    }
    if plan.requiresVideoEncode {
        lines.append("Mode: video re-encode required (slow)")
    } else if plan.requiresAudioEncode {
        lines.append("Mode: stream copy, audio converted (fast)")
    } else {
        lines.append("Mode: stream copy (fast — limited by disk speed)")
    }
    lines.append("Container: .\(plan.container.fileExtension)")
    for entry in plan.video {
        lines.append("  video  \(entry.stream.sourceCodec) → \(label(entry.action))")
    }
    for entry in plan.audio {
        let language = entry.stream.language.map { " [\($0)]" } ?? ""
        lines.append("  audio  \(entry.stream.sourceCodec)\(language) → \(label(entry.action))")
    }
    for entry in plan.subtitles {
        let language = entry.stream.language.map { " [\($0)]" } ?? ""
        lines.append("  subs   \(entry.stream.sourceCodec)\(language) → tx3g timed text")
    }
    if plan.includeChapters { lines.append("  chapters carried over") }
    for warning in plan.warnings {
        lines.append("  \(warning.severity == .warning ? "!" : "·") \(warning.message)")
    }
    return lines.joined(separator: "\n")
}

func label(_ action: VideoAction) -> String {
    switch action {
    case .copy(let tag): return tag.map { "copy (tagged \($0))" } ?? "copy"
    case .transcode(let encoder, let bitrate):
        return bitrate.map { "\(encoder) @ \($0)k" } ?? encoder
    case .drop(let reason): return "dropped — \(reason)"
    }
}

func label(_ action: AudioAction) -> String {
    switch action {
    case .copy: return "copy"
    case .transcode(let codec, let bitrate, _):
        return bitrate.map { "\(codec) @ \($0)k" } ?? codec
    case .drop(let reason): return "dropped — \(reason)"
    }
}

@main
struct MilktoastCommand {
    static func main() async {
        exit(await run())
    }
}

@MainActor
func run() async -> Int32 {
    let invocation: Invocation
    do {
        invocation = try parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        standardError(String(describing: error))
        return 2
    }

    if invocation.mode == .help {
        print(usage)
        return 0
    }

    let store = RemuxCacheStore(root: RemuxCacheStore.defaultRoot())

    switch invocation.mode {
    case .cacheInfo:
        let entries = store.entries()
        print("Cache: \(store.root.path)")
        print("Entries: \(entries.count) (\(entries.filter(\.isComplete).count) complete)")
        print("Size: \(formatBytes(entries.reduce(0) { $0 + $1.sizeBytes }))")
        return 0
    case .clearCache:
        let freed = store.totalSizeBytes()
        store.removeAll()
        print("Cleared \(formatBytes(freed)).")
        return 0
    default:
        break
    }

    guard !invocation.files.isEmpty else {
        standardError(String(describing: CLIError.noInput))
        return 2
    }

    let tools: ToolPaths
    do {
        tools = try makeTools()
    } catch {
        standardError(String(describing: error))
        standardError("Install ffmpeg (brew install ffmpeg) or run the bundled Milktoast.app.")
        return 69  // EX_UNAVAILABLE
    }

    let service = RemuxService(
        tools: tools,
        cache: store,
        capabilities: HostCapabilities.current(),
        options: invocation.options
    )

    var status: Int32 = 0
    for path in invocation.files {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        do {
            if invocation.mode == .plan {
                let probe = try await service.probe(source)
                let plan = try service.plan(for: probe)
                print("\(source.lastPathComponent):")
                print(describe(plan))
                continue
            }

            let quiet = invocation.quiet
            let output = try await service.remux(source: source) { event in
                guard !quiet else { return }
                switch event {
                case .analyzing:
                    standardError("Analyzing \(source.lastPathComponent)…")
                case .planned(let plan):
                    standardError(describe(plan))
                case .reusedCache:
                    standardError("Reusing cached remux.")
                case .started:
                    break
                case .progress(_, let fraction):
                    if let fraction {
                        standardError(String(format: "  %3.0f%%", fraction * 100))
                    }
                case .finished:
                    break
                }
            }

            if invocation.mode == .remuxOnly {
                print(output.path)
            } else {
                let opened = try await ProcessRunner.run(
                    executable: "/usr/bin/open",
                    arguments: ["-a", invocation.player, output.path]
                )
                guard opened.succeeded else {
                    standardError("Could not open \(invocation.player): \(opened.standardError)")
                    status = 1
                    continue
                }
                if !invocation.quiet {
                    standardError("Playing \(output.lastPathComponent) in \(invocation.player).")
                }
            }
        } catch {
            standardError("\(source.lastPathComponent): \(String(describing: error))")
            status = 1
        }
    }
    return status
}
