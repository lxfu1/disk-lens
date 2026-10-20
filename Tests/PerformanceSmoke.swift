import Foundation
import SQLite3
import Darwin

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw indexError("CHECK FAILED: " + message) }
}

@main struct PerformanceSmoke {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-performance-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let url = fixture.appendingPathComponent("state/index.sqlite")
        for folder in 0..<50 {
            let dir = root.appendingPathComponent(String(format: "dir-%02d", folder))
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<50 {
                let source = dir.appendingPathComponent("源文件-\(file).bin")
                try Data(repeating: 1, count: 4096).write(to: source)
                try fm.linkItem(at: source, to: dir.appendingPathComponent("link-\(file).bin"))
            }
        }
        let identity = try IndexIdentity.read(root)
        var index = try DiskIndex(url: url)
        let reader = try DiskIndex(url: url, readOnly: true)
        let cancelled = ScanCancellation()
        var readWhileWriting = false
        var pausedReads = 0
        let started = Date()
        do {
            try index.rebuild(identity, cursor: 10, cancellation: cancelled) { reads in
                if reads > 1000 {
                    let time = Date()
                    if let result = try? reader.result(for: root.path, scope: root.path) {
                        readWhileWriting = result.incomplete && Date().timeIntervalSince(time) < 1
                    }
                    pausedReads = reads
                    cancelled.cancel()
                }
            }
            throw indexError("fixture did not exercise pause")
        } catch is CancellationError { }
        try check(readWhileWriting, "independent reader must return partial snapshot during writer operation")
        try check(index.coveringRoot(root.path)!.incomplete, "paused state is durable")
        index = try DiskIndex(url: url)
        try index.resume(identity, cancellation: ScanCancellation())
        try check(index.lastWork.manualCheckpoints < index.lastWork.commits, "manual checkpoint must not run after every batch")
        print("PASS: \(index.lastWork.commits) commits / \(index.lastWork.manualCheckpoints) manual checkpoints")
        let result = try reader.result(for: root.path, scope: root.path)!
        try check(result.files == 5000 && result.total == 2500 * 4096 && !result.incomplete, "resumed hard links and aggregates")
        try check(index.lastWork.metadataReads < 10051, "resume must retain completed directories")
        let walBytes = (try? fm.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        try check(walBytes < 8 * 1024 * 1024, "WAL should be checkpointed after completion")
        print("PASS: 5,000 paths / 2,500 hard-link identities, pause after \(pausedReads) metadata reads, resume \(index.lastWork.metadataReads), \(index.lastWork.commits) commits; \(String(format: "%.2f", Date().timeIntervalSince(started)))s; final WAL \(walBytes) bytes")

        // Exercise 100,000 indexed rows without scanning personal files or creating 100,000 files.
        var raw: OpaquePointer?
        sqlite3_open(url.path, &raw)
        defer { sqlite3_close(raw) }
        let scope = root.path.replacingOccurrences(of: "'", with: "''")
        let sql = """
            BEGIN;
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
            INSERT INTO nodes(scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped)
            SELECT (SELECT id FROM roots WHERE path='\(scope)'),
                (SELECT id FROM folders WHERE path='\(scope)' AND scope=(SELECT id FROM roots WHERE path='\(scope)')), 'synthetic-'||printf('%06d',x),
                (SELECT id FROM node_paths WHERE path='\(scope)' AND scope=(SELECT id FROM roots WHERE path='\(scope)')),
                1,1,CAST(x AS TEXT),1,x,x,1,0,0 FROM n;
            UPDATE nodes SET bytes=5022980000,files=105000 WHERE id=(SELECT id FROM node_paths WHERE scope=(SELECT id FROM roots WHERE path='\(scope)') AND path='\(scope)');
            COMMIT;
            """
        try check(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK, "synthetic metadata fixture")
        var query = IndexQuery(largest: true)
        var paths = Set<String>()
        let queryStart = Date()
        for _ in 0..<3 {
            let page = try reader.result(for: root.path, scope: root.path, query: query)!
            try check(page.entries.count == 200, "bounded page")
            for entry in page.entries { try check(paths.insert(entry.path).inserted, "keyset pages must not repeat rows") }
            query.after = page.next
        }
        let querySeconds = Date().timeIntervalSince(queryStart)
        try check(querySeconds < 3, "three pages within budget")
        let search = try reader.result(for: root.path, scope: root.path, query: IndexQuery(largest: true, search: "synthetic-000001", recursive: true))!
        try check(search.entries.count == 1 && search.entries[0].name == "synthetic-000001", "search must include matches outside the former top 100")
        let chinese = try reader.result(for: root.path, scope: root.path, query: IndexQuery(search: "源文件-49", recursive: true))!
        try check(chinese.entries.count == 50, "Unicode substring recursive search")
        let local = try reader.result(for: root.path, scope: root.path, query: IndexQuery(search: "源文件", recursive: false))!
        try check(local.entries.isEmpty, "direct-child search scope")
        print("PASS: 105,000 metadata rows: three 200-row pages \(String(format: "%.3f", querySeconds))s; recursive Unicode search, direct scope, small-file match beyond top 100")
        let stale = ScanCancellation(); stale.cancel()
        do {
            _ = try reader.result(for: root.path, scope: root.path, query: IndexQuery(search: "absent", recursive: true), cancellation: stale)
            throw indexError("cancelled query returned")
        } catch is CancellationError { }
        print("PASS: stale query cancellation")
        let events = (0..<5000).map { FileChange(path: root.path + "/hot/file-\($0)", recursive: false) }
        let coalesced = IndexCoordinator.coalesce(events + [FileChange(path: root.path + "/quiet/one", recursive: false)], root: root.path)
        try check(coalesced.count == 2 && !coalesced.contains(where: { $0.path == root.path }), "event burst must not widen to whole root")
        let direct = (0..<5000).map { FileChange(path: root.path + "/file-\($0)", recursive: false) }
        try check(!IndexCoordinator.coalesce(direct, root: root.path).contains(where: { $0.path == root.path }), "even a burst of root children must not force a root rescan")
        print("PASS: 5,001 events merge to affected subtree plus unrelated leaf, without root rescan")
    }
}
