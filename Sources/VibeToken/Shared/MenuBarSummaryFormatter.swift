import Foundation

enum MenuBarSummaryFormatter {
    static func string(
        tokens: Int64?,
        estimatedCost: MoneyAmount?,
        locale: Locale
    ) -> String {
        let tokenText = tokens.map { TokenFormatter.string($0, locale: locale) } ?? "--"
        let costText = estimatedCost.map { MoneyFormatter.string($0, locale: locale) } ?? "--"
        return "\(tokenText)｜\(costText)"
    }
}
