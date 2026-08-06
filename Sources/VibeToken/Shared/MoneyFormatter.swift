import Foundation

struct MoneyAmount: Equatable, Sendable {
    let micros: Int64
    let currencyCode: String
}

enum MoneyFormatter {
    static func string(_ amount: MoneyAmount, locale: Locale = Locale(identifier: "zh_CN")) -> String {
        let decimal = Decimal(amount.micros) / Decimal(1_000_000)
        let absoluteDecimal = abs(decimal)
        let scale: (divisor: Decimal, suffix: String)?
        if absoluteDecimal >= 1_000_000 {
            scale = (1_000_000, "M")
        } else if absoluteDecimal >= 1_000 {
            scale = (1_000, "K")
        } else {
            scale = nil
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = amount.currencyCode
        if amount.currencyCode == "USD" {
            formatter.currencySymbol = "$"
        }
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let displayValue = scale.map { decimal / $0.divisor } ?? decimal
        let formatted = formatter.string(from: displayValue as NSDecimalNumber) ?? "--"
        return formatted == "--" ? formatted : "\(formatted)\(scale?.suffix ?? "")"
    }
}
