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

                SettingsRow(title: state.text(.launchAtLogin)) {
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
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    init(
        title: String,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
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
