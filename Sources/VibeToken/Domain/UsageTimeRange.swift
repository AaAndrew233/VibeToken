import Foundation

enum UsageTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case hours24
    case days7
    case days30

    var id: String { rawValue }

    func startDate(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .today:
            calendar.startOfDay(for: now)
        case .hours24:
            now.addingTimeInterval(-24 * 60 * 60)
        case .days7:
            now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .days30:
            now.addingTimeInterval(-30 * 24 * 60 * 60)
        }
    }

    func title(language: AppLanguage) -> String {
        switch (self, language) {
        case (.today, .simplifiedChinese): "今天"
        case (.today, .english): "Today"
        case (.hours24, _): "24H"
        case (.days7, _): "7D"
        case (.days30, _): "30D"
        }
    }
}
