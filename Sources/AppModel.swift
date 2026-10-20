import AppKit
import SwiftUI
import UserNotifications

enum ResultsView: Hashable { case directory, largest, treemap }

@MainActor
final class AppModel: ObservableObject {
    let loginStartup: LoginStartup
    private let defaults: UserDefaults
    @Published private(set) var queryError: String?
    @Published private(set) var notificationError: String?
    @Published private(set) var isAuthorizingNotifications = false
    @Published private(set) var isMaintainingCache = false
    @Published private(set) var isLoadingCache = false
    @Published private(set) var navigation = NavigationHistory()
    @Published private(set) var feedback: String?
    @Published private(set) var indexFailure: String?
    var indexStatusSummary: String {
        if indexFailure != nil { return "索引更新失败" }
        if isIndexingPaused { return "已暂停自动更新" }
        if isMaintainingCache { return "正在整理缓存" }
        if result?.incomplete == true { return isUpdating ? "正在建立索引" : "索引尚未完成" }
        return "自动更新"
    }
    var isBusy: Bool { isUpdating || isMaintainingCache }
    var canUseSelection: Bool { selectedEntry != nil && !isBlockingQuery && queryError == nil }
    var isBlockingQuery: Bool { isQuerying && (isReplacingResults || result == nil) }
    @Published private var isReplacingResults = false
    var isWaitingForResults: Bool {
        guard let result else { return isUpdating || isQuerying }
        guard result.incomplete || isBlockingQuery else { return false }
        if viewMode == .treemap {
            return result.total <= 0 && !result.entries.contains { $0.bytes > 0 }
        }
        return result.entries.isEmpty
    }
    @Published var showCache = false
    @Published private(set) var cacheStorage: CacheStorage?
    @Published private(set) var protectedCache: String?
    @Published private(set) var cacheBudgetGiB = 2
    @Published private(set) var cacheError: String?
    @Published var root: URL
    @Published var volume: VolumeStatus?
    @Published var volumeError: String?
    @Published var result: ScanResult?
    @Published var baseline: ComparisonBaseline?
    @Published var isUpdating = false
    @Published private(set) var isIndexingPaused = false
    @Published var checkedItems = 0
    @Published var selection: String?
    @Published var search = "" { didSet { scheduleQuery(debounce: true) } }
    @Published var viewMode: ResultsView = .directory { didSet {
        guard viewMode != oldValue else { return }
        result = nil
        scheduleQuery()
    } }
    var showLargest: Bool { viewMode == .largest }
    @Published var recursiveSearch = true { didSet { scheduleQuery() } }
    @Published var isQuerying = false
    @Published private(set) var isTrashing = false
    @Published private(set) var pageNumber = 1
    @Published private(set) var pageNotice: String?
    private var pageHistory: [PageCursor?] = []
    private var after: PageCursor?
    private var queryWork: DispatchWorkItem?
    private var navigating = false
    @Published var message: String?
    @Published var notificationEnabled: Bool
    @Published var threshold: Double {
        didSet { defaults.set(threshold, forKey: "threshold"); refreshVolume() }
    }
    @Published var indexStatus = "选择目录后建立索引，后续自动更新。"
    @Published private(set) var workSummary = "索引操作完成后显示本次工作量。"
    private var coordinator: IndexCoordinator!
    private var timer: Timer?
    private var alerts = CapacityAlerts()
    private var notificationAuthorization = UUID()
    private let volumeReader = VolumeReader()
    private let trashQueue = DispatchQueue(label: "DiskLens.trash", qos: .userInitiated)
    private var lastVolumeRead = Date.distantPast
    private var lastVolumePath = ""

    init(defaults: UserDefaults = .standard, databaseURL: URL? = nil, startServices: Bool = true) {
        self.defaults = defaults
        loginStartup = LoginStartup(defaults: defaults)
        cacheBudgetGiB = defaults.object(forKey: "cacheBudgetGiB") == nil ? 2 : defaults.integer(forKey: "cacheBudgetGiB")
        let saved = defaults.string(forKey: "root")
        root = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        notificationEnabled = defaults.bool(forKey: "notifications")
        threshold = defaults.object(forKey: "threshold") == nil ? 85 : defaults.double(forKey: "threshold")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskLens")
        coordinator = IndexCoordinator(databaseURL: databaseURL ?? support.appendingPathComponent("index.sqlite")) { [weak self] update in
            self?.receive(update)
        }
        guard startServices else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshVolume() }
        }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--scan"), args.indices.contains(index + 1) {
            root = URL(fileURLWithPath: args[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
            coordinator.open(root)
        } else {
            coordinator.open(root, buildIfMissing: false)
        }
        refreshVolume()
        loginStartup.applyDefault()
    }

    var entries: [DiskEntry] { result?.entries ?? [] }

    private func scheduleQuery(debounce: Bool = false) {
        guard coordinator != nil, !navigating else { return }
        queryWork?.cancel()
        coordinator.cancelQueries()
        result = nil
        queryError = nil
        feedback = nil
        pageHistory.removeAll()
        after = nil
        pageNumber = 1
        pageNotice = nil
        baseline = nil
        selection = nil
        isReplacingResults = true
        isQuerying = true
        coordinator.prepareQuery(root, options: queryOptions)
        let work = DispatchWorkItem { [weak self] in self?.loadPage() }
        queryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.2 : 0), execute: work)
    }

    private var queryOptions: IndexQuery {
        viewMode == .treemap ? IndexQuery() : IndexQuery(largest: showLargest, search: search,
            recursive: recursiveSearch, after: after)
    }

    func retryQuery() { queryError = nil; loadPage() }

    private func beginQuery(replacingResults: Bool) {
        queryError = nil
        isReplacingResults = replacingResults
        isQuerying = true
    }

    private func loadPage(replacingResults: Bool = true) {
        beginQuery(replacingResults: replacingResults)
        coordinator.query(root, options: queryOptions)
    }

    func nextPage() {
        guard let next = result?.next, !isQuerying else { return }
        pageNotice = nil
        pageHistory.append(after)
        after = next
        pageNumber += 1
        selection = nil
        loadPage()
    }

    func previousPage() {
        guard !pageHistory.isEmpty, !isQuerying else { return }
        pageNotice = nil
        after = pageHistory.removeLast()
        pageNumber -= 1
        selection = nil
        loadPage()
    }

    var selectedEntry: DiskEntry? { entries.first { $0.id == selection } }
    var menuTitle: String { volume.map { "剩余 \(formatBytes($0.free))" } ?? "磁盘状态不可用" }

    func refreshVolume() {
        let requested = root
        volumeReader.request(requested) { [weak self] response in
            guard let self, self.root == requested else { return }
            self.lastVolumeRead = Date()
            self.lastVolumePath = requested.path
            self.receiveVolume(response)
        }
    }

    private func receiveVolume(_ response: Result<VolumeStatus, Error>) {
        switch response {
        case .success(let status):
            volume = status
            volumeError = nil
            if let token = alerts.prepare(status, threshold: threshold, enabled: notificationEnabled) {
                let content = UNMutableNotificationContent()
                content.title = "磁盘空间不足"
                content.body = "已用 \(Int(status.fraction * 100))%，剩余 \(formatBytes(status.free))。打开 DiskLens 查看占用。"
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "disk-capacity", content: content, trigger: nil)) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.alerts.complete(token, succeeded: error == nil) else { return }
                        if let error {
                            self.message = "通知发送失败：\(error.localizedDescription)；稍后重试。"
                        }
                    }
                }
            }
        case .failure(let error): volume = nil; volumeError = "无法读取磁盘容量：\(error.localizedDescription)"
        }
    }

    func setNotifications(_ enabled: Bool) {
        guard !enabled || !isAuthorizingNotifications else { return }
        isAuthorizingNotifications = enabled
        notificationError = nil
        notificationAuthorization = UUID()
        let authorization = notificationAuthorization
        alerts.reset()
        guard enabled else {
            notificationEnabled = false
            defaults.set(false, forKey: "notifications")
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["disk-capacity"])
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                guard let self, self.notificationAuthorization == authorization else { return }
                self.isAuthorizingNotifications = false
                self.notificationEnabled = granted
                self.defaults.set(granted, forKey: "notifications")
                if !granted { self.notificationError = error?.localizedDescription ?? "通知未获授权，请在系统设置 → 通知 → DiskLens 中允许通知。" }
                self.refreshVolume()
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "分析此目录"
        if panel.runModal() == .OK, let url = panel.url { navigate(to: url) }
    }

    func goBack() { if let url = navigation.goBack(from: root) { navigate(to: url, recordHistory: false) } }
    func goForward() { if let url = navigation.goForward(from: root) { navigate(to: url, recordHistory: false) } }

    func isCurrentDirectory(_ url: URL) -> Bool {
        root.standardizedFileURL.path == url.standardizedFileURL.path
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        let hasCurrentState = result != nil || isQuerying || isUpdating || isIndexingPaused
        if isCurrentDirectory(url), hasCurrentState { return }
        let next = url.standardizedFileURL.resolvingSymlinksInPath()
        if isCurrentDirectory(next), hasCurrentState { return }
        if recordHistory { navigation.visit(from: root, to: next) }
        navigating = true
        indexFailure = nil
        queryError = nil
        feedback = nil
        queryWork?.cancel()
        coordinator.cancelQueries()
        root = next
        defaults.set(root.path, forKey: "root")
        if viewMode != .treemap { viewMode = .directory }
        search = ""
        result = nil
        workSummary = "索引操作完成后显示本次工作量。"
        baseline = nil
        selection = nil
        after = nil
        pageHistory.removeAll()
        pageNumber = 1
        pageNotice = nil
        navigating = false
        if isIndexingPaused {
            refreshVolume()
            loadPage()
        } else {
            refreshIndex()
        }
    }

    func refreshIndex() {
        isIndexingPaused = false
        indexFailure = nil
        refreshVolume()
        beginQuery(replacingResults: false)
        coordinator.open(root, options: queryOptions)
    }

    func rebuildIndex() {
        guard !isBusy, !isQuerying, let scan = result else { return }
        let scope = scan.indexedScope.isEmpty ? root.path : scan.indexedScope
        let alert = NSAlert()
        alert.messageText = "重新扫描整个索引范围？"
        alert.informativeText = scope + "\n\n这可能比当前显示目录更大。重建会重新读取元数据，较大目录可能耗时较长；可以暂停并继续。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "重建索引")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        isIndexingPaused = false
        baseline = nil
        beginQuery(replacingResults: true)
        coordinator.open(root, force: true, options: queryOptions)
    }

    func openCache() { showCache = true; refreshCache() }
    func refreshCache() { cacheError = nil; isLoadingCache = true; coordinator.loadCacheStorage() }
    private func maintainCache(_ action: IndexCoordinator.CacheAction) {
        guard !isBusy else { return }
        isMaintainingCache = true
        cacheError = nil
        feedback = nil
        coordinator.maintainCache(action)
    }
    func setCacheBudget(_ gib: Int) {
        guard !isBusy, [0, 1, 2, 5, 10].contains(gib) else { return }
        cacheBudgetGiB = gib
        defaults.set(gib, forKey: "cacheBudgetGiB")
        maintainCache(.budget(Int64(gib) * 1024 * 1024 * 1024))
    }
    func reclaimCache() { maintainCache(.reclaim) }
    func removeCache(_ scope: CachedScope) {
        guard scope.path != protectedCache else { return }
        let alert = NSAlert()
        alert.messageText = "清除这个目录的索引缓存？"
        alert.informativeText = scope.path + "\n\n以后打开需重新扫描。未完成的扫描进度也会清除，用户文件保持不变。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除缓存")
        if alert.runModal() == .alertSecondButtonReturn { maintainCache(.remove(scope.path)) }
    }
    func removeMigrationBackup() {
        let alert = NSAlert()
        alert.messageText = "移除旧索引备份以释放空间？"
        alert.informativeText = "请先确认新版索引浏览和恢复正常。移除后不能从此备份回退，但仍可重新扫描建立索引。用户文件保持不变。"
        alert.addButton(withTitle: "保留")
        alert.addButton(withTitle: "移除备份")
        if alert.runModal() == .alertSecondButtonReturn { maintainCache(.removeBackup) }
    }

    func pauseIndexing() {
        guard !isIndexingPaused else { return }
        isIndexingPaused = true
        coordinator.cancel()
    }

    private var pausedStatus: String { "已暂停扫描与自动更新 · 可浏览缓存，点击继续分析恢复。" }

    func receive(_ update: IndexUpdate) {
        switch update {
        case .cache(let storage, let protected):
            isLoadingCache = false
            cacheStorage = storage
            protectedCache = protected
        case .cacheFailure(let error): isLoadingCache = false; cacheError = error
        case .cacheFinished: isMaintainingCache = false
        case .statistics(let scope, let work):
            if isWithin(root.path, scope) { workSummary = work.summary }
        case .activity(let status):
            if !isMaintainingCache { indexFailure = nil }
            isUpdating = true
            indexStatus = status
            checkedItems = 0
        case .phase(let status):
            isUpdating = true
            indexStatus = status
        case .progress(let count):
            checkedItems = count
        case .snapshot(let scan, let status, let busy):
            guard scan.root.path == root.path else { return }
            queryError = nil
            if scan.pageReset {
                pageHistory.removeAll()
                after = nil
                pageNumber = 1
                selection = nil
                pageNotice = "索引已变化，已返回第一页。"
            }
            if search.isEmpty, !showLargest, !scan.incomplete, scan.skipped == 0 {
                if baseline == nil { baseline = ComparisonBaseline(date: scan.date, sizes: [:]) }
                baseline?.include(scan.entries)
            }
            result = scan
            indexStatus = isIndexingPaused ? pausedStatus : status
            isUpdating = busy
            if let selection, !entries.contains(where: { $0.id == selection }) { self.selection = nil }
            if !volumeReader.isReading && (lastVolumePath != root.path || Date().timeIntervalSince(lastVolumeRead) >= 5) { refreshVolume() }
        case .idle(let status):
            indexStatus = isIndexingPaused ? pausedStatus : status
            isUpdating = false
        case .missing(let path):
            if path == root.path { result = nil }
        case .querying(let value):
            isQuerying = value
            if !value { isReplacingResults = false }
        case .queryFailure(let error):
            isQuerying = false
            isReplacingResults = false
            result = nil
            selection = nil
            queryError = error
        case .failure(let error):
            indexStatus = error
            isUpdating = false
            if isMaintainingCache { cacheError = error }
            else { indexFailure = error; message = error }
        }
    }

    func delta(for entry: DiskEntry) -> Int64? {
        guard !showLargest, search.isEmpty, result?.incomplete == false, let previous = baseline,
              result?.skipped == 0,
              let oldSize = previous.sizes[entry.path] else { return nil }
        return entry.bytes - oldSize
    }

    @discardableResult func copyPath(_ path: String, showFeedback: Bool = true) -> Bool {
        feedback = nil
        if FileActions.copyPath(path) {
            if showFeedback { feedback = "已复制路径：\(path)" }
            return true
        } else {
            message = "无法写入剪贴板，请重试。"
            return false
        }
    }

    func revealSelection() {
        if canUseSelection, let entry = selectedEntry { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
    }

    func trashSelection() {
        guard let entry = selectedEntry, let scan = result, !isBusy, !isQuerying, !isTrashing, !scan.incomplete else { return }
        let target = URL(fileURLWithPath: entry.path)
        guard let identity = entry.identity else { message = "文件身份不可用，请刷新索引。"; return }
        isTrashing = true
        trashQueue.async { [weak self] in
            let validation = Result { try TrashPolicy.validate(target, root: scan.root, expected: identity) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.root == scan.root, self.selection == entry.path else { self.isTrashing = false; return }
                switch validation {
                case .failure(let error): self.isTrashing = false; self.message = error.localizedDescription
                case .success: self.confirmTrash(entry, root: scan.root, identity: identity)
                }
            }
        }
    }

    private func confirmTrash(_ entry: DiskEntry, root: URL, identity: FileIdentity) {
        let alert = NSAlert()
        alert.messageText = "将“\(entry.name)”移到废纸篓？"
        alert.informativeText = "\(entry.path)\n\n扫描占用：\(formatBytes(entry.bytes))。\(entry.isDirectory ? "文件夹中的全部内容都会一起移动。" : "")\n可以在 Finder 的废纸篓中恢复；清空废纸篓前，磁盘空间不会释放。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { isTrashing = false; return }
        trashQueue.async { [weak self] in
            let outcome = Result {
                let target = URL(fileURLWithPath: entry.path)
                try TrashPolicy.validate(target, root: root, expected: identity)
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isTrashing = false
                switch outcome {
                case .success:
                    self.feedback = "已将“\(entry.name)”移到废纸篓，可在 Finder 中恢复。"
                    self.selection = nil
                    self.coordinator.changed(entry.path); self.refreshVolume()
                case .failure(let error): self.message = "无法移到废纸篓：\(error.localizedDescription)"
                }
            }
        }
    }
}
