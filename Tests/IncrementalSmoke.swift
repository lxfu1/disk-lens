import Foundation
import Darwin

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw indexError("CHECK FAILED: " + message) }
}

@main
struct IncrementalSmoke {
    static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    private static func run() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-incremental-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("root")
        let active = root.appendingPathComponent("active")
        let unrelated = root.appendingPathComponent("unrelated")
        try fm.createDirectory(at: active, withIntermediateDirectories: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let first = active.appendingPathComponent("first.bin")
        try Data(repeating: 3, count: 8192).write(to: first)
        for i in 0..<180 {
            try Data(repeating: UInt8(i), count: 4096).write(to: unrelated.appendingPathComponent("file-\(i).bin"))
        }
        let identity = try IndexIdentity.read(root)
        let databaseURL = fixture.appendingPathComponent("state/index.sqlite")
        var index = try DiskIndex(url: databaseURL)
        try index.rebuild(identity, cursor: 10, cancellation: ScanCancellation())
        let initialReads = index.lastWork.metadataReads
        let initial = try index.result(for: root.path, scope: root.path)!
        try require(initial.files == 181 && initial.skipped == 0, "initial index")

        index = try DiskIndex(url: databaseURL)
        let cachedChild = try index.result(for: active.path, scope: root.path)!
        try require(cachedChild.files == 1 && index.lastWork.metadataReads == 0, "reopen and child navigation must use SQLite only")
        print("PASS: persisted index and child browsing require 0 file metadata reads")

        try Data(repeating: 9, count: 65_536).write(to: first)
        try index.update([FileChange(path: first.path, recursive: false)], identity: identity, cursor: 11, cancellation: ScanCancellation())
        let incrementalReads = index.lastWork.metadataReads
        var grown = try index.result(for: root.path, scope: root.path)!
        var info = stat(); lstat(first.path, &info)
        try require(grown.total == initial.total - cachedChild.total + Int64(info.st_blocks) * 512, "ancestor totals after growth")
        try require(try index.result(for: root.path, scope: root.path, query: IndexQuery(largest: true))!.entries.first?.path == first.path, "largest files after growth")
        try require(incrementalReads < 8 && index.lastWork.enumeratedDirectories == 0, "single-file update must not enumerate unrelated directories")
        print("PASS: file growth checks \(incrementalReads) metadata entries versus \(initialReads) initially; no directory enumeration")

        let link = root.appendingPathComponent("a-hardlink.bin")
        try fm.linkItem(at: first, to: link)
        try index.update([FileChange(path: link.path, recursive: false)], identity: identity, cursor: 12, cancellation: ScanCancellation())
        try require(index.result(for: root.path, scope: root.path)!.total == grown.total, "new hard link must not double count")
        try fm.removeItem(at: link)
        try index.update([FileChange(path: link.path, recursive: false)], identity: identity, cursor: 13, cancellation: ScanCancellation())
        try require(index.result(for: root.path, scope: root.path)!.total == grown.total, "deleting link owner transfers bytes to survivor")
        try fm.linkItem(at: first, to: link)
        try index.update([FileChange(path: link.path, recursive: false), FileChange(path: first.path, recursive: false)], identity: identity, cursor: 13, cancellation: ScanCancellation())
        try fm.removeItem(at: link)
        let writer = try FileHandle(forWritingTo: first)
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Data(repeating: 6, count: 131_072))
        try writer.close()
        try index.update([FileChange(path: first.path, recursive: false)], identity: identity, cursor: 13, cancellation: ScanCancellation())
        try index.update([FileChange(path: link.path, recursive: false)], identity: identity, cursor: 13, cancellation: ScanCancellation())
        lstat(first.path, &info)
        try require(index.result(for: root.path, scope: root.path)!.total == initial.total - cachedChild.total + Int64(info.st_blocks) * 512,
                    "a delayed unlink event must not restore a stale shared-file size")
        grown = try index.result(for: root.path, scope: root.path)!
        print("PASS: cross-directory hard-link creation and owner deletion keep totals stable")

        let moved = root.appendingPathComponent("renamed")
        try fm.moveItem(at: active, to: moved)
        try index.update([FileChange(path: active.path, recursive: false), FileChange(path: moved.path, recursive: false)], identity: identity, cursor: 14, cancellation: ScanCancellation())
        try require(index.result(for: active.path, scope: root.path) == nil, "old directory removed")
        try require(index.result(for: moved.path, scope: root.path)!.files == 1, "renamed directory indexed")
        try require(index.result(for: root.path, scope: root.path)!.total == grown.total, "rename preserves total")
        print("PASS: directory rename refreshes only old/new paths")

        let largest = try index.result(for: root.path, scope: root.path, query: IndexQuery(largest: true))!.entries.first!
        try fm.removeItem(atPath: largest.path)
        try index.update([FileChange(path: largest.path, recursive: false)], identity: identity, cursor: 15, cancellation: ScanCancellation())
        let afterDelete = try index.result(for: root.path, scope: root.path)!
        let largestPage = try index.result(for: root.path, scope: root.path, query: IndexQuery(largest: true, limit: 100))!
        try require(largestPage.entries.count == 100 && !largestPage.entries.contains(where: { $0.path == largest.path }), "largest-file list promotes cached candidates after deletion")

        let cancelled = ScanCancellation()
        do {
            try index.update([FileChange(path: root.path, recursive: true)], identity: identity, cursor: 99, cancellation: cancelled) { _ in cancelled.cancel() }
            throw indexError("expected cancellation")
        } catch is CancellationError { }
        try require(index.coveringRoot(root.path)!.cursor == 15, "cancel must roll back cursor")
        try require(index.coveringRoot(root.path)!.incomplete, "cancelled work must remain marked incomplete")
        index = try DiskIndex(url: databaseURL)
        try index.resume(identity, cancellation: ScanCancellation())
        try require(index.result(for: root.path, scope: root.path)!.total == afterDelete.total, "resume must restore complete totals")
        try require(index.coveringRoot(root.path)!.cursor == 99 && !index.coveringRoot(root.path)!.incomplete, "cursor advances only after resume completes")
        print("PASS: deletion promotes candidates; cancellation persists work and resume completes data before cursor")

        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16384).write(to: outside.appendingPathComponent("private.bin"))
        try fm.removeItem(at: moved)
        try fm.createSymbolicLink(at: moved, withDestinationURL: outside)
        try index.update([FileChange(path: moved.appendingPathComponent("private.bin").path, recursive: false)], identity: identity, cursor: 16, cancellation: ScanCancellation())
        try require(index.result(for: moved.path, scope: root.path) == nil, "replaced ancestor symlink must not be traversed")
        try require(index.result(for: root.path, scope: root.path)!.files == afterDelete.files + 1, "only symlink itself is counted")
        print("PASS: late events through a replaced ancestor cannot escape the indexed directory")

        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unrelated.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unrelated.path) }
        try index.update([FileChange(path: unrelated.path, recursive: true)], identity: identity, cursor: 17, cancellation: ScanCancellation())
        try require(index.result(for: root.path, scope: root.path)!.skipped > 0, "permission gaps must be visible")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unrelated.path)
        try index.update([FileChange(path: unrelated.path, recursive: false)], identity: identity, cursor: 18, cancellation: ScanCancellation())
        try require(index.result(for: root.path, scope: root.path)!.skipped == 0, "restored access can be reconciled")

        try Data(repeating: 4, count: 12288).write(to: root.appendingPathComponent("missed.bin"))
        try index.update([FileChange(path: root.path, recursive: true)], identity: identity, cursor: 19, cancellation: ScanCancellation())
        try require(index.result(for: root.path, scope: root.path)!.entries.contains(where: { $0.name == "missed.bin" }), "recursive fallback repairs missed changes")
        print("PASS: permission errors/restoration and recursive repair of missed events")
    }
}
