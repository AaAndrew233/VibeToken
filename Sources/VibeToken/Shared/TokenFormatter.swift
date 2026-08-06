import Foundation

enum TokenFormatter {
    static func string(_ value: Int64, locale: Locale = Locale(identifier: "zh_CN")) -> String {
        let absoluteValue = Decimal(value.magnitude)
        let scale: (divisor: Decimal, suffix: String)?
        if absoluteValue >= 1_000_000_000 {
            scale = (1_000_000_000, "B")
        } else if absoluteValue >= 1_000_000 {
            scale = (1_000_000, "M")
        } else if absoluteValue >= 1_000 {
            scale = (1_000, "K")
        } else {
            scale = nil
        }

        guard let scale else {
            return value.formatted(
                IntegerFormatStyle<Int64>.number
                    .grouping(.automatic)
                    .locale(locale)
            )
        }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let signedValue = value < 0 ? -absoluteValue : absoluteValue
        let compactValue = signedValue / scale.divisor
        return "\(formatter.string(from: compactValue as NSDecimalNumber) ?? "0")\(scale.suffix)"
    }
}
