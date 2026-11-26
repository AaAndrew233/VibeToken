import SwiftUI

struct SettingsWindowView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.text(.settingsDockStartup))
                .font(.system(size: 16, weight: .semibold))

            VStack(spacing: 0) {
                SettingsRow(title: state.text(.dockIcon)) {
                    Picker("", selection: $state.dockIconMode) {
                        ForEach(DockIconMode.allCases) { mode in
                            Text(state.dockIconModeTitle(mode)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                SettingsRow(
                    title: state.text(.launchAtLogin),
                    detail: state.launchAtLoginStatusText
                ) {
                    Toggle("", isOn: Binding(
                        get: { state.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            }
        }
        .padding(24)
        .frame(width: 420, height: 220, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshLaunchAtLoginStatus()
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 16)
        }
    }
}
