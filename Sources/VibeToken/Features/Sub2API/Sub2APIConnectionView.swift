import SwiftUI

struct Sub2APIConnectionView: View {
    @Bindable var state: AppState
    @Binding var isPresented: Bool

    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var confirmDisconnect = false
    @State private var selectedTiers: [Int64: Sub2APICapacityTier] = [:]

    private enum TableLayout {
        static let planWidth: CGFloat = 52
        static let quotaWidth: CGFloat = 96
        static let multiplierWidth: CGFloat = 72
        static let trailingWidth: CGFloat = planWidth + quotaWidth + multiplierWidth + 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            Group {
                if case .requiresTwoFactor(let maskedEmail) = state.sub2APIStatus {
                    twoFactorForm(maskedEmail: maskedEmail)
                } else if state.sub2APIConnection != nil {
                    capacityConfigurationForm
                } else {
                    loginForm
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            if let error = state.sub2APILastError {
                Label(error.message(language: state.language), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }

            Spacer(minLength: 0)

            if state.sub2APIConnection != nil {
                connectedFooter
            }
        }
        .frame(
            width: state.sub2APIConnection == nil ? 420 : 444,
            height: state.sub2APIConnection == nil ? 350 : 560
        )
        .background(.regularMaterial)
        .onAppear {
            serverURL = state.sub2APIConnection?.baseURL.absoluteString ?? ""
            email = state.sub2APIConnection?.email ?? ""
            syncSelectedTiers()
            Task {
                await state.prepareSub2APICapacityConfiguration()
            }
        }
        .onChange(of: state.sub2APIAccountCapacityOptions) {
            syncSelectedTiers()
        }
        .alert(state.text(.disconnectTitle), isPresented: $confirmDisconnect) {
            Button(state.text(.cancel), role: .cancel) {}
            Button(state.text(.disconnect), role: .destructive) {
                Task {
                    await state.disconnectSub2API()
                    if state.sub2APIStatus == .disconnected {
                        isPresented = false
                    }
                }
            }
        } message: {
            Text(state.text(.disconnectMessage))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.text(
                    state.sub2APIConnection == nil
                        ? .configureConnection
                        : .configureAccountCapacity
                ))
                    .font(.system(size: 17, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.7), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(state.text(.cancel))
            .help(state.text(.cancel))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var headerSubtitle: String {
        guard state.sub2APIConnection != nil else { return "Sub2API" }
        let count = state.sub2APIAccountCapacityOptions.count
        guard count > 0 else { return "Sub2API" }
        return state.language == .simplifiedChinese
            ? "Sub2API · \(count) 个账号"
            : "Sub2API · \(count) accounts"
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            fieldLabel(state.text(.serverAddress))
            TextField("https://relay.example.com", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(state.text(.serverAddress))

            fieldLabel(state.text(.adminEmail))
            TextField("admin@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(state.text(.adminEmail))

            fieldLabel(state.text(.password))
            SecureField(state.text(.password), text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(state.text(.password))

            HStack {
                Spacer()
                Button {
                    Task {
                        await state.connectSub2API(
                            serverURL: serverURL,
                            email: email,
                            password: password
                        )
                        password = ""
                    }
                } label: {
                    submitLabel(state.text(.connect))
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverURL.isEmpty || email.isEmpty || password.isEmpty || state.sub2APIStatus.isBusy)
            }
        }
    }

    private func twoFactorForm(maskedEmail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !maskedEmail.isEmpty {
                Text(maskedEmail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            fieldLabel(state.text(.verificationCode))
            SecureField(state.text(.verificationCode), text: $verificationCode)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(state.text(.verificationCode))

            HStack {
                Button(state.text(.restartLogin)) {
                    Task {
                        await state.cancelSub2APITwoFactor()
                    }
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    Task {
                        await state.completeSub2APITwoFactor(code: verificationCode)
                        verificationCode = ""
                    }
                } label: {
                    submitLabel(state.text(.verify))
                }
                .buttonStyle(.borderedProminent)
                .disabled(verificationCode.count != 6 || state.sub2APIStatus.isBusy)
            }
        }
    }

    private var capacityConfigurationForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(state.text(.capacityConfigurationHint), systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                capacityTableHeader
                Divider()

                if state.sub2APIAccountCapacityOptions.isEmpty {
                    HStack(spacing: 9) {
                        if state.sub2APIStatus.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(state.text(
                            state.sub2APIStatus.isBusy ? .syncing : .noAccountsFound
                        ))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(state.sub2APIAccountCapacityOptions) { option in
                                capacityRow(option)
                                if option.id != state.sub2APIAccountCapacityOptions.last?.id {
                                    Divider().padding(.leading, 10)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                }
            }
            .frame(minHeight: 280, idealHeight: 340, maxHeight: 340)
            .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }
        }
    }

    private var capacityTableHeader: some View {
        HStack(spacing: 12) {
            Text(state.text(.account))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Text(state.text(.detectedPlan))
                    .frame(width: TableLayout.planWidth, alignment: .leading)
                Text(state.text(.remainingCapacity))
                    .frame(width: TableLayout.quotaWidth, alignment: .leading)
                Text(state.text(.capacityType))
                    .frame(width: TableLayout.multiplierWidth, alignment: .leading)
            }
            .frame(width: TableLayout.trailingWidth, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.quaternary.opacity(0.42))
    }

    private func capacityRow(_ option: Sub2APIAccountCapacityOption) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName ?? "\(state.text(.account)) #\(option.accountID)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(option.displayName ?? "\(state.text(.account)) #\(option.accountID)")
                if option.displayName != nil {
                    Text("#\(option.accountID)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(option.detectedPlan)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        isDetectedPro(option)
                            ? AnyShapeStyle(.blue)
                            : AnyShapeStyle(.secondary)
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        isDetectedPro(option)
                            ? Color.blue.opacity(0.10)
                            : Color.secondary.opacity(0.08),
                        in: Capsule()
                    )
                    .frame(width: TableLayout.planWidth, alignment: .leading)

                accountQuotaView(option.quotaStatus)
                    .frame(width: TableLayout.quotaWidth, alignment: .leading)

                if isDetectedPro(option) {
                    Picker("", selection: capacitySelectionBinding(for: option)) {
                        Text(state.text(.selectCapacityType))
                            .tag(nil as Sub2APICapacityTier?)
                        Text("5x").tag(Optional(Sub2APICapacityTier.pro5))
                        Text("10x").tag(Optional(Sub2APICapacityTier.pro10))
                        Text("20x").tag(Optional(Sub2APICapacityTier.pro20))
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(selectedTiers[option.accountID] == nil ? .orange : .accentColor)
                    .frame(width: TableLayout.multiplierWidth, alignment: .leading)
                    .disabled(state.sub2APIStatus.isBusy)
                    .accessibilityLabel(state.text(.capacityType))
                } else {
                    Text("1x")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: TableLayout.multiplierWidth, alignment: .leading)
                }
            }
            .frame(width: TableLayout.trailingWidth, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .background(
            isUnconfiguredPro(option)
                ? Color.orange.opacity(0.055)
                : Color.clear
        )
    }

    @ViewBuilder
    private func accountQuotaView(_ status: Sub2APIAccountQuotaStatus) -> some View {
        switch status {
        case .current(let fiveHourRemainingPercent, let sevenDayRemainingPercent):
            VStack(alignment: .leading, spacing: 2) {
                quotaLine(label: "5h", remainingPercent: fiveHourRemainingPercent)
                quotaLine(label: "7d", remainingPercent: sevenDayRemainingPercent)
            }
            .accessibilityElement(children: .combine)
            .help(
                "\(state.text(.fiveHourWindow)) \(quotaText(fiveHourRemainingPercent)), "
                    + "\(state.text(.sevenDayWindow)) \(quotaText(sevenDayRemainingPercent))"
            )
        case .stale:
            Text(state.text(.staleData))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .unobserved:
            Text(state.text(.missingWindow))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func quotaLine(label: String, remainingPercent: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
            Text(quotaText(remainingPercent))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(quotaColor(remainingPercent))
        }
    }

    private func quotaText(_ remainingPercent: Double) -> String {
        let rounded = remainingPercent.rounded()
        if abs(remainingPercent - rounded) < 0.05 {
            return "\(Int(rounded))%"
        }
        return String(format: "%.1f%%", remainingPercent)
    }

    private func quotaColor(_ remainingPercent: Double) -> Color {
        if remainingPercent <= 0 { return .red }
        if remainingPercent <= 20 { return .orange }
        return .primary
    }

    private func capacitySelectionBinding(
        for option: Sub2APIAccountCapacityOption
    ) -> Binding<Sub2APICapacityTier?> {
        Binding(
            get: { selectedTiers[option.accountID] },
            set: { selectedTiers[option.accountID] = $0 }
        )
    }

    private func isUnconfiguredPro(_ option: Sub2APIAccountCapacityOption) -> Bool {
        isDetectedPro(option) && selectedTiers[option.accountID]?.isProCapacity != true
    }

    private var connectedFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(state.text(.disconnect), role: .destructive) {
                    confirmDisconnect = true
                }
                .buttonStyle(.borderless)
                .disabled(state.sub2APIStatus.isBusy)

                Spacer()

                if unconfiguredProAccountCount > 0 {
                    Label(
                        "\(state.text(.unconfiguredCapacity)) \(unconfiguredProAccountCount)",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                }

                Button {
                    Task {
                        if await state.saveSub2APICapacitySelections(selectedTiers) {
                            isPresented = false
                        }
                    }
                } label: {
                    submitLabel(state.text(.saveConfiguration))
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    state.sub2APIAccountCapacityOptions.isEmpty
                        || hasUnconfiguredProAccounts
                        || state.sub2APIStatus.isBusy
                )
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
        }
    }

    private func syncSelectedTiers() {
        for option in state.sub2APIAccountCapacityOptions {
            if isDetectedPro(option) {
                let current = selectedTiers[option.accountID]
                if current?.isProCapacity != true {
                    selectedTiers[option.accountID] = option.selectedTier
                }
            } else {
                selectedTiers[option.accountID] = .plus
            }
        }
    }

    private var hasUnconfiguredProAccounts: Bool {
        unconfiguredProAccountCount > 0
    }

    private var unconfiguredProAccountCount: Int {
        state.sub2APIAccountCapacityOptions.count(where: isUnconfiguredPro)
    }

    private func isDetectedPro(_ option: Sub2APIAccountCapacityOption) -> Bool {
        option.detectedPlan.caseInsensitiveCompare("Pro") == .orderedSame
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .medium))
    }

    private func submitLabel(_ title: String) -> some View {
        HStack(spacing: 7) {
            if state.sub2APIStatus.isBusy {
                ProgressView().controlSize(.small)
            }
            Text(title)
        }
        .frame(minWidth: 76)
    }

}
