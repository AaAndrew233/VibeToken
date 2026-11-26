import Foundation

enum AppSettingsDefaults {
    static let suiteName = "app.vibetoken.mac"

    static var shared: UserDefaults {
        resolve(suiteName: suiteName, legacyDefaults: .standard)
    }

    static func resolve(
        suiteName: String,
        legacyDefaults: UserDefaults,
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> UserDefaults {
        // 打包运行时 standard 已对应应用配置域；不能将自身 bundle ID 传给 suite 初始化器。
        guard suiteName != currentBundleIdentifier else { return legacyDefaults }
        guard let defaults = UserDefaults(suiteName: suiteName) else { return legacyDefaults }
        // 固定配置域，避免从 app 包或开发可执行文件启动时读写不同位置。
        // 只补齐缺失值，旧启动方式留下的选择不能覆盖更新后的设置。
        for key in [DockIconMode.userDefaultsKey, LaunchAtLogin.preferenceKey] {
            if defaults.object(forKey: key) == nil, let value = legacyDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        return defaults
    }
}
