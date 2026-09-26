import XCTest
@testable import MilktoastCore

final class RemuxCacheKeyTests: XCTestCase {
    private let base = SourceFingerprint(
        name: "Movie.mkv",
        sizeBytes: 4_290_772_992,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    func testKeyIsStableAcrossCalls() {
        let first = RemuxCacheKey.digest(source: base, options: .default)
        let second = RemuxCacheKey.digest(source: base, options: .default)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 16)
    }

    func testKeyChangesWithSize() {
        var other = base
        other.sizeBytes += 1
        XCTAssertNotEqual(
            RemuxCacheKey.digest(source: base, options: .default),
            RemuxCacheKey.digest(source: other, options: .default)
        )
    }

    func testKeyChangesWithModificationDate() {
        var other = base
        other.modifiedAt = base.modifiedAt.addingTimeInterval(60)
        XCTAssertNotEqual(
            RemuxCacheKey.digest(source: base, options: .default),
            RemuxCacheKey.digest(source: other, options: .default)
        )
    }

    func testSubSecondModificationJitterDoesNotInvalidateTheCache() {
        // Copy tools routinely round APFS timestamps; a 0.4s difference must not
        // force a multi-gigabyte re-remux.
        var other = base
        other.modifiedAt = base.modifiedAt.addingTimeInterval(0.4)
        XCTAssertEqual(
            RemuxCacheKey.digest(source: base, options: .default),
            RemuxCacheKey.digest(source: other, options: .default)
        )
    }

    func testKeyChangesWhenSettingsChange() {
        var options = RemuxOptions.default
        options.includeSubtitles = false
        XCTAssertNotEqual(
            RemuxCacheKey.digest(source: base, options: .default),
            RemuxCacheKey.digest(source: base, options: options)
        )
    }

    func testOutputFileNameKeepsTheOriginalStem() {
        // QuickTime's title bar, Recents menu, and AirPlay "Now Playing" all
        // show this name, so it has to survive the round trip intact.
        XCTAssertEqual(RemuxCacheKey.outputFileName(for: "Movie.mkv", container: .mp4), "Movie.mp4")
        XCTAssertEqual(
            RemuxCacheKey.outputFileName(for: "S04E08.1080p.WEB.mkv", container: .mp4),
            "S04E08.1080p.WEB.mp4"
        )
        XCTAssertEqual(RemuxCacheKey.outputFileName(for: "NoExtension", container: .mov), "NoExtension.mov")
        XCTAssertEqual(RemuxCacheKey.outputFileName(for: ".hidden", container: .mp4), ".hidden.mp4")
        XCTAssertEqual(RemuxCacheKey.outputFileName(for: "a/b.mkv", container: .mov), "a-b.mov")
    }
}

final class CacheEvictionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let gigabyte: Int64 = 1024 * 1024 * 1024

    private func entry(_ name: String, gb: Int64, ageDays: Double, complete: Bool = true) -> CacheEntry {
        CacheEntry(
            directoryName: name,
            sizeBytes: gb * gigabyte,
            lastAccessed: now.addingTimeInterval(-ageDays * 86_400),
            isComplete: complete
        )
    }

    func testNothingIsRemovedWhenWithinLimits() {
        let plan = CacheEviction.plan(
            entries: [entry("a", gb: 4, ageDays: 1), entry("b", gb: 4, ageDays: 2)],
            limits: CacheLimits(maxTotalBytes: 40 * gigabyte, maxAge: 14 * 86_400),
            now: now
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testIncompleteLeftoversGoFirst() {
        let plan = CacheEviction.plan(
            entries: [entry("good", gb: 1, ageDays: 1), entry("partial", gb: 9, ageDays: 0, complete: false)],
            limits: CacheLimits(maxTotalBytes: 40 * gigabyte, maxAge: 14 * 86_400),
            now: now
        )
        XCTAssertEqual(plan, ["partial"])
    }

    func testStaleEntriesAreRemoved() {
        let plan = CacheEviction.plan(
            entries: [entry("fresh", gb: 1, ageDays: 1), entry("stale", gb: 1, ageDays: 20)],
            limits: CacheLimits(maxTotalBytes: 40 * gigabyte, maxAge: 14 * 86_400),
            now: now
        )
        XCTAssertEqual(plan, ["stale"])
    }

    func testOverflowEvictsLeastRecentlyUsedUntilItFits() {
        let plan = CacheEviction.plan(
            entries: [
                entry("newest", gb: 10, ageDays: 0),
                entry("middle", gb: 10, ageDays: 2),
                entry("oldest", gb: 10, ageDays: 5),
            ],
            limits: CacheLimits(maxTotalBytes: 20 * gigabyte, maxAge: 14 * 86_400),
            now: now
        )
        XCTAssertEqual(plan, ["oldest"], "removing one 10 GB entry brings 30 GB down to 20 GB")
    }

    func testOverflowStopsAsSoonAsItFits() {
        let plan = CacheEviction.plan(
            entries: [
                entry("a", gb: 10, ageDays: 0),
                entry("b", gb: 10, ageDays: 1),
                entry("c", gb: 10, ageDays: 2),
                entry("d", gb: 10, ageDays: 3),
            ],
            limits: CacheLimits(maxTotalBytes: 15 * gigabyte, maxAge: 14 * 86_400),
            now: now
        )
        XCTAssertEqual(plan, ["d", "c", "b"])
    }

    func testCleanupDisabledKeepsFinishedMoviesButStillCollectsLeftovers() {
        let plan = CacheEviction.plan(
            entries: [
                entry("finished", gb: 400, ageDays: 900),
                entry("half-written", gb: 5, ageDays: 0, complete: false),
            ],
            limits: .retainEverything,
            now: now
        )
        XCTAssertEqual(plan, ["half-written"],
                       "an unplayable leftover is never worth keeping")
    }

    func testProtectedEntryIsNeverEvicted() {
        let plan = CacheEviction.plan(
            entries: [
                entry("incoming", gb: 30, ageDays: 0, complete: false),
                entry("old", gb: 30, ageDays: 30),
            ],
            limits: CacheLimits(maxTotalBytes: 10 * gigabyte, maxAge: 14 * 86_400),
            now: now,
            protecting: ["incoming"]
        )
        XCTAssertEqual(plan, ["old"])
    }
}

final class RemuxCacheStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("milktoast-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAnIncompleteDirectoryIsNotReported() throws {
        let store = RemuxCacheStore(root: root)
        let fingerprint = SourceFingerprint(name: "A.mkv", sizeBytes: 10, modifiedAt: Date())
        let directory = try store.prepareDirectory(for: fingerprint, options: .default)
        let output = store.outputURL(for: fingerprint, options: .default, container: .mp4)
        try Data("partial".utf8).write(to: output)

        XCTAssertNil(store.completedOutput(for: fingerprint, options: .default),
                     "a .mov without the completion marker must never be played")

        try store.markComplete(directory: directory, sourcePath: "/tmp/A.mkv")
        XCTAssertEqual(store.completedOutput(for: fingerprint, options: .default), output)
    }

    func testPreparingClearsAnEarlierPartialAttempt() throws {
        let store = RemuxCacheStore(root: root)
        let fingerprint = SourceFingerprint(name: "A.mkv", sizeBytes: 10, modifiedAt: Date())
        let first = try store.prepareDirectory(for: fingerprint, options: .default)
        try Data("junk".utf8).write(to: first.appendingPathComponent("stray.tmp"))

        _ = try store.prepareDirectory(for: fingerprint, options: .default)
        let contents = try FileManager.default.contentsOfDirectory(atPath: first.path)
        XCTAssertFalse(contents.contains("stray.tmp"))
    }

    func testEntriesReportSizeAndCompletion() throws {
        let store = RemuxCacheStore(root: root)
        let fingerprint = SourceFingerprint(name: "A.mkv", sizeBytes: 10, modifiedAt: Date())
        let directory = try store.prepareDirectory(for: fingerprint, options: .default)
        try Data(repeating: 7, count: 2048)
            .write(to: store.outputURL(for: fingerprint, options: .default, container: .mp4))
        try store.markComplete(directory: directory, sourcePath: "/tmp/A.mkv")

        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isComplete)
        XCTAssertGreaterThanOrEqual(entries[0].sizeBytes, 2048)
        XCTAssertGreaterThanOrEqual(store.totalSizeBytes(), 2048)
    }

    func testRemoveAllEmptiesTheCache() throws {
        let store = RemuxCacheStore(root: root)
        for index in 0..<3 {
            let fingerprint = SourceFingerprint(name: "\(index).mkv", sizeBytes: Int64(index), modifiedAt: Date())
            _ = try store.prepareDirectory(for: fingerprint, options: .default)
        }
        XCTAssertEqual(store.entries().count, 3)
        store.removeAll()
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testEvictionDeletesFromDisk() throws {
        let store = RemuxCacheStore(root: root)
        let fingerprint = SourceFingerprint(name: "A.mkv", sizeBytes: 10, modifiedAt: Date())
        let directory = try store.prepareDirectory(for: fingerprint, options: .default)
        // No completion marker, so this is a leftover and always evictable.
        let removed = store.evict(limits: .default)
        XCTAssertEqual(removed, [directory.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFingerprintReadsRealFileAttributes() throws {
        let file = root.appendingPathComponent("sample.mkv")
        try Data(repeating: 1, count: 1234).write(to: file)
        let fingerprint = try RemuxCacheStore(root: root).fingerprint(of: file)
        XCTAssertEqual(fingerprint.name, "sample.mkv")
        XCTAssertEqual(fingerprint.sizeBytes, 1234)
    }

    func testPrepareRootCreatesTheDirectory() throws {
        let nested = root.appendingPathComponent("a/b/remux", isDirectory: true)
        let store = RemuxCacheStore(root: nested)
        XCTAssertTrue(store.prepareRoot())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    #if canImport(Darwin)
    func testPrepareRootExcludesTheCacheFromBackups() throws {
        // Multi-gigabyte derived files that rebuild in seconds have no business
        // in a Time Machine backup.
        let store = RemuxCacheStore(root: root.appendingPathComponent("remux", isDirectory: true))
        XCTAssertTrue(store.prepareRoot())
        let values = try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
    #endif

    func testDefaultLimitsAreModestBecauseARemuxIsCheap() {
        XCTAssertEqual(CacheLimits.default.maxTotalBytes, 20 * 1024 * 1024 * 1024)
        XCTAssertEqual(CacheLimits.default.maxAge, 7 * 24 * 60 * 60)
    }

    func testDefaultRootLandsUnderCaches() {
        let root = RemuxCacheStore.defaultRoot(bundleIdentifier: "io.bino.milktoast")
        XCTAssertTrue(root.path.contains("io.bino.milktoast"))
        XCTAssertEqual(root.lastPathComponent, "remux")
    }
}
