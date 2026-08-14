import Charts
import SwiftUI

struct MenuBarView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var distributionMetric = UsageDistributionMetric.tokens
    @State private var trendMetric = UsageDistributionMetric.tokens
    @State private var hoveredTrendPoint: UsageTrendPoint?
    @State private var highlightedDistributionKey: String?
    @State private var manualRefreshFeedback = ManualRefreshFeedback.idle
    @State private var showingSub2APIConnection = false

    let onQuit: () -> Void

    private let distributionColors: [Color] = [
        Color(red: 0.18, green: 0.48, blue: 0.96),
        Color(red: 0.10, green: 0.67, blue: 0.48),
        Color(red: 0.96, green: 0.57, blue: 0.15),
        Color(red: 0.92, green: 0.28, blue: 0.40),
        Color(red: 0.53, green: 0.36, blue: 0.91),
        Color(red: 0.10, green: 0.64, blue: 0.73)
    ]

    private var snapshot: TokenUsageSnapshot {
        state.snapshot ?? .empty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    rangePicker
                    Divider()
                    summary
                    Divider()
                    breakdown
                    Divider()
                    Sub2APIPoolSection(state: state) {
                        showingSub2APIConnection = true
                    }
                    Divider()
                    usageTrend
                    Divider()
                    distributions
                    Divider()
                    activity
                }
            }
            .scrollIndicators(.automatic)
            Divider()
            footer
        }
        .frame(width: 500, height: 720)
        .background(.regularMaterial)
        .onChange(of: state.selectedTimeRange) {
            hoveredTrendPoint = nil
            highlightedDistributionKey = nil
        }
        .onChange(of: distributionMetric) {
            highlightedDistributionKey = nil
        }
        .overlay {
            if showingSub2APIConnection {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingSub2APIConnection = false
                        }

                    Sub2APIConnectionView(
                        state: state,
                        isPresented: $showingSub2APIConnection
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
                    .padding(28)
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: showingSub2APIConnection
        )
        .onAppear {
            if ProcessInfo.processInfo.environment["VIBETOKEN_UI_TEST_SUB2API_SHEET"] == "1" {
                showingSub2APIConnection = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("VibeToken")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            statusLabel
            Menu {
                ForEach(AppLanguage.allCases) { language in
                    Button(language.shortLabel) {
                        state.language = language
                    }
                }
            } label: {
                Label(state.language.shortLabel, systemImage: "globe")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state.sourceStatus {
        case .loading:
            ProgressView().controlSize(.small)
        case .online:
            HStack(spacing: 5) {
                Text(state.text(.live))
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        case .noData, .unavailable, .failed:
            Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
                get: { state.selectedTimeRange },
                set: { state.selectTimeRange($0) }
            )) {
                ForEach(UsageTimeRange.allCases) { range in
                    Text(state.timeRangeTitle(range)).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            dockIconPicker
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var dockIconPicker: some View {
        Picker(selection: Binding(
            get: { state.dockIconMode },
            set: { state.dockIconMode = $0 }
        )) {
            ForEach(DockIconMode.allCases) { mode in
                Text(state.dockIconModeTitle(mode)).tag(mode)
            }
        } label: {
            Label(state.text(.dockIcon), systemImage: "dock.rectangle")
                .font(.system(size: 12))
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.timeRangeTitle())
                        .font(.system(size: 13, weight: .semibold))
                    Text(state.text(.totalTokens))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(state.text(.exact))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.teal)
            }

            RollingTokenText(snapshot.totalTokens, locale: tokenLocale)
                .font(.system(size: 46, weight: .medium, design: .rounded))
                .monospacedDigit()
                .animation(tokenAnimation, value: snapshot.totalTokens)
                .lineLimit(1)
                .minimumScaleFactor(0.62)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.text(.estimatedCost))
                    .foregroundStyle(.secondary)
                Text(state.estimatedCostText())
                    .fontWeight(.semibold)
                Spacer()
                if let coverage = state.costCoverageText() {
                    Text(coverage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 14))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var breakdown: some View {
        HStack(spacing: 0) {
            metric(state.text(.cachedTokens), snapshot.cachedInputTokens, color: .teal)
            metric(state.text(.input), snapshot.inputTokens, color: .blue)
            metric(state.text(.output), snapshot.outputTokens, color: .purple)
            metric(state.text(.reasoning), snapshot.reasoningTokens, color: .secondary)
        }
        .padding(.vertical, 14)
    }

    private func metric(_ title: String, _ value: Int64, color: Color) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            RollingTokenText(value, locale: tokenLocale)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .animation(tokenAnimation, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    private var usageTrend: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(state.text(.usageTrend), systemImage: "chart.xyaxis.line")
                    .font(.system(size: 13, weight: .semibold))
                Text(state.text(state.trendGranularity == .hourly ? .hourly : .daily))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $trendMetric) {
                    Text(state.text(.tokensMetric)).tag(UsageDistributionMetric.tokens)
                    Text(state.text(.costMetric)).tag(UsageDistributionMetric.cost)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 126)
            }

            if state.trendPoints.isEmpty || maximumTrendValue == 0 {
                Text(trendMetric == .cost ? state.text(.noPricedCost) : state.text(.noData))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                if let point = highlightedTrendPoint {
                    HStack(alignment: .firstTextBaseline) {
                        Text(trendDateLabel(point.bucketStart))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formattedTrendValue(point))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }

                Chart {
                    ForEach(state.trendPoints) { point in
                        BarMark(
                            x: .value("Time", point.bucketStart),
                            y: .value("Value", trendValue(point))
                        )
                        .foregroundStyle(trendColor.gradient)
                        .cornerRadius(2)
                        .opacity(hoveredTrendPoint == nil || hoveredTrendPoint?.id == point.id ? 1 : 0.5)
                    }

                    if let hoveredTrendPoint {
                        RuleMark(x: .value("Selected", hoveredTrendPoint.bucketStart))
                            .foregroundStyle(.secondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: 0...maximumTrendValue)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                        AxisTick().foregroundStyle(.secondary.opacity(0.35))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(trendAxisLabel(date))
                                    .font(.system(size: 9))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.1))
                        AxisValueLabel {
                            if let number = value.as(Int64.self) {
                                Text(compactTrendAxisValue(number))
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let frame = geometry[plotFrame]
                                    let xPosition = location.x - frame.origin.x
                                    guard xPosition >= 0, xPosition <= frame.width,
                                          let date: Date = proxy.value(atX: xPosition) else {
                                        hoveredTrendPoint = nil
                                        return
                                    }
                                    hoveredTrendPoint = state.trendPoints.min {
                                        abs($0.bucketStart.timeIntervalSince(date))
                                            < abs($1.bucketStart.timeIntervalSince(date))
                                    }
                                case .ended:
                                    hoveredTrendPoint = nil
                                }
                            }
                    }
                }
                .frame(height: 150)
            }

            if trendMetric == .cost,
               state.trendPoints.contains(where: { !$0.isCostComplete }) {
                Text(state.text(.partialPricing))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var distributions: some View {
        VStack(alignment: .leading, spacing: 16) {
            distributionSection(
                title: state.text(.toolDistribution),
                systemImage: "terminal",
                items: state.toolDistribution,
                groupID: "tool"
            )

            Divider()

            distributionSection(
                title: state.text(.modelDistribution),
                systemImage: "cpu",
                items: state.modelDistribution,
                groupID: "model"
            )

            if distributionMetric == .cost,
               (state.modelDistribution + state.toolDistribution).contains(where: { !$0.isCostComplete }) {
                Text(state.text(.partialPricing))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func distributionSection(
        title: String,
        systemImage: String,
        items: [UsageDistributionItem],
        groupID: String
    ) -> some View {
        let slices = UsageDistributionBuilder.slices(
            from: items,
            metric: distributionMetric,
            otherLabel: state.text(.other),
            visibleItemLimit: 4
        )
        let total = slices.reduce(Int64(0)) { partial, slice in
            saturatingAdd(partial, slice.value)
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Picker("", selection: $distributionMetric) {
                    Text(state.text(.tokensMetric)).tag(UsageDistributionMetric.tokens)
                    Text(state.text(.costMetric)).tag(UsageDistributionMetric.cost)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 126)
            }

            if slices.isEmpty {
                Text(distributionMetric == .cost ? state.text(.noPricedCost) : state.text(.noData))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .center)
            } else {
                HStack(spacing: 18) {
                    distributionRing(slices: slices, total: total, groupID: groupID, title: title)
                    distributionLegend(slices: slices, total: total, groupID: groupID)
                }
            }
        }
    }

    private func distributionRing(
        slices: [UsageDistributionSlice],
        total: Int64,
        groupID: String,
        title: String
    ) -> some View {
        let highlightedSlice = highlightedDistributionSlice(in: slices, groupID: groupID)
        let displayValue = highlightedSlice?.value ?? total
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.12), lineWidth: 15)

            ForEach(distributionSegments(slices: slices, total: total)) { segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(
                        segment.color,
                        style: StrokeStyle(lineWidth: 15, lineCap: .butt)
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(distributionOpacity(groupID: groupID, sliceID: segment.sliceID))
                    .animation(.easeOut(duration: 0.16), value: highlightedDistributionKey)
                    .onHover { hovering in
                        updateDistributionHighlight(
                            hovering: hovering,
                            groupID: groupID,
                            sliceID: segment.sliceID
                        )
                    }
            }

            VStack(spacing: 3) {
                Text(highlightedSlice.map { percentageText(value: $0.value, total: total) }
                    ?? (distributionMetric == .tokens
                        ? state.text(.tokensMetric)
                        : state.text(.estimatedCost)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(formattedDistributionValue(displayValue))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .padding(18)
        }
        .frame(width: 112, height: 112)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(formattedDistributionValue(displayValue))
    }

    private func distributionLegend(
        slices: [UsageDistributionSlice],
        total: Int64,
        groupID: String
    ) -> some View {
        VStack(spacing: 9) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let color = distributionColors[index % distributionColors.count]
                HStack(spacing: 7) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text(slice.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(formattedDistributionValue(slice.value))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(percentageText(value: slice.value, total: total))
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 43, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .opacity(distributionOpacity(groupID: groupID, sliceID: slice.id))
                .onHover { hovering in
                    updateDistributionHighlight(
                        hovering: hovering,
                        groupID: groupID,
                        sliceID: slice.id
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var activity: some View {
        VStack(spacing: 0) {
            informationRow(
                icon: "terminal.fill",
                iconColor: .blue,
                title: state.text(.dataSources),
                subtitle: state.sourceStatus == .online ? state.sessionCountText() : sourceSubtitle,
                value: TokenFormatter.string(snapshot.totalTokens, locale: tokenLocale)
            )
            Divider().padding(.leading, 42)
            informationRow(
                icon: "bubble.left.and.bubble.right.fill",
                iconColor: .teal,
                title: state.text(.currentSession),
                subtitle: state.currentSessionSnapshot?.model ?? "--",
                value: TokenFormatter.string(
                    state.currentSessionSnapshot?.totalTokens ?? 0,
                    locale: tokenLocale
                )
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func informationRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        value: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(height: 58)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(RefreshMode.allCases) { mode in
                    Button(state.refreshModeTitle(mode)) {
                        state.refreshMode = mode
                    }
                }
            } label: {
                Label(state.refreshModeTitle(), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                Task { await performManualRefresh() }
            } label: {
                manualRefreshIcon
            }
            .buttonStyle(.borderless)
            .disabled(state.isRefreshing || manualRefreshFeedback != .idle)
            .accessibilityLabel(manualRefreshHelp)
            .help(manualRefreshHelp)

            Text(syncStatusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(syncStatusColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 4)

            Label(
                state.text(state.sub2APIConnection == nil ? .localOnly : .credentialsSavedLocally),
                systemImage: "lock.fill"
            )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button(action: onQuit) {
                Image(systemName: "power")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(state.text(.quit))
            .help(state.text(.quit))
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    @ViewBuilder
    private var manualRefreshIcon: some View {
        Group {
            if state.isRefreshing || manualRefreshFeedback == .refreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: manualRefreshFeedback.systemImage)
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .foregroundStyle(manualRefreshFeedback.foregroundColor)
        .frame(width: 30, height: 28)
        .background(
            manualRefreshFeedback.backgroundColor,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeOut(duration: 0.18), value: manualRefreshFeedback)
    }

    private var syncStatusText: String {
        switch manualRefreshFeedback {
        case .idle:
            return state.isRefreshing
                ? state.text(.syncing)
                : RefreshTimestampFormatter.string(state.lastRefreshAt, language: state.language)
        case .refreshing:
            return state.text(.syncing)
        case .succeeded:
            return state.text(.refreshSucceeded)
        case .failed:
            return state.text(.refreshFailed)
        }
    }

    private var syncStatusColor: Color {
        switch manualRefreshFeedback {
        case .succeeded: .green
        case .failed: .red
        case .idle, .refreshing: .secondary
        }
    }

    private var manualRefreshHelp: String {
        switch manualRefreshFeedback {
        case .idle: state.text(.retry)
        case .refreshing: state.text(.syncing)
        case .succeeded: state.text(.refreshSucceeded)
        case .failed: state.text(.refreshFailed)
        }
    }

    private func performManualRefresh() async {
        guard !state.isRefreshing, manualRefreshFeedback == .idle else { return }
        manualRefreshFeedback = .refreshing
        let didSucceed = await state.refresh(forceRemote: true)
        manualRefreshFeedback = didSucceed ? .succeeded : .failed
        do {
            try await Task.sleep(for: .seconds(1.4))
        } catch {
            return
        }
        manualRefreshFeedback = .idle
    }

    private var sourceSubtitle: String {
        switch state.sourceStatus {
        case .online: state.text(.updatedJustNow)
        case .loading: "..."
        case .noData: state.text(.noData)
        case .unavailable: state.text(.sourceUnavailable)
        case .failed(let message): message
        }
    }

    private func formattedDistributionValue(_ value: Int64) -> String {
        switch distributionMetric {
        case .tokens:
            TokenFormatter.string(value, locale: tokenLocale)
        case .cost:
            MoneyFormatter.string(
                MoneyAmount(micros: value, currencyCode: "USD"),
                locale: tokenLocale
            )
        }
    }

    private var highlightedTrendPoint: UsageTrendPoint? {
        hoveredTrendPoint
            ?? state.trendPoints.last(where: { trendValue($0) > 0 })
            ?? state.trendPoints.last
    }

    private var maximumTrendValue: Int64 {
        max(1, state.trendPoints.map(trendValue).max() ?? 0)
    }

    private var trendColor: Color {
        trendMetric == .tokens ? .blue : .teal
    }

    private func trendValue(_ point: UsageTrendPoint) -> Int64 {
        switch trendMetric {
        case .tokens:
            point.totalTokens
        case .cost:
            point.estimatedCost?.micros ?? 0
        }
    }

    private func formattedTrendValue(_ point: UsageTrendPoint) -> String {
        switch trendMetric {
        case .tokens:
            return TokenFormatter.string(point.totalTokens, locale: tokenLocale)
        case .cost:
            guard let estimatedCost = point.estimatedCost else { return "--" }
            return MoneyFormatter.string(estimatedCost, locale: tokenLocale)
        }
    }

    private func trendDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = tokenLocale
        formatter.timeZone = .current
        switch (state.trendGranularity, state.language) {
        case (.hourly, .simplifiedChinese): formatter.dateFormat = "M月d日 HH:00"
        case (.hourly, .english): formatter.dateFormat = "MMM d, HH:00"
        case (.daily, .simplifiedChinese): formatter.dateFormat = "M月d日"
        case (.daily, .english): formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    private func trendAxisLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = tokenLocale
        formatter.timeZone = .current
        formatter.dateFormat = state.trendGranularity == .hourly ? "HH:mm" : "M/d"
        return formatter.string(from: date)
    }

    private func compactTrendAxisValue(_ value: Int64) -> String {
        let numericValue = Double(max(0, value))
        if trendMetric == .cost {
            let dollars = numericValue / 1_000_000
            if dollars >= 1_000 {
                return "$\(compactDecimal(dollars / 1_000))K"
            }
            return "$\(compactDecimal(dollars))"
        }
        return TokenFormatter.string(max(0, value), locale: tokenLocale)
    }

    private func compactDecimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = tokenLocale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value < 10 ? 1 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    private func percentageText(value: Int64, total: Int64) -> String {
        let percentage = UsageDistributionBuilder.percentage(value: value, total: total)
        let formatter = NumberFormatter()
        formatter.locale = tokenLocale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return "\(formatter.string(from: percentage as NSDecimalNumber) ?? "0.0")%"
    }

    private func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }

    private func distributionSegments(
        slices: [UsageDistributionSlice],
        total: Int64
    ) -> [MenuBarDistributionSegment] {
        guard total > 0 else { return [] }
        var cursor = 0.0
        let gap = slices.count > 1 ? 0.005 : 0
        return slices.enumerated().map { index, slice in
            let fraction = Double(slice.value) / Double(total)
            let start = min(1, cursor + gap / 2)
            cursor += fraction
            let end = max(start, min(1, cursor - gap / 2))
            return MenuBarDistributionSegment(
                sliceID: slice.id,
                color: distributionColors[index % distributionColors.count],
                start: start,
                end: end
            )
        }
    }

    private func highlightedDistributionSlice(
        in slices: [UsageDistributionSlice],
        groupID: String
    ) -> UsageDistributionSlice? {
        guard let highlightedDistributionKey else { return nil }
        return slices.first { distributionKey(groupID: groupID, sliceID: $0.id) == highlightedDistributionKey }
    }

    private func distributionOpacity(groupID: String, sliceID: String) -> Double {
        guard let highlightedDistributionKey,
              highlightedDistributionKey.hasPrefix("\(groupID)::") else {
            return 1
        }
        return highlightedDistributionKey == distributionKey(groupID: groupID, sliceID: sliceID)
            ? 1
            : 0.3
    }

    private func updateDistributionHighlight(
        hovering: Bool,
        groupID: String,
        sliceID: String
    ) {
        let key = distributionKey(groupID: groupID, sliceID: sliceID)
        if hovering {
            highlightedDistributionKey = key
        } else if highlightedDistributionKey == key {
            highlightedDistributionKey = nil
        }
    }

    private func distributionKey(groupID: String, sliceID: String) -> String {
        "\(groupID)::\(sliceID)"
    }

    private var tokenAnimation: Animation? {
        reduceMotion
            ? nil
            : .linear(duration: TokenMotion.duration)
    }

    private var tokenLocale: Locale {
        state.language == .simplifiedChinese
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
    }
}

private struct MenuBarDistributionSegment: Identifiable {
    let sliceID: String
    let color: Color
    let start: Double
    let end: Double

    var id: String { sliceID }
}

private enum ManualRefreshFeedback: Equatable {
    case idle
    case refreshing
    case succeeded
    case failed

    var systemImage: String {
        switch self {
        case .idle, .refreshing: "arrow.clockwise"
        case .succeeded: "checkmark"
        case .failed: "exclamationmark"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .idle: .primary
        case .refreshing: .blue
        case .succeeded: .green
        case .failed: .red
        }
    }

    var backgroundColor: Color {
        switch self {
        case .idle: Color.secondary.opacity(0.08)
        case .refreshing: Color.blue.opacity(0.12)
        case .succeeded: Color.green.opacity(0.12)
        case .failed: Color.red.opacity(0.12)
        }
    }
}
