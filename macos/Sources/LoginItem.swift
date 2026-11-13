import Combine
import ServiceManagement
import SwiftUI

final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage = ""

    private let defaults = UserDefaults.standard
    private let configuredKey = "launchAtLoginConfigured"

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }

    /// Enable once on the first launch of a version with this feature.
    /// Later launches respect changes made in Floe or System Settings.
    func configureDefault() {
        refresh()
        guard !defaults.bool(forKey: configuredKey) else { return }
        defaults.set(true, forKey: configuredKey)
        setEnabled(true)
    }

    func setEnabled(_ requested: Bool) {
        defaults.set(true, forKey: configuredKey)
        errorMessage = ""
        do {
            let service = SMAppService.mainApp
            if requested {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            errorMessage = "Could not update login startup: \(error.localizedDescription)"
        }
        refresh()
        if requested && requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

struct LoginItemView: View {
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch Floe at login", isOn: Binding(
                get: { loginItem.enabled },
                set: { loginItem.setEnabled($0) }
            ))
            if loginItem.requiresApproval {
                HStack {
                    Text("Approval required in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
            if !loginItem.errorMessage.isEmpty {
                Text(loginItem.errorMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
