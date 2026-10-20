import Foundation
import SQLite3
import Darwin

struct CachedScope: Identifiable {
    let id: String
    let path: String
    let incomplete: Bool
    let estimatedBytes: Int64
    let lastUsed: Date
}

struct CacheStorage {
    let scopes: [CachedScope]
    let databaseBytes: Int64
    let walBytes: Int64
    let freeBytes: Int64
    let backupBytes: Int64
}

struct IndexedRoot {
    let path: String
    let fileID: String
    let eventUUID: String
    let cursor: UInt64
    let date: Date
    let incomplete: Bool
}

struct IndexWork {
    var metadataReads = 0
    var statCalls = 0
    var bulkCalls = 0
    var bulkItems = 0
    var initialInserts = 0
    var streamedFiles = 0
    var enumeratedDirectories = 0
    var commits = 0
    var manualCheckpoints = 0
    var sqlSteps = 0
    var sqlSeconds = 0.0
    var metadataSeconds = 0.0
    var linkSeconds = 0.0
    var aggregateSeconds = 0.0
    var fullAggregations = 0
    var deltaAncestors = 0
    var peakDeletionPage = 0
    var partialAggregations = 0
    var resolvedLinks = 0

    var summary: String {
        String(format: "元数据 %.1f ms · lstat %lld 次 / 批量 %lld 次\nSQL %.1f ms（%lld 步）· 提交 %lld 次\n硬链接 %.1f ms · 汇总 %.1f ms（含各阶段 SQL）\n逐目录汇总 %lld · 最终校准 %lld · 文件差量祖先 %lld",
            metadataSeconds * 1000, Int64(statCalls), Int64(bulkCalls),
            sqlSeconds * 1000, Int64(sqlSteps), Int64(commits),
            linkSeconds * 1000, aggregateSeconds * 1000, Int64(partialAggregations), Int64(fullAggregations), Int64(deltaAncestors))
    }
}

private struct NodeRecord {
    let kind: String
    let device: String
    let inode: String
    let links: Int
    let bytes: Int64
    let files: Int
    let skipped: Int

    init(_ row: [String]) {
        kind = row[0]; device = row[1]; inode = row[2]
        links = Int(row[3]) ?? 0; bytes = Int64(row[5]) ?? 0
        files = Int(row[6]) ?? 0; skipped = Int(row[7]) ?? 0
    }
}

private enum SQLValue {
    case text(String)
    case integer(Int64)
}

private struct EnumerationContext {
    let scope: Int64
    let parent: Int64
    let parentPath: String
    let folder: Int64
    let generation: Int64
    let isEmpty: Bool
    let publishInserted: Bool
}

private enum JobMode: Int { case recursive = 0, enumerate = 1, reconcile = 2 }
enum IndexSchemaPending: Error { case upgrade }

struct PageCursor: Equatable {
    let bytes: Int64
    let nodeID: Int64
    let revision: String
}

struct IndexQuery: Equatable {
    var largest = false
    var search = ""
    var recursive = false
    var after: PageCursor?
    var limit = 200
}

private final class QueryBudget {
    let cancellation: ScanCancellation
    let deadline = Date().addingTimeInterval(3)
    init(_ cancellation: ScanCancellation) { self.cancellation = cancellation }
    var stopped: Bool { cancellation.isCancelled || Date() > deadline }
}

// Each connection belongs to exactly one queue. Readers never use the writer connection.
final class DiskIndex {
    // The range for / includes / itself; preserve the job that will re-enumerate it.
    static let descendantJobsDeletion = "DELETE FROM jobs WHERE scope=? AND path!=? AND path>=? AND path<?"
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    let excludedPath: String
    private let url: URL
    private let readOnly: Bool
    private let useBulkMetadata: Bool
    private(set) var lastWork = IndexWork()
    private var rootIDs: [String: String] = [:]
    private var folderIDs: [String: String] = [:]
    private var mutations = 0
    private var batchBytes = 0
    private var markedDirectories = Set<String>()
    private var pendingSummaries: [Int64: (bytes: Int64, files: Int64)] = [:]
    private var lastCommit = Date()
    private var lastProgress = Date.distantPast
    private var token = ScanCancellation()
    private var progress: (Int) -> Void = { _ in }
    private var workScope = ""
    var cacheBudgetBytes: Int64 = 0
    var phaseChanged: (String) -> Void = { _ in }
    private var phase = "枚举与写入"

    private func reportProgress() {
        phaseChanged("\(phase) · 已检查 \(lastWork.metadataReads) 项 · 已汇总 \(lastWork.partialAggregations + lastWork.fullAggregations) 个目录 · 已校准 \(lastWork.resolvedLinks) 组硬链接")
        progress(lastWork.metadataReads)
        lastProgress = Date()
    }

    private func setPhase(_ value: String) {
        phase = value
        reportProgress()
    }

    init(url: URL, readOnly: Bool = false, useBulkMetadata: Bool = true) throws {
        self.url = url
        self.readOnly = readOnly
        self.useBulkMetadata = useBulkMetadata
        excludedPath = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        if !readOnly { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let error = indexError("无法打开本地索引。")
            sqlite3_close(db); db = nil
            throw error
        }
        sqlite3_busy_timeout(db, 1000)
        sqlite3_create_function_v2(db, "path_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, values in
            guard let values, let a = sqlite3_value_text(values[0]), let b = sqlite3_value_text(values[1]) else {
                sqlite3_result_int(context, 0); return
            }
            sqlite3_result_int(context, String(cString: a).localizedCaseInsensitiveContains(String(cString: b)) ? 1 : 0)
        }, nil, nil, nil)
        if readOnly {
            let version = try rows("PRAGMA user_version").first?.first ?? "0"
            if version == "0" { throw IndexSchemaPending.upgrade }
            guard version == "5" else { throw Self.schemaError(version) }
            try run("PRAGMA query_only=ON")
            return
        }
        let version = try rows("PRAGMA user_version").first?.first ?? "0"
        guard ["0", "5"].contains(version) else { throw Self.schemaError(version) }
        // Set pointer-map mode before WAL creates the first database page.
        if version == "0" { try run("PRAGMA auto_vacuum=INCREMENTAL") }
        try run("PRAGMA journal_mode=WAL")
        try run("PRAGMA synchronous=NORMAL")
        try run("PRAGMA cache_size=-16384")
        try run("PRAGMA wal_autocheckpoint=1000")
        try run("PRAGMA journal_size_limit=8388608")
        if version == "0" {
            try run("BEGIN IMMEDIATE")
            do {
                guard sqlite3_exec(db, IndexSchema.sql, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
                try run("COMMIT")
            } catch { try? run("ROLLBACK"); throw error }
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    private static func schemaError(_ version: String) -> Error {
        indexError(["2", "3", "4"].contains(version)
            ? "缓存需要压缩迁移（保留进度）。请退出应用，在项目目录运行 python3 scripts/migrate-index.py，再重新打开应用。"
            : "不支持的索引版本（\(version)）；请保留缓存并使用兼容版本的应用。")
    }
    private func statement(_ sql: String, _ arguments: [SQLValue]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let cached = statements[sql] { stmt = cached; sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        else {
            var created: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &created, nil) == SQLITE_OK, let created else { throw databaseError() }
            statements[sql] = created
            stmt = created
        }
        for (offset, value) in arguments.enumerated() {
            let code: Int32
            switch value {
            case .text(let text):
                code = sqlite3_bind_text(stmt, Int32(offset + 1), text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .integer(let integer): code = sqlite3_bind_int64(stmt, Int32(offset + 1), integer)
            }
            guard code == SQLITE_OK else { throw databaseError() }
        }
        return stmt
    }

    private func databaseError() -> Error {
        indexError("索引读写失败：\(String(cString: sqlite3_errmsg(db)))")
    }

    private func run(_ sql: String, _ arguments: [String] = []) throws {
        try runBound(sql, arguments.map(SQLValue.text))
    }

    private func runBound(_ sql: String, _ arguments: [SQLValue]) throws {
        let stmt = try statement(sql, arguments)
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordSQL(stmt, since: start); sqlite3_reset(stmt) }
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW { code = sqlite3_step(stmt) }
        guard code == SQLITE_DONE else { throw databaseError() }
    }

    private func rows(_ sql: String, _ arguments: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, arguments.map(SQLValue.text))
        let start = ProcessInfo.processInfo.systemUptime
        defer { recordSQL(stmt, since: start); sqlite3_reset(stmt) }
        var values: [[String]] = []
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            values.append((0..<sqlite3_column_count(stmt)).map { column in
                sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
            })
            code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else { throw databaseError() }
        return values
    }

    private func recordSQL(_ stmt: OpaquePointer, since start: TimeInterval) {
        lastWork.sqlSeconds += ProcessInfo.processInfo.systemUptime - start
        lastWork.sqlSteps += Int(sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_VM_STEP, 1))
    }

    func coveringRoot(_ path: String) throws -> IndexedRoot? {
        for row in try rows("SELECT path,file_id,event_uuid,cursor,updated,incomplete FROM roots ORDER BY length(path) DESC") where isWithin(path, row[0]) {
            return IndexedRoot(path: row[0], fileID: row[1], eventUUID: row[2], cursor: UInt64(row[3]) ?? 0,
                date: Date(timeIntervalSince1970: Double(row[4]) ?? 0), incomplete: row[5] == "1")
        }
        return nil
    }

    private func scopeID(_ scope: String) throws -> String {
        if !readOnly, let id = rootIDs[scope] { return id }
        guard let id = try rows("SELECT id FROM roots WHERE path=?", [scope]).first?.first else {
            throw indexError("索引范围已失效，请刷新。")
        }
        if !readOnly { rootIDs[scope] = id }
        return id
    }

    private func components(_ path: String) -> (String, String) {
        guard let slash = path.lastIndex(of: "/") else { return ("/", path) }
        return (slash == path.startIndex ? "/" : String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    private func folderID(_ path: String, scope: String) throws -> String {
        if let cached = folderIDs[path] { return cached }
        let id = try scopeID(scope)
        if let found = try rows("SELECT id FROM folders WHERE scope=? AND path=?", [id, path]).first?.first {
            if folderIDs.count >= 2048 { folderIDs.removeAll(keepingCapacity: true) }
            folderIDs[path] = found
            return found
        }
        try run("INSERT INTO folders(scope,path) VALUES(?,?)", [id, path])
        let found = String(sqlite3_last_insert_rowid(db))
        if folderIDs.count >= 2048 { folderIDs.removeAll(keepingCapacity: true) }
        folderIDs[path] = found
        return found
    }

    private func nodeArguments(_ path: String, scope: String) throws -> [String] {
        let (folder, name) = components(path)
        let id = try scopeID(scope)
        return [id, id, folder, name]
    }
    private var nodePredicate: String { "scope=? AND folder=(SELECT id FROM folders WHERE scope=? AND path=?) AND name=?" }
    private func nodeID(_ path: String, scope: String) throws -> String {
        try rows("SELECT id FROM nodes WHERE " + nodePredicate, nodeArguments(path, scope: scope)).first?.first ?? "0"
    }

    private func range(_ path: String) -> (String, String) { path == "/" ? ("/", "0") : (path + "/", path + "0") }
    private func node(_ path: String, scope: String) throws -> NodeRecord? {
        try rows("SELECT kind,device,inode,nlink,raw,bytes,files,skipped FROM nodes WHERE " + nodePredicate,
            nodeArguments(path, scope: scope)).first.map(NodeRecord.init)
    }
    func hasDirectory(_ path: String, scope: String) throws -> Bool { try node(path, scope: scope)?.kind == "0" }

    func result(for path: String, scope: String, query: IndexQuery = IndexQuery(), cancellation: ScanCancellation = ScanCancellation()) throws -> ScanResult? {
        let budget = QueryBudget(cancellation)
        sqlite3_progress_handler(db, 1000, { pointer in
            Unmanaged<QueryBudget>.fromOpaque(pointer!).takeUnretainedValue().stopped ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(budget) {} }
        // Short snapshot: summaries and the page describe the same committed batch.
        try run("BEGIN")
        defer { try? run("ROLLBACK") }
        do {
            guard let summary = try node(path, scope: scope), summary.kind == "0" else { return nil }
            let root = try rows("SELECT updated,incomplete,id,revision FROM roots WHERE path=?", [scope]).first!
            let revision = root[2] + ":" + root[3]
            let pageReset = query.after.map { $0.revision != revision } ?? false
            let bounds = range(path)
            var conditions = ["scope=?"]
            var args = [try scopeID(scope)]
            if query.largest || (query.recursive && !query.search.isEmpty) {
                conditions.append("folder IN (SELECT id FROM folders WHERE scope=? AND (path=? OR (path>=? AND path<?)))")
                args += [try scopeID(scope), path, bounds.0, bounds.1]
                conditions.append("id!=?")
                args.append(try nodeID(path, scope: scope))
            } else { conditions.append("parent=?"); args.append(try nodeID(path, scope: scope)) }
            if query.largest { conditions += ["kind=1", "bytes>0"] }
            if !query.search.isEmpty { conditions.append("path_contains(path,?)"); args.append(query.search) }
            if let after = query.after, !pageReset {
                conditions.append("(bytes<? OR (bytes=? AND id>?))")
                args += [String(after.bytes), String(after.bytes), String(after.nodeID)]
            }
            let limit = min(500, max(1, query.limit))
            let data = try rows("SELECT path,kind,bytes,id,device,inode FROM node_paths WHERE \(conditions.joined(separator: " AND ")) ORDER BY bytes DESC,id LIMIT \(limit + 1)", args)
            let entries = data.prefix(limit).map { DiskEntry(path: $0[0], isDirectory: $0[1] == "0", bytes: Int64($0[2]) ?? 0,
                identity: FileIdentity(device: Int64($0[4]) ?? 0, inode: $0[5])) }
            let issues = summary.skipped == 0 ? [] : try rows("SELECT path FROM node_paths WHERE scope=? AND issue>0 AND (path=? OR (path>=? AND path<?)) LIMIT 5", [try scopeID(scope), path, bounds.0, bounds.1]).map { $0[0] }
            return ScanResult(root: URL(fileURLWithPath: path), entries: entries, files: summary.files,
                skipped: summary.skipped, issues: issues, date: Date(timeIntervalSince1970: Double(root[0]) ?? 0),
                total: summary.bytes, incomplete: root[1] == "1",
                next: data.count > limit ? PageCursor(bytes: Int64(data[limit - 1][2])!, nodeID: Int64(data[limit - 1][3])!, revision: revision) : nil,
                pageReset: pageReset, indexedScope: scope)
        } catch {
            if cancellation.isCancelled { throw CancellationError() }
            if budget.stopped { throw indexError("查询超过 3 秒，请缩小搜索目录或使用更具体的关键词。") }
            throw error
        }
    }

    private func spaceCheck() throws {
        let free = try VolumeStatus.read(at: url.deletingLastPathComponent()).free
        guard free > 512 * 1024 * 1024 else { throw indexError("剩余空间不足 512 MB，索引已暂停；释放空间后点击刷新继续。") }
        let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
        guard wal < 64 * 1024 * 1024 else { throw indexError("索引日志达到 64 MB，已暂停写入；待查询结束后点击刷新继续。") }
    }

    private func checkpoint(idle: Bool = false) {
        let walBytes = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
        guard walBytes > 0, idle || walBytes >= 32 * 1024 * 1024 else { return }
        sqlite3_busy_timeout(db, 0)
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_busy_timeout(db, 1000)
        lastWork.manualCheckpoints += 1
    }

    private func boundary(force: Bool = false) throws {
        if token.isCancelled { throw CancellationError() }
        if force || mutations >= 1024 || batchBytes >= 1024 * 1024 || Date().timeIntervalSince(lastCommit) > 0.25 {
            try commitBatch()
            lastWork.commits += 1
            checkpoint()
            try spaceCheck()
            try run("BEGIN IMMEDIATE")
            mutations = 0
            lastCommit = Date()
            if Date().timeIntervalSince(lastProgress) > 0.3 {
                reportProgress()
            }
        }
    }

    private func commitBatch() throws {
        // A fresh token covers every committed partial batch, including rebuilds and resumes.
        try flushSummaries()
        try run("UPDATE roots SET revision=? WHERE path=?", [UUID().uuidString, workScope])
        try run("COMMIT")
        markedDirectories.removeAll(keepingCapacity: true)
        batchBytes = 0
    }

    private func work(_ cancellation: ScanCancellation, scope: String, progress: @escaping (Int) -> Void, body: () throws -> Void) throws {
        precondition(!readOnly)
        rootIDs.removeAll(keepingCapacity: true)
        folderIDs.removeAll(keepingCapacity: true)
        token = cancellation
        workScope = scope
        self.progress = progress
        defer { self.progress = { _ in } }
        lastWork = IndexWork()
        pendingSummaries.removeAll(keepingCapacity: true)
        phase = "枚举与写入"
        mutations = 0
        batchBytes = 0
        markedDirectories.removeAll(keepingCapacity: true)
        lastCommit = Date()
        lastProgress = .distantPast
        checkpoint()
        try spaceCheck()
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            if token.isCancelled { throw CancellationError() }
            try commitBatch()
            lastWork.commits += 1
            checkpoint(idle: true)
        } catch { try? run("ROLLBACK"); rootIDs.removeAll(); checkpoint(idle: true); throw error }
    }

    func rebuild(_ identity: IndexIdentity, cursor: UInt64, cancellation: ScanCancellation, progress: @escaping (Int) -> Void = { _ in }) throws {
        guard !isWithin(identity.root, excludedPath) else { throw indexError("应用自身的索引目录不参与分析。") }
        try work(cancellation, scope: identity.root, progress: progress) {
            try run("INSERT INTO roots(path,file_id,event_uuid,cursor,updated,incomplete,target_cursor) VALUES(?,?,?,?,?,1,?) ON CONFLICT(path) DO UPDATE SET file_id=excluded.file_id,event_uuid=excluded.event_uuid,cursor=excluded.cursor,incomplete=1,target_cursor=excluded.target_cursor",
                [identity.root, identity.fileID, identity.eventUUID, String(cursor), String(Date().timeIntervalSince1970), String(cursor)])
            try touch(identity.root)
            try run("DELETE FROM garbage WHERE scope=?", [try scopeID(identity.root)])
            for table in ["jobs", "dirty_dirs", "dirty_links"] { try run("DELETE FROM \(table) WHERE scope=?", [try scopeID(identity.root)]) }
            try enqueue(identity.root, scope: identity.root, mode: .recursive)
            try boundary(force: true)
            try drain(identity)
            try prune(keeping: identity.root)
        }
    }

    func resume(_ identity: IndexIdentity, cancellation: ScanCancellation, progress: @escaping (Int) -> Void = { _ in }) throws {
        try work(cancellation, scope: identity.root, progress: progress) { try drain(identity); try prune(keeping: identity.root) }
    }

    func update(_ changes: [FileChange], identity: IndexIdentity, cursor: UInt64, cancellation: ScanCancellation, progress: @escaping (Int) -> Void = { _ in }) throws {
        if try coveringRoot(identity.root)?.incomplete == true { try resume(identity, cancellation: cancellation, progress: progress) }
        try work(cancellation, scope: identity.root, progress: progress) {
            let nextCursor = max(cursor, try coveringRoot(identity.root)?.cursor ?? 0)
            try run("UPDATE roots SET incomplete=1,target_cursor=? WHERE path=?", [String(nextCursor), identity.root])
            for change in changes where isWithin(change.path, identity.root) && !isWithin(change.path, excludedPath) {
                let path = try safeTarget(change.path, identity: identity)
                try enqueue(path, scope: identity.root, mode: change.recursive ? .recursive : .reconcile)
            }
            try boundary(force: true)
            try drain(identity)
        }
    }

    private func enqueue(_ path: String, scope: String, mode: JobMode) throws {
        try run("INSERT INTO jobs VALUES(?,?,?) ON CONFLICT(scope,path) DO UPDATE SET mode=MIN(jobs.mode,excluded.mode)", [try scopeID(scope), path, String(mode.rawValue)])
    }

    private func dirty(_ path: String, scope: String) throws {
        guard isWithin(path, scope), !markedDirectories.contains(path) else { return }
        try run("INSERT OR IGNORE INTO dirty_dirs VALUES(?,?,?)", [try scopeID(scope), path, String(path.utf8.count)])
        markedDirectories.insert(path)
    }

    private func link(_ row: NodeRecord?, scope: String) throws {
        if let row, row.kind == "1", row.links > 1 {
            try run("INSERT OR IGNORE INTO dirty_links VALUES(?,?,?,NULL)", [try scopeID(scope), row.device, row.inode])
        }
    }

    private func metadata(_ path: String) throws -> stat? {
        if token.isCancelled { throw CancellationError() }
        lastWork.metadataReads += 1
        lastWork.statCalls += 1
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastWork.metadataSeconds += ProcessInfo.processInfo.systemUptime - start }
        var info = stat()
        if lstat(path, &info) == 0 { return info }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func safeTarget(_ path: String, identity: IndexIdentity) throws -> String {
        var ancestors: [String] = []
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != identity.root && isWithin(parent, identity.root) {
            ancestors.append(parent)
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        for ancestor in ancestors.reversed() {
            let info = try? metadata(ancestor)
            if token.isCancelled { throw CancellationError() }
            if info == nil || info!.st_mode & S_IFMT != S_IFDIR || info!.st_dev != identity.device { return ancestor }
            if try node(ancestor, scope: identity.root) == nil { return ancestor }
        }
        return path
    }

    private func removeTree(_ path: String, scope: String) throws {
        let id = try scopeID(scope), bounds = range(path)
        var after = ""
        while true {
            let folders = try rows("SELECT id,path FROM folders WHERE scope=? AND (path=? OR (path>=? AND path<?)) AND path>? ORDER BY path LIMIT 128",
                [id, path, bounds.0, bounds.1, after])
            if folders.isEmpty { break }
            for folder in folders {
                while true {
                    let page = try rows("SELECT id,path,kind,device,inode,nlink,raw,bytes,files,skipped FROM node_paths WHERE scope=? AND folder=? LIMIT 256", [id, folder[0]])
                    if page.isEmpty { break }
                    try removeNodes(page, scope: scope)
                }
                try run("DELETE FROM folders WHERE id=?", [folder[0]])
                folderIDs.removeValue(forKey: folder[1])
                after = folder[1]
            }
        }
        let root = try rows("SELECT id,path,kind,device,inode,nlink,raw,bytes,files,skipped FROM node_paths WHERE id=?", [try nodeID(path, scope: scope)])
        try removeNodes(root, scope: scope)
    }

    private func removeNodes(_ page: [[String]], scope: String) throws {
        for row in page {
            try link(NodeRecord(Array(row.dropFirst(2))), scope: scope)
            try dirty(components(row[1]).0, scope: scope)
            try run("DELETE FROM nodes WHERE id=?", [row[0]])
            mutations += 1
        }
        try boundary()
    }

    private func put(_ path: String, info: stat, identity: IndexIdentity, enumeration: EnumerationContext? = nil) throws {
        let scope = identity.root
        let old = enumeration?.isEmpty == true ? nil : try node(path, scope: scope)
        try link(old, scope: scope)
        let type = info.st_mode & S_IFMT
        let kind = type == S_IFDIR ? 0 : (type == S_IFREG ? 1 : 2)
        if let old, old.kind == "0", kind != 0 { try removeTree(path, scope: scope) }
        let raw = kind == 0 ? 0 : Int64(info.st_blocks) * 512
        let parent = enumeration?.parentPath ?? (path == scope ? "" : URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let scopeNumber = try enumeration?.scope ?? Int64(scopeID(scope))!
        let parentNumber = try enumeration?.parent ?? Int64(nodeID(parent, scope: scope))!
        let name = components(path).1
        let folder = try enumeration?.folder ?? Int64(folderID(components(path).0, scope: scope))!
        let insertSQL = """
            INSERT INTO nodes(scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped,seen) VALUES(?,?,?,?,?,?,?,?,?,?,?,0,0,?)
            """
        let updateSQL = """
            ON CONFLICT(scope,folder,name) DO UPDATE SET parent=excluded.parent,kind=excluded.kind,
                device=excluded.device,inode=excluded.inode,nlink=excluded.nlink,raw=excluded.raw,
                bytes=CASE WHEN excluded.kind=0 THEN nodes.bytes ELSE excluded.bytes END,
                files=CASE WHEN excluded.kind=0 THEN nodes.files ELSE excluded.files END,issue=0,
                skipped=CASE WHEN excluded.kind=0 THEN nodes.skipped ELSE 0 END,
                seen=CASE WHEN ? THEN excluded.seen ELSE nodes.seen END
            """
        var values: [SQLValue] = [.integer(scopeNumber), .integer(folder), .text(name), .integer(parentNumber), .integer(Int64(kind)),
                  .integer(Int64(info.st_dev)), .text(String(info.st_ino)), .integer(Int64(info.st_nlink)),
                  .integer(raw), .integer(raw), .integer(kind == 0 ? 0 : 1),
                  .integer(enumeration?.generation ?? 0)]
        if let enumeration, enumeration.isEmpty {
            try runBound(insertSQL + " ON CONFLICT(scope,folder,name) DO NOTHING", values)
            if sqlite3_changes(db) == 0 {
                // A filesystem may repeat a name while it changes. Reconcile that row;
                // never publish a second insertion delta for the same file.
                try put(path, info: info, identity: identity, enumeration: EnumerationContext(
                    scope: enumeration.scope, parent: enumeration.parent, parentPath: enumeration.parentPath, folder: enumeration.folder, generation: enumeration.generation,
                    isEmpty: false, publishInserted: false))
                return
            }
            lastWork.initialInserts += 1
            if enumeration.publishInserted {
                var delta = pendingSummaries[parentNumber] ?? (bytes: 0, files: 0)
                delta.bytes += raw; delta.files += 1
                pendingSummaries[parentNumber] = delta
                lastWork.streamedFiles += 1
            }
        } else {
            values.append(.integer(enumeration == nil ? 0 : 1))
            try runBound(insertSQL + " " + updateSQL, values)
        }
        if kind == 0 { try dirty(path, scope: scope) }
        else { try dirty(parent, scope: scope) }
        if kind == 1 && (info.st_nlink > 1 || (old?.kind == "1" && (old?.links ?? 0) > 1)) {
            try run("INSERT INTO dirty_links VALUES(?,?,?,?) ON CONFLICT(scope,device,inode) DO UPDATE SET size=excluded.size", [try scopeID(scope), String(info.st_dev), String(info.st_ino), String(raw)])
        }
        mutations += 1
        batchBytes += path.utf8.count + 128
        try boundary()
    }

    private func markIssue(_ path: String, scope: String) throws {
        if try node(path, scope: scope) == nil {
            let parent = path == scope ? "" : URL(fileURLWithPath: path).deletingLastPathComponent().path
            try run("INSERT INTO nodes(scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped) VALUES(?,?,?,?,0,0,0,0,0,0,0,1,1)", [try scopeID(scope), try folderID(components(path).0, scope: scope), components(path).1, try nodeID(parent, scope: scope)])
        } else { try run("UPDATE nodes SET issue=1,skipped=CASE WHEN kind=0 THEN skipped ELSE 1 END WHERE id=?", [try nodeID(path, scope: scope)]) }
        try dirty(path, scope: scope)
        mutations += 1
        try boundary()
    }

    // Only an existing, unchanged single-link identity may use a delta. Structural changes,
    // permission gaps and unresolved summaries continue through the full repair path.
    // No boundary inside this method: node, ancestors and job completion commit together.
    private func updateOrdinaryFile(_ path: String, info: stat, old: NodeRecord?, scope: String) throws -> Bool {
        guard let old, old.kind == "1", old.links == 1, old.skipped == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              old.device == String(info.st_dev), old.inode == String(info.st_ino) else { return false }
        let id = try scopeID(scope)
        guard try rows("SELECT 1 FROM dirty_dirs WHERE scope=? LIMIT 1", [id]).isEmpty,
              try rows("SELECT 1 FROM dirty_links WHERE scope=? LIMIT 1", [id]).isEmpty else { return false }
        var ancestors: [String] = []
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while isWithin(parent, scope) {
            guard let row = try node(parent, scope: scope), row.kind == "0", row.skipped == 0 else { return false }
            ancestors.append(parent)
            if parent == scope { break }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        guard ancestors.last == scope else { return false }
        let bytes = Int64(info.st_blocks) * 512
        let delta = bytes - old.bytes
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastWork.aggregateSeconds += ProcessInfo.processInfo.systemUptime - start }
        try run("UPDATE nodes SET raw=?,bytes=? WHERE id=?", [String(bytes), String(bytes), try nodeID(path, scope: scope)])
        for ancestor in ancestors where delta != 0 {
            try run("UPDATE nodes SET bytes=bytes+? WHERE id=?", [String(delta), try nodeID(ancestor, scope: scope)])
            lastWork.deltaAncestors += 1
        }
        mutations += 1 + ancestors.count
        return true
    }

    // A directory remains queued until its direct children are committed. Resume repeats at most
    // that directory's enumeration; completed descendant jobs are not rescanned.
    private func process(_ path: String, mode: JobMode, identity: IndexIdentity) throws {
        let scope = identity.root
        let safe = try safeTarget(path, identity: identity)
        if safe != path {
            try enqueue(safe, scope: scope, mode: .recursive)
            try run("DELETE FROM jobs WHERE scope=? AND path=?", [try scopeID(scope), path])
            return
        }
        if mode == .recursive {
            try removeTree(path, scope: scope)
            let bounds = range(path)
            try run(Self.descendantJobsDeletion, [try scopeID(scope), path, bounds.0, bounds.1])
            try run("UPDATE jobs SET mode=1 WHERE scope=? AND path=?", [try scopeID(scope), path])
            try boundary(force: true)
            return
        }
        do {
            guard !isWithin(path, excludedPath) else { try finishJob(path, scope: scope); return }
            guard let info = try metadata(path) else {
                if path == scope { throw indexError("索引根目录已不存在。") }
                try removeTree(path, scope: scope)
                try finishJob(path, scope: scope)
                return
            }
            guard info.st_dev == identity.device else { try markIssue(path, scope: scope); try finishJob(path, scope: scope); return }
            let old = try node(path, scope: scope)
            if mode == .reconcile, info.st_mode & S_IFMT == S_IFDIR,
               old == nil || old!.kind != "0" || old!.inode != String(info.st_ino) {
                try run("UPDATE jobs SET mode=0 WHERE scope=? AND path=?", [try scopeID(scope), path]); return
            }
            if mode == .reconcile, try updateOrdinaryFile(path, info: info, old: old, scope: scope) {
                try finishJob(path, scope: scope)
                return
            }
            try put(path, info: info, identity: identity)
            if info.st_mode & S_IFMT == S_IFDIR {
                let directory = try DirectoryReader(path: path, useBulk: useBulkMetadata)
                defer {
                    lastWork.bulkCalls += directory.bulkCalls
                    lastWork.metadataSeconds += directory.bulkSeconds
                }
                lastWork.enumeratedDirectories += 1
                let id = try scopeID(scope)
                let parentID = try nodeID(path, scope: scope)
                let maximum = try rows("SELECT MAX(seen) FROM nodes WHERE scope=? AND parent=?", [id, parentID]).first![0]
                let enumeration = String((Int64(maximum) ?? 0) + 1)
                let context = EnumerationContext(scope: Int64(id)!, parent: Int64(parentID)!, parentPath: path, folder: Int64(try folderID(path, scope: scope))!,
                    generation: Int64(enumeration)!, isEmpty: maximum.isEmpty,
                    publishInserted: mode == .enumerate && old == nil)
                while true {
                    if token.isCancelled { throw CancellationError() }
                    guard let entry = try directory.next() else { break }
                    let child = path == "/" ? "/" + entry.name : path + "/" + entry.name
                    if isWithin(child, excludedPath) { continue }
                    var marked = false
                    do {
                        if entry.info != nil {
                            lastWork.metadataReads += 1
                            lastWork.bulkItems += 1
                        }
                        if let item = try entry.info ?? metadata(child) {
                            if item.st_dev != identity.device { try markIssue(child, scope: scope) }
                            else if item.st_mode & S_IFMT == S_IFDIR {
                                let cached = mode == .enumerate ? nil : try node(child, scope: scope)
                                if mode == .enumerate || cached == nil || cached!.kind != "0" || cached!.inode != String(item.st_ino) {
                                    try enqueue(child, scope: scope, mode: mode == .enumerate ? .enumerate : .recursive)
                                }
                            } else {
                                try put(child, info: item, identity: identity, enumeration: context)
                                marked = true
                            }
                        }
                    } catch let error as NSError where error.domain == NSPOSIXErrorDomain { try markIssue(child, scope: scope) }
                    // Preserve existing rows even when metadata cannot be read. Resume starts
                    // a fresh generation and cannot mistake partial enumeration for absence.
                    if !marked {
                        try run("UPDATE nodes SET seen=? WHERE id=?", [enumeration, try nodeID(child, scope: scope)])
                        mutations += 1
                        try boundary()
                    }
                }
                // Reaching EOF successfully is required before removing any absent children.
                // Two index ranges avoid repeatedly walking all the already-seen children.
                for comparison in ["<", ">"] {
                    while true {
                        let missing = try rows("SELECT p.path FROM nodes n INDEXED BY nodes_seen JOIN node_paths p ON p.id=n.id WHERE n.scope=? AND n.parent=? AND n.seen\(comparison)? LIMIT 256", [id, parentID, enumeration])
                        if missing.isEmpty { break }
                        lastWork.peakDeletionPage = max(lastWork.peakDeletionPage, missing.count)
                        for child in missing { try removeTree(child[0], scope: scope) }
                    }
                }
                if mode == .enumerate { try summarizePartial(path, scope: scope) }
            }
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain || error.domain == NSCocoaErrorDomain {
            try markIssue(path, scope: scope)
        }
        try finishJob(path, scope: scope)
    }

    // Publish a completed directory's direct contents immediately. The summary and all
    // ancestor deltas share a transaction; replay computes zero delta for committed work.
    // Hard links are provisional until the later identity reconciliation phase.
    private func summarizePartial(_ path: String, scope: String) throws {
        try flushSummaries()
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastWork.aggregateSeconds += ProcessInfo.processInfo.systemUptime - start }
        let id = try scopeID(scope)
        guard let row = try rows("""
            SELECT n.id,COALESCE(SUM(c.bytes),0)-n.bytes,COALESCE(SUM(c.files),0)-n.files,
                   n.issue+COALESCE(SUM(c.skipped),0)-n.skipped
            FROM nodes n LEFT JOIN nodes c ON c.scope=n.scope AND c.parent=n.id
            WHERE n.id=? AND n.kind=0 GROUP BY n.id
            """, [try nodeID(path, scope: scope)]).first else { return }
        if row.dropFirst().contains(where: { $0 != "0" }) {
            try applySummaryDelta(node: row[0], scope: id, bytes: row[1], files: row[2], skipped: row[3])
        }
        try run("DELETE FROM dirty_dirs WHERE scope=? AND path=?", [id, path])
        markedDirectories.remove(path)
        lastWork.partialAggregations += 1
        mutations += 1
    }

    private func applySummaryDelta(node: String, scope: String, bytes: String, files: String, skipped: String) throws {
        // Force primary-key access: choosing a scope index here scans the whole scope
        // for each directory and makes initial publication quadratic.
        try run("""
            WITH RECURSIVE ancestors(id) AS (
                SELECT CAST(? AS INTEGER) UNION ALL
                SELECT n.parent FROM nodes n JOIN ancestors a ON n.id=a.id
                WHERE n.scope=? AND n.parent!=0
            )
            UPDATE nodes NOT INDEXED SET bytes=bytes+?,files=files+?,skipped=skipped+?
            WHERE id IN (SELECT id FROM ancestors) AND scope=?
            """, [node, scope, bytes, files, skipped, scope])
    }

    private func flushSummaries() throws {
        guard !pendingSummaries.isEmpty else { return }
        let start = ProcessInfo.processInfo.systemUptime
        defer { lastWork.aggregateSeconds += ProcessInfo.processInfo.systemUptime - start }
        let id = try scopeID(workScope)
        for (parent, delta) in pendingSummaries {
            try applySummaryDelta(node: String(parent), scope: id, bytes: String(delta.bytes), files: String(delta.files), skipped: "0")
        }
        pendingSummaries.removeAll(keepingCapacity: true)
    }

    private func finishJob(_ path: String, scope: String) throws {
        try run("DELETE FROM jobs WHERE scope=? AND path=?", [try scopeID(scope), path])
        mutations += 1
        try boundary()
    }

    func touch(_ scope: String) throws {
        try run("UPDATE roots SET last_used=? WHERE path=?", [String(Date().timeIntervalSince1970), scope])
    }

    func cacheStorage() throws -> CacheStorage {
        let scopes = try rows("SELECT id,path,incomplete,estimated_bytes,last_used FROM roots ORDER BY last_used DESC,id").map {
            CachedScope(id: $0[0], path: $0[1], incomplete: $0[2] == "1", estimatedBytes: Int64($0[3]) ?? 0,
                lastUsed: Date(timeIntervalSince1970: Double($0[4]) ?? 0))
        }
        let size = Int64(try rows("PRAGMA page_size").first![0])!
        let pages = Int64(try rows("PRAGMA page_count").first![0])!
        let free = Int64(try rows("PRAGMA freelist_count").first![0])!
        func bytes(_ path: String) -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        return CacheStorage(scopes: scopes, databaseBytes: pages * size, walBytes: bytes(url.path + "-wal"),
            freeBytes: free * size, backupBytes: bytes(url.path + ".pre-v5"))
    }

    // Budget refers to estimated live metadata, not a hard SQLite file-size limit.
    // Current and unfinished scopes are protected; their excess is shown in the UI.
    private func prune(keeping scope: String) throws {
        setPhase("缓存整理")
        let records = try rows("SELECT id,path,incomplete,estimated_bytes FROM roots ORDER BY last_used,id")
        var remaining = records.reduce(Int64(0)) { $0 + (Int64($1[3]) ?? 0) }
        var count = records.count
        let completeCoverage = try coveringRoot(scope)?.path == scope && node(scope, scope: scope)?.skipped == 0 && coveringRoot(scope)?.incomplete == false
        for row in records where row[1] != scope {
            let covered = completeCoverage && isWithin(row[1], scope)
            let overBudget = cacheBudgetBytes > 0 && remaining > cacheBudgetBytes
            if covered || (row[2] == "0" && (overBudget || count > 20)) {
                try retire(row[0], path: row[1])
                remaining -= Int64(row[3]) ?? 0
                count -= 1
            }
        }
        try boundary(force: true)
        try collectGarbage()
    }

    private func retire(_ id: String, path: String) throws {
        try run("INSERT OR IGNORE INTO garbage VALUES(?)", [id])
        try run("DELETE FROM roots WHERE id=?", [id])
        rootIDs.removeValue(forKey: path)
    }

    func maintainCache(keeping scope: String, removing path: String? = nil, cancellation: ScanCancellation) throws {
        if let path, path == scope { throw indexError("当前索引范围正在使用，不能清除。") }
        try work(cancellation, scope: scope, progress: { _ in }) {
            if let path, let id = try rows("SELECT id FROM roots WHERE path=?", [path]).first?.first {
                try retire(id, path: path)
            }
            try prune(keeping: scope)
        }
        try reclaimFreePages(cancellation: cancellation)
    }

    // At most 64 MiB of free pages, in small cancellable chunks, and a one-second
    // soft deadline between SQLite calls. Live readers may defer truncation.
    func reclaimFreePages(cancellation: ScanCancellation) throws {
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<64 {
            if cancellation.isCancelled { throw CancellationError() }
            guard try rows("PRAGMA freelist_count").first![0] != "0" else { break }
            try run("PRAGMA incremental_vacuum(256)")
            if ProcessInfo.processInfo.systemUptime - start >= 1 { break }
        }
        checkpoint(idle: true)
    }

    func removeMigrationBackup() throws {
        let path = url.path + ".pre-v5"
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }

    private func collectGarbage() throws {
        while let row = try rows("SELECT scope FROM garbage LIMIT 1").first {
            let old = row[0]
            while true {
                let paths = try rows("SELECT id FROM nodes WHERE scope=? LIMIT 256", [old])
                if paths.isEmpty { break }
                for path in paths { try run("DELETE FROM nodes WHERE id=?", [path[0]]) }
                mutations += paths.count
                try boundary()
            }
            for table in ["folders", "jobs", "dirty_dirs", "dirty_links"] {
                while true {
                    try run("DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) WHERE scope=? LIMIT 256)", [old])
                    let changed = Int(sqlite3_changes(db))
                    if changed == 0 { break }
                    mutations += changed
                    try boundary()
                }
            }
            folderIDs.removeAll(keepingCapacity: true)
            try run("DELETE FROM garbage WHERE scope=?", [old])
            try boundary(force: true)
        }
    }

    private func drain(_ identity: IndexIdentity) throws {
        let scope = identity.root
        while let job = try rows("SELECT path,mode FROM jobs WHERE scope=? ORDER BY path LIMIT 1", [try scopeID(scope)]).first {
            guard let raw = Int(job[1]), let mode = JobMode(rawValue: raw) else { throw indexError("无法识别索引任务，请使用兼容版本。") }
            try process(job[0], mode: mode, identity: identity)
        }
        setPhase("硬链接校准")
        while let key = try rows("SELECT device,inode,size FROM dirty_links WHERE scope=? LIMIT 1", [try scopeID(scope)]).first {
            let start = ProcessInfo.processInfo.systemUptime
            defer { lastWork.linkSeconds += ProcessInfo.processInfo.systemUptime - start }
            let peers = try rows("SELECT p.path,p.raw,p.id FROM nodes n INDEXED BY nodes_identity JOIN node_paths p ON p.id=n.id WHERE n.scope=? AND n.kind=1 AND n.device=? AND n.inode=? ORDER BY p.path", [try scopeID(scope), key[0], key[1]])
            if let owner = peers.first {
                let bytes = key[2].isEmpty ? owner[1] : key[2]
                for peer in peers {
                    try run("UPDATE nodes SET raw=?,bytes=? WHERE id=?", [bytes, peer[0] == owner[0] ? bytes : "0", peer[2]])
                    try dirty(URL(fileURLWithPath: peer[0]).deletingLastPathComponent().path, scope: scope)
                    mutations += 1
                    try boundary()
                }
            }
            try run("DELETE FROM dirty_links WHERE scope=? AND device=? AND inode=?", [try scopeID(scope), key[0], key[1]])
            lastWork.resolvedLinks += 1
            mutations += 1
            try boundary()
        }
        setPhase("目录汇总")
        let id = try scopeID(scope)
        while true {
            // Fetch IDs with the work page instead of looking up every directory again.
            let page = try rows("""
                SELECT d.path FROM dirty_dirs d
                WHERE d.scope=? ORDER BY d.depth DESC,d.path LIMIT 128
                """, [id])
            if page.isEmpty { break }
            for row in page {
                let start = ProcessInfo.processInfo.systemUptime
                defer { lastWork.aggregateSeconds += ProcessInfo.processInfo.systemUptime - start }
                lastWork.fullAggregations += 1
                let path = row[0]
                let directoryID = try nodeID(path, scope: scope)
                if directoryID != "0" {
                    try run("""
                        UPDATE nodes SET (bytes,files,skipped)=(
                            SELECT COALESCE(SUM(c.bytes),0),COALESCE(SUM(c.files),0),nodes.issue+COALESCE(SUM(c.skipped),0)
                            FROM nodes c WHERE c.scope=? AND c.parent=?) WHERE id=? AND kind=0
                        """, [id, directoryID, directoryID])
                }
                if path != scope { try dirty(URL(fileURLWithPath: path).deletingLastPathComponent().path, scope: scope) }
                try run("DELETE FROM dirty_dirs WHERE scope=? AND path=?", [id, path])
                markedDirectories.remove(path)
                mutations += 1
                try boundary()
            }
        }
        if token.isCancelled { throw CancellationError() }
        try run("UPDATE roots SET incomplete=0,cursor=target_cursor,updated=? WHERE path=?", [String(Date().timeIntervalSince1970), scope])
    }
}
