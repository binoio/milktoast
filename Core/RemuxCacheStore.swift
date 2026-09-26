import Foundation

/// The on-disk side of the remux cache.
public struct RemuxCacheStore: @unchecked Sendable {
    public let root: URL
    // FileManager is not Sendable, but `.default` is documented as thread-safe
    // for the operations used here.
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// `~/Library/Caches/io.bino.milktoast/remux` — under Caches so the system can
    /// reclaim the space under pressure, and so nothing lands in the user's
    /// movie folders.
    public static func defaultRoot(
        bundleIdentifier: String = "io.bino.milktoast",
        fileManager: FileManager = .default
    ) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("remux", isDirectory: true)
    }

    /// Creates the cache root and marks it as derived data.
    ///
    /// The contents are multi-gigabyte files that can always be rebuilt from the
    /// source in seconds, so they have no business in a Time Machine backup or
    /// an iCloud sync.
    @discardableResult
    public func prepareRoot() -> Bool {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return false
        }
        #if canImport(Darwin)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
        return true
    }

    public func fingerprint(of source: URL) throws -> SourceFingerprint {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return SourceFingerprint(
            name: source.lastPathComponent,
            sizeBytes: size,
            modifiedAt: modified
        )
    }

    public func directory(for fingerprint: SourceFingerprint, options: RemuxOptions) -> URL {
        root.appendingPathComponent(
            RemuxCacheKey.directoryName(source: fingerprint, options: options),
            isDirectory: true
        )
    }

    public func outputURL(
        for fingerprint: SourceFingerprint,
        options: RemuxOptions,
        container: OutputContainer
    ) -> URL {
        directory(for: fingerprint, options: options)
            .appendingPathComponent(
                RemuxCacheKey.outputFileName(for: fingerprint.name, container: container)
            )
    }

    /// A previously finished remux, or nil. Only returns paths whose completion
    /// marker is present, so a partial file from a crash is never played.
    ///
    /// The directory is scanned rather than reconstructed, because the container
    /// (and therefore the extension) is only known after the source is probed.
    public func completedOutput(for fingerprint: SourceFingerprint, options: RemuxOptions) -> URL? {
        let directory = directory(for: fingerprint, options: options)
        let marker = directory.appendingPathComponent(RemuxCacheKey.completionMarkerName)
        guard fileManager.fileExists(atPath: marker.path),
              let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else { return nil }

        for name in names where !name.hasPrefix(".") {
            let candidate = directory.appendingPathComponent(name)
            guard let size = try? fileManager.attributesOfItem(atPath: candidate.path)[.size] as? NSNumber,
                  size.int64Value > 0
            else { continue }
            return candidate
        }
        return nil
    }

    public func prepareDirectory(for fingerprint: SourceFingerprint, options: RemuxOptions) throws -> URL {
        prepareRoot()
        let directory = directory(for: fingerprint, options: options)
        // Clear any partial output from an earlier interrupted attempt.
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func markComplete(directory: URL, sourcePath: String) throws {
        let marker = directory.appendingPathComponent(RemuxCacheKey.completionMarkerName)
        try Data(sourcePath.utf8).write(to: marker, options: .atomic)
    }

    /// Refreshes the modification date so LRU eviction sees the reuse.
    public func touch(directory: URL, now: Date = Date()) {
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: directory.path)
    }

    public func discard(directory: URL) {
        try? fileManager.removeItem(at: directory)
    }

    public func entries() -> [CacheEntry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let marker = directory.appendingPathComponent(RemuxCacheKey.completionMarkerName)
            let attributes = try? fileManager.attributesOfItem(atPath: directory.path)
            return CacheEntry(
                directoryName: name,
                sizeBytes: size(ofDirectory: directory),
                lastAccessed: (attributes?[.modificationDate] as? Date) ?? .distantPast,
                isComplete: fileManager.fileExists(atPath: marker.path)
            )
        }
    }

    public func totalSizeBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.sizeBytes }
    }

    /// Applies `CacheEviction.plan`. Returns the directories removed.
    @discardableResult
    public func evict(
        limits: CacheLimits = .default,
        now: Date = Date(),
        protecting: Set<String> = []
    ) -> [String] {
        let doomed = CacheEviction.plan(
            entries: entries(),
            limits: limits,
            now: now,
            protecting: protecting
        )
        for name in doomed {
            try? fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
        return doomed
    }

    public func removeAll() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            try? fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
        }
    }

    private func size(ofDirectory directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
