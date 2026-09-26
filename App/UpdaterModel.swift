#if canImport(Sparkle)
import Combine
import Foundation
import Sparkle

/// Sparkle updater wrapper for the Developer ID build.
///
/// The updater is started manually rather than on construction so a bare
/// `swift run` binary — which has no Info.plist and therefore no feed URL —
/// never spins up scheduled update checks.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    @Published var canCheckForUpdates = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            controller.startUpdater()
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
