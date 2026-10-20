import SwiftUI
import AppKit

struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: { Label("设置…", systemImage: "gearshape") }
    }
}

struct SettingsView: View {
    @ObservedObject var startup: LoginStartup
    @Binding var notifications: Bool
    @Binding var threshold: Double
    @Binding var cacheBudget: Int
    let isUpdating: Bool
    var notificationError: String? = nil
    var isAuthorizingNotifications = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: AppBrand.image).resizable().scaledToFit().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DiskLens 设置").font(.title2.bold())
                    Text("磁盘透镜 · 按你的习惯运行").foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("开机启动（登录时）", isOn: Binding(get: { startup.isRequested }, set: startup.setEnabled))
                    Text(startup.statusText).font(.caption).foregroundStyle(.secondary)
                    if let error = startup.error {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack {
                        Button("系统登录项…") { startup.openSystemSettings() }
                        if startup.error != nil || startup.status == .notFound {
                            Button(startup.failedRequest == false ? "重试关闭" : "重试开启") { startup.retry() }
                        }
                    }
                    Text("默认开启；关闭窗口后仍在菜单栏运行，退出应用后停止监控。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Text("通用").font(.headline) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("空间不足时通知", isOn: $notifications).disabled(isAuthorizingNotifications)
                    if isAuthorizingNotifications { ProgressView("等待通知授权…").controlSize(.small) }
                    if let error = notificationError {
                        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    HStack {
                        Text("已用达到")
                        Slider(value: $threshold, in: 70...98, step: 1)
                            .accessibilityLabel("磁盘占用通知阈值")
                        Text("\(Int(threshold))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Text("每分钟检查所选目录所在磁盘。通知需要 macOS 授权。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Text("容量提醒").font(.headline) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("缓存预算（估算）", selection: $cacheBudget) {
                        Text("不限容量").tag(0)
                        ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) GiB").tag($0) }
                    }.disabled(isUpdating)
                    Text(isUpdating ? "索引更新中，完成后可调整预算。" : "默认 2 GiB。优先清理旧完整缓存，保留当前目录和未完成任务。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } label: { Text("索引缓存").font(.headline) }
        }
        .padding(24).frame(width: 480)
        .onAppear { startup.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in startup.refresh() }
    }
}
