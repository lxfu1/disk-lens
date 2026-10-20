import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("DiskLens · 磁盘透镜", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 610)
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsButton().keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("选择目录…") { model.chooseFolder() }.keyboardShortcut("o")
                Button(model.isIndexingPaused ? "继续分析" : "刷新变化") { model.refreshIndex() }.keyboardShortcut("r").disabled(model.isBusy)
            }
        }
        Window("DiskLens 设置", id: "settings") {
            SettingsView(startup: model.loginStartup,
                         notifications: Binding(get: { model.notificationEnabled }, set: model.setNotifications),
                         threshold: $model.threshold,
                         cacheBudget: Binding(get: { model.cacheBudgetGiB }, set: model.setCacheBudget),
                         isUpdating: model.isBusy, notificationError: model.notificationError, isAuthorizingNotifications: model.isAuthorizingNotifications)
        }.windowResizability(.contentSize)
        MenuBarExtra {
            DiskMenu(model: model)
        } label: {
            Label(model.menuTitle, systemImage: "internaldrive")
        }
    }
}

struct DiskMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.menuTitle)
        if let volume = model.volume { Text("已用 \(Int(volume.fraction * 100))% · 总计 \(formatBytes(volume.total))") }
        Text("每分钟更新 · 所选目录所在磁盘")
        Divider()
        Button("打开磁盘透镜") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("刷新容量") { model.refreshVolume() }
        SettingsButton().keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("退出 DiskLens") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
