import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .simplifiedChinese: "中"
        case .english: "EN"
        }
    }
}

enum CopyKey: String, Sendable {
    case live
    case today
    case totalTokens
    case cachedTokens
    case input
    case output
    case reasoning
    case estimatedCost
    case currentSession
    case sessionCount
    case exact
    case estimatedUsage
    case updatedJustNow
    case noData
    case sourceUnavailable
    case retry
    case overview
    case dataSources
    case settings
    case refreshMode
    case eventDriven
    case realTimeRefresh
    case fiveMinuteRefresh
    case thirtyMinuteRefresh
    case manualRefresh
    case localOnly
    case localFirst
    case credentialsSavedLocally
    case connected
    case language
    case enabled
    case source
    case model
    case modelDistribution
    case toolDistribution
    case usageTrend
    case hourly
    case daily
    case tokensMetric
    case costMetric
    case other
    case unknownModel
    case noPricedCost
    case partialPricing
    case lastUpdated
    case syncing
    case refreshSucceeded
    case refreshFailed
    case relayCapacity
    case fiveHourWindow
    case sevenDayWindow
    case effectiveCapacity
    case windowBalances
    case currentAvailableAccounts
    case windowLimitedAccounts
    case dataIssues
    case nextRecovery
    case limitedByFiveHour
    case limitedBySevenDay
    case limitedByBothWindows
    case remainingCapacity
    case equivalentAccounts
    case schedulableAccounts
    case unavailableAccounts
    case staleData
    case missingWindow
    case excludedShadows
    case connectSub2API
    case configureConnection
    case configureAccountCapacity
    case detectedPlan
    case capacityType
    case account
    case saveConfiguration
    case capacityConfigurationHint
    case noAccountsFound
    case selectCapacityType
    case unconfiguredCapacity
    case serverAddress
    case adminEmail
    case password
    case verificationCode
    case connect
    case verify
    case restartLogin
    case disconnect
    case disconnectTitle
    case disconnectMessage
    case cancel
    case noWindowData
    case resetsAt
    case quit
}

enum Localizer {
    static func text(_ key: CopyKey, language: AppLanguage) -> String {
        switch language {
        case .simplifiedChinese:
            chinese[key] ?? key.rawValue
        case .english:
            english[key] ?? key.rawValue
        }
    }

    private static let chinese: [CopyKey: String] = [
        .live: "实时",
        .today: "今日",
        .totalTokens: "总 Token",
        .cachedTokens: "缓存 Token",
        .input: "输入",
        .output: "输出",
        .reasoning: "推理",
        .estimatedCost: "估算花费",
        .currentSession: "当前会话",
        .sessionCount: "会话数",
        .exact: "精确",
        .estimatedUsage: "估算",
        .updatedJustNow: "刚刚更新",
        .noData: "暂无用量数据",
        .sourceUnavailable: "未检测到本地用量",
        .retry: "重试",
        .overview: "概览",
        .dataSources: "数据源",
        .settings: "设置",
        .refreshMode: "刷新方式",
        .eventDriven: "实时（事件驱动）",
        .realTimeRefresh: "实时",
        .fiveMinuteRefresh: "每 5 分钟",
        .thirtyMinuteRefresh: "每 30 分钟",
        .manualRefresh: "手动刷新",
        .localOnly: "数据处理",
        .localFirst: "本地优先",
        .credentialsSavedLocally: "本地保存",
        .connected: "已连接",
        .language: "语言",
        .enabled: "开启",
        .source: "来源",
        .model: "模型",
        .modelDistribution: "模型分布",
        .toolDistribution: "工具分布",
        .usageTrend: "用量趋势",
        .hourly: "每小时",
        .daily: "每天",
        .tokensMetric: "Token",
        .costMetric: "费用",
        .other: "其他",
        .unknownModel: "未知模型",
        .noPricedCost: "暂无已定价费用",
        .partialPricing: "费用仅包含已定价模型",
        .lastUpdated: "最后更新",
        .syncing: "正在同步",
        .refreshSucceeded: "同步完成",
        .refreshFailed: "同步失败",
        .relayCapacity: "中转额度",
        .fiveHourWindow: "5 小时窗口",
        .sevenDayWindow: "7 天窗口",
        .effectiveCapacity: "当前可用账号",
        .windowBalances: "剩余额度 / 总额度",
        .currentAvailableAccounts: "当前可用",
        .windowLimitedAccounts: "窗口受限",
        .dataIssues: "数据异常",
        .nextRecovery: "下次恢复",
        .limitedByFiveHour: "受 5 小时窗口限制",
        .limitedBySevenDay: "受 7 天窗口限制",
        .limitedByBothWindows: "两个窗口共同限制",
        .remainingCapacity: "剩余额度",
        .equivalentAccounts: "账号等效容量",
        .schedulableAccounts: "可调度",
        .unavailableAccounts: "不可用",
        .staleData: "数据过期",
        .missingWindow: "未探测",
        .excludedShadows: "已排除影子账号",
        .connectSub2API: "连接 Sub2API",
        .configureConnection: "连接设置",
        .configureAccountCapacity: "配置账号额度",
        .detectedPlan: "检测套餐",
        .capacityType: "额度类型",
        .account: "账号",
        .saveConfiguration: "保存配置",
        .capacityConfigurationHint: "基础套餐由 Sub2API 识别；Pro 的额度倍数需要手动确认。",
        .noAccountsFound: "未找到可同步账号",
        .selectCapacityType: "请选择",
        .unconfiguredCapacity: "待配置额度",
        .serverAddress: "服务地址",
        .adminEmail: "管理员邮箱",
        .password: "密码",
        .verificationCode: "6 位验证码",
        .connect: "连接",
        .verify: "验证",
        .restartLogin: "重新登录",
        .disconnect: "断开连接",
        .disconnectTitle: "断开 Sub2API？",
        .disconnectMessage: "本机保存的登录状态将被清除，账号池数据停止同步。",
        .cancel: "取消",
        .noWindowData: "暂无可用窗口数据",
        .resetsAt: "重置",
        .quit: "退出 VibeToken"
    ]

    private static let english: [CopyKey: String] = [
        .live: "Live",
        .today: "Today",
        .totalTokens: "Total Tokens",
        .cachedTokens: "Cached Tokens",
        .input: "Input",
        .output: "Output",
        .reasoning: "Reasoning",
        .estimatedCost: "Estimated Cost",
        .currentSession: "Current Session",
        .sessionCount: "Sessions",
        .exact: "Exact",
        .estimatedUsage: "Estimated",
        .updatedJustNow: "Updated just now",
        .noData: "No usage data",
        .sourceUnavailable: "No local usage detected",
        .retry: "Retry",
        .overview: "Overview",
        .dataSources: "Data Sources",
        .settings: "Settings",
        .refreshMode: "Refresh Mode",
        .eventDriven: "Live (Event-driven)",
        .realTimeRefresh: "Real-time",
        .fiveMinuteRefresh: "Every 5 Minutes",
        .thirtyMinuteRefresh: "Every 30 Minutes",
        .manualRefresh: "Manual",
        .localOnly: "Data Processing",
        .localFirst: "Local-first",
        .credentialsSavedLocally: "Saved locally",
        .connected: "Connected",
        .language: "Language",
        .enabled: "On",
        .source: "Source",
        .model: "Model",
        .modelDistribution: "Model Distribution",
        .toolDistribution: "Tool Distribution",
        .usageTrend: "Usage Trend",
        .hourly: "Hourly",
        .daily: "Daily",
        .tokensMetric: "Tokens",
        .costMetric: "Cost",
        .other: "Other",
        .unknownModel: "Unknown Model",
        .noPricedCost: "No priced usage",
        .partialPricing: "Cost includes priced models only",
        .lastUpdated: "Last Updated",
        .syncing: "Syncing",
        .refreshSucceeded: "Synced",
        .refreshFailed: "Sync failed",
        .relayCapacity: "Relay Capacity",
        .fiveHourWindow: "5-Hour Window",
        .sevenDayWindow: "7-Day Window",
        .effectiveCapacity: "Accounts Available Now",
        .windowBalances: "Remaining / Total",
        .currentAvailableAccounts: "Available Now",
        .windowLimitedAccounts: "Window Limited",
        .dataIssues: "Data Issues",
        .nextRecovery: "Next Recovery",
        .limitedByFiveHour: "Limited by 5-hour window",
        .limitedBySevenDay: "Limited by 7-day window",
        .limitedByBothWindows: "Limited by both windows",
        .remainingCapacity: "Remaining",
        .equivalentAccounts: "Account-equivalent capacity",
        .schedulableAccounts: "Schedulable",
        .unavailableAccounts: "Unavailable",
        .staleData: "Stale",
        .missingWindow: "Unobserved",
        .excludedShadows: "Shadow accounts excluded",
        .connectSub2API: "Connect Sub2API",
        .configureConnection: "Connection Settings",
        .configureAccountCapacity: "Configure Account Capacity",
        .detectedPlan: "Detected Plan",
        .capacityType: "Capacity Type",
        .account: "Account",
        .saveConfiguration: "Save Configuration",
        .capacityConfigurationHint: "Sub2API detects the base plan. Confirm the Pro capacity multiplier manually.",
        .noAccountsFound: "No syncable accounts found",
        .selectCapacityType: "Select",
        .unconfiguredCapacity: "Capacity Not Set",
        .serverAddress: "Server Address",
        .adminEmail: "Admin Email",
        .password: "Password",
        .verificationCode: "6-digit code",
        .connect: "Connect",
        .verify: "Verify",
        .restartLogin: "Sign In Again",
        .disconnect: "Disconnect",
        .disconnectTitle: "Disconnect Sub2API?",
        .disconnectMessage: "Saved login state will be removed from this Mac and pool syncing will stop.",
        .cancel: "Cancel",
        .noWindowData: "No window data available",
        .resetsAt: "Resets",
        .quit: "Quit VibeToken"
    ]
}
