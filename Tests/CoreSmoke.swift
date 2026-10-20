import Foundation
import Darwin

@main
struct CoreSmoke {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-check-" + UUID().uuidString)
        let root = fixture.appendingPathComponent("scan")
        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let first = root.appendingPathComponent("first.bin")
        let second = nested.appendingPathComponent("second.bin")
        let outside = fixture.appendingPathComponent("outside.bin")
        try Data(repeating: 0x5a, count: 16_384).write(to: first)
        try Data(repeating: 0x31, count: 32_768).write(to: second)
        try Data(repeating: 0x22, count: 65_536).write(to: outside)
        try fm.linkItem(at: first, to: root.appendingPathComponent("first-hardlink.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("outside-link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: nested.appendingPathComponent("cycle"), withDestinationURL: root)

        func allocated(_ url: URL) -> Int64 {
            var info = stat()
            precondition(lstat(url.path, &info) == 0)
            return Int64(info.st_blocks) * 512
        }
        let index = try DiskIndex(url: fixture.appendingPathComponent("state/index.sqlite"))
        let identity = try IndexIdentity.read(root)
        try index.rebuild(identity, cursor: 1, cancellation: ScanCancellation())
        let scan = try index.result(for: root.path, scope: root.path)!
        let expected = allocated(first) + allocated(second)
            + allocated(root.appendingPathComponent("outside-link")) + allocated(nested.appendingPathComponent("cycle"))
        precondition(scan.total == expected, "Expected \(expected), got \(scan.total), entries \(scan.entries)")
        precondition(scan.files == 5 && scan.skipped == 0)
        let largest = try index.result(for: root.path, scope: root.path, query: IndexQuery(largest: true))!
        precondition(largest.entries.count == 2)
        precondition(largest.entries.first?.path == second.path)
        precondition(scan.entries.first(where: { $0.path == nested.path })?.isDirectory == true)
        print("PASS: allocated size, nested aggregation, largest files, hard-link deduplication, symlink cycle/external target")

        let cancelled = ScanCancellation()
        cancelled.cancel()
        do { try index.rebuild(identity, cursor: 2, cancellation: cancelled); preconditionFailure("Expected cancellation") }
        catch is CancellationError { print("PASS: cancellation") }
        do { _ = try IndexIdentity.read(fixture.appendingPathComponent("missing")); preconditionFailure("Expected root failure") }
        catch { print("PASS: missing directory failure") }

        try TrashPolicy.validate(first, root: root)
        try TrashPolicy.validate(root.appendingPathComponent("outside-link"), root: root)
        for target in [root, outside, URL(fileURLWithPath: "/System"), fm.homeDirectoryForCurrentUser] {
            do { try TrashPolicy.validate(target, root: root); preconditionFailure("Unsafe target allowed: \(target.path)") }
            catch { }
        }
        let alias = root.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: alias, withDestinationURL: fixture)
        do { try TrashPolicy.validate(alias.appendingPathComponent("outside.bin"), root: root); preconditionFailure("Ancestor link escape allowed") }
        catch { }
        print("PASS: trash scope, protected roots, final symlink allowed, ancestor symlink escape rejected (no trash operations executed)")

        let volume = try VolumeStatus.read(at: root)
        precondition(volume.total > 0 && volume.free > 0 && volume.free <= volume.total)
        print("PASS: volume capacity — \(formatBytes(volume.free)) free / \(formatBytes(volume.total))")
    }
}
