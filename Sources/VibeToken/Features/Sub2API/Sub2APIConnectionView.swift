import SwiftUI

struct Sub2APIConnectionView: View {
    @Bindable var state: AppState
    @Binding var isPresented: Bool

    @State private var serverURL = ""
    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var confirmDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.text(.configureConnection))
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
        .frame(width: 420, height: state.sub2APIConnection == nil ? 350 : 400)
        .background(.regularMaterial)
        .onAppear {
            serverURL = state.sub2APIConnection?.baseURL.absoluteString ?? ""
            email = state.sub2APIConnection?.email ?? ""
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
                        if state.sub2APIStatus == .connected {
                            isPresented = false
                        }
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
                        if state.sub2APIStatus == .connected {
                            isPresented = false
                        }
                    }
                } label: {
                    submitLabel(state.text(.verify))
                }
                .buttonStyle(.borderedProminent)
                .disabled(verificationCode.count != 6 || state.sub2APIStatus.isBusy)
            }
        }
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
