import SwiftUI

enum TokenMotion {
    static let duration: TimeInterval = 1.2
    static let framesPerSecond: TimeInterval = 30
}

struct RollingTokenText: View, Animatable {
    private var value: Double
    private let locale: Locale

    init(_ value: Int64, locale: Locale = Locale(identifier: "zh_CN")) {
        self.value = Double(value)
        self.locale = locale
    }

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(
            TokenFormatter.string(
                Int64(value.rounded(.towardZero)),
                locale: locale
            )
        )
    }
}

enum TokenValueInterpolation {
    static func value(from start: Int64, to target: Int64, progress: Double) -> Int64 {
        guard progress > 0 else { return start }
        guard progress < 1 else { return target }
        let value = Double(start) + (Double(target) - Double(start)) * progress
        return Int64(value.rounded(.towardZero))
    }
}
