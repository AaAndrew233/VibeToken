import SwiftUI

struct DetailWindowView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case overview
        case sources
        case settings

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: "chart.xyaxis.line"
            case .sources: "externaldrive.connected.to.line.below"
            case .settings: "gearshape"
            }
        }
    }

    @Bindable var state: AppState
    @State private var selection = Section.overview

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(.blue)
                    Text("VibeToken")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)

                ForEach(Section.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        Label(title(for: section), systemImage: section.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .background(
                                selection == section ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            switch selection {
            case .overview:
                OverviewView(state: state)
            case .sources:
                SourcesView(state: state)
            case .settings:
                SettingsContentView(state: state)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func title(for section: Section) -> String {
        switch section {
        case .overview: state.text(.overview)
        case .sources: state.text(.dataSources)
        case .settings: state.text(.settings)
        }
    }
}

private struct OverviewView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: TokenUsageSnapshot {
        state.snapshot ?? .empty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.text(.overview))
                            .font(.system(size: 28, weight: .bold))
                        Text(state.timeRangeTitle())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await state.refresh(forceRemote: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(state.text(.retry))
                }

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

                HStack(spacing: 0) {
                    largeMetric(state.text(.totalTokens), snapshot.totalTokens, color: .primary)
                    Divider().frame(height: 72)
                    largeMetric(state.text(.cachedTokens), snapshot.cachedInputTokens, color: .teal)
                    Divider().frame(height: 72)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(state.text(.estimatedCost))
                            .foregroundStyle(.secondary)
                        Text(state.estimatedCostText())
                            .font(.system(size: 30, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .allowsTightening(true)
                        if let coverage = state.costCoverageText() {
                            Text(coverage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .layoutPriority(1)
                }
                .padding(.vertical, 20)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.7), lineWidth: 1)
                }

                HStack(spacing: 16) {
                    compactMetric(state.text(.input), snapshot.inputTokens, color: .blue)
                    compactMetric(state.text(.output), snapshot.outputTokens, color: .purple)
                    compactMetric(state.text(.reasoning), snapshot.reasoningTokens, color: .secondary)
                    compactMetric(state.text(.cachedTokens), snapshot.cachedInputTokens, color: .teal)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    DistributionCard(
                        title: state.text(.toolDistribution),
                        systemImage: "terminal",
                        items: state.toolDistribution,
                        state: state
                    )
                    DistributionCard(
                        title: state.text(.modelDistribution),
                        systemImage: "cpu",
                        items: state.modelDistribution,
                        state: state
                    )
                }

                VStack(alignment: .leading, spacing: 0) {
                    informationRow(state.text(.source), value: state.sourceCountText())
                    Divider()
                    informationRow(state.text(.sessionCount), value: state.sessionCountText())
                    Divider()
                    informationRow(state.text(.model), value: state.modelSummaryText())
                    Divider()
                    informationRow(
                        state.text(.lastUpdated),
                        value: snapshot.recordedAt == .distantPast
                            ? "--"
                            : snapshot.recordedAt.formatted(date: .omitted, time: .standard)
                    )
                }
                .padding(.horizontal, 18)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.7), lineWidth: 1)
                }

                currentSessionCard
            }
            .padding(28)
            .frame(maxWidth: 1_080)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var currentSessionCard: some View {
        let current = state.currentSessionSnapshot
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(state.text(.currentSession))
                    .font(.system(size: 13, weight: .medium))
                Text(current?.model ?? "--")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RollingTokenText(current?.totalTokens ?? 0, locale: tokenLocale)
                .font(.system(size: 18, weight: .medium))
                .monospacedDigit()
                .animation(tokenAnimation, value: current?.totalTokens ?? 0)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }

    private func largeMetric(_ title: String, _ value: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).foregroundStyle(.secondary)
            RollingTokenText(value, locale: tokenLocale)
                .font(.system(size: 31, weight: .semibold))
                .monospacedDigit()
                .animation(tokenAnimation, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .allowsTightening(true)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .layoutPriority(1)
    }

    private func compactMetric(_ title: String, _ value: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            RollingTokenText(value, locale: tokenLocale)
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .animation(tokenAnimation, value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }

    private func informationRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .frame(height: 48)
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

private struct DistributionSegment: Identifiable {
    let id: String
    let slice: UsageDistributionSlice
    let color: Color
    let start: Double
    let end: Double
}

private struct DistributionCard: View {
    private static let palette: [Color] = [
        Color(red: 0.18, green: 0.48, blue: 0.96),
        Color(red: 0.10, green: 0.67, blue: 0.48),
        Color(red: 0.96, green: 0.57, blue: 0.15),
        Color(red: 0.92, green: 0.28, blue: 0.40),
        Color(red: 0.53, green: 0.36, blue: 0.91),
        Color(red: 0.10, green: 0.64, blue: 0.73)
    ]

    let title: String
    let systemImage: String
    let items: [UsageDistributionItem]
    @Bindable var state: AppState

    @State private var metric = UsageDistributionMetric.tokens
    @State private var highlightedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                Picker("", selection: $metric) {
                    Text(state.text(.tokensMetric)).tag(UsageDistributionMetric.tokens)
                    Text(state.text(.costMetric)).tag(UsageDistributionMetric.cost)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 126)
            }

            if slices.isEmpty {
                Text(metric == .cost ? state.text(.noPricedCost) : state.text(.noData))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 142)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 22) {
                        ring
                        legend
                    }
                    VStack(spacing: 18) {
                        ring
                        legend
                    }
                }

                if metric == .cost && items.contains(where: { !$0.isCostComplete }) {
                    Text(state.text(.partialPricing))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .onChange(of: metric) {
            highlightedID = nil
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.12), lineWidth: 17)

            ForEach(segments) { segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(segment.color, style: StrokeStyle(lineWidth: 17, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .opacity(highlightedID == nil || highlightedID == segment.id ? 1 : 0.28)
                    .animation(.easeOut(duration: 0.16), value: highlightedID)
                    .onHover { hovering in
                        highlightedID = hovering ? segment.id : nil
                    }
            }

            VStack(spacing: 3) {
                Text(centerCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(centerValue)
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .padding(20)
        }
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(centerValue)
    }

    private var legend: some View {
        VStack(spacing: 10) {
            ForEach(slices) { slice in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: slice))
                        .frame(width: 9, height: 9)
                    Text(slice.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(formattedValue(slice.value))
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(percentageText(for: slice.value))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .opacity(highlightedID == nil || highlightedID == slice.id ? 1 : 0.35)
                .onHover { hovering in
                    highlightedID = hovering ? slice.id : nil
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var slices: [UsageDistributionSlice] {
        UsageDistributionBuilder.slices(
            from: items,
            metric: metric,
            otherLabel: state.text(.other)
        )
    }

    private var segments: [DistributionSegment] {
        guard totalValue > 0 else { return [] }
        var cursor = 0.0
        let gap = slices.count > 1 ? 0.004 : 0
        return slices.enumerated().map { index, slice in
            let fraction = Double(slice.value) / Double(totalValue)
            let start = min(1, cursor + gap / 2)
            cursor += fraction
            let end = max(start, min(1, cursor - gap / 2))
            return DistributionSegment(
                id: slice.id,
                slice: slice,
                color: index < Self.palette.count
                    ? Self.palette[index]
                    : Color.secondary.opacity(0.55),
                start: start,
                end: end
            )
        }
    }

    private var totalValue: Int64 {
        slices.reduce(0) { saturatingAdd($0, $1.value) }
    }

    private var highlightedSlice: UsageDistributionSlice? {
        guard let highlightedID else { return nil }
        return slices.first { $0.id == highlightedID }
    }

    private var centerCaption: String {
        if let highlightedSlice {
            return percentageText(for: highlightedSlice.value)
        }
        return metric == .tokens ? state.text(.tokensMetric) : state.text(.estimatedCost)
    }

    private var centerValue: String {
        formattedValue(highlightedSlice?.value ?? totalValue)
    }

    private func formattedValue(_ value: Int64) -> String {
        switch metric {
        case .tokens:
            return TokenFormatter.string(value, locale: displayLocale)
        case .cost:
            return MoneyFormatter.string(
                MoneyAmount(micros: value, currencyCode: "USD"),
                locale: displayLocale
            )
        }
    }

    private func percentageText(for value: Int64) -> String {
        guard totalValue > 0 else { return "0.0%" }
        let percentage = UsageDistributionBuilder.percentage(value: value, total: totalValue)
        let formatter = NumberFormatter()
        formatter.locale = displayLocale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return "\(formatter.string(from: percentage as NSDecimalNumber) ?? "0.0")%"
    }

    private func color(for slice: UsageDistributionSlice) -> Color {
        guard let index = slices.firstIndex(where: { $0.id == slice.id }) else {
            return Color.secondary.opacity(0.55)
        }
        return index < Self.palette.count
            ? Self.palette[index]
            : Color.secondary.opacity(0.55)
    }

    private func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }

    private var displayLocale: Locale {
        state.language == .simplifiedChinese
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
    }
}

private struct SourcesView: View {
    @Bindable var state: AppState

    private let sources = [
        UsageSourceDescriptor(
            id: "codex",
            name: "Codex",
            path: "~/.codex/{sessions,archived_sessions}",
            icon: "terminal.fill",
            color: Color.blue
        ),
        UsageSourceDescriptor(
            id: "claude-code",
            name: "Claude Code",
            path: "~/.claude/{projects,transcripts}",
            icon: "bubble.left.and.text.bubble.right.fill",
            color: Color.orange
        ),
        UsageSourceDescriptor(
            id: "gemini-cli",
            name: "Gemini CLI",
            path: "~/.gemini/tmp/*/chats",
            icon: "sparkles",
            color: Color.purple
        ),
        UsageSourceDescriptor(
            id: "opencode",
            name: "OpenCode",
            path: "~/.local/share/opencode",
            icon: "chevron.left.forwardslash.chevron.right",
            color: Color.teal
        ),
        UsageSourceDescriptor(
            id: "copilot-cli",
            name: "GitHub Copilot CLI",
            path: "~/.copilot/session-state",
            icon: "terminal.fill",
            color: Color.indigo
        ),
        UsageSourceDescriptor(
            id: "cursor",
            name: "Cursor",
            path: "state.vscdb → cursor.com",
            icon: "cursorarrow.rays",
            color: Color.green
        ),
        UsageSourceDescriptor(
            id: "cline",
            name: "Cline",
            path: "~/.cline + VS Code hosts",
            icon: "square.stack.3d.up.fill",
            color: Color.pink
        ),
        UsageSourceDescriptor(
            id: "roo-code",
            name: "Roo Code",
            path: "VS Code hosts / globalStorage",
            icon: "shippingbox.fill",
            color: Color.brown
        ),
        UsageSourceDescriptor(
            id: "kiro",
            name: "Kiro",
            path: "~/.kiro/sessions/cli",
            icon: "wand.and.stars",
            color: Color.cyan,
            accuracy: .estimated
        ),
        UsageSourceDescriptor(
            id: "grok",
            name: "Grok",
            path: "~/.grok/sessions",
            icon: "bolt.fill",
            color: Color.primary
        ),
        UsageSourceDescriptor(
            id: "dimagent",
            name: "DimAgent",
            path: "~/.dimcode/v2/dimcode.sqlite",
            icon: "square.stack.3d.down.right.fill",
            color: Color.mint
        ),
        UsageSourceDescriptor(
            id: "openclaw",
            name: "OpenClaw",
            path: "~/.openclaw*/agents",
            icon: "point.3.connected.trianglepath.dotted",
            color: Color.red
        ),
        UsageSourceDescriptor(
            id: "pi-coding-agent",
            name: "pi",
            path: "~/.pi/agent/sessions",
            icon: "function",
            color: Color.yellow
        ),
        UsageSourceDescriptor(
            id: "qwen-code",
            name: "Qwen Code",
            path: "~/.qwen/tmp/*/chats",
            icon: "q.circle.fill",
            color: Color.blue
        ),
        UsageSourceDescriptor(
            id: "kimi-code",
            name: "Kimi Code",
            path: "~/.kimi-code + ~/.kimi",
            icon: "moon.stars.fill",
            color: Color.indigo
        ),
        UsageSourceDescriptor(
            id: "mimocode",
            name: "MiMoCode",
            path: "~/.local/share/mimocode",
            icon: "m.circle.fill",
            color: Color.orange
        ),
        UsageSourceDescriptor(
            id: "amp",
            name: "Amp",
            path: "~/.local/share/amp/threads",
            icon: "waveform.path.ecg",
            color: Color.pink
        ),
        UsageSourceDescriptor(
            id: "droid",
            name: "Droid",
            path: "~/.factory/sessions",
            icon: "cpu.fill",
            color: Color.green
        ),
        UsageSourceDescriptor(
            id: "hermes",
            name: "Hermes",
            path: "~/.hermes/{state,profiles}.db",
            icon: "paperplane.fill",
            color: Color.teal
        ),
        UsageSourceDescriptor(
            id: "trae-cli",
            name: "Trae CLI",
            path: "~/Library/Caches/trae-cli/sessions",
            icon: "terminal.fill",
            color: Color.purple
        ),
        UsageSourceDescriptor(
            id: "antigravity",
            name: "Antigravity",
            path: "~/.gemini/antigravity*",
            icon: "sparkle.magnifyingglass",
            color: Color.cyan
        ),
        UsageSourceDescriptor(
            id: "zcode",
            name: "ZCode",
            path: "~/.zcode/cli/db/db.sqlite",
            icon: "z.circle.fill",
            color: Color.brown
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(state.text(.dataSources))
                    .font(.system(size: 28, weight: .bold))

                VStack(spacing: 0) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                        sourceRow(source)
                        if index < sources.count - 1 {
                            Divider().padding(.leading, 70)
                        }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.7), lineWidth: 1)
                }
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sourceRow(_ source: UsageSourceDescriptor) -> some View {
        let hasUsage = state.toolDistribution.contains { $0.id == source.id }
        return HStack(spacing: 14) {
            Image(systemName: source.icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(source.color, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(source.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(hasUsage ? .green : .secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(sourceStatusText(source, hasUsage: hasUsage))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(18)
    }

    private func sourceStatusText(
        _ source: UsageSourceDescriptor,
        hasUsage: Bool
    ) -> String {
        guard hasUsage else { return state.text(.noData) }
        guard source.accuracy != .exact else { return state.text(.connected) }
        return "\(state.text(.connected)) · \(state.text(.estimatedUsage))"
    }
}

private struct UsageSourceDescriptor: Identifiable {
    let id: String
    let name: String
    let path: String
    let icon: String
    let color: Color
    let accuracy: UsageAccuracy

    init(
        id: String,
        name: String,
        path: String,
        icon: String,
        color: Color,
        accuracy: UsageAccuracy = .exact
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon
        self.color = color
        self.accuracy = accuracy
    }
}

private struct SettingsContentView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section {
                Picker(state.text(.language), selection: $state.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.shortLabel).tag(language)
                    }
                }
            }

            Section {
                Picker(state.text(.refreshMode), selection: $state.refreshMode) {
                    ForEach(RefreshMode.allCases) { mode in
                        Text(state.refreshModeTitle(mode)).tag(mode)
                    }
                }
                LabeledContent(state.text(.localOnly), value: state.text(.localFirst))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
