import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static let preferenceKey = "launchAtLogin"

    static func savedPreference(from userDefaults: UserDefaults = AppSettingsDefaults.shared) -> Bool? {
        guard userDefaults.object(forKey: preferenceKey) != nil else { return nil }
        return userDefaults.bool(forKey: preferenceKey)
    }

    static func savePreference(
        _ enabled: Bool,
        to userDefaults: UserDefaults = AppSettingsDefaults.shared
    ) {
        userDefaults.set(enabled, forKey: preferenceKey)
    }

    static func updatePreference(
        _ enabled: Bool,
        to userDefaults: UserDefaults = AppSettingsDefaults.shared,
        register: (Bool) throws -> Void = { try setRegistered($0) }
    ) throws {
        // 系统注册失败时仍保留用户选择，下一次启动可继续恢复。
        savePreference(enabled, to: userDefaults)
        try register(enabled)
    }

    static func restorePreference(
        from userDefaults: UserDefaults = AppSettingsDefaults.shared,
        register: (Bool) throws -> Void = { try setRegistered($0) }
    ) throws {
        guard let enabled = savedPreference(from: userDefaults) else { return }
        try register(enabled)
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

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setRegistered(
        _ registered: Bool,
        currentStatus: SMAppService.Status = SMAppService.mainApp.status,
        register: () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) throws {
        if registered {
            // 等待批准也属于已注册；不能重复注册或绕过用户在系统设置中的选择。
            guard currentStatus != .enabled, currentStatus != .requiresApproval else { return }
            try register()
        } else {
            guard currentStatus != .notRegistered, currentStatus != .notFound else { return }
            try unregister()
        }
    }
}
