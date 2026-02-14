import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// Wrapper around Sparkle's updater for auto-update support.
///
/// When built with the Sparkle framework, this class configures and manages
/// automatic update checks. It exposes `canCheckForUpdates` and
/// `checkForUpdates()` for UI integration.
@MainActor
class SparkleUpdater: ObservableObject {

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif

    init() {
        #if canImport(Sparkle)
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller?.updater.canCheckForUpdates ?? false
        #else
        canCheckForUpdates = false
        #endif
    }

    /// Trigger an explicit update check.
    func checkForUpdates() {
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        lastUpdateCheckDate = Date()
        #else
        print("[SparkleUpdater] Sparkle not available – skipping update check")
        #endif
    }

    /// Whether automatic update checks are enabled.
    var automaticallyChecksForUpdates: Bool {
        get {
            #if canImport(Sparkle)
            return controller?.updater.automaticallyChecksForUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    /// The update check interval (in seconds).
    var updateCheckInterval: TimeInterval {
        get {
            #if canImport(Sparkle)
            return controller?.updater.updateCheckInterval ?? 86400
            #else
            return 86400
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller?.updater.updateCheckInterval = newValue
            #endif
        }
    }
}
