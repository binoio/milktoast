import Foundation

public struct RemuxProgress: Sendable, Equatable {
    /// Output position in seconds.
    public var outTimeSeconds: Double
    /// Encoding speed as a multiple of realtime, when ffmpeg reports it.
    public var speed: Double?
    public var frame: Int?
    public var fps: Double?
    public var totalSizeBytes: Int64?
    public var isFinished: Bool

    public init(
        outTimeSeconds: Double = 0,
        speed: Double? = nil,
        frame: Int? = nil,
        fps: Double? = nil,
        totalSizeBytes: Int64? = nil,
        isFinished: Bool = false
    ) {
        self.outTimeSeconds = outTimeSeconds
        self.speed = speed
        self.frame = frame
        self.fps = fps
        self.totalSizeBytes = totalSizeBytes
        self.isFinished = isFinished
    }

    /// Completion in `0...1`, or nil when the source duration is unknown.
    public func fraction(ofDuration duration: Double?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        if isFinished { return 1 }
        return min(1, max(0, outTimeSeconds / duration))
    }

    /// Remaining wall-clock seconds, derived from ffmpeg's own speed figure.
    public func estimatedSecondsRemaining(duration: Double?) -> Double? {
        guard let duration, duration > 0, let speed, speed > 0.01 else { return nil }
        let remaining = duration - outTimeSeconds
        guard remaining > 0 else { return 0 }
        return remaining / speed
    }
}

/// Incremental parser for `ffmpeg -progress pipe:1`.
///
/// ffmpeg writes `key=value` lines and terminates each block with
/// `progress=continue` or `progress=end`. Values accumulate across a block, so
/// the parser only emits once a block closes.
public struct ProgressParser: Sendable {
    private var pending: [String: String] = [:]

    public init() {}

    /// Feeds one line. Returns a snapshot when the line closed a block.
    public mutating func consume(line rawLine: String) -> RemuxProgress? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let separator = line.firstIndex(of: "=") else { return nil }
        let key = String(line[line.startIndex..<separator])
        let value = String(line[line.index(after: separator)...])
        guard key == "progress" else {
            pending[key] = value
            return nil
        }

        let snapshot = RemuxProgress(
            outTimeSeconds: Self.outTime(from: pending),
            speed: Self.speed(from: pending["speed"]),
            frame: pending["frame"].flatMap { Int($0) },
            fps: pending["fps"].flatMap { Double($0) },
            totalSizeBytes: pending["total_size"].flatMap { Int64($0) },
            isFinished: value == "end"
        )
        pending.removeAll(keepingCapacity: true)
        return snapshot
    }

    /// Feeds an arbitrary chunk of stdout, returning every completed snapshot.
    public mutating func consume(chunk: String) -> [RemuxProgress] {
        chunk.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { consume(line: String($0)) }
    }

    private static func outTime(from fields: [String: String]) -> Double {
        if let micros = fields["out_time_us"].flatMap({ Double($0) }), micros >= 0 {
            return micros / 1_000_000
        }
        if let millis = fields["out_time_ms"].flatMap({ Double($0) }), millis >= 0 {
            // Despite the name, ffmpeg writes microseconds here too.
            return millis / 1_000_000
        }
        if let clock = fields["out_time"] { return parseClock(clock) ?? 0 }
        return 0
    }

    /// `HH:MM:SS.mmm` → seconds.
    public static func parseClock(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// ffmpeg formats speed as e.g. `12.4x`, or `N/A` before the first frame.
    private static func speed(from text: String?) -> Double? {
        guard var text else { return nil }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("x") { text.removeLast() }
        guard let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }
}
