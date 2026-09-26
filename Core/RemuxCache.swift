import Foundation

/// Identity of a source file, independent of where it is mounted. Size plus
/// modification time is enough to notice an edited or replaced file while still
/// matching the same movie opened from a different path.
public struct SourceFingerprint: Sendable, Equatable {
    public var name: String
    public var sizeBytes: Int64
    public var modifiedAt: Date

    public init(name: String, sizeBytes: Int64, modifiedAt: Date) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

/// Derives the cache location for a remux result.
///
/// Reopening the same movie a second time is instant because the previous
/// `.mov` is still there — the key folds in the options fingerprint so a settings
/// change invalidates stale output instead of silently reusing it.
public enum RemuxCacheKey {
    /// Hex digest identifying a (source, options) pair.
    public static func digest(source: SourceFingerprint, options: RemuxOptions) -> String {
        // Whole seconds: APFS records sub-second mtimes that some copy tools
        // round, which would otherwise cause spurious cache misses.
        let mtime = Int64(source.modifiedAt.timeIntervalSince1970.rounded(.down))
        let canonical = [
            source.name,
            String(source.sizeBytes),
            String(mtime),
            options.fingerprint,
        ].joined(separator: "\u{1F}")
        return String(SHA256Digest.hex(canonical).prefix(16))
    }

    /// Directory holding one cached remux, relative to the cache root.
    public static func directoryName(source: SourceFingerprint, options: RemuxOptions) -> String {
        digest(source: source, options: options)
    }

    /// Output filename. Keeping the original stem means QuickTime's title bar,
    /// Recents menu, and AirPlay "Now Playing" all show the real movie name.
    public static func outputFileName(for sourceName: String, container: OutputContainer) -> String {
        var stem = sourceName
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            stem = String(stem[stem.startIndex..<dot])
        }
        stem = stem.replacingOccurrences(of: "/", with: "-")
        if stem.isEmpty { stem = "Movie" }
        return stem + "." + container.fileExtension
    }

    /// Marker written only after ffmpeg exits 0, so a half-written `.mov` left by
    /// a crash or a cancel is never handed to QuickTime.
    public static let completionMarkerName = ".complete"
}

/// One cached remux as seen on disk.
public struct CacheEntry: Sendable, Equatable {
    public var directoryName: String
    public var sizeBytes: Int64
    public var lastAccessed: Date
    public var isComplete: Bool

    public init(directoryName: String, sizeBytes: Int64, lastAccessed: Date, isComplete: Bool) {
        self.directoryName = directoryName
        self.sizeBytes = sizeBytes
        self.lastAccessed = lastAccessed
        self.isComplete = isComplete
    }
}

public struct CacheLimits: Sendable, Equatable {
    public var maxTotalBytes: Int64
    public var maxAge: TimeInterval

    public init(maxTotalBytes: Int64, maxAge: TimeInterval) {
        self.maxTotalBytes = maxTotalBytes
        self.maxAge = maxAge
    }

    /// Deliberately modest. A cache hit saves a second or two, not minutes, so
    /// there is little reason to let prepared copies pile up for a fortnight.
    public static let `default` = CacheLimits(
        maxTotalBytes: 20 * 1024 * 1024 * 1024,  // 20 GB
        maxAge: 7 * 24 * 60 * 60                 // 7 days
    )

    /// Automatic cleanup turned off: complete movies are kept indefinitely.
    ///
    /// Half-written leftovers are still collected — they are unplayable by
    /// definition, so keeping them would only waste disk.
    public static let retainEverything = CacheLimits(
        maxTotalBytes: .max,
        maxAge: .greatestFiniteMagnitude
    )
}

/// Decides which cache directories to remove. Split out from the filesystem so
/// the eviction order is unit-testable.
public enum CacheEviction {
    /// Directory names to delete, in the order they should go.
    ///
    /// - Incomplete leftovers first: they are useless and usually large.
    /// - Then anything past `maxAge`.
    /// - Then least-recently-used until the total fits `maxTotalBytes`.
    /// - `protecting` is never evicted (the job currently being handed off).
    public static func plan(
        entries: [CacheEntry],
        limits: CacheLimits,
        now: Date,
        protecting: Set<String> = []
    ) -> [String] {
        var doomed: [String] = []
        var survivors: [CacheEntry] = []

        for entry in entries where !protecting.contains(entry.directoryName) {
            if !entry.isComplete {
                doomed.append(entry.directoryName)
            } else if now.timeIntervalSince(entry.lastAccessed) > limits.maxAge {
                doomed.append(entry.directoryName)
            } else {
                survivors.append(entry)
            }
        }

        var total = survivors.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > limits.maxTotalBytes else { return doomed }

        for entry in survivors.sorted(by: { $0.lastAccessed < $1.lastAccessed }) {
            doomed.append(entry.directoryName)
            total -= entry.sizeBytes
            if total <= limits.maxTotalBytes { break }
        }
        return doomed
    }
}
