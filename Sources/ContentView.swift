import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var copyConfirmation: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                header
                capacity
                scanControls
                results
                footer
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showCache) { cacheManagement }
        .alert("DiskLens", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("知道了") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var cacheManagement: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("索引缓存").font(.title2.bold())
                Spacer()
                Button("刷新") { model.refreshCache() }.disabled(model.isLoadingCache || model.isMaintainingCache)
                Button("完成") { model.showCache = false }
            }
            if let error = model.cacheError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let storage = model.cacheStorage {
                Text("数据库 \(formatBytes(storage.databaseBytes)) · 写入日志 \(formatBytes(storage.walBytes)) · 可回收空闲页 \(formatBytes(storage.freeBytes))")
                    .font(.callout)
                Picker("缓存预算（估算）", selection: Binding(get: { model.cacheBudgetGiB }, set: model.setCacheBudget)) {
                    Text("不限容量").tag(0)
                    Text("1 GiB").tag(1)
                    Text("2 GiB").tag(2)
                    Text("5 GiB").tag(5)
                    Text("10 GiB").tag(10)
                }.disabled(model.isBusy)
                Text("超过预算时移除最久未用的完整缓存；当前目录和未完成任务保留，因此可能超出预算。范围占用为估算，数据库大小以实际页面为准。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(storage.scopes) { scope in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(scope.path).lineLimit(2).textSelection(.enabled)
                                    Text("约 \(formatBytes(scope.estimatedBytes)) · \(scope.incomplete ? "未完成" : "完整缓存")\(scope.path == model.protectedCache ? " · 当前使用" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("最近使用：\(scope.lastUsed.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("清除") { model.removeCache(scope) }
                                    .disabled(model.isBusy || scope.path == model.protectedCache)
                            }
                            Divider()
                        }
                    }
                }.frame(minHeight: 160, maxHeight: 300)
                HStack {
                    Button("回收空闲空间") { model.reclaimCache() }
                        .disabled(model.isBusy || storage.freeBytes == 0)
                    Text("分批回收；较多时可再次点击。").font(.caption).foregroundStyle(.secondary)
                }
                if storage.backupBytes > 0 {
                    HStack {
                        Text("迁移备份额外占用 \(formatBytes(storage.backupBytes))").font(.callout)
                        Spacer()
                        Button("移除旧备份…") { model.removeMigrationBackup() }.disabled(model.isBusy)
                    }
                }
                if model.isBusy || model.isLoadingCache {
                    ProgressView(model.isMaintainingCache ? "正在整理缓存…" : (model.isLoadingCache ? "正在读取缓存…" : model.indexStatus)).controlSize(.small)
                }
            } else if model.cacheError == nil { ProgressView("正在读取缓存信息…") }
        }.padding(24).frame(width: 640)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(nsImage: AppBrand.image).resizable().scaledToFit().frame(width: 32, height: 32)
                VStack(alignment: .leading) {
                    Text("DiskLens").font(.title3.bold())
                    Text("磁盘透镜").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("浏览目录").font(.caption).foregroundStyle(.secondary)
                shortcut("用户目录", icon: "house", url: FileManager.default.homeDirectoryForCurrentUser)
                shortcut("下载", icon: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                shortcut("桌面", icon: "desktopcomputer", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
                shortcut("资源库", icon: "books.vertical", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"))
                Button { model.chooseFolder() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").frame(width: 20, height: 20)
                        Text("选择其他目录…").lineLimit(1)
                    }
                }.buttonStyle(SidebarNavigationButtonStyle(isSelected: false))
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("容量提醒").font(.caption).foregroundStyle(.secondary)
                Text(model.notificationEnabled ? "已用达到 \(Int(model.threshold))% 时通知" : "通知未开启")
                    .font(.callout)
                Text("每分钟检查，关闭窗口后仍在菜单栏运行。可在设置中调整。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            SettingsButton().buttonStyle(.plain)
            Button { model.openCache() } label: { Label("索引缓存…", systemImage: "internaldrive") }
                .buttonStyle(.plain)
            Text("本地扫描 · 无需联网")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func shortcut(_ title: String, icon: String, url: URL) -> some View {
        Button { model.navigate(to: url) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 20, height: 20)
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(SidebarNavigationButtonStyle(isSelected: model.isCurrentDirectory(url)))
        .accessibilityAddTraits(model.isCurrentDirectory(url) ? .isSelected : [])
    }

    private var header: some View {
        HStack {
            Text("磁盘概览").font(.title2.weight(.semibold))
            Spacer()
            Button { model.chooseFolder() } label: { Label("选择目录", systemImage: "folder.badge.plus") }
        }
    }

    private var capacity: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let volume = model.volume {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatBytes(volume.free)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("可用").foregroundStyle(.secondary)
                    Spacer()
                    Text("已用 \(Int(volume.fraction * 100))%")
                        .foregroundStyle(volume.fraction * 100 >= model.threshold ? Color.orange : Color.secondary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(volume.fraction * 100 >= model.threshold ? Color.orange : Color.teal)
                            .frame(width: geometry.size.width * min(1, max(0, volume.fraction)))
                    }
                }.frame(height: 9).accessibilityLabel("磁盘已用百分之 \(Int(volume.fraction * 100))")
                HStack {
                    Text("总容量 \(formatBytes(volume.total)) · 已用 \(formatBytes(volume.used))")
                    Spacer()
                    Text("所选目录所在磁盘")
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Label(model.volumeError ?? "正在读取容量…", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .help("后退（⌘[）").accessibilityLabel("后退")
                    .keyboardShortcut("[", modifiers: .command).disabled(!model.navigation.canGoBack)
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .help("前进（⌘]）").accessibilityLabel("前进")
                    .keyboardShortcut("]", modifiers: .command).disabled(!model.navigation.canGoForward)
                Button { model.navigate(to: model.root.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                    .help("上一级目录（⌘↑）").accessibilityLabel("上一级目录")
                    .keyboardShortcut(.upArrow, modifiers: .command).disabled(model.root.path == "/")
                Menu {
                    ForEach(ancestorDirectories, id: \.path) { url in
                        Button(url.path) { model.navigate(to: url) }
                    }
                    Divider()
                    Button("复制当前路径") { copyCurrentPath() }
                } label: {
                    Text(model.root.path).font(.callout).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.menuStyle(.borderlessButton).frame(maxWidth: .infinity, alignment: .leading).help(model.root.path)
                Button { copyCurrentPath() } label: {
                    Image(systemName: copyConfirmation == nil ? "doc.on.doc" : "checkmark")
                        .foregroundStyle(copyConfirmation == nil ? Color.primary : Color.teal)
                        .frame(width: 16, height: 16)
                }
                    .help("复制当前目录路径").accessibilityLabel("复制当前目录路径")
                    .accessibilityValue(copyConfirmation == nil ? "" : "已复制")
                    .overlay(alignment: .top) {
                        Text("已复制路径").font(.caption).foregroundStyle(.teal)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .fixedSize().offset(y: -30)
                            .opacity(copyConfirmation == nil ? 0 : 1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .task(id: copyConfirmation) {
                        guard let confirmation = copyConfirmation else { return }
                        do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                        catch { return }
                        guard copyConfirmation == confirmation else { return }
                        copyConfirmation = nil
                    }
                    .onChange(of: model.root.path) { _ in copyConfirmation = nil }
                    .onDisappear { copyConfirmation = nil }
                Button {
                    if model.isUpdating { model.pauseIndexing() }
                    else { model.refreshIndex() }
                } label: {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 16, height: 16).overlay {
                            if model.isUpdating { ProgressView().controlSize(.small) }
                            else { Image(systemName: model.isIndexingPaused ? "play.fill" : "arrow.clockwise") }
                        }
                        Text(model.isUpdating ? (model.isIndexingPaused ? "正在暂停…" : "暂停")
                             : (model.isIndexingPaused ? "继续分析" : (model.result == nil ? "建立索引" : "刷新")))
                            .frame(maxWidth: .infinity)
                    }.frame(width: 88, height: 18)
                }
                .disabled(model.isMaintainingCache || (model.isUpdating && model.isIndexingPaused))
                Menu {
                    Button("重建索引…") { model.rebuildIndex() }
                        .disabled(model.isBusy || model.isQuerying || model.result == nil)
                } label: { Image(systemName: "ellipsis") }
                    .help("完整扫描前会确认索引范围")
            }
            HStack {
                Picker("视图", selection: $model.viewMode) {
                    Text("目录占用").tag(ResultsView.directory)
                    Text("最大文件").tag(ResultsView.largest)
                    Text("占用地图").tag(ResultsView.treemap)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 290, alignment: .leading)
                Spacer()
                Color.clear.frame(width: 16, height: 16).overlay {
                    if model.isQuerying { ProgressView().controlSize(.small).help("正在查询索引") }
                }
            }
            if model.viewMode != .treemap {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索名称或完整路径", text: $model.search)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onExitCommand { model.search = "" }
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                    }
                    Toggle("含子目录", isOn: $model.recursiveSearch).toggleStyle(.checkbox).disabled(model.showLargest)
                }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .background(Button("") { if model.viewMode == .treemap { model.viewMode = .directory }; searchFocused = true }
            .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true))
    }

    private var ancestorDirectories: [URL] {
        var result: [URL] = []
        var path = model.root
        while true {
            result.append(path)
            if path.path == "/" { return result }
            path = path.deletingLastPathComponent()
        }
    }

    @ViewBuilder private var results: some View {
        if let error = model.queryError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.magnifyingglass").font(.largeTitle).foregroundStyle(.orange)
                Text("查询未完成").font(.headline)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                HStack {
                    Button("重试查询") { model.retryQuery() }
                    if !model.search.isEmpty { Button("清除搜索") { model.search = "" } }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isWaitingForResults {
            VStack(spacing: 12) {
                if model.isUpdating || model.isQuerying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "pause.circle").font(.largeTitle).foregroundStyle(.secondary)
                }
                Text(model.isUpdating ? "正在读取目录并建立索引" : (model.isQuerying ? "正在查询索引" : "索引尚未完成")).font(.headline)
                Text("尚未获得可展示的结果，不代表目录为空。").foregroundStyle(.secondary)
                Text(model.indexStatus).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.isUpdating {
                    Text("已检查 \(model.checkedItems.formatted()) 个位置，已提交的进度可继续。").font(.caption)
                } else if !model.isQuerying {
                    Button("继续分析") { model.refreshIndex() }.disabled(model.isMaintainingCache)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.result {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(result.files.formatted()) 个文件 · \(result.incomplete ? "暂计" : "合计") \(formatBytes(result.total))")
                    Spacer()
                    Text("更新于 \(result.date.formatted(date: .omitted, time: .shortened))")
                }.font(.caption).foregroundStyle(.secondary)
                if model.viewMode == .treemap {
                    TreemapView(result: result, selection: model.selection,
                                select: { model.selection = $0 }, navigate: { model.navigate(to: $0) },
                                showList: { model.search = ""; model.viewMode = .directory }, failure: { model.message = $0 })
                        .disabled(model.isBlockingQuery).allowsHitTesting(!model.isBlockingQuery)
                } else if model.entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: model.search.isEmpty ? "folder" : "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.search.isEmpty ? "没有可显示的项目" : "没有匹配的项目").font(.headline)
                        if !model.search.isEmpty { Button("清除搜索") { model.search = "" } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    entryTable(result: result).disabled(model.isBlockingQuery).allowsHitTesting(!model.isBlockingQuery)
                }
                if model.viewMode != .treemap {
                    HStack {
                        Text(model.pageNotice ?? "第 \(model.pageNumber) 页 · 本页 \(model.entries.count) 项").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("上一页") { model.previousPage() }.disabled(model.pageNumber == 1 || model.isQuerying)
                        Button("下一页") { model.nextPage() }.disabled(result.next == nil || model.isQuerying)
                    }
                }
                if result.incomplete || result.skipped > 0 {
                    Label(result.incomplete ? "部分汇总，索引完成后自动刷新；硬链接校准前可能重复计费。" : "\(result.skipped) 个位置无法读取或属于其他磁盘。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(result.issues.joined(separator: "\n"))
                }
                IndexStatusView(title: model.indexStatusSummary,
                                detail: (model.indexFailure ?? model.indexStatus) + "\n" + model.workSummary,
                                isActive: model.isUpdating || model.isQuerying)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.magnifyingglass").font(.system(size: 36)).foregroundStyle(.teal)
                Text(model.isIndexingPaused ? "此目录暂无可用缓存" : "为此目录建立索引").font(.title3.weight(.semibold))
                Text(model.isIndexingPaused ? "扫描已暂停，继续分析后读取此目录。" : "按占用查看文件夹和文件，后续变化自动更新。").foregroundStyle(.secondary)
                Button(model.isIndexingPaused ? "继续分析" : "开始分析") { model.refreshIndex() }.buttonStyle(.borderedProminent).tint(.teal)
                Text(model.indexStatus).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func entryTable(result: ScanResult) -> some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn("名称") { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? Color.teal : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(1)
                        if model.showLargest || !model.search.isEmpty {
                            Text(URL(fileURLWithPath: entry.path).deletingLastPathComponent().path)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }.help(entry.path)
            }.width(min: 160, ideal: 260)
            TableColumn("占用") { entry in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(formatBytes(entry.bytes)).monospacedDigit()
                    GeometryReader { geometry in
                        Capsule().fill(Color.teal.opacity(0.65))
                            .frame(width: geometry.size.width * min(1, max(0, Double(entry.bytes) / Double(max(1, result.total)))))
                    }.frame(height: 3)
                }
            }.width(100)
            TableColumn("变化") { entry in
                if let delta = model.delta(for: entry) {
                    Text(delta == 0 ? "—" : (delta > 0 ? "+" : "−") + formatBytes(abs(delta)))
                        .foregroundStyle(delta > 0 ? Color.orange : Color.secondary).monospacedDigit()
                        .help("相对本会话首次完整加载的占用")
                } else { Text("—").foregroundStyle(.tertiary) }
            }.width(85)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !model.isBlockingQuery, ids.count == 1, let entry = model.entries.first(where: { $0.id == ids.first }) {
                entryMenu(entry)
            }
        } primaryAction: { ids in
            if !model.isBlockingQuery, let path = ids.first, let entry = model.entries.first(where: { $0.path == path }) {
                if entry.isDirectory { model.navigate(to: URL(fileURLWithPath: path)) }
                else { FileActions.open(URL(fileURLWithPath: path)) { model.message = $0 } }
            }
        }
    }

    @ViewBuilder private func entryMenu(_ entry: DiskEntry) -> some View {
        let url = URL(fileURLWithPath: entry.path)
        Button(entry.isDirectory ? "打开此文件夹" : "打开") {
            if entry.isDirectory { model.navigate(to: url) }
            else { FileActions.open(url) { model.message = $0 } }
        }
        if !entry.isDirectory {
            Menu("打开方式") {
                ForEach(FileActions.applications(for: url), id: \.self) { app in
                    Button(FileActions.applicationName(app, for: url)) { FileActions.open(url, with: app) { model.message = $0 } }
                }
                Divider()
                Button("其他应用…") { FileActions.chooseApplication(for: url) { model.message = $0 } }
            }
        }
        Divider()
        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("复制路径") { model.copyPath(entry.path) }
    }

    private func copyCurrentPath() {
        copyConfirmation = model.copyPath(model.root.path, showFeedback: false) ? UUID() : nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let feedback = model.feedback {
                Label(feedback, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.teal)
                    .lineLimit(1).truncationMode(.middle).help(feedback)
            }
            HStack {
                Button { model.revealSelection() } label: { Label("Finder 中显示", systemImage: "arrow.up.forward.square") }
                    .disabled(!model.canUseSelection)
                Button {
                    if model.canUseSelection, let entry = model.selectedEntry { model.copyPath(entry.path) }
                } label: { Label("复制路径", systemImage: "doc.on.doc") }
                    .disabled(!model.canUseSelection)
                if model.selectedEntry?.isDirectory == true {
                    Button("进入文件夹") { if let entry = model.selectedEntry { model.navigate(to: URL(fileURLWithPath: entry.path)) } }
                        .disabled(!model.canUseSelection)
                }
                Spacer()
                Button(role: .destructive) { model.trashSelection() } label: {
                    Label(model.isTrashing ? "正在处理…" : "移到废纸篓…", systemImage: "trash")
                }.disabled(!model.canUseSelection || model.isBusy || model.isTrashing || model.result?.incomplete == true)
            }
            Text("已分配空间估算；APFS 共享块与系统储存统计可能不同。移到废纸篓后仍占空间。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct SidebarNavigationButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7).padding(.horizontal, 8)
            .background(Color.teal.opacity(configuration.isPressed ? 0.22 : (isSelected ? 0.12 : 0)),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
    }
}

struct IndexStatusView: View {
    let title: String
    let detail: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            IndexActivityIcon(isActive: isActive)
            Text(title).lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isActive ? "正在更新" : "空闲")
        .transaction { $0.animation = nil }
    }
}

private struct IndexActivityIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = IndexActivityRotation()
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !rotation.isRunning || reduceMotion)) { context in
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(rotation.isRunning || (reduceMotion && isActive) ? Color.teal : Color.secondary)
                .rotationEffect(.degrees(rotation.angle(at: ProcessInfo.processInfo.systemUptime)))
                .onChange(of: context.date) { _ in
                    rotation.finishIfNeeded(at: ProcessInfo.processInfo.systemUptime)
                }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
        .onAppear { updateActivity(active: isActive, reducedMotion: reduceMotion) }
        .onChange(of: isActive) { active in updateActivity(active: active, reducedMotion: reduceMotion) }
        .onChange(of: reduceMotion) { reducedMotion in updateActivity(active: isActive, reducedMotion: reducedMotion) }
        .onDisappear { rotation.reset() }
    }

    private func updateActivity(active: Bool, reducedMotion: Bool) {
        if reducedMotion { rotation.reset() }
        else { rotation.setActive(active, at: ProcessInfo.processInfo.systemUptime) }
    }
}

// Short updates finish their current turn; subsequent updates keep the same phase.
// The view supplies monotonic uptime so wall-clock adjustments cannot jump the icon.
struct IndexActivityRotation {
    private let duration: TimeInterval = 3
    private var startedAt: TimeInterval?
    private var finishesAt: TimeInterval?
    var isRunning: Bool { startedAt != nil }

    mutating func setActive(_ active: Bool, at time: TimeInterval) {
        finishIfNeeded(at: time)
        if active {
            if startedAt == nil { startedAt = time }
            finishesAt = nil
        } else if let startedAt, finishesAt == nil {
            let turns = max(1, ceil((time - startedAt) / duration))
            finishesAt = startedAt + turns * duration
        }
    }

    func angle(at time: TimeInterval) -> Double {
        guard let startedAt else { return 0 }
        let elapsed = max(0, min(time, finishesAt ?? time) - startedAt)
        return elapsed.truncatingRemainder(dividingBy: duration) / duration * 360
    }

    mutating func finishIfNeeded(at time: TimeInterval) {
        if let finishesAt, time >= finishesAt { reset() }
    }

    mutating func reset() {
        startedAt = nil
        finishesAt = nil
    }
}
