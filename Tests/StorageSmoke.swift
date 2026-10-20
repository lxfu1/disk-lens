import Foundation
import SQLite3

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw indexError("CHECK FAILED: " + message) }
}
private func sql(_ url: URL, _ statement: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw indexError("fixture open failed") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else { throw indexError(String(cString: sqlite3_errmsg(db))) }
}

@main struct StorageSmoke {
    static func main() throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--inspect" {
            let index = try DiskIndex(url: URL(fileURLWithPath: args[2]), readOnly: true)
            let result = try index.result(for: args[3], scope: args[3], query: IndexQuery(search: "文件-0", recursive: true))!
            try check(result.entries.count == 1 && result.entries[0].identity?.inode == "18446744073709551614", "Swift opens migrated cache with exact inode and path search")
            let orphan = try index.result(for: args[3], scope: args[3], query: IndexQuery(search: "missing-parent", recursive: true))!
            try check(orphan.entries.count == 1 && orphan.entries[0].name == "orphan", "orphan path searchable while saved deletion resumes")
            print("PASS: migrated cache read by Swift, full path search and unsigned identity")
            return
        }
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-storage-" + UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("root")
        let url = fixture.appendingPathComponent("state/index.sqlite")
        let a = root.appendingPathComponent("a-完整路径-'")
        let b = root.appendingPathComponent("b")
        let c = root.appendingPathComponent("c")
        for dir in [a, b, c] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<100 { try Data(repeating: 3, count: 4096).write(to: dir.appendingPathComponent("文件-\(i)")) }
        }
        let index = try DiskIndex(url: url)
        for dir in [a, b, c] { try index.rebuild(IndexIdentity.read(dir), cursor: 1, cancellation: ScanCancellation()) }
        var storage = try index.cacheStorage()
        try check(storage.scopes.count == 3 && storage.scopes.allSatisfy { $0.estimatedBytes > 0 }, "live estimated storage tracked per root")
        let fullPath = try index.result(for: a.path, scope: a.path, query: IndexQuery(search: "完整路径", recursive: true))!
        try check(fullPath.entries.count == 100, "search still matches ancestor path, not just basename")
        let page = try index.result(for: a.path, scope: a.path, query: IndexQuery(limit: 20))!
        let next = try index.result(for: a.path, scope: a.path, query: IndexQuery(after: page.next, limit: 20))!
        try check(Set(page.entries.map(\.path)).isDisjoint(with: next.entries.map(\.path)), "normalized storage preserves stable paging")
        let bid = storage.scopes.first { $0.path == b.path }!.id
        try sql(url, "UPDATE roots SET incomplete=1 WHERE id=\(bid)")
        index.cacheBudgetBytes = 1
        try index.maintainCache(keeping: c.path, cancellation: ScanCancellation())
        storage = try index.cacheStorage()
        try check(Set(storage.scopes.map(\.path)) == Set([b.path, c.path]), "budget retires old complete cache while keeping active and incomplete scopes")
        try check(index.coveringRoot(a.path) == nil && fm.fileExists(atPath: a.appendingPathComponent("文件-0").path), "cache eviction never removes user files")
        do { try index.maintainCache(keeping: c.path, removing: c.path, cancellation: ScanCancellation()); throw indexError("active scope removed") }
        catch let error as NSError where error.localizedDescription.contains("当前索引") { }
        // Model a committed retirement interrupted before all pages were collected.
        try sql(url, """
            INSERT INTO folders(id,scope,path) VALUES(777,777,'/retired');
            INSERT INTO nodes(scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped) VALUES(777,777,'remaining',0,1,1,'42',1,4096,4096,1,0,0);
            INSERT INTO garbage VALUES(777);
            """)
        try index.maintainCache(keeping: c.path, cancellation: ScanCancellation())
        try sql(url, """
            CREATE TEMP TABLE cleaned(n INTEGER CHECK(n=0));
            INSERT INTO cleaned SELECT COUNT(*) FROM nodes WHERE scope=777;
            INSERT INTO cleaned SELECT COUNT(*) FROM folders WHERE scope=777;
            INSERT INTO cleaned SELECT COUNT(*) FROM garbage WHERE scope=777;
            """)
        print("PASS: path search, pagination, storage estimates, budget protection and cache-only eviction")

        index.cacheBudgetBytes = 0
        try index.rebuild(IndexIdentity.read(root), cursor: 2, cancellation: ScanCancellation())
        try check(index.cacheStorage().scopes.map(\.path) == [root.path], "complete ancestor replaces covered caches")
        let result = try index.result(for: root.path, scope: root.path)!
        try check(result.files == 300 && result.total == 300 * 4096, "coverage cleanup preserves complete ancestor summaries")
        let incomplete = ScanCancellation()
        do { try index.rebuild(IndexIdentity.read(a), cursor: 3, cancellation: incomplete) { _ in incomplete.cancel() } }
        catch is CancellationError { }
        try check(index.coveringRoot(root.path) != nil, "incomplete child never replaces complete ancestor")
        // A manual removal can discard a paused cache; a later maintenance resumes garbage collection.
        try index.maintainCache(keeping: root.path, removing: a.path, cancellation: ScanCancellation())
        let before = try index.cacheStorage().databaseBytes
        try index.maintainCache(keeping: "", removing: root.path, cancellation: ScanCancellation())
        for _ in 0..<4 { try index.reclaimFreePages(cancellation: ScanCancellation()) }
        let after = try index.cacheStorage()
        try check(after.scopes.isEmpty && after.databaseBytes < before, "incremental vacuum returns free pages to the filesystem")
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: url.path + ".pre-v5"))
        try check(index.cacheStorage().backupBytes == 3, "migration backup is included in storage UI")
        try index.removeMigrationBackup()
        try check(!fm.fileExists(atPath: url.path + ".pre-v5") && fm.fileExists(atPath: url.path), "remove backup without touching current cache")
        print("PASS: complete coverage deduplication, interrupted cache cleanup, physical file reclamation and backup removal")

        try sql(url, """
            INSERT INTO roots(id,path,file_id,event_uuid,cursor,updated,incomplete,target_cursor) VALUES(990,'/','1:1','',1,0,1,1);
            INSERT INTO folders(id,scope,path) VALUES(990,990,'/');
            INSERT INTO nodes(id,scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped) VALUES(990,990,990,'',0,0,1,'1',1,0,4096,1,0,0);
            INSERT INTO nodes(scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped) VALUES(990,990,'α',990,1,1,'18446744073709551614',1,4096,4096,1,0,0);
            """)
        let slash = try index.result(for: "/", scope: "/", query: IndexQuery(search: "/", recursive: true))!
        try check(slash.entries.count == 1 && slash.entries[0].path == "/α", "root slash reconstructs correctly and recursive queries exclude the root itself")
        print("PASS: slash root and Unicode path reconstruction")
    }
}
