import Foundation
import Darwin
import SQLite3

private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw indexError("CHECK FAILED: " + message) }
}

@main struct FirstScanSmoke {
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-first-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        for shape in ["flat", "nested"] {
            let root = fixture.appendingPathComponent(shape)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for i in 0..<2000 {
                let dir = shape == "flat" ? root : root.appendingPathComponent("group-\(i/200)/dir-\(i/10)")
                if i % 10 == 0 && shape == "nested" { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                try Data(repeating: 7, count: 4096).write(to: dir.appendingPathComponent("file-\(i).bin"))
            }
            let identity = try IndexIdentity.read(root)
            var expected: Int64?
            for useBulk in [false, true] {
                let index = try DiskIndex(url: fixture.appendingPathComponent("state-\(shape)-\(useBulk)/index.sqlite"), useBulkMetadata: useBulk)
                let start = ProcessInfo.processInfo.systemUptime
                try index.rebuild(identity, cursor: 1, cancellation: ScanCancellation())
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let work = index.lastWork
                let result = try index.result(for: root.path, scope: root.path)!
                try check(result.files == 2000 && !result.incomplete && result.skipped == 0, "complete initial result")
                if let expected { try check(result.total == expected, "bulk and scalar disk accounting agree") }
                expected = result.total
                try check(work.sqlSteps < 1_000_000, "summary publication must not rescan the scope for each directory")
                try check(work.initialInserts == 2000 && work.streamedFiles == 2000, "all fresh files use insertion and streaming path")
                if useBulk { try check(work.bulkItems == 2000 && work.statCalls < 1000, "regular metadata is batched") }
                print(String(format: "%@ bulk=%@ elapsed_ms=%.2f stat=%d bulk_calls=%d SQL_steps=%d commits=%d", shape, String(useBulk), elapsed, work.statCalls, work.bulkCalls, work.sqlSteps, work.commits))
            }
            if shape == "nested" {
                let url = fixture.appendingPathComponent("state-nested-true/index.sqlite")
                var db: OpaquePointer?
                try check(sqlite3_open(url.path, &db) == SQLITE_OK, "open aggregation fixture")
                defer { sqlite3_close(db) }
                try check(sqlite3_exec(db, """
                    UPDATE nodes SET bytes=0,files=0 WHERE kind=0;
                    INSERT INTO dirty_dirs SELECT scope,path,length(CAST(path AS BLOB)) FROM node_paths WHERE kind=0;
                    UPDATE roots SET incomplete=1,target_cursor='10';
                    """, nil, nil, nil) == SQLITE_OK, "prepare saved aggregation backlog")
                let index = try DiskIndex(url: url)
                try index.resume(identity, cancellation: ScanCancellation())
                let result = try index.result(for: root.path, scope: root.path)!
                try check(result.total == expected && result.files == 2000 && !result.incomplete, "multi-page bottom-up aggregation restores totals")
                try check(index.lastWork.metadataReads == 0 && index.lastWork.fullAggregations == 211, "saved backlog resumes without filesystem traversal or repeated summaries")
                print("PASS: saved backlog of 211 directories resumes in bounded pages with zero metadata reads")
            }
            if shape == "flat" {
                let url = fixture.appendingPathComponent("resume-state/index.sqlite")
                var index = try DiskIndex(url: url)
                let token = ScanCancellation()
                var observedPartial = false
                index.phaseChanged = { phase in
                    if phase.hasPrefix("硬链接") {
                        let reader = try! DiskIndex(url: url, readOnly: true)
                        let partial = try! reader.result(for: root.path, scope: root.path)!
                        observedPartial = partial.incomplete && partial.files > 0 && partial.files < 2000 && partial.total > 0
                        token.cancel()
                    }
                }
                do {
                    try index.rebuild(identity, cursor: 9, cancellation: token)
                    throw indexError("expected cancellation")
                } catch is CancellationError { }
                try check(observedPartial, "reader sees useful committed summaries before scan completion")
                // Change the partly ingested directory before reopening; markers and deltas must replay safely.
                try fm.removeItem(at: root.appendingPathComponent("file-0.bin"))
                try Data(repeating: 3, count: 16384).write(to: root.appendingPathComponent("file-1.bin"))
                index = try DiskIndex(url: url)
                try index.resume(identity, cancellation: ScanCancellation())
                let resumed = try index.result(for: root.path, scope: root.path)!
                var exact: Int64 = 0
                for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    var info = stat(); try check(lstat(file.path, &info) == 0, "stat expected file")
                    exact += Int64(info.st_blocks) * 512
                }
                try check(resumed.files == 1999 && resumed.total == exact && !resumed.incomplete, "resume after partial publication is exact")
                try check(index.coveringRoot(root.path)!.cursor == 9, "cursor completes with resumed summary")
                print("PASS: committed partial summaries; cancel/reopen with deletion and growth; no duplicate ancestor deltas")
            }
        }
        try mixedMetadata(fixture)
    }

    private static func mixedMetadata(_ fixture: URL) throws {
        let fm = FileManager.default
        let root = fixture.appendingPathComponent("mixed")
        let sub = root.appendingPathComponent("子目录")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(".隐藏-é.bin")
        try Data(repeating: 2, count: 8192).write(to: file)
        try fm.linkItem(at: file, to: sub.appendingPathComponent("hardlink"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: sub)
        let sparse = root.appendingPathComponent("sparse")
        _ = fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.seek(toOffset: 16 * 1024 * 1024)
        try handle.write(contentsOf: Data([1])); try handle.close()
        try check(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0, "create FIFO")
        var indexed: [ScanResult] = []
        for bulk in [false, true] {
            let reader = try DirectoryReader(path: root.path, useBulk: bulk)
            var names = Set<String>()
            while let entry = try reader.next() {
                names.insert(entry.name)
                if let info = entry.info {
                    var expected = stat()
                    try check(lstat(root.appendingPathComponent(entry.name).path, &expected) == 0, "expected metadata")
                    try check(info.st_dev == expected.st_dev && info.st_ino == expected.st_ino && info.st_nlink == expected.st_nlink && info.st_blocks == expected.st_blocks, "bulk identity, hardlink count and allocated bytes equal lstat")
                }
            }
            try check(names.count == 5 && names.contains(file.lastPathComponent), "hidden, Unicode, symlink and special entries preserved")
            let index = try DiskIndex(url: fixture.appendingPathComponent("mixed-state-\(bulk)/index.sqlite"), useBulkMetadata: bulk)
            try index.rebuild(IndexIdentity.read(root), cursor: 10, cancellation: ScanCancellation())
            indexed.append(try index.result(for: root.path, scope: root.path)!)
        }
        var a = stat(), b = stat(), c = stat(), d = stat()
        lstat(file.path, &a); lstat(sparse.path, &b)
        lstat(root.appendingPathComponent("link").path, &c); lstat(root.appendingPathComponent("pipe").path, &d)
        let expected = Int64(a.st_blocks + b.st_blocks + c.st_blocks + d.st_blocks) * 512
        try check(indexed.allSatisfy { $0.files == 5 && $0.total == expected && $0.skipped == 0 }, "hardlinks counted once; symlink not followed; sparse blocks exact")
        do { _ = try DirectoryReader(path: root.appendingPathComponent("link").path); throw indexError("followed symlink directory") }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain { }
        print("PASS: scalar/bulk agreement for Unicode, hidden files, sparse allocation, cross-directory hardlinks, symlinks, FIFO")
    }
}
