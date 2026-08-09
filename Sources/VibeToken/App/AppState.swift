import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private(set) var snapshot: TokenUsageSnapshot?
    private(set) var currentSessionSnapshot: TokenUsageSnapshot?
    private(set) var estimatedCost: MoneyAmount?
    private(set) var costCoveragePercentage: Decimal?
    private(set) var isCostEstimateComplete = false
    private(set) var sessionCount = 0
    private(set) var modelCount = 0
    private(set) var modelDistribution: [UsageDistributionItem] = []
    private(set) var toolDistribution: [UsageDistributionItem] = []
    private(set) var trendPoints: [UsageTrendPoint] = []
    private(set) var trendGranularity = UsageTrendGranularity.hourly
    private(set) var sub2APIPoolSnapshot: Sub2APIPoolSnapshot?
    private(set) var sub2APIAccountCapacityOptions: [Sub2APIAccountCapacityOption] = []
    private(set) var sub2APIConnection: Sub2APIConnection?
    private(set) var sub2APIStatus = Sub2APIStatus.disconnected
    private(set) var sub2APILastError: Sub2APIError?
    private(set) var pendingSub2APIMaskedEmail: String?
    private(set) var selectedTimeRange: UsageTimeRange
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?
    var sourceStatus: SourceStatus = .loading
    var refreshMode: RefreshMode {
        didSet {
            guard refreshMode != oldValue else { return }
            UserDefaults.standard.set(refreshMode.rawValue, forKey: Self.refreshModeKey)
            guard isMonitoringStarted else { return }
            restartMonitoring()
        }
    }
    var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            updateMenuBarText()
        }
    }
    @ObservationIgnored private let ingestionCoordinator: UsageIngestionCoordinator
    @ObservationIgnored private let sub2APIPoolMonitor: Sub2APIPoolMonitor
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private let sub2APIRefreshInterval: Duration
    @ObservationIgnored private let costEstimator: CostEstimator
    @ObservationIgnored private let fileObserver: CodexFileChangeObserver
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var sub2APIMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var isMonitoringStarted = false
    @ObservationIgnored private var refreshRequestedWhileBusy = false
    @ObservationIgnored private var isSub2APIRefreshInFlight = false
    @ObservationIgnored private var isSub2APIVisualFixture = false
    @ObservationIgnored private var hasAttemptedSub2APIRestore = false
    @ObservationIgnored var onMenuBarSummaryChange: ((Int64?, MoneyAmount?, Locale) -> Void)?

    private static let languageKey = "appLanguage"
    private static let timeRangeKey = "usageTimeRange"
    private static let refreshModeKey = "refreshMode"

    init(
        ingestionCoordinator: UsageIngestionCoordinator,
        sub2APIPoolMonitor: Sub2APIPoolMonitor,
        refreshInterval: Duration,
        sub2APIRefreshInterval: Duration,
        fileEventDebounceMilliseconds: Int,
        costEstimator: CostEstimator
    ) {
        self.ingestionCoordinator = ingestionCoordinator
        self.sub2APIPoolMonitor = sub2APIPoolMonitor
        self.refreshInterval = refreshInterval
        self.sub2APIRefreshInterval = sub2APIRefreshInterval
        self.costEstimator = costEstimator
        fileObserver = CodexFileChangeObserver(
            debounceMilliseconds: fileEventDebounceMilliseconds
        )
        language = ProcessInfo.processInfo.environment["VIBETOKEN_UI_TEST_LANGUAGE"]
            .flatMap(AppLanguage.init(rawValue:))
            ?? UserDefaults.standard.string(forKey: Self.languageKey)
                .flatMap(AppLanguage.init(rawValue:))
            ?? .simplifiedChinese
        selectedTimeRange = UserDefaults.standard.string(forKey: Self.timeRangeKey)
            .flatMap(UsageTimeRange.init(rawValue:)) ?? .today
        refreshMode = UserDefaults.standard.string(forKey: Self.refreshModeKey)
            .flatMap(RefreshMode.init(rawValue:)) ?? .realTime
    }

    func startMonitoring() {
        guard !isMonitoringStarted else { return }
        isMonitoringStarted = true
        restartMonitoring()
        startSub2APIMonitoring()
    }

    private func restartMonitoring() {
        monitorTask?.cancel()
        fileObserver.stop()
        let activeMode = refreshMode
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            guard let interval = activeMode.pollingInterval(
                realTimeFallback: refreshInterval
            ) else {
                return
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await refresh()
            }
        }
    }

    private func startSub2APIMonitoring() {
        sub2APIMonitorTask?.cancel()
        let interval = sub2APIRefreshInterval
        sub2APIMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await restoreSub2APIConnectionIfNeeded()
                _ = await refreshSub2APIPool(force: true, displaysProgress: false)
            }
        }
    }

    func stopMonitoring() {
        isMonitoringStarted = false
        monitorTask?.cancel()
        monitorTask = nil
        sub2APIMonitorTask?.cancel()
        sub2APIMonitorTask = nil
        fileObserver.stop()
    }

    func selectTimeRange(_ timeRange: UsageTimeRange) {
        guard selectedTimeRange != timeRange else { return }
        selectedTimeRange = timeRange
        UserDefaults.standard.set(timeRange.rawValue, forKey: Self.timeRangeKey)
        Task { [weak self] in
            await self?.refreshAggregation()
        }
    }

    @discardableResult
    func refresh(forceRemote: Bool = false) async -> Bool {
        guard !isRefreshing else {
            refreshRequestedWhileBusy = true
            return false
        }

        isRefreshing = true
        var didSucceed = false
        repeat {
            refreshRequestedWhileBusy = false
            didSucceed = await performRefresh(forceRemote: forceRemote) || didSucceed
        } while refreshRequestedWhileBusy && !Task.isCancelled
        isRefreshing = false
        return didSucceed
    }

    func text(_ key: CopyKey) -> String {
        Localizer.text(key, language: language)
    }

    func timeRangeTitle(_ range: UsageTimeRange? = nil) -> String {
        (range ?? selectedTimeRange).title(language: language)
    }

    func refreshModeTitle(_ mode: RefreshMode? = nil) -> String {
        switch mode ?? refreshMode {
        case .realTime: text(.realTimeRefresh)
        case .fiveMinutes: text(.fiveMinuteRefresh)
        case .thirtyMinutes: text(.thirtyMinuteRefresh)
        case .manual: text(.manualRefresh)
        }
    }

    func estimatedCostText() -> String {
        guard let estimatedCost else { return "--" }
        return MoneyFormatter.string(estimatedCost, locale: displayLocale)
    }

    func costCoverageText() -> String? {
        guard !isCostEstimateComplete, let costCoveragePercentage else { return nil }
        if costCoveragePercentage >= Decimal(9_995) / Decimal(100) {
            return language == .simplifiedChinese
                ? "定价覆盖 >99.9%"
                : ">99.9% priced"
        }
        let formatter = NumberFormatter()
        formatter.locale = displayLocale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let percentage = formatter.string(from: costCoveragePercentage as NSDecimalNumber) ?? "0.0"
        return language == .simplifiedChinese
            ? "定价覆盖 \(percentage)%"
            : "\(percentage)% priced"
    }

    func sessionCountText() -> String {
        language == .simplifiedChinese
            ? "\(sessionCount) 个会话"
            : "\(sessionCount) sessions"
    }

    func modelSummaryText() -> String {
        if modelCount == 0 { return "--" }
        if modelCount == 1 { return snapshot?.model ?? "--" }
        return language == .simplifiedChinese
            ? "\(modelCount) 个模型"
            : "\(modelCount) models"
    }

    func sourceCountText() -> String {
        language == .simplifiedChinese
            ? "\(toolDistribution.count) 个工具"
            : "\(toolDistribution.count) tools"
    }

    func connectSub2API(serverURL: String, email: String, password: String) async {
        guard !sub2APIStatus.isBusy else { return }
        sub2APIStatus = .connecting
        sub2APILastError = nil
        do {
            let result = try await sub2APIPoolMonitor.login(
                serverURL: serverURL,
                email: email,
                password: password
            )
            switch result {
            case .authenticated:
                pendingSub2APIMaskedEmail = nil
                sub2APIConnection = await sub2APIPoolMonitor.savedConnection()
                _ = await refreshSub2APIPool(force: true)
            case .requiresTwoFactor(_, let maskedEmail):
                pendingSub2APIMaskedEmail = maskedEmail
                sub2APIStatus = .requiresTwoFactor(maskedEmail: maskedEmail)
            }
        } catch let error as Sub2APIError {
            PrivacyLog.relay.error("Sub2API authentication failed: \(String(describing: error), privacy: .public)")
            sub2APILastError = error
            sub2APIStatus = .failed(error)
        } catch {
            sub2APILastError = .serverUnavailable
            sub2APIStatus = .failed(.serverUnavailable)
        }
    }

    func completeSub2APITwoFactor(code: String) async {
        guard case .requiresTwoFactor = sub2APIStatus else { return }
        sub2APIStatus = .connecting
        sub2APILastError = nil
        do {
            try await sub2APIPoolMonitor.completeTwoFactor(code: code)
            pendingSub2APIMaskedEmail = nil
            sub2APIConnection = await sub2APIPoolMonitor.savedConnection()
            _ = await refreshSub2APIPool(force: true)
        } catch let error as Sub2APIError {
            PrivacyLog.relay.error("Sub2API 2FA failed: \(String(describing: error), privacy: .public)")
            sub2APILastError = error
            sub2APIStatus = .requiresTwoFactor(maskedEmail: pendingSub2APIMaskedEmail ?? "")
        } catch {
            sub2APILastError = .serverUnavailable
            sub2APIStatus = .requiresTwoFactor(maskedEmail: pendingSub2APIMaskedEmail ?? "")
        }
    }

    func cancelSub2APITwoFactor() async {
        await sub2APIPoolMonitor.cancelTwoFactor()
        pendingSub2APIMaskedEmail = nil
        sub2APILastError = nil
        sub2APIConnection = await sub2APIPoolMonitor.savedConnection()
        sub2APIStatus = sub2APIConnection == nil ? .disconnected : .connected
    }

    func disconnectSub2API() async {
        do {
            try await sub2APIPoolMonitor.disconnect()
            sub2APIConnection = nil
            sub2APIPoolSnapshot = nil
            sub2APIAccountCapacityOptions = []
            sub2APILastError = nil
            pendingSub2APIMaskedEmail = nil
            sub2APIStatus = .disconnected
        } catch let error as Sub2APIError {
            PrivacyLog.relay.error("Sub2API refresh failed: \(String(describing: error), privacy: .public)")
            sub2APILastError = error
            sub2APIStatus = .failed(error)
        } catch {
            sub2APILastError = .secureStorageFailed
            sub2APIStatus = .failed(.secureStorageFailed)
        }
    }

    func prepareSub2APICapacityConfiguration() async {
        if isSub2APIVisualFixture { return }
        guard sub2APIConnection != nil, !sub2APIStatus.isBusy else { return }
        if sub2APIAccountCapacityOptions.isEmpty {
            _ = await refreshSub2APIPool(force: true)
        } else {
            await loadSub2APICapacityOptions()
        }
    }

    @discardableResult
    func saveSub2APICapacitySelections(
        _ tiersByAccountID: [Int64: Sub2APICapacityTier]
    ) async -> Bool {
        guard sub2APIConnection != nil, !sub2APIStatus.isBusy else { return false }
        sub2APIStatus = .syncing
        sub2APILastError = nil
        do {
            let selections = tiersByAccountID.map {
                Sub2APIAccountCapacitySelection(accountID: $0.key, tier: $0.value)
            }
            if let snapshot = try await sub2APIPoolMonitor.saveCapacitySelections(selections) {
                sub2APIPoolSnapshot = snapshot
            }
            sub2APIAccountCapacityOptions = try await sub2APIPoolMonitor.capacityOptions()
            sub2APIStatus = .connected
            return true
        } catch let error as Sub2APIError {
            sub2APILastError = error
            sub2APIStatus = .failed(error)
            return false
        } catch {
            sub2APILastError = .secureStorageFailed
            sub2APIStatus = .failed(.secureStorageFailed)
            return false
        }
    }

    func installSub2APIVisualTestFixture() {
        guard let fixtureURL = URL(string: "https://relay.example.com/api/v1") else { return }
        isSub2APIVisualFixture = true
        let now = Date()
        sub2APIConnection = Sub2APIConnection(
            baseURL: fixtureURL,
            email: "admin@example.com"
        )
        sub2APIPoolSnapshot = Sub2APIPoolSnapshot(
            totalAccounts: 11,
            eligibleAccounts: 11,
            excludedShadowAccounts: 0,
            unavailableAccounts: 0,
            missingWindowAccounts: 0,
            staleWindowAccounts: 0,
            unconfiguredCapacityAccounts: 0,
            effectiveCapacity: Sub2APIEffectiveCapacitySnapshot(
                observedAccounts: 11,
                availableAccounts: 1,
                windowLimitedAccounts: 10,
                remainingEquivalentAccounts: 0.79,
                fiveHourRemainingEquivalentAccounts: 1,
                sevenDayRemainingEquivalentAccounts: 0.79,
                availableFiveHourRemainingFraction: 1,
                availableSevenDayRemainingFraction: 0.79,
                nextRecoveryAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                totalCapacityWeight: 87
            ),
            fiveHour: Sub2APIWindowSnapshot(
                observedAccounts: 11,
                remainingEquivalentAccounts: 1,
                totalCapacityWeight: 87,
                nextResetAt: now.addingTimeInterval(75 * 60)
            ),
            sevenDay: Sub2APIWindowSnapshot(
                observedAccounts: 11,
                remainingEquivalentAccounts: 0.79,
                totalCapacityWeight: 87,
                nextResetAt: now.addingTimeInterval(2 * 24 * 60 * 60)
            ),
            plans: [
                Sub2APIPlanSnapshot(
                    plan: "Plus",
                    accountCount: 7,
                    fiveHour: Sub2APIWindowSnapshot(
                        observedAccounts: 7,
                        remainingEquivalentAccounts: 1,
                        totalCapacityWeight: 7,
                        nextResetAt: nil
                    ),
                    sevenDay: Sub2APIWindowSnapshot(
                        observedAccounts: 7,
                        remainingEquivalentAccounts: 0.79,
                        totalCapacityWeight: 7,
                        nextResetAt: nil
                    )
                ),
                Sub2APIPlanSnapshot(
                    plan: "Pro",
                    accountCount: 4,
                    fiveHour: Sub2APIWindowSnapshot(
                        observedAccounts: 4,
                        remainingEquivalentAccounts: 0,
                        totalCapacityWeight: 80,
                        nextResetAt: nil
                    ),
                    sevenDay: Sub2APIWindowSnapshot(
                        observedAccounts: 4,
                        remainingEquivalentAccounts: 0,
                        totalCapacityWeight: 80,
                        nextResetAt: nil
                    )
                )
            ],
            fetchedAt: now
        )
        sub2APIAccountCapacityOptions = (1...11).map { id in
            let isPro = id <= 4
            return Sub2APIAccountCapacityOption(
                accountID: Int64(id),
                displayName: nil,
                detectedPlan: isPro ? "Pro" : "Plus",
                selectedTier: isPro ? .pro20 : .plus
            )
        }
        sub2APIStatus = .connected
    }

    private func performRefresh(forceRemote: Bool) async -> Bool {
        do {
            await restoreSub2APIConnectionIfNeeded()
            if snapshot == nil {
                sourceStatus = .loading
            }
            try await ingestionCoordinator.ingestRecentSessions()
            currentSessionSnapshot = try await ingestionCoordinator.currentSnapshot()
            let didRefreshAggregation = await refreshAggregation()
            if refreshMode.usesFileEvents {
                let targets = await ingestionCoordinator.watchTargets()
                fileObserver.watch(
                    fileURLs: targets.fileURLs,
                    directoryURLs: targets.directoryURLs
                ) { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.refresh()
                    }
                }
            } else {
                fileObserver.stop()
            }
            let didRefreshPool = await refreshSub2APIPool(force: forceRemote)
            return didRefreshAggregation && didRefreshPool
        } catch let error as AppError {
            sourceStatus = .failed(error.errorDescription ?? "")
            return false
        } catch is CancellationError {
            return false
        } catch {
            PrivacyLog.ingestion.error(
                "Usage refresh failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            sourceStatus = .failed(AppError.unexpected("").errorDescription ?? "")
            return false
        }
    }

    private func restoreSub2APIConnectionIfNeeded() async {
        guard !hasAttemptedSub2APIRestore, !isSub2APIVisualFixture else { return }
        hasAttemptedSub2APIRestore = true
        sub2APIConnection = await sub2APIPoolMonitor.savedConnection()
    }

    @discardableResult
    private func refreshSub2APIPool(
        force: Bool,
        displaysProgress: Bool = true
    ) async -> Bool {
        if isSub2APIVisualFixture { return true }
        guard sub2APIConnection != nil else {
            sub2APIStatus = .disconnected
            return true
        }
        guard !isSub2APIRefreshInFlight else { return true }
        isSub2APIRefreshInFlight = true
        defer { isSub2APIRefreshInFlight = false }
        if displaysProgress && (sub2APIPoolSnapshot == nil || force) {
            sub2APIStatus = .syncing
        }
        do {
            if let snapshot = try await sub2APIPoolMonitor.refresh(force: force) {
                sub2APIPoolSnapshot = snapshot
                sub2APIAccountCapacityOptions = try await sub2APIPoolMonitor.capacityOptions()
                sub2APILastError = nil
                sub2APIStatus = .connected
            } else {
                sub2APIStatus = .disconnected
            }
            return true
        } catch is CancellationError {
            return false
        } catch let error as Sub2APIError {
            sub2APILastError = error
            sub2APIStatus = .failed(error)
            return false
        } catch {
            sub2APILastError = .serverUnavailable
            sub2APIStatus = .failed(.serverUnavailable)
            return false
        }
    }

    private func loadSub2APICapacityOptions() async {
        do {
            sub2APIAccountCapacityOptions = try await sub2APIPoolMonitor.capacityOptions()
        } catch let error as Sub2APIError {
            sub2APILastError = error
            sub2APIStatus = .failed(error)
        } catch {
            sub2APILastError = .secureStorageFailed
            sub2APIStatus = .failed(.secureStorageFailed)
        }
    }

    @discardableResult
    private func refreshAggregation() async -> Bool {
        do {
            let range = selectedTimeRange
            let now = Date()
            let aggregation = try await ingestionCoordinator.aggregate(range: range, now: now)
            let trend = try await ingestionCoordinator.trend(range: range, now: now)
            guard selectedTimeRange == range else { return false }
            snapshot = aggregation.snapshot
            sessionCount = aggregation.sessionCount
            modelCount = aggregation.modelSnapshots.count
            modelDistribution = aggregation.modelSnapshots.map { snapshot in
                let estimate = costEstimator.estimate(for: snapshot)?.amount
                return UsageDistributionItem(
                    id: snapshot.model ?? "unknown-model",
                    displayName: displayName(forModel: snapshot.model),
                    totalTokens: snapshot.totalTokens,
                    estimatedCost: estimate,
                    isCostComplete: estimate != nil
                )
            }
            toolDistribution = aggregation.sourceBreakdowns.map { breakdown in
                let estimates = breakdown.modelSnapshots.compactMap {
                    costEstimator.estimate(for: $0)?.amount
                }
                return UsageDistributionItem(
                    id: breakdown.sourceIdentifier,
                    displayName: breakdown.displayName,
                    totalTokens: breakdown.modelSnapshots.reduce(0) {
                        saturatingAdd($0, $1.totalTokens)
                    },
                    estimatedCost: sum(estimates),
                    isCostComplete: estimates.count == breakdown.modelSnapshots.count
                )
            }
            let costCoverage = costEstimator.estimateKnown(for: aggregation.modelSnapshots)
            estimatedCost = costCoverage?.amount
            costCoveragePercentage = costCoverage?.coveragePercentage
            isCostEstimateComplete = costCoverage?.isComplete ?? false
            trendGranularity = trend.granularity
            trendPoints = UsageTrendBuilder.points(
                from: trend,
                costEstimator: costEstimator
            )
            sourceStatus = currentSessionSnapshot == nil && snapshot == nil ? .noData : .online
            lastRefreshAt = Date()
            updateMenuBarText()
            return true
        } catch {
            PrivacyLog.database.error(
                "Usage aggregation failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            sourceStatus = .failed(AppError.unexpected("").errorDescription ?? "")
            return false
        }
    }

    private var displayLocale: Locale {
        language == .simplifiedChinese
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
    }

    private func displayName(forModel model: String?) -> String {
        guard let model, !model.isEmpty else { return text(.unknownModel) }
        return model
    }

    private func sum(_ amounts: [MoneyAmount]) -> MoneyAmount? {
        guard let currencyCode = amounts.first?.currencyCode else { return nil }
        var total: Int64 = 0
        for amount in amounts where amount.currencyCode == currencyCode {
            total = saturatingAdd(total, amount.micros)
        }
        return MoneyAmount(micros: total, currencyCode: currencyCode)
    }

    private func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }

    private func updateMenuBarText() {
        onMenuBarSummaryChange?(
            snapshot?.totalTokens,
            estimatedCost,
            displayLocale
        )
    }

}
