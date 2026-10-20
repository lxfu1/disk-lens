import AppKit
import SwiftUI
import SQLite3

@main struct ReleaseSmoke {
    @MainActor static func main() throws {
        verifyActivityRotation()
        // Exercise the production deletion statement without scanning the actual filesystem root.
        var db: OpaquePointer?
        precondition(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, "CREATE TABLE jobs(scope INTEGER,path TEXT,mode INTEGER); INSERT INTO jobs VALUES(1,'/',0),(1,'/a',1),(1,'/a/b',1),(2,'/other',1);", nil, nil, nil) == SQLITE_OK)
        func removeDescendants(scope: String, path: String, lower: String, upper: String) {
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, DiskIndex.descendantJobsDeletion, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            for (offset, value) in [scope, path, lower, upper].enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            precondition(sqlite3_step(statement) == SQLITE_DONE)
        }
        func count(_ predicate: String) -> Int {
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM jobs WHERE " + predicate, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            precondition(sqlite3_step(statement) == SQLITE_ROW)
            return Int(sqlite3_column_int(statement, 0))
        }
        removeDescendants(scope: "1", path: "/", lower: "/", upper: "0")
        precondition(count("scope=1 AND path='/'") == 1 && count("scope=1") == 1 && count("scope=2") == 1)
        sqlite3_exec(db, "INSERT INTO jobs VALUES(1,'/a',0),(1,'/a/b',1),(1,'/ab',1);", nil, nil, nil)
        removeDescendants(scope: "1", path: "/a", lower: "/a/", upper: "/a0")
        precondition(count("path='/a'") == 1 && count("path='/a/b'") == 0 && count("path='/ab'") == 1)
        print("PASS: root rebuild retains its own job; normal subtree and unrelated scopes preserved")

        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b"), c = URL(fileURLWithPath: "/c")
        var history = NavigationHistory()
        history.visit(from: a, to: b)
        precondition(history.goBack(from: b) == a && history.canGoForward)
        precondition(history.goForward(from: a) == b)
        _ = history.goBack(from: b)
        history.visit(from: a, to: c)
        precondition(!history.canGoForward && history.goBack(from: c) == a)
        history.visit(from: a, to: a)
        precondition(!history.canGoBack)
        print("PASS: navigation back/forward, new branch and same-directory no-op")

        _ = NSApplication.shared
        let suite = "DiskLens.release-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: fixture) }
        defaults.set("/示例项目", forKey: "root")
        let model = AppModel(defaults: defaults, databaseURL: fixture.appendingPathComponent("index.sqlite"), startServices: false)
        let entries = [DiskEntry(path: "/示例项目/应用源码", isDirectory: true, bytes: 420_000_000),
                       DiskEntry(path: "/示例项目/依赖", isDirectory: true, bytes: 280_000_000),
                       DiskEntry(path: "/示例项目/设计稿.fig", isDirectory: false, bytes: 160_000_000),
                       DiskEntry(path: "/示例项目/演示视频.mov", isDirectory: false, bytes: 90_000_000),
                       DiskEntry(path: "/示例项目/说明.md", isDirectory: false, bytes: 30_000_000)]
        let scan = ScanResult(root: model.root, entries: entries, files: 2000, skipped: 0, issues: [], date: Date(), total: 1_000_000_000, incomplete: false, next: nil, pageReset: false, indexedScope: "/示例项目")
        model.result = scan; model.selection = entries[0].path
        model.receive(.queryFailure("查询超时，请缩小范围"))
        precondition(model.result == nil && model.selection == nil && !model.canUseSelection && model.queryError != nil)
        model.receive(.snapshot(scan, "自动更新 · 当前索引已完成", false))
        precondition(model.queryError == nil && model.entries.count == 5)
        model.selection = entries[0].path
        model.receive(.querying(true))
        precondition(model.canUseSelection && !model.isBlockingQuery && model.result?.entries == entries,
                     "background refresh preserves results, selection and browsing")
        model.receive(.querying(false))
        model.result = ScanResult(root: scan.root, entries: entries, files: scan.files, skipped: 0, issues: [],
                                  date: scan.date, total: scan.total, incomplete: false,
                                  next: PageCursor(bytes: 1, nodeID: 200, revision: "test"), pageReset: false)
        model.nextPage()
        precondition(model.isBlockingQuery && !model.canUseSelection && model.result?.entries == entries,
                     "page transition retains content but blocks operations on the previous page")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        model.receive(.snapshot(scan, "自动更新 · 当前索引已完成", false))
        model.receive(.querying(false))
        model.reclaimCache()
        precondition(model.isMaintainingCache && model.isBusy, "maintenance has immediate feedback before queue runs")
        model.receive(.failure("维护失败示例"))
        model.receive(.cache(CacheStorage(scopes: [], databaseBytes: 0, walBytes: 0, freeBytes: 0, backupBytes: 0), nil))
        precondition(model.cacheError == "维护失败示例", "storage refresh must not erase operation errors")
        let deadline = Date().addingTimeInterval(5)
        while model.isMaintainingCache && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(!model.isMaintainingCache, "real coordinator completes maintenance state")
        print("PASS: query failure clears stale selection/results, snapshots recover, maintenance immediately disables actions")

        func emptyScan(incomplete: Bool, entries: [DiskEntry] = []) -> ScanResult {
            ScanResult(root: model.root, entries: entries, files: 0, skipped: 0, issues: [], date: Date(),
                       total: 0, incomplete: incomplete, next: nil, pageReset: false)
        }
        model.receive(.activity("正在读取目录索引…"))
        model.receive(.missing(model.root.path))
        model.receive(.querying(false))
        precondition(model.isWaitingForResults, "cache miss must not end directory loading")
        model.receive(.snapshot(emptyScan(incomplete: true), "首次建立索引", true))
        precondition(model.isWaitingForResults, "empty partial snapshot is not an empty directory")
        model.receive(.idle("已暂停"))
        precondition(model.isWaitingForResults && !model.isUpdating, "paused partial index still has unknown results")
        model.receive(.snapshot(emptyScan(incomplete: false), "已完成", false))
        precondition(!model.isWaitingForResults, "completed empty directory can show empty state")
        model.receive(.activity("正在更新变化…"))
        model.receive(.querying(true))
        precondition(!model.isWaitingForResults, "refreshing a complete empty directory must not replace it with a loading page")
        model.receive(.querying(false))
        model.viewMode = .treemap
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        model.receive(.querying(false))
        model.receive(.snapshot(emptyScan(incomplete: true, entries: [DiskEntry(path: "/示例项目/待汇总", isDirectory: true, bytes: 0)]), "扫描中", true))
        precondition(model.isWaitingForResults, "zero-byte partial map must show progress")
        model.receive(.snapshot(emptyScan(incomplete: true, entries: entries), "扫描中", true))
        precondition(!model.isWaitingForResults, "positive partial results remain browsable")
        model.receive(.snapshot(emptyScan(incomplete: false), "已完成", false))
        precondition(!model.isWaitingForResults, "completed zero-byte map can show empty state")
        model.receive(.querying(true))
        precondition(!model.isWaitingForResults, "refreshing a complete zero-byte map must retain its empty state")
        model.receive(.querying(false))
        var openingUpdates: [IndexUpdate] = []
        let opening = IndexCoordinator(databaseURL: fixture.appendingPathComponent("opening-state/index.sqlite")) { openingUpdates.append($0) }
        opening.open(fixture, buildIfMissing: false)
        let openingDeadline = Date().addingTimeInterval(5)
        while !openingUpdates.contains(where: { if case .idle = $0 { return true }; return false }) && Date() < openingDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(openingUpdates.contains { if case .idle = $0 { return true }; return false }, "opening completes without scanning")
        guard case .activity = openingUpdates.first else { preconditionFailure("opening publishes loading before any cache query result") }
        print("PASS: new directory loading, partial/paused empty results, zero-byte map and completed empty state")
        try verifyPausedNavigation()
        try verifyRefreshPresentation(model)
        if ProcessInfo.processInfo.environment["DISKLENS_CAPTURE_ANIMATION"] == "1" {
            try verifyRenderedActivityAnimation()
        }

        if ProcessInfo.processInfo.environment["DISKLENS_CAPTURE_UI"] == "1" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DISKLENS_CAPTURE_DIR"] ?? ".build/previews")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for (name, mode, size, appearance) in [
                ("main", ResultsView.treemap, CGSize(width: 1080, height: 740), NSAppearance.Name.aqua),
                ("compact", .directory, CGSize(width: 860, height: 610), .aqua),
                ("dark", .treemap, CGSize(width: 1080, height: 740), .darkAqua)
            ] {
                // Keep prior smoke-test events and capacity reads out of the demo state.
                let previewModel = AppModel(defaults: defaults, databaseURL: fixture.appendingPathComponent("preview.sqlite"), startServices: false)
                previewModel.viewMode = mode
                let deadline = Date().addingTimeInterval(5)
                while previewModel.isQuerying && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                precondition(!previewModel.isQuerying && previewModel.queryError == nil)
                previewModel.result = scan
                previewModel.selection = entries[0].path
                previewModel.volume = VolumeStatus(id: "preview", total: 1_000_000_000_000, free: 360_000_000_000)
                let host = NSHostingView(rootView: ContentView(model: previewModel))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.title = "DiskLens · 磁盘透镜"
                window.contentView = host
                window.setContentSize(size)
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                precondition(previewModel.result != nil && previewModel.volume != nil && !previewModel.isQuerying && !previewModel.isUpdating,
                             "Documentation screenshots must show stable synthetic data")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
                try process.run(); process.waitUntilExit()
                precondition(process.terminationStatus == 0)
                window.orderOut(nil)
            }
            print("PASS: actual main window screenshots (standard, compact and dark), synthetic paths only")
        }
    }

    @MainActor private static func verifyRenderedActivityAnimation() throws {
        final class Activity: ObservableObject { @Published var isActive = false }
        struct Probe: View {
            @ObservedObject var activity: Activity
            var body: some View {
                IndexStatusView(title: "自动更新", detail: "动画验证", isActive: activity.isActive)
                    .padding(20).frame(width: 240, height: 60).background(Color.white)
            }
        }
        let activity = Activity()
        let host = NSHostingView(rootView: Probe(activity: activity))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let output = URL(fileURLWithPath: ".build/animation-check")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func capture(_ name: String) throws -> (Data, Data) {
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            let pixels = Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            let iconEnd = Int(38 * CGFloat(bitmap.pixelsWide) / host.bounds.width) * bitmap.bitsPerPixel / 8
            var textPixels = Data()
            for row in 0..<bitmap.pixelsHigh {
                textPixels.append(pixels[(row * bitmap.bytesPerRow + iconEnd)..<((row + 1) * bitmap.bytesPerRow)])
            }
            return (pixels, textPixels)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let initial = try capture("idle")
        activity.isActive = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        activity.isActive = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let first = try capture("finishing-1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let second = try capture("finishing-2")
        precondition(first.0 != second.0, "icon must keep moving after an 80ms update has ended")
        precondition(initial.1 == first.1 && first.1 == second.1, "text and surrounding region must remain pixel-stable")
        RunLoop.main.run(until: Date().addingTimeInterval(2.6))
        let finished = try capture("finished")
        precondition(initial.0 == finished.0, "completed turn must return to the exact idle rendering")
        print("PASS: rendered 80ms activity continues rotating; text pixels stay fixed; full turn returns exactly to idle")
    }

    private static func verifyActivityRotation() {
        func near(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.001 }
        var rotation = IndexActivityRotation()
        rotation.setActive(true, at: 100.75)
        precondition(near(rotation.angle(at: 100.75), 0), "start must not inherit the wall-clock phase")
        rotation.setActive(false, at: 100.77)
        precondition(rotation.isRunning && near(rotation.angle(at: 101.5), 90), "20ms update must keep rotating smoothly")
        rotation.finishIfNeeded(at: 103.7)
        precondition(rotation.isRunning && near(rotation.angle(at: 103.7), 354), "short update must complete its turn")
        precondition(near(rotation.angle(at: 104), 0), "a late frame must stop at the completed turn")
        rotation.finishIfNeeded(at: 104)
        precondition(!rotation.isRunning && rotation.angle(at: 104) == 0)

        rotation.setActive(true, at: 200.25)
        rotation.setActive(false, at: 200.3)
        let phase = rotation.angle(at: 201)
        rotation.setActive(true, at: 201)
        precondition(near(rotation.angle(at: 201), phase), "resuming during a final turn must not restart it")
        rotation.setActive(true, at: 201.25)
        precondition(near(rotation.angle(at: 201.25), 120), "repeated active updates preserve phase")
        rotation.setActive(false, at: 203.5)
        rotation.finishIfNeeded(at: 204)
        precondition(rotation.isRunning && near(rotation.angle(at: 204), 90), "long updates finish the current turn")
        rotation.finishIfNeeded(at: 206.25)
        precondition(!rotation.isRunning)
        rotation.setActive(true, at: 210.5)
        precondition(near(rotation.angle(at: 210.5), 0), "next independent update starts at zero")
        rotation.reset()
        precondition(!rotation.isRunning && rotation.angle(at: 211) == 0, "reduced motion or disappearance stops the schedule")
        print("PASS: rotation starts at zero, completes short bursts, preserves phase on resume and stops at full turns")
    }

    @MainActor private static func verifyRefreshPresentation(_ model: AppModel) throws {
        model.viewMode = .directory
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        var entries = (0..<200).map { DiskEntry(path: model.root.path + "/file-\($0).bin", isDirectory: false, bytes: Int64(4096 * (201 - $0))) }
        func snapshot() -> ScanResult {
            ScanResult(root: model.root, entries: entries, files: entries.count, skipped: 0, issues: [], date: Date(),
                       total: entries.reduce(0) { $0 + $1.bytes }, incomplete: false, next: nil, pageReset: false)
        }
        model.receive(.snapshot(snapshot(), "自动更新", false))
        model.receive(.querying(false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        model.volume = VolumeStatus(id: "preview", total: 1_000_000_000_000, free: 360_000_000_000)
        model.selection = entries[80].path
        let host = NSHostingView(rootView: ContentView(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 610), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = findTable(child) { return table } }
            return nil
        }
        guard let table = findTable(host), let scroll = table.enclosingScrollView else {
            throw indexError("Main window did not render the native result table")
        }
        table.scrollRowToVisible(80)
        let origin = scroll.contentView.bounds.origin
        let frame = table.convert(table.visibleRect, to: host)
        func nativeButtons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(nativeButtons)
        }
        let buttons = nativeButtons(host)
        let statusTitle = model.indexStatusSummary
        precondition(statusTitle == "自动更新", "complete cached result has a stable status title")
        precondition(buttons.count >= 3, "window exposes native action buttons")
        let buttonFrames = buttons.map { $0.convert($0.bounds, to: host) }
        func checkButtons() {
            let current = nativeButtons(host)
            precondition(current.map(ObjectIdentifier.init) == buttons.map(ObjectIdentifier.init),
                         "background updates must not replace or remove action buttons")
            for (button, original) in zip(current, buttonFrames) {
                let currentFrame = button.convert(button.bounds, to: host)
                precondition(abs(currentFrame.minX - original.minX) < 1 && abs(currentFrame.minY - original.minY) < 1
                             && abs(currentFrame.width - original.width) < 1 && abs(currentFrame.height - original.height) < 1,
                             "background updates must preserve action button positions and sizes")
            }
        }
        for _ in 0..<3 {
            model.receive(.activity("正在更新变化…"))
            model.receive(.phase("枚举与写入 · 已检查 9 项"))
            model.receive(.progress(9))
            model.receive(.querying(true))
            precondition(model.indexStatusSummary == statusTitle, "scan phases and progress must not replace status text")
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            checkButtons()
            precondition(findTable(host) === table && table.isEnabled && model.canUseSelection,
                         "background refresh must retain the enabled native table")
            let loadingFrame = table.convert(table.visibleRect, to: host)
            precondition(abs(loadingFrame.minY - frame.minY) < 1 && abs(loadingFrame.height - frame.height) < 1,
                         "active update indicators must not shift the table")
            entries[0].bytes += 4096
            model.receive(.snapshot(snapshot(), "自动更新", false))
            model.receive(.querying(false))
            precondition(model.indexStatusSummary == statusTitle, "completion must retain the same status text")
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            checkButtons()
            precondition(findTable(host) === table && model.selection == entries[80].path,
                         "incremental results must preserve table identity and selection")
            precondition(abs(scroll.contentView.bounds.origin.y - origin.y) < 1,
                         "same-page refresh must preserve scroll offset")
            let updatedFrame = table.convert(table.visibleRect, to: host)
            precondition(abs(updatedFrame.minY - frame.minY) < 1 && abs(updatedFrame.height - frame.height) < 1,
                         "progress indicators must not move or resize the table")
        }
        model.receive(.failure("测试：索引读取失败"))
        precondition(model.indexStatusSummary == "索引更新失败", "stable status must not conceal indexing failures")
        model.receive(.snapshot(snapshot(), "测试：索引读取失败", false))
        precondition(model.indexFailure != nil, "cached snapshots must not erase an indexing failure")
        model.receive(.activity("重试更新"))
        precondition(model.indexFailure == nil && model.indexStatusSummary == statusTitle)
        model.receive(.idle("自动更新"))
        model.message = nil
        print("PASS: three native refreshes retain table/buttons, action geometry, enabled browsing, selection, scroll and layout")
        print("PASS: status title stays fixed through phases/progress/completion and still exposes failures")
    }

    @MainActor private static func verifyPausedNavigation() throws {
        let fm = FileManager.default
        let suite = "DiskLens.pause-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: fixture) }
        let cached = fixture.appendingPathComponent("cached")
        let unfinished = fixture.appendingPathComponent("unfinished")
        let fresh = fixture.appendingPathComponent("fresh")
        for folder in [cached, unfinished, fresh] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("file.bin"))
        }
        try Data([1]).write(to: cached.appendingPathComponent("ignore.txt"))
        let databaseURL = fixture.appendingPathComponent("state/index.sqlite")
        do {
            let seed = try DiskIndex(url: databaseURL)
            let identity = try IndexIdentity.read(cached)
            try seed.rebuild(identity, cursor: identity.startingCursor, cancellation: ScanCancellation())
            let partial = try IndexIdentity.read(unfinished)
            let cancellation = ScanCancellation()
            do {
                try seed.rebuild(partial, cursor: partial.startingCursor, cancellation: cancellation) { _ in cancellation.cancel() }
            } catch is CancellationError { }
        }
        defaults.set(cached.path, forKey: "root")
        let model = AppModel(defaults: defaults, databaseURL: databaseURL, startServices: false)
        func wait(_ label: String, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() {
                if let error = model.message ?? model.queryError { throw indexError(error) }
                guard Date() < deadline else {
                    throw indexError("Timed out: \(label); root=\(model.root.path), result=\(model.result?.root.path ?? "nil"), querying=\(model.isQuerying), updating=\(model.isUpdating), status=\(model.indexStatus)")
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        model.navigate(to: cached)
        precondition(model.isQuerying, "initial current directory still loads when no state exists")
        try wait("initial cached scope") { model.result != nil && !model.isUpdating && !model.isQuerying }
        model.search = "file.bin"
        try wait("initial filtered query") { !model.isQuerying }
        model.selection = model.entries.first?.id
        let selected = model.selection
        let equivalent = URL(fileURLWithPath: cached.path + "/", isDirectory: true)
        precondition(model.isCurrentDirectory(equivalent), "sidebar selection ignores URL trailing slash")
        model.navigate(to: equivalent)
        precondition(model.result != nil && !model.isQuerying && model.selection == selected && model.search == "file.bin",
                     "repeated directory click retains results, selection and search")
        precondition(!model.navigation.canGoBack && !model.navigation.canGoForward,
                     "repeated click must not add history")
        var unfilteredSnapshot = false
        let observation = model.$result.sink { result in
            if let result, result.entries.contains(where: { $0.name == "ignore.txt" }) { unfilteredSnapshot = true }
        }
        model.refreshIndex()
        try wait("refresh retains search") { !model.isQuerying && !model.isUpdating }
        observation.cancel()
        precondition(!unfilteredSnapshot && model.entries.count == 1 && model.entries.first?.name == "file.bin",
                     "refresh must use current query options for every snapshot")
        model.pauseIndexing()
        model.navigate(to: fresh)
        precondition(model.isIndexingPaused, "navigation preserves pause immediately")
        try wait("paused uncached navigation") { !model.isUpdating && !model.isQuerying }
        precondition(model.result == nil && model.isIndexingPaused, "uncached directory must not scan")
        model.goBack()
        try wait("paused back navigation") { model.result?.root.path == cached.path && !model.isQuerying }
        precondition(model.isIndexingPaused && !model.isUpdating, "cached history remains browseable while paused")
        model.search = "file.bin"
        try wait("paused search") { !model.isQuerying }
        precondition(model.entries.count == 1 && model.isIndexingPaused && !model.isUpdating)
        model.goForward()
        try wait("paused forward navigation") { !model.isQuerying }
        precondition(model.root.path == fresh.path && model.result == nil && model.isIndexingPaused)
        model.navigate(to: unfinished)
        try wait("paused incomplete navigation") { !model.isQuerying }
        let inspect = try DiskIndex(url: databaseURL, readOnly: true)
        let pendingRoot = try inspect.coveringRoot(unfinished.path)
        let missingRoot = try inspect.coveringRoot(fresh.path)
        precondition(pendingRoot?.incomplete == true && missingRoot == nil, "paused browsing must neither resume nor create an index")
        model.refreshIndex()
        precondition(!model.isIndexingPaused, "explicit resume clears pause")
        try wait("explicit resume") { model.result?.incomplete == false && !model.isUpdating && !model.isQuerying }
        precondition(model.result?.files == 1, "resume finishes previously incomplete scope")
        model.pauseIndexing()
        var staleSnapshot = false
        let navigationObservation = model.$result.sink { result in
            if let result, result.root.path != model.root.path { staleSnapshot = true }
        }
        for destination in [cached, unfinished, cached, unfinished, cached] { model.navigate(to: destination) }
        try wait("rapid cached navigation") { model.result?.root.path == cached.path && !model.isQuerying }
        navigationObservation.cancel()
        precondition(!staleSnapshot && model.isIndexingPaused, "rapid switching delivers only the current directory and keeps pause")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        print("PASS: pause survives uncached/cached/incomplete navigation, history and search; explicit resume finishes indexing")
        print("PASS: repeated directory clicks retain state, refresh preserves filters, rapid switching rejects stale snapshots")
    }
}
