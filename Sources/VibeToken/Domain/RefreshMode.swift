import Foundation

enum RefreshMode: String, CaseIterable, Identifiable, Sendable {
    case realTime
    case fiveMinutes
    case thirtyMinutes
    case manual

    var id: String { rawValue }

    var usesFileEvents: Bool {
        self == .realTime
    }

    func pollingInterval(realTimeFallback: Duration) -> Duration? {
        switch self {
        case .realTime:
            realTimeFallback
        case .fiveMinutes:
            .seconds(5 * 60)
        case .thirtyMinutes:
            .seconds(30 * 60)
        case .manual:
            nil
        }
    }
}

enum RefreshTimestampFormatter {
    static func string(
        _ date: Date?,
        language: AppLanguage,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date else {
            return language == .simplifiedChinese ? "尚未同步" : "Not synced"
        }
        let formatter = DateFormatter()
        formatter.locale = language == .simplifiedChinese
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: date)
        return language == .simplifiedChinese
            ? "同步 \(time)"
            : "Synced \(time)"
    }
}
