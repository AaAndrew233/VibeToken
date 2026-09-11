import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static let preferenceKey = "launchAtLogin"

    static func savedPreference(from userDefaults: UserDefaults = .standard) -> Bool? {
        guard userDefaults.object(forKey: preferenceKey) != nil else { return nil }
        return userDefaults.bool(forKey: preferenceKey)
    }

    static func savePreference(
        _ enabled: Bool,
        to userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(enabled, forKey: preferenceKey)
    }

    static var isRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    static func setRegistered(_ registered: Bool) throws {
        if registered {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
