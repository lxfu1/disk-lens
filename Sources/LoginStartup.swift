import Foundation
import Combine
import ServiceManagement

@MainActor protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor private struct MainAppLoginService: LoginService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor final class LoginStartup: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error: String?
    @Published private(set) var failedRequest: Bool?
    private let defaults: UserDefaults
    private let service: LoginService
    private static let initializedKey = "loginStartupInitialized"

    init(defaults: UserDefaults = .standard, service: LoginService? = nil) {
        self.defaults = defaults
        self.service = service ?? MainAppLoginService()
        status = self.service.status
    }

    // Apply the default once. Respect later changes in either our UI or System Settings.
    func applyDefault() {
        guard !defaults.bool(forKey: Self.initializedKey) else { refresh(); return }
        defaults.set(true, forKey: Self.initializedKey)
        refresh()
        if status == .notRegistered { setEnabled(true) }
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var statusText: String {
        switch status {
        case .enabled: return "已开启，登录此 Mac 时自动启动。"
        case .requiresApproval: return "等待系统批准，请在系统登录项中允许 DiskLens。"
        case .notRegistered: return "已关闭，登录时不会自动启动。"
        case .notFound: return "系统找不到应用，请将 DiskLens 放在固定位置后重试。"
        @unknown default: return "无法确认状态，请检查系统登录项。"
        }
    }
    func refresh() {
        status = service.status
        if (failedRequest == true && status == .enabled) || (failedRequest == false && status == .notRegistered) {
            error = nil; failedRequest = nil
        }
    }
    func retry() { setEnabled(failedRequest ?? true) }
    func setEnabled(_ enabled: Bool) {
        defaults.set(true, forKey: Self.initializedKey)
        error = nil
        failedRequest = nil
        refresh()
        do {
            if enabled {
                if !isRequested { try service.register() }
            } else if status != .notRegistered { try service.unregister() }
        } catch {
            failedRequest = enabled
            self.error = "无法\(enabled ? "开启" : "关闭")开机启动：\(error.localizedDescription)"
        }
        refresh()
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
