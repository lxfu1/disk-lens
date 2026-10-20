import Foundation
import Darwin
import SQLite3

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw indexError("CHECK FAILED: " + message) }
}

@main struct OptimizationSmoke {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-optimizations-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let files = (0..<4).map { root.appendingPathComponent("file-\($0)") }
        for (i, file) in files.enumerated() { try Data(repeating: 7, count: (4-i)*16384).write(to: file) }
        let url = fixture.appendingPathComponent("state/index.sqlite")
        var index = try DiskIndex(url: url)
        let identity = try IndexIdentity.read(root)
        try index.rebuild(identity, cursor: 1, cancellation: ScanCancellation())
        let page = try index.result(for: root.path, scope: root.path, query: IndexQuery(limit: 2))!
        let cursor = page.next!
        let second = try index.result(for: root.path, scope: root.path, query: IndexQuery(after: cursor, limit: 2))!
        try check(!second.pageReset && Set(page.entries.map(\.path)).isDisjoint(with: second.entries.map(\.path)), "unchanged pages remain disjoint")
        try Data(repeating: 8, count: 131072).write(to: files[2])
        try index.update([FileChange(path: files[2].path, recursive: false)], identity: identity, cursor: 2, cancellation: ScanCancellation())
        try check(index.lastWork.fullAggregations == 0 && index.lastWork.deltaAncestors == 1, "single-link size update uses ancestor delta")
        let reset = try index.result(for: root.path, scope: root.path, query: IndexQuery(after: cursor, limit: 2))!
        try check(reset.pageReset && reset.entries.first?.path == files[2].path, "changed revision restarts at first page")
        let paused = ScanCancellation()
        do {
            try index.rebuild(identity, cursor: 3, cancellation: paused) { _ in paused.cancel() }
        } catch is CancellationError { }
        index = try DiskIndex(url: url)
        try index.resume(identity, cancellation: ScanCancellation())
        try check(index.result(for: root.path, scope: root.path, query: IndexQuery(after: reset.next!, limit: 2))!.pageReset, "rebuild/resume invalidates old cursor")
        print("PASS: static pagination, changed-size cursor invalidation, rebuild/resume invalidation")

        let entry = try index.result(for: root.path, scope: root.path)!.entries.first { $0.path == files[0].path }!
        try TrashPolicy.validate(files[0], root: root, expected: entry.identity!)
        // Retain the original inode so this cannot accidentally pass through inode reuse.
        try fm.moveItem(at: files[0], to: fixture.appendingPathComponent("original"))
        try Data([1]).write(to: files[0])
        do {
            try TrashPolicy.validate(files[0], root: root, expected: entry.identity!)
            throw indexError("replacement file was accepted")
        } catch let error as NSError where error.localizedDescription.contains("已被替换") { }
        print("PASS: unchanged file accepted, replacement identity rejected; no trash operation executed")

        try boundedEnumeration(fixture: fixture)
        if !CommandLine.arguments.contains("--index-only") {
            try eventBudget()
            try displayState()
            try asynchronousVolume()
        }
    }

    private static func boundedEnumeration(fixture: URL) throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("wide")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for i in 0..<600 { try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("f-\(i)")) }
        let url = fixture.appendingPathComponent("wide-state/index.sqlite")
        var index = try DiskIndex(url: url)
        let identity = try IndexIdentity.read(root)
        try index.rebuild(identity, cursor: 1, cancellation: ScanCancellation())
        let original = try index.result(for: root.path, scope: root.path)!
        for i in 0..<300 { try fm.removeItem(at: root.appendingPathComponent("f-\(i)")) }
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        try index.update([FileChange(path: root.path, recursive: false)], identity: identity, cursor: 2, cancellation: ScanCancellation())
        let denied = try index.result(for: root.path, scope: root.path)!
        try check(denied.files == 600 && denied.skipped > 0, "failed enumeration retains old children")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let cancel = ScanCancellation()
        do {
            try index.update([FileChange(path: root.path, recursive: false)], identity: identity, cursor: 3, cancellation: cancel) { _ in cancel.cancel() }
        } catch is CancellationError { }
        // Model a crash after committing only part of the directory's new markers.
        try rawSQL(url, "UPDATE nodes SET seen=17 WHERE id IN (SELECT id FROM nodes WHERE kind=1 LIMIT 50)")
        index = try DiskIndex(url: url)
        try index.resume(identity, cancellation: ScanCancellation())
        let repaired = try index.result(for: root.path, scope: root.path)!
        try check(repaired.files == 300 && repaired.total == original.total / 2 && repaired.skipped == 0, "resume removes only absent children")
        try check(index.lastWork.peakDeletionPage == 256, "missing children are fetched in bounded pages")
        let grown = root.appendingPathComponent("f-599")
        try Data(repeating: 4, count: 32768).write(to: grown)
        try index.update([FileChange(path: grown.path, recursive: false)], identity: identity, cursor: 4, cancellation: ScanCancellation())
        let steps = index.lastWork.sqlSteps
        try check(index.lastWork.fullAggregations == 0 && index.lastWork.deltaAncestors == 1, "wide parent does not SUM children for file growth")
        var info = stat(); lstat(grown.path, &info)
        try check(index.result(for: root.path, scope: root.path)!.total == repaired.total - 4096 + Int64(info.st_blocks)*512, "delta total is exact")
        // A durable queued job plus an already-updated file must replay idempotently.
        try rawSQL(url, "UPDATE roots SET incomplete=1,target_cursor='5'; INSERT INTO jobs SELECT id,path||'/f-599',2 FROM roots;")
        index = try DiskIndex(url: url)
        try index.resume(identity, cancellation: ScanCancellation())
        try check(index.result(for: root.path, scope: root.path)!.total == repaired.total - 4096 + Int64(info.st_blocks)*512, "replayed delta is not applied twice")
        try rawSQL(url, """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000)
            INSERT INTO nodes(scope,folder,name,parent,kind,device,inode,nlink,raw,bytes,files,issue,skipped)
            SELECT r.id,f.id,'synthetic-'||x,p.id,1,1,CAST(x AS TEXT),1,1,1,1,0,0
            FROM n,roots r JOIN node_paths p ON p.scope=r.id AND p.path=r.path JOIN folders f ON f.scope=r.id AND f.path=r.path;
            UPDATE nodes SET bytes=bytes+10000,files=files+10000 WHERE parent=0 AND kind=0;
            """)
        try Data(repeating: 5, count: 65536).write(to: grown)
        try index.update([FileChange(path: grown.path, recursive: false)], identity: identity, cursor: 6, cancellation: ScanCancellation())
        let wideSteps = index.lastWork.sqlSteps
        try check(index.lastWork.fullAggregations == 0 && wideSteps < steps + 100, "delta SQL cost stays bounded when parent grows by 10,000 children")
        lstat(grown.path, &info)
        try check(index.result(for: root.path, scope: root.path)!.total == repaired.total - 4096 + Int64(info.st_blocks)*512 + 10000, "wide-parent delta preserves total")
        print("PASS: permission failure retains 600 children; partial markers resume/delete in pages <=256; replay idempotent; 300/10,300 children: \(steps)/\(wideSteps) delta SQL steps")
    }

    private static func rawSQL(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw indexError("fixture database open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw indexError(String(cString: sqlite3_errmsg(db))) }
    }

    private static func eventBudget() throws {
        var events = EventChanges(root: "/root")
        for i in 0..<20000 {
            events.append(FileChange(path: "/root/branch-\(i % 4)/dir-\(i)/leaf", recursive: false))
            try check(events.count <= EventChanges.pathLimit, "event count stays bounded")
        }
        let compacted = events.sorted
        try check(!compacted.contains { $0.path == "/root" }, "nested bursts repair only affected subtrees")
        for i in 0..<20000 {
            let path = "/root/branch-\(i % 4)/dir-\(i)/leaf"
            try check(compacted.contains { $0.path == path || ($0.recursive && isWithin(path, $0.path)) }, "coalescing cannot drop an event")
        }
        var wide = EventChanges(root: "/root")
        for i in 0..<9000 { wide.append(FileChange(path: "/root/file-\(i)", recursive: false)) }
        try check(wide.sorted.count == 1 && wide.sorted[0].path == "/root" && wide.sorted[0].recursive, "extreme root fanout has bounded lossless fallback")
        var longPaths = EventChanges(root: "/root")
        for i in 0..<1200 { longPaths.append(FileChange(path: "/root/\(i)-" + String(repeating: "x", count: 4000), recursive: false)) }
        try check(longPaths.sorted.count == 1 && longPaths.sorted[0].path == "/root", "path bytes also have a budget")
        print("PASS: 20,000 nested events retain coverage with bounded state; root fanout and long paths have lossless fallback")
    }

    private static func displayState() throws {
        var baseline = ComparisonBaseline(date: Date(), sizes: [:])
        baseline.include([DiskEntry(path: "/a", isDirectory: false, bytes: 100)])
        baseline.include([DiskEntry(path: "/b", isDirectory: false, bytes: 200)])
        baseline.include([DiskEntry(path: "/a", isDirectory: false, bytes: 300)])
        try check(baseline.sizes == ["/a": 100, "/b": 200], "baseline extends across pages without overwriting first values")
        let now = Date(timeIntervalSince1970: 100000)
        let high = VolumeStatus(id: "one", total: 100, free: 10)
        let low = VolumeStatus(id: "one", total: 100, free: 30)
        var alerts = CapacityAlerts()
        let first = alerts.prepare(high, threshold: 85, enabled: true, now: now)!
        try check(alerts.prepare(high, threshold: 85, enabled: true, now: now) == nil, "in-flight notification is deduplicated")
        alerts.complete(first, succeeded: false, now: now)
        try check(alerts.prepare(high, threshold: 85, enabled: true, now: now.addingTimeInterval(59)) == nil, "failure backs off briefly")
        let retried = alerts.prepare(high, threshold: 85, enabled: true, now: now.addingTimeInterval(60))!
        alerts.complete(retried, succeeded: true, now: now.addingTimeInterval(60))
        try check(alerts.prepare(high, threshold: 85, enabled: true, now: now.addingTimeInterval(120)) == nil, "successful submission starts six-hour cooldown")
        _ = alerts.prepare(low, threshold: 85, enabled: true, now: now.addingTimeInterval(180))
        let recovered = alerts.prepare(high, threshold: 85, enabled: true, now: now.addingTimeInterval(240))!
        _ = alerts.prepare(VolumeStatus(id: "two", total: 100, free: 10), threshold: 85, enabled: true, now: now)
        try check(!alerts.complete(recovered, succeeded: true, now: now), "stale volume completion cannot change new volume cooldown")
        alerts.reset()
        try check(alerts.prepare(high, threshold: 85, enabled: false, now: now) == nil, "disabled notifications stay disabled")
        print("PASS: baseline grows across pages; notification failure retries after 60s, success cools down, hysteresis and stale completions are handled")
    }

    @MainActor private static func asynchronousVolume() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var reads: [String] = []
        let reader = VolumeReader { url in
            precondition(!Thread.isMainThread)
            lock.lock(); reads.append(url.path); lock.unlock()
            if url.path == "/slow" { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            if url.path == "/error" { throw indexError("simulated unavailable volume") }
            return VolumeStatus(id: url.path, total: 100, free: 50)
        }
        var delivered: [String] = []
        reader.request(URL(fileURLWithPath: "/slow")) { response in
            if case .success(let status) = response { delivered.append(status.id) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() {
                if Date() > deadline { throw indexError("async volume test timed out") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }
        try wait { entered.wait(timeout: .now()) == .success }
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        try wait { heartbeat }
        for i in 0..<20 {
            reader.request(URL(fileURLWithPath: "/latest-\(i)")) { response in
                if case .success(let status) = response { delivered.append(status.id) }
            }
        }
        release.signal()
        try wait { delivered == ["/latest-19"] }
        lock.lock(); let captured = reads; lock.unlock()
        try check(captured == ["/slow", "/latest-19"], "pending requests coalesce and stale completion is discarded")
        var failed = false
        reader.request(URL(fileURLWithPath: "/error")) { if case .failure = $0 { failed = true } }
        try wait { failed }
        print("PASS: slow capacity read leaves main queue responsive; 20 requests coalesce; stale results and errors handled")
    }
}
