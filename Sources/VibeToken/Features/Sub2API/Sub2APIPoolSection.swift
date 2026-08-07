import SwiftUI

struct Sub2APIPoolSection: View {
    @Bindable var state: AppState
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(state.text(.relayCapacity), systemImage: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                poolStatus
                Button(action: onConfigure) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(state.text(.configureConnection))
                .help(state.text(.configureConnection))
            }

            if let snapshot = state.sub2APIPoolSnapshot {
                poolContent(snapshot)
                if case .failed(let error) = state.sub2APIStatus {
                    errorLabel(error)
                }
            } else {
                emptyContent
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var poolStatus: some View {
        switch state.sub2APIStatus {
        case .connected:
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .accessibilityLabel(state.text(.connected))
        case .connecting, .syncing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(state.text(.syncing))
        case .requiresTwoFactor:
            Circle()
                .fill(.orange)
                .frame(width: 7, height: 7)
                .accessibilityLabel(state.text(.verificationCode))
        case .failed(let error):
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .accessibilityLabel(error.message(language: state.language))
        case .disconnected:
            EmptyView()
        }
    }

    private func poolContent(_ snapshot: Sub2APIPoolSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                availableAccounts(snapshot)
                Divider().frame(height: 108)
                poolCapacity(snapshot)
            }

            if snapshot.requiresCapacityConfiguration {
                capacityConfigurationPrompt(snapshot.unconfiguredCapacityAccounts)
            }

            HStack(spacing: 14) {
                diagnostic(
                    state.text(.currentAvailableAccounts),
                    snapshot.effectiveCapacity.availableAccounts,
                    color: .green
                )
                diagnostic(
                    state.text(.windowLimitedAccounts),
                    snapshot.effectiveCapacity.windowLimitedAccounts,
                    color: .orange
                )
                diagnostic(state.text(.unavailableAccounts), snapshot.unavailableAccounts, color: .orange)
                diagnostic(
                    state.text(.dataIssues),
                    snapshot.staleWindowAccounts
                        + snapshot.missingWindowAccounts
                        + snapshot.unconfiguredCapacityAccounts,
                    color: .secondary
                )
            }

            if snapshot.excludedShadowAccounts > 0
                || snapshot.staleWindowAccounts > 0
                || snapshot.missingWindowAccounts > 0
                || snapshot.unconfiguredCapacityAccounts > 0 {
                HStack(spacing: 8) {
                    if snapshot.excludedShadowAccounts > 0 {
                        Text("\(state.text(.excludedShadows)) \(snapshot.excludedShadowAccounts)")
                    }
                    if snapshot.staleWindowAccounts > 0 {
                        Text("\(state.text(.staleData)) \(snapshot.staleWindowAccounts)")
                    }
                    if snapshot.missingWindowAccounts > 0 {
                        Text("\(state.text(.missingWindow)) \(snapshot.missingWindowAccounts)")
                    }
                    if snapshot.unconfiguredCapacityAccounts > 0 {
                        Text(
                            "\(state.text(.unconfiguredCapacity)) "
                                + "\(snapshot.unconfiguredCapacityAccounts)"
                        )
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                if !snapshot.plans.isEmpty {
                    Text(planSummary(snapshot.plans))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text(RefreshTimestampFormatter.string(snapshot.fetchedAt, language: state.language))
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
    }

    private func capacityConfigurationPrompt(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(unconfiguredProMessage(count))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onConfigure) {
                Label(state.text(.configureAccountCapacity), systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.orange.opacity(0.22), lineWidth: 0.5)
        }
    }

    private func unconfiguredProMessage(_ count: Int) -> String {
        state.language == .simplifiedChinese
            ? "发现 \(count) 个新的 Pro 账号，请选择额度类型"
            : "\(count) new Pro account\(count == 1 ? "" : "s") need a capacity type"
    }

    private func availableAccounts(
        _ snapshot: Sub2APIPoolSnapshot
    ) -> some View {
        let value = snapshot.effectiveCapacity
        let fraction = snapshot.displayedAvailableAccountFraction
        return VStack(alignment: .leading, spacing: 7) {
            Text(state.text(.effectiveCapacity))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(availableAccountCountText(snapshot))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    snapshot.totalCapacityAccounts == 0
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.primary)
                )
            ProgressView(value: fraction ?? 0)
                .tint(.green)
            Text(limitedAccountSummary(value.windowLimitedAccounts))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let resetAt = value.nextRecoveryAt {
                Text("\(state.text(.nextRecovery)) \(resetText(resetAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func poolCapacity(
        _ snapshot: Sub2APIPoolSnapshot
    ) -> some View {
        let hasCapacity = snapshot.totalCapacityAccounts > 0
        return VStack(alignment: .leading, spacing: 7) {
            Text(state.text(.windowBalances))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(poolCapacityText(snapshot))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(hasCapacity ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            ProgressView(
                value: snapshot.displayedRemainingFraction ?? 0
            )
                .tint(.teal)
            Text(poolWindowCapacityText(snapshot))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let limitingText = limitingText(snapshot) {
                Text(limitingText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diagnostic(_ title: String, _ count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(count))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch state.sub2APIStatus {
        case .disconnected:
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                Text(state.text(.noWindowData))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(state.text(.connectSub2API), action: onConfigure)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        case .connecting, .syncing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(state.text(.syncing))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
        case .requiresTwoFactor:
            Button(state.text(.verificationCode), action: onConfigure)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 52)
        case .failed(let error):
            VStack(spacing: 10) {
                errorLabel(error)
                Button(state.text(.configureConnection), action: onConfigure)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        case .connected:
            Text(state.text(.noWindowData))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
    }

    private func errorLabel(_ error: Sub2APIError) -> some View {
        Label(error.message(language: state.language), systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func availableAccountCountText(_ snapshot: Sub2APIPoolSnapshot) -> String {
        guard snapshot.totalCapacityAccounts > 0 else { return "--" }
        return "\(snapshot.effectiveCapacity.availableAccounts) / \(snapshot.totalCapacityAccounts)"
    }

    private func poolCapacityText(_ snapshot: Sub2APIPoolSnapshot) -> String {
        guard let remaining = snapshot.displayedRemainingFraction else { return "--" }
        return "\(capacityPercentText(remaining)) / \(capacityPercentText(1))"
    }

    private func poolWindowCapacityText(_ snapshot: Sub2APIPoolSnapshot) -> String {
        guard snapshot.unconfiguredCapacityAccounts == 0 else {
            return "\(state.text(.unconfiguredCapacity)) \(snapshot.unconfiguredCapacityAccounts)"
        }
        let value = snapshot.effectiveCapacity
        guard value.totalCapacityWeight > 0 else { return state.text(.noWindowData) }
        let fiveHour = value.fiveHourRemainingEquivalentAccounts / value.totalCapacityWeight
        let sevenDay = value.sevenDayRemainingEquivalentAccounts / value.totalCapacityWeight
        return "5h \(capacityPercentText(fiveHour))"
            + " · 7d \(capacityPercentText(sevenDay))"
    }

    private func capacityPercentText(_ equivalentAccounts: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        let percentage = equivalentAccounts * 100
        formatter.minimumFractionDigits = abs(percentage.rounded() - percentage) < 0.000_1 ? 0 : 1
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: equivalentAccounts)) ?? "--"
    }

    private func limitedAccountSummary(_ count: Int) -> String {
        state.language == .simplifiedChinese
            ? "\(count) 个账号受窗口限制"
            : "\(count) accounts window-limited"
    }

    private func limitingText(_ snapshot: Sub2APIPoolSnapshot) -> String? {
        guard snapshot.unconfiguredCapacityAccounts == 0 else { return nil }
        let value = snapshot.effectiveCapacity
        guard value.totalCapacityWeight > 0 else { return nil }
        let fiveHour = value.fiveHourRemainingEquivalentAccounts
        let sevenDay = value.sevenDayRemainingEquivalentAccounts
        if abs(fiveHour - sevenDay) < 0.000_1 {
            return state.text(.limitedByBothWindows)
        }
        return state.text(fiveHour < sevenDay ? .limitedByFiveHour : .limitedBySevenDay)
    }

    private func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = .current
        formatter.dateFormat = state.language == .simplifiedChinese ? "M/d HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    private func planSummary(_ plans: [Sub2APIPlanSnapshot]) -> String {
        plans.prefix(4).map { "\($0.plan) \($0.accountCount)" }.joined(separator: "  ·  ")
    }

    private var locale: Locale {
        state.language == .simplifiedChinese
            ? Locale(identifier: "zh_CN")
            : Locale(identifier: "en_US")
    }

}
