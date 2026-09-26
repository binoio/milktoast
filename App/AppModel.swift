import AppKit
import Observation
import SwiftUI
import MilktoastCore

@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    private(set) var jobs: [RemuxJob] = []
    /// Non-nil when ffmpeg could not be found at all; the UI shows this instead
    /// of failing every job with the same message.
    private(set) var toolProblem: String?
    private(set) var cacheSizeBytes: Int64 = 0

    private var tools: ToolPaths?
    private var runner: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var pending: [RemuxJob] = []

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        resolveTools()
        tidyCache()
    }

    // MARK: - Intake

    /// Extensions Finder routes here via Info.plist. Anything else is still
    /// accepted — ffmpeg reads far more than Matroska, and refusing would only
    /// be annoying.
    static let recognizedExtensions: Set<String> = ["mkv", "mka", "mk3d", "mks", "webm"]

    func enqueue(_ urls: [URL]) {
        let additions = urls
            .map { $0.standardizedFileURL }
            .filter { url in
                !jobs.contains { $0.source == url && !$0.phase.isTerminal }
            }
            .map(RemuxJob.init(source:))
        guard !additions.isEmpty else { return }
        jobs.append(contentsOf: additions)
        pending.append(contentsOf: additions)
        startRunnerIfIdle()
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a movie to prepare for QuickTime Player."
        panel.prompt = "Play"
        if panel.runModal() == .OK {
            enqueue(panel.urls)
        }
    }

    // MARK: - Queue

    var hasWorkInFlight: Bool {
        jobs.contains { !$0.phase.isTerminal }
    }

    func cancel(_ job: RemuxJob) {
        pending.removeAll { $0.id == job.id }
        if case .queued = job.phase {
            job.phase = .cancelled
            return
        }
        // Cancelling the current task terminates ffmpeg via ProcessRunner.
        activeTask?.cancel()
    }

    func cancelAll() {
        pending.removeAll()
        for job in jobs where job.phase == .queued {
            job.phase = .cancelled
        }
        activeTask?.cancel()
        runner?.cancel()
    }

    /// Opens an already-prepared movie on demand.
    ///
    /// Used by the job row's button in prepare-only mode, and as a "play it
    /// again" affordance once a job has finished. Falls back to QuickTime Player
    /// when no player is configured, which is the point of the app.
    func openInPlayer(_ job: RemuxJob) {
        guard let output = job.output else { return }
        let choice = preferences.player.opensAPlayer ? preferences.player : .quickTimePlayer
        Task {
            do {
                job.phase = .handingOff
                try await PlayerHandoff.open(output, with: choice)
                job.phase = .playing
            } catch {
                job.phase = .ready
                fail(job, with: error)
            }
        }
    }

    /// Label for the manual open button, so it names the app it will actually use.
    var manualOpenTitle: String {
        let choice = preferences.player.opensAPlayer ? preferences.player : .quickTimePlayer
        switch choice {
        case .quickTimePlayer: return "Open in QuickTime"
        case .systemDefault: return "Open"
        case .custom: return "Open in \(PlayerHandoff.displayName(for: choice))"
        case .prepareOnly: return "Open"
        }
    }

    func removeFinished() {
        jobs.removeAll { $0.phase.isTerminal }
    }

    private func startRunnerIfIdle() {
        guard runner == nil else { return }
        runner = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, let job = self.takeNextJob() {
                let task = Task { @MainActor in await self.process(job) }
                self.activeTask = task
                await task.value
            }
            self?.runnerDidFinish()
        }
    }

    private func takeNextJob() -> RemuxJob? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    private func runnerDidFinish() {
        runner = nil
        activeTask = nil
        // Sweep once more now that the queue is drained: this is the last moment
        // the app is guaranteed to be running, and prepare-only jobs never went
        // through the pre-remux eviction at all.
        tidyCache(protecting: Set(jobs.compactMap { $0.output?.deletingLastPathComponent().lastPathComponent }))
        considerQuitting()
    }

    /// Applies the cache budget and refreshes the displayed size.
    ///
    /// Eviction runs at launch as well as around each job, so simply opening
    /// Milktoast is enough to clear out movies you finished with — it never
    /// depends on you remembering to tidy up.
    private func tidyCache(protecting: Set<String> = []) {
        let store = RemuxCacheStore(root: RemuxCacheStore.defaultRoot())
        let limits = preferences.cacheLimits
        Task.detached(priority: .utility) {
            store.prepareRoot()
            store.evict(limits: limits, protecting: protecting)
            let size = store.totalSizeBytes()
            await MainActor.run { [weak self] in self?.cacheSizeBytes = size }
        }
    }

    // MARK: - Work

    private func process(_ job: RemuxJob) async {
        guard let tools else {
            job.phase = .failed(toolProblem ?? "ffmpeg is unavailable.")
            return
        }

        let service = RemuxService(
            tools: tools,
            cache: RemuxCacheStore(root: RemuxCacheStore.defaultRoot()),
            capabilities: HostCapabilities.current(),
            options: preferences.remuxOptions,
            cacheLimits: preferences.cacheLimits
        )

        job.phase = .analyzing

        do {
            let output = try await service.remux(source: job.source) { event in
                // ProcessRunner's callbacks arrive off the main actor.
                Task { @MainActor in
                    Self.apply(event, to: job)
                }
            }

            job.output = output

            guard preferences.player.opensAPlayer else {
                job.phase = .ready
                return
            }

            job.phase = .handingOff
            try await PlayerHandoff.open(output, with: preferences.player)
            job.phase = .playing
        } catch is CancellationError {
            job.phase = .cancelled
        } catch let error as ProcessRunnerError {
            if case .cancelled = error {
                job.phase = .cancelled
            } else {
                fail(job, with: error)
            }
        } catch {
            fail(job, with: error)
        }
    }

    private func fail(_ job: RemuxJob, with error: Error) {
        let full = String(describing: error)
        // The first line is the headline; the rest goes behind the disclosure.
        let lines = full.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        job.phase = .failed(String(lines.first ?? "Failed"))
        job.failureDetail = lines.count > 1 ? String(lines[1]) : nil
    }

    private static func apply(_ event: RemuxEvent, to job: RemuxJob) {
        switch event {
        case .analyzing:
            job.phase = .analyzing
        case .planned(let plan):
            job.plan = plan
            // Only a video re-encode is slow enough to warrant a different
            // verb; an audio conversion still runs at disk speed.
            job.phase = .working(isEncode: plan.requiresVideoEncode)
        case .reusedCache(let url):
            job.reusedCache = true
            job.output = url
            job.fraction = 1
        case .started(let command):
            job.commandLine = command
        case .progress(let progress, let fraction):
            job.fraction = fraction
            job.speed = progress.speed
            job.secondsRemaining = progress.estimatedSecondsRemaining(
                duration: job.plan?.durationSeconds
            )
        case .finished:
            job.fraction = 1
            job.secondsRemaining = nil
        }
    }

    // MARK: - Tools

    private func resolveTools() {
        do {
            tools = try BundledTools.locate()
            toolProblem = nil
        } catch {
            tools = nil
            toolProblem = """
            Milktoast could not find ffmpeg. Install it with `brew install ffmpeg`, or \
            rebuild Milktoast.app with the helpers bundled (Scripts/build.sh).
            """
        }
    }

    // MARK: - Cache

    func refreshCacheSize() {
        let store = RemuxCacheStore(root: RemuxCacheStore.defaultRoot())
        cacheSizeBytes = store.totalSizeBytes()
    }

    func clearCache() {
        RemuxCacheStore(root: RemuxCacheStore.defaultRoot()).removeAll()
        refreshCacheSize()
    }

    func revealCache() {
        let root = RemuxCacheStore.defaultRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path)
    }

    var cacheSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: cacheSizeBytes)
    }

    // MARK: - Lifecycle

    /// Once every movie is playing, Milktoast has nothing left to do. Sticking around
    /// would leave a second icon in the Dock next to QuickTime Player for no
    /// reason. Failures keep the window open so the message can be read, and so
    /// does prepare-only mode, where the window is how you reach the result.
    private func considerQuitting() {
        guard preferences.quitAfterHandoff, preferences.player.opensAPlayer else { return }
        guard !jobs.isEmpty else { return }
        guard jobs.allSatisfy({ $0.phase == .playing }) else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !hasWorkInFlight, jobs.allSatisfy({ $0.phase == .playing }) else { return }
            NSApp.terminate(nil)
        }
    }
}
