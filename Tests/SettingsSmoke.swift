import AppKit
import SwiftUI
import ServiceManagement

@MainActor private final class FakeLoginService: LoginService {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var removals = 0
    var needsApproval = false
    var fail = false
    func register() throws {
        registrations += 1
        if fail { throw NSError(domain: "SettingsSmoke", code: 1) }
        status = needsApproval ? .requiresApproval : .enabled
    }
    func unregister() throws {
        removals += 1
        if fail { throw NSError(domain: "SettingsSmoke", code: 2) }
        status = .notRegistered
    }
}

@main struct SettingsSmoke {
    @MainActor static func main() throws {
        let suite = "DiskLens.settings-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeLoginService()
        let startup = LoginStartup(defaults: defaults, service: fake)
        startup.applyDefault()
        precondition(fake.registrations == 1 && startup.status == .enabled, "first launch enables login startup")
        startup.applyDefault()
        precondition(fake.registrations == 1, "default is one-time")
        startup.setEnabled(false)
        precondition(fake.removals == 1 && !startup.isRequested, "manual disable unregisters")
        let reopened = LoginStartup(defaults: defaults, service: fake)
        reopened.applyDefault()
        precondition(fake.registrations == 1 && !reopened.isRequested, "relaunch respects disable")
        reopened.setEnabled(true)
        fake.status = .notRegistered
        reopened.refresh(); reopened.applyDefault()
        precondition(!reopened.isRequested && fake.registrations == 2, "external disable is respected")
        fake.needsApproval = true
        reopened.setEnabled(true)
        precondition(reopened.status == .requiresApproval && reopened.statusText.contains("等待"), "approval is not reported as enabled")
        reopened.setEnabled(false)
        fake.fail = true
        reopened.setEnabled(true)
        precondition(reopened.error != nil && !reopened.isRequested, "registration failure remains off")
        fake.fail = false; fake.needsApproval = false
        reopened.setEnabled(true)
        precondition(reopened.error == nil && reopened.status == .enabled, "manual retry succeeds")
        fake.fail = true
        reopened.setEnabled(false)
        precondition(reopened.error != nil && reopened.status == .enabled, "unregister failure remains enabled")
        precondition(reopened.failedRequest == false, "retry keeps the user's disable intent")
        fake.fail = false
        reopened.retry()
        precondition(!reopened.isRequested && reopened.failedRequest == nil && reopened.error == nil, "retry unregisters instead of enabling")
        print("PASS: default-on once, persistent disable, external changes, pending approval, errors and retry; no real login item changed")

        guard ProcessInfo.processInfo.environment["DISKLENS_CAPTURE_UI"] == "1" else { return }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DISKLENS_CAPTURE_DIR"] ?? ".build/previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        fake.fail = false
        reopened.setEnabled(true)
        let view = SettingsView(startup: reopened, notifications: .constant(false), threshold: .constant(85),
                                cacheBudget: .constant(2), isUpdating: false)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.title = "DiskLens 设置"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent("settings.png").path]
        try capture.run(); capture.waitUntilExit()
        window.orderOut(nil)
        precondition(capture.terminationStatus == 0, "Settings screenshot capture failed")
        print("PASS: settings screenshot; simulated login service only")
    }
}
