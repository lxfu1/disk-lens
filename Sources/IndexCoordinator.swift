import Foundation

enum IndexUpdate {
    case activity(String)
    case progress(Int)
    case phase(String)
    case cache(CacheStorage, String?)
    case cacheFailure(String)
    case cacheFinished
    case snapshot(ScanResult, String, Bool)
    case idle(String)
    case failure(String)
    case querying(Bool)
    case queryFailure(String)
    case missing(String)
    case statistics(String, IndexWork)
}

private final class CancellationSlot {
    private let lock = NSLock()
    private var token = ScanCancellation()
    func replace() -> ScanCancellation {
        lock.lock(); defer { lock.unlock() }
        token.cancel()
        token = ScanCancellation()
        return token
    }
    var current: ScanCancellation { lock.lock(); defer { lock.unlock() }; return token }
}

// Incremental deduplication; sorting is deferred until consumption. Both the callback
// inbox and the writer's pending window use the same bounded representation.
struct EventChanges {
    static let pathLimit = 8192
    static let byteLimit = 4 * 1024 * 1024
    let root: String
    private var paths: [String: Bool] = [:]
    private var bytes = 0
    private var compactAt = 4096
    init(root: String) { self.root = root }
    var count: Int { paths.count }
    var isEmpty: Bool { paths.isEmpty }
    var sorted: [FileChange] { paths.keys.sorted().map { FileChange(path: $0, recursive: paths[$0]!) } }

    mutating func append(_ change: FileChange) {
        guard isWithin(change.path, root) else { return }
        var parent = change.path
        while true {
            if paths[parent] == true { return }
            if parent == root || parent == "/" { break }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        if change.recursive {
            for key in Array(paths.keys) where key != change.path && isWithin(key, change.path) {
                bytes -= key.utf8.count; paths.removeValue(forKey: key)
            }
        }
        if paths[change.path] == nil { bytes += change.path.utf8.count }
        paths[change.path] = (paths[change.path] ?? false) || change.recursive
        if paths.count > compactAt {
            var siblings: [String: [String]] = [:]
            for key in paths.keys {
                siblings[URL(fileURLWithPath: key).deletingLastPathComponent().path, default: []].append(key)
            }
            for (parent, children) in siblings where children.count > 64 && parent != root {
                for child in children { paths.removeValue(forKey: child) }
                paths[parent] = true
            }
            bytes = paths.keys.reduce(0) { $0 + $1.utf8.count }
            compactAt = min(Self.pathLimit, paths.count + 4096)
        }
        if paths.count > Self.pathLimit || bytes > Self.byteLimit {
            // Widen only to affected top-level subtrees first. If even that exceeds
            // the budget, one root repair is the bounded, lossless fallback.
            if paths[root] != nil { paths = [root: true]; bytes = root.utf8.count; return }
            var branches: [String: Bool] = [:]
            for key in paths.keys {
                let suffix = key.dropFirst(root == "/" ? 1 : root.count + 1)
                guard let first = suffix.split(separator: "/").first else { continue }
                branches[(root == "/" ? "/" : root + "/") + first] = true
            }
            paths = branches
            bytes = paths.keys.reduce(0) { $0 + $1.utf8.count }
            if paths.count > Self.pathLimit || bytes > Self.byteLimit { paths = [root: true]; bytes = root.utf8.count }
            compactAt = min(Self.pathLimit, paths.count + 4096)
        }
    }
    mutating func append(contentsOf changes: [FileChange]) { for change in changes { append(change) } }
    mutating func removeAll() { paths.removeAll(); bytes = 0; compactAt = 4096 }
}

private final class EventInbox {
    private let lock = NSLock()
    private var batch = EventBatch()
    private var changes: EventChanges
    private var scheduled = false
    init(root: String) { changes = EventChanges(root: root) }
    func append(_ next: EventBatch) -> Bool {
        lock.lock(); defer { lock.unlock() }
        changes.append(contentsOf: next.changes)
        batch.cursor = max(batch.cursor, next.cursor)
        batch.historyDone = batch.historyDone || next.historyDone
        batch.invalidateRoot = batch.invalidateRoot || next.invalidateRoot
        if scheduled { return false }
        scheduled = true
        return true
    }
    func take() -> EventBatch {
        lock.lock(); defer { lock.unlock() }
        var result = batch
        result.changes = changes.sorted
        changes.removeAll()
        batch = EventBatch()
        scheduled = false
        return result
    }
}

final class IndexCoordinator {
    private let queue = DispatchQueue(label: "DiskLens.index", qos: .utility)
    private let cancellations = CancellationSlot()
    private let queryCancellations = CancellationSlot()
    private let queryQueue = DispatchQueue(label: "DiskLens.queries", qos: .userInitiated)
    private var reader: DiskIndex?
    private let viewLock = NSLock()
    private var requestedPath = ""
    private var requestedQuery = IndexQuery()
    private var activeScope: String?
    private var scopeReady = false
    private var status = "选择目录后建立索引。"
    private var busy = false
    private var queryInFlight = false
    private var lastPartialRead = Date.distantPast
    private let databaseURL: URL
    private let delivery: (IndexUpdate) -> Void
    private var database: DiskIndex?
    private var monitor: FileEventMonitor?
    private var identity: IndexIdentity?
    private var viewPath = ""
    private var generation = UUID()
    private var pending = EventChanges(root: "/")
    private var pendingCursor: UInt64 = 0
    private var historyDone = false
    private var caughtUp = false
    private var invalidated = false
    private var scheduled: DispatchWorkItem?

    init(databaseURL: URL, delivery: @escaping (IndexUpdate) -> Void) {
        self.databaseURL = databaseURL
        self.delivery = delivery
    }

    private func publish(_ update: IndexUpdate) {
        viewLock.lock()
        switch update {
        case .activity(let value), .phase(let value): status = value; busy = true
        case .idle(let value), .failure(let value): status = value; busy = false
        default: break
        }
        viewLock.unlock()
        DispatchQueue.main.async { [delivery] in delivery(update) }
        if case .progress = update, Date().timeIntervalSince(lastPartialRead) > 1 {
            lastPartialRead = Date()
            readView(background: true)
        }
    }

    func cancelQueries() { queryCancellations.current.cancel() }

    func prepareQuery(_ url: URL, options: IndexQuery) {
        queryCancellations.current.cancel()
        viewLock.lock()
        requestedPath = url.path
        requestedQuery = options
        queryInFlight = true
        viewLock.unlock()
    }

    func query(_ url: URL, options: IndexQuery) {
        prepareQuery(url, options: options)
        readView()
    }

    private func readView(background: Bool = false) {
        viewLock.lock()
        if background && queryInFlight { viewLock.unlock(); return }
        queryInFlight = true
        let token = queryCancellations.replace()
        let path = requestedPath
        let options = requestedQuery
        viewLock.unlock()
        publish(.querying(true))
        queryQueue.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            var response: IndexUpdate?
            do {
                if self.reader == nil, FileManager.default.fileExists(atPath: self.databaseURL.path) {
                    self.reader = try DiskIndex(url: self.databaseURL, readOnly: true)
                }
                if let db = self.reader, let cached = try db.coveringRoot(path),
                   let result = try db.result(for: path, scope: cached.path, query: options, cancellation: token) {
                    self.viewLock.lock()
                    let status = self.status
                    let busy = self.busy
                    self.viewLock.unlock()
                    response = .snapshot(result, status, busy)
                } else { response = .missing(path) }
            } catch is CancellationError { return }
            catch is IndexSchemaPending { self.reader = nil }
            catch {
                if error.localizedDescription.contains("no such table") { self.reader = nil }
                else { response = .queryFailure(error.localizedDescription) }
            }
            let update = response
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { return }
                if case .snapshot(let result, _, _) = update {
                    self.viewLock.lock()
                    if result.pageReset { self.requestedQuery.after = nil }
                    let status = self.status
                    let busy = self.busy
                    self.viewLock.unlock()
                    self.delivery(.snapshot(result, status, busy))
                } else if let update { self.delivery(update) }
                self.viewLock.lock(); self.queryInFlight = false; self.viewLock.unlock()
                self.delivery(.querying(false))
            }
        }
    }

    private func store() throws -> DiskIndex {
        if let database { return database }
        let created = try DiskIndex(url: databaseURL)
        created.phaseChanged = { [weak self] status in self?.publish(.phase(status)) }
        let defaults = UserDefaults.standard
        let gib = defaults.object(forKey: "cacheBudgetGiB") == nil ? 2 : defaults.integer(forKey: "cacheBudgetGiB")
        created.cacheBudgetBytes = Int64(gib) * 1024 * 1024 * 1024
        database = created
        return created
    }

    func open(_ url: URL, force: Bool = false, buildIfMissing: Bool = true, options: IndexQuery = IndexQuery()) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        viewLock.lock()
        requestedPath = path
        requestedQuery = options
        let canBrowse = !force && activeScope.map { path == $0 || (scopeReady && isWithin(path, $0)) } == true
        viewLock.unlock()
        if !canBrowse { publish(.activity("正在读取目录索引…")) }
        readView()
        if canBrowse {
            queue.async { [weak self] in self?.monitor?.flush() }
            return
        }
        let token = cancellations.replace()
        queue.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            do { try self.openOnQueue(url, force: force, buildIfMissing: buildIfMissing, token: token) }
            catch {
                self.stopMonitoring()
                guard self.cancellations.current === token else { return }
                if error is CancellationError { self.publish(.idle("已暂停；已提交的进度保留，点击刷新继续。")) }
                else { self.publish(.failure(error.localizedDescription)) }
                self.readView()
            }
        }
    }

    private func openOnQueue(_ url: URL, force: Bool, buildIfMissing: Bool, token: ScanCancellation) throws {
        let db = try store()
        viewPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !isWithin(viewPath, db.excludedPath) else { throw indexError("应用自身的索引目录已排除，不参与分析。") }
        let covering = try db.coveringRoot(viewPath)
        // A partially built ancestor cannot serve this subtree yet. Build the requested
        // directory independently rather than resuming an unrelated whole-home scan.
        let cached = covering.flatMap { $0.incomplete && $0.path != viewPath ? nil : $0 }
        if cached == nil && !buildIfMissing { publish(.idle("选择目录后建立索引，后续自动更新。")); return }
        let scope = cached?.path ?? viewPath
        if cached != nil { try db.touch(scope) }
        let freshIdentity = try IndexIdentity.read(URL(fileURLWithPath: scope))
        let valid = cached != nil && cached!.fileID == freshIdentity.fileID &&
            cached!.eventUUID == freshIdentity.eventUUID && !freshIdentity.eventUUID.isEmpty && cached!.cursor > 0
        stopMonitoring()
        identity = freshIdentity
        pending = EventChanges(root: scope)
        viewLock.lock(); activeScope = scope; scopeReady = valid && !force && !cached!.incomplete; viewLock.unlock()
        caughtUp = freshIdentity.eventUUID.isEmpty
        let cursor = valid && !force ? cached!.cursor : freshIdentity.startingCursor
        pendingCursor = cursor
        let currentGeneration = generation
        let inbox = EventInbox(root: scope)
        let excludedPath = db.excludedPath
        monitor = try FileEventMonitor(identity: freshIdentity, since: cursor) { [weak self] batch in
            var filtered = batch
            filtered.changes.removeAll { isWithin($0.path, excludedPath) }
            guard !filtered.changes.isEmpty || filtered.historyDone || filtered.invalidateRoot else { return }
            guard inbox.append(filtered) else { return }
            self?.queue.async { [weak self] in
                let merged = inbox.take()
                guard let self, self.generation == currentGeneration else { return }
                self.receive(merged)
            }
        }
        if valid && !force {
            if !cached!.incomplete, try !db.hasDirectory(viewPath, scope: scope) { pending.append(FileChange(path: viewPath, recursive: true)) }
            publishSnapshot(busy: true, status: "已载入缓存 · 正在补齐退出期间的变化")
            if cached!.incomplete {
                publish(.activity("正在继续索引：\(scope)"))
                try db.resume(freshIdentity, cancellation: token) { [weak self] count in self?.publish(.progress(count)) }
                publish(.statistics(scope, db.lastWork))
                publishSnapshot(busy: true, status: "索引进度已恢复 · 正在补齐变化")
            }
        } else {
            publish(.activity((force || cached != nil ? "正在重建索引：" : "首次建立索引：") + scope))
            try db.rebuild(freshIdentity, cursor: cursor, cancellation: token) { [weak self] count in self?.publish(.progress(count)) }
            publish(.statistics(scope, db.lastWork))
            publishSnapshot(busy: !caughtUp, status: caughtUp ? "索引已建立 · 正在监听变化" : "索引已建立 · 正在校准扫描期间的变化")

        }
        viewLock.lock(); scopeReady = true; viewLock.unlock()
        monitor?.flush()
        schedulePending()
    }

    private func publishSnapshot(busy: Bool, status: String) {
        viewLock.lock()
        self.busy = busy
        self.status = status
        viewLock.unlock()
        readView()
    }

    static func coalesce(_ changes: [FileChange], root: String = "/") -> [FileChange] {
        var accumulator = EventChanges(root: root)
        accumulator.append(contentsOf: changes)
        return accumulator.sorted
    }

    private func receive(_ batch: EventBatch) {
        guard let db = database else { return }
        let changes = batch.changes.filter { !isWithin($0.path, db.excludedPath) }
        // Never write the cursor for index-only events: writing it would generate another event forever.
        guard !changes.isEmpty || batch.historyDone || batch.invalidateRoot else { return }
        pending.append(contentsOf: changes)
        pendingCursor = max(pendingCursor, batch.cursor)
        historyDone = historyDone || batch.historyDone
        invalidated = invalidated || batch.invalidateRoot
        schedulePending()
    }

    private func schedulePending() {
        guard !pending.isEmpty || historyDone || invalidated else { return }
        // A fixed batch window avoids starvation when files change continuously.
        guard scheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduled = nil
            self.processPending()
        }
        scheduled = work
        queue.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func processPending() {
        guard let identity, let db = database else { return }
        let token = cancellations.current
        guard !token.isCancelled else { return }
        do {
            let currentIdentity = try IndexIdentity.read(URL(fileURLWithPath: identity.root))
            if invalidated || currentIdentity.fileID != identity.fileID || currentIdentity.eventUUID != identity.eventUUID {
                viewLock.lock()
                let requested = URL(fileURLWithPath: requestedPath)
                let options = requestedQuery
                viewLock.unlock()
                stopMonitoring()
                publish(.activity("文件事件记录已失效，正在校准索引…"))
                open(requested, force: true, options: options)
                return
            }
            let changes = pending.sorted
            publish(.activity(changes.contains(where: { $0.recursive && $0.path == identity.root }) ? "事件要求校准索引…" : "正在更新变化…"))
            try db.update(changes, identity: identity, cursor: pendingCursor, cancellation: token) { [weak self] count in self?.publish(.progress(count)) }
            pending.removeAll()
            caughtUp = caughtUp || historyDone
            historyDone = false
            let work = db.lastWork
            publish(.statistics(identity.root, work))
            publishSnapshot(busy: !caughtUp,
                status: caughtUp ? "自动更新 · 本次检查 \(work.metadataReads) 个位置" : "正在补齐历史变化…")
        } catch is CancellationError {
            stopMonitoring()
            publish(.idle("更新已暂停；已提交的进度保留，点击刷新继续。"))
            readView()
        } catch {
            stopMonitoring()
            publish(.failure("增量更新暂停：\(error.localizedDescription) 点击刷新可重试。"))
            readView()
        }
    }

    enum CacheAction { case budget(Int64), remove(String), reclaim, removeBackup }

    func loadCacheStorage() {
        viewLock.lock()
        let requested = requestedPath
        let active = activeScope
        viewLock.unlock()
        queryQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.reader == nil { self.reader = try DiskIndex(url: self.databaseURL, readOnly: true) }
                guard let reader = self.reader else { return }
                let protected = try active ?? reader.coveringRoot(requested)?.path
                self.publish(.cache(try reader.cacheStorage(), protected))
            } catch { self.publish(.cacheFailure(error.localizedDescription)) }
        }
    }

    func maintainCache(_ action: CacheAction) {
        queue.async { [weak self] in
            guard let self else { return }
            let token = self.cancellations.current.isCancelled ? self.cancellations.replace() : self.cancellations.current
            do {
                let db = try self.store()
                let scope = try self.identity?.root ?? db.coveringRoot(self.viewPath)?.path ?? ""
                self.publish(.activity("正在整理索引缓存…"))
                switch action {
                case .budget(let bytes):
                    db.cacheBudgetBytes = bytes
                    try db.maintainCache(keeping: scope, cancellation: token)
                case .remove(let path): try db.maintainCache(keeping: scope, removing: path, cancellation: token)
                case .reclaim: try db.reclaimFreePages(cancellation: token)
                case .removeBackup: try db.removeMigrationBackup()
                }
                self.publish(.idle("缓存已更新 · 用户文件保持不变"))
                self.readView()
            } catch is CancellationError { self.publish(.idle("缓存整理已暂停；已完成的清理保留。")) }
            catch { self.publish(.failure(error.localizedDescription)) }
            self.loadCacheStorage()
            self.publish(.cacheFinished)
        }
    }

    func changed(_ path: String) {
        queue.async { [weak self] in
            guard let self, self.identity != nil else { return }
            self.pending.append(FileChange(path: path, recursive: true))
            self.schedulePending()
        }
    }

    func cancel() {
        cancellations.current.cancel()
        queue.async { [weak self] in
            self?.stopMonitoring()
            self?.publish(.idle("更新已暂停；点击刷新可继续监听。"))
            self?.readView()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queryCancellations.current.cancel()
        cancellations.current.cancel()
        queue.async { [weak self] in
            self?.stopMonitoring()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private func stopMonitoring() {
        generation = UUID()
        scheduled?.cancel()
        scheduled = nil
        monitor?.stop()
        monitor = nil
        identity = nil
        viewLock.lock(); activeScope = nil; scopeReady = false; viewLock.unlock()
        pending.removeAll()
        pendingCursor = 0
        historyDone = false
        caughtUp = false
        invalidated = false
    }
}
