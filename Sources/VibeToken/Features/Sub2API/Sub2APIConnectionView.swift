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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.text(
                        state.sub2APIConnection == nil
                            ? .configureConnection
                            : .configureAccountCapacity
                    ))
                        .font(.system(size: 17, weight: .semibold))
                    Text("Sub2API")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(state.text(.cancel))
                .help(state.text(.cancel))
            }

            if case .requiresTwoFactor(let maskedEmail) = state.sub2APIStatus {
                twoFactorForm(maskedEmail: maskedEmail)
            } else if state.sub2APIConnection != nil {
                capacityConfigurationForm
            } else {
                loginForm
            }

            if let error = state.sub2APILastError {
                Label(error.message(language: state.language), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if state.sub2APIConnection != nil {
                Divider()
                Button(state.text(.disconnect), role: .destructive) {
                    confirmDisconnect = true
                }
                .buttonStyle(.borderless)
                .disabled(state.sub2APIStatus.isBusy)
            }
        }
        .padding(22)
        .frame(
            width: state.sub2APIConnection == nil ? 420 : 540,
            height: state.sub2APIConnection == nil ? 350 : 570
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
            Text(state.text(.capacityConfigurationHint))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Text(state.text(.account))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(state.text(.detectedPlan))
                    .frame(width: 90, alignment: .leading)
                Text(state.text(.capacityType))
                    .frame(width: 116, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)

            Group {
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
                    .frame(maxWidth: .infinity, minHeight: 220)
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
                    .frame(maxHeight: 300)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }

            HStack {
                Text("\(state.sub2APIAccountCapacityOptions.count) \(state.text(.account))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
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
        }
    }

    private func capacityRow(_ option: Sub2APIAccountCapacityOption) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName ?? "\(state.text(.account)) #\(option.accountID)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if option.displayName != nil {
                    Text("#\(option.accountID)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(option.detectedPlan)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            if isDetectedPro(option) {
                Menu {
                    Button(Sub2APICapacityTier.pro5.displayName) {
                        selectedTiers[option.accountID] = .pro5
                    }
                    Button(Sub2APICapacityTier.pro10.displayName) {
                        selectedTiers[option.accountID] = .pro10
                    }
                    Button(Sub2APICapacityTier.pro20.displayName) {
                        selectedTiers[option.accountID] = .pro20
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(
                            selectedTiers[option.accountID]?.displayName
                                ?? state.text(.selectCapacityType)
                        )
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 104, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 116, alignment: .leading)
            } else {
                Text(Sub2APICapacityTier.plus.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 116, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 46)
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
        state.sub2APIAccountCapacityOptions.contains { option in
            guard isDetectedPro(option) else { return false }
            let tier = selectedTiers[option.accountID]
            return tier?.isProCapacity != true
        }
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
