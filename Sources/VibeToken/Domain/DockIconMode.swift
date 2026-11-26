import Foundation

enum DockIconMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case menuBarOnly

    static let userDefaultsKey = "dockIconMode"

    var id: String { rawValue }

    func save(to userDefaults: UserDefaults = AppSettingsDefaults.shared) {
        userDefaults.set(rawValue, forKey: Self.userDefaultsKey)
    }

    static func load(from userDefaults: UserDefaults = AppSettingsDefaults.shared) -> DockIconMode {
        guard let rawValue = userDefaults.string(forKey: userDefaultsKey),
              let mode = DockIconMode(rawValue: rawValue) else {
            return .always
        }
        return mode
    }
}
