import Foundation
import Sparkle

@MainActor
final class AppUpdateController {
    private let standardController: SPUStandardUpdaterController?

    let isConfigured: Bool

    init(bundle: Bundle = .main) {
        guard AppUpdateConfiguration(infoDictionary: bundle.infoDictionary) != nil else {
            standardController = nil
            isConfigured = false
            return
        }

        let startsUpdater = ProcessInfo.processInfo.environment["VIBETOKEN_UI_TEST_MODE"] == nil
        standardController = SPUStandardUpdaterController(
            startingUpdater: startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        isConfigured = true
    }

    func checkForUpdates() {
        guard standardController?.updater.canCheckForUpdates == true else { return }
        standardController?.checkForUpdates(nil)
    }
}
