import Combine
import Sparkle
import SwiftUI

/// Sparkle owns updating, as of the move off Davit's hand-rolled updater.
///
/// What this buys over the 215 lines it replaced: an EdDSA signature over the
/// archive, which is a trust root independent of the Developer ID certificate,
/// plus delta support and the deferral UI. What it costs: a framework in the
/// bundle and a second signing key. The key point is that both Davit and
/// Don't Miss now use one mechanism, so a fix to either is a fix to both.
///
/// `SPUStandardUpdaterController` starts the scheduler itself; the check
/// interval and feed live in Info.plist (see `scripts/bundle.sh`), not here, so
/// there is exactly one place that decides them.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    /// Sparkle disables its own menu item while a check is in flight; mirroring
    /// that keeps our Settings button from starting a second one.
    @Published private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController

    /// Read from the bundle rather than a constant, so it cannot drift from
    /// what `scripts/bundle.sh` stamped in.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheck)
    }

    /// User-initiated. Sparkle presents its own window, including the
    /// "you're up to date" case, which the old updater had to render itself.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
