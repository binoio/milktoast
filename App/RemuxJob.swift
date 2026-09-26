import Foundation
import Observation
import MilktoastCore

@MainActor
@Observable
final class RemuxJob: Identifiable {
    enum Phase: Equatable {
        case queued
        case analyzing
        case working(isEncode: Bool)
        case handingOff
        case playing
        /// Prepared, but nothing was opened — the user asked to do that part.
        case ready
        case failed(String)
        case cancelled

        var isTerminal: Bool {
            switch self {
            case .playing, .ready, .failed, .cancelled: return true
            default: return false
            }
        }

        var succeeded: Bool {
            switch self {
            case .playing, .ready: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let source: URL
    var phase: Phase = .queued
    /// 0...1 while working, nil when the duration is unknown.
    var fraction: Double?
    var secondsRemaining: Double?
    var speed: Double?
    var plan: RemuxPlan?
    var output: URL?
    var reusedCache = false
    var commandLine: String?
    var failureDetail: String?

    init(source: URL) {
        self.source = source
    }

    var title: String { source.lastPathComponent }

    var statusText: String {
        switch phase {
        case .queued:
            return "Waiting…"
        case .analyzing:
            return "Analyzing…"
        case .working(let isEncode):
            if reusedCache { return "Already prepared" }
            let verb = isEncode ? "Converting" : "Remuxing"
            guard let fraction else { return "\(verb)…" }
            var text = "\(verb) \(Int(fraction * 100))%"
            if let secondsRemaining, secondsRemaining > 1 {
                text += " · \(Self.formatDuration(secondsRemaining)) left"
            }
            if let speed, speed >= 1 {
                text += String(format: " · %.0f×", speed)
            }
            return text
        case .handingOff:
            return "Opening in player…"
        case .playing:
            return reusedCache ? "Playing (reused earlier remux)" : "Playing"
        case .ready:
            return "Ready to open"
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Progress bars that jump to a wrong 100% are worse than indeterminate ones,
    /// so only report a value when ffmpeg has given a usable position.
    var isIndeterminate: Bool {
        switch phase {
        case .analyzing, .handingOff: return true
        case .working: return fraction == nil
        default: return false
        }
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 1))s" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
