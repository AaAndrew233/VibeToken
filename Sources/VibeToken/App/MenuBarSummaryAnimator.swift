import AppKit

@MainActor
final class MenuBarSummaryAnimator {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var displayedTokens: Int64?
    private var startTokens: Int64 = 0
    private var targetTokens: Int64?
    private var animationStartedAt: TimeInterval = 0
    private var estimatedCost: MoneyAmount?
    private var locale = Locale(identifier: "zh_CN")

    init(button: NSStatusBarButton) {
        self.button = button
    }

    func update(tokens: Int64?, estimatedCost: MoneyAmount?, locale: Locale) {
        self.estimatedCost = estimatedCost
        self.locale = locale

        guard let tokens else {
            stopAnimation()
            displayedTokens = nil
            targetTokens = nil
            render(tokens: nil)
            return
        }

        guard let displayedTokens,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopAnimation()
            self.displayedTokens = tokens
            targetTokens = tokens
            render(tokens: tokens)
            return
        }

        guard targetTokens != tokens || displayedTokens != tokens else {
            render(tokens: tokens)
            return
        }

        stopAnimation()
        startTokens = displayedTokens
        targetTokens = tokens
        animationStartedAt = ProcessInfo.processInfo.systemUptime

        let timer = Timer(
            timeInterval: 1 / TokenMotion.framesPerSecond,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceAnimation()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        stopAnimation()
    }

    private func advanceAnimation() {
        guard let targetTokens else {
            stopAnimation()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
        let progress = min(1, elapsed / TokenMotion.duration)
        let nextValue = TokenValueInterpolation.value(
            from: startTokens,
            to: targetTokens,
            progress: progress
        )
        displayedTokens = nextValue
        render(tokens: nextValue)

        if progress >= 1 {
            stopAnimation()
        }
    }

    private func render(tokens: Int64?) {
        button?.title = MenuBarSummaryFormatter.string(
            tokens: tokens,
            estimatedCost: estimatedCost,
            locale: locale
        )
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }
}
