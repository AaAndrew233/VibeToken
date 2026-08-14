import Foundation

enum DockIconMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case menuBarOnly

    static let userDefaultsKey = "dockIconMode"

    var id: String { rawValue }

    static func load(from userDefaults: UserDefaults = .standard) -> DockIconMode {
        guard let rawValue = userDefaults.string(forKey: userDefaultsKey),
              let mode = DockIconMode(rawValue: rawValue) else {
            return .always
        }
        return mode
    }
}
