import Foundation

@main
struct EventSmoke {
    static func main() {
        setbuf(stdout, nil)
        do { try run() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    private static func run() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-events-" + UUID().uuidString)
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let child = fixture.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: child.appendingPathComponent("initial.bin"))
        // Keep the index inside the watched tree to exercise exclusion and feedback-loop prevention.
        let databaseURL = fixture.appendingPathComponent("index-state/index.sqlite")
        var snapshots: [(ScanResult, String, Bool)] = []
        var activities: [String] = []
        var failure: String?
        var onActivity: (() -> Void)?
        let receive: (IndexUpdate) -> Void = { update in
            switch update {
            case .snapshot(let result, let status, let busy): snapshots.append((result, status, busy))
            case .activity(let status):
                activities.append(status)
                let action = onActivity; onActivity = nil; action?()
            case .failure(let error): failure = error
            default: break
            }
        }
        func wait(_ label: String, seconds: Double = 12, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if let failure { throw indexError("\(label): \(failure)") }
                if Date() > deadline {
                    throw indexError("Timed out: \(label); activities=\(activities); snapshots=\(snapshots.map { ($0.0.files, $0.1, $0.2) })")
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        var coordinator: IndexCoordinator? = IndexCoordinator(databaseURL: databaseURL, delivery: receive)
        defer { coordinator?.stop() }
        coordinator!.open(fixture)
        try wait("initial index and HistoryDone") { snapshots.last.map { !$0.2 && $0.0.files == 1 } ?? false }
        let initial = snapshots.last!.0
        if initial.entries.contains(where: { $0.name == "index-state" }) { throw indexError("Index storage was not excluded") }
        print("PASS: real per-device FSEvents stream, initial scan catch-up, index-directory exclusion")

        let fresh = child.appendingPathComponent("live.bin")
        try Data(repeating: 2, count: 16_384).write(to: fresh)
        try wait("live file creation") { snapshots.last.map { !$0.2 && $0.0.files == 2 && $0.0.total > initial.total } ?? false }
        print("PASS: native create event updates ancestor totals automatically (\(snapshots.last!.1))")

        try fm.removeItem(at: fresh)
        try wait("live file deletion") { snapshots.last.map { !$0.2 && $0.0.files == 1 && $0.0.total == initial.total } ?? false }
        print("PASS: native deletion event removes cached file without manual rescan")

        let quietStart = snapshots.count
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if snapshots.count - quietStart > 1 { throw indexError("Index writes caused an event feedback loop") }
        print("PASS: index writes do not cause a continuous refresh loop")

        var stopped = false
        coordinator!.stop { stopped = true }
        try wait("stop") { stopped }
        coordinator = nil
        try Data(repeating: 7, count: 32768).write(to: child.appendingPathComponent("offline.bin"))
        snapshots.removeAll()
        activities.removeAll()
        coordinator = IndexCoordinator(databaseURL: databaseURL, delivery: receive)
        coordinator!.open(fixture)
        try wait("cached result then replay after restart") { snapshots.last.map { !$0.2 && $0.0.files == 2 } ?? false }
        guard let first = snapshots.first, first.1.contains("缓存"), first.0.files == 1 else {
            throw indexError("Restart did not display persisted cache before replay")
        }
        if activities.contains(where: { $0.contains("首次建立") || $0.contains("正在重建") }) {
            throw indexError("Restart unnecessarily rebuilt the index")
        }
        print("PASS: restart displays cache immediately and replays changes made while stopped")

        snapshots.removeAll()
        activities.removeAll()
        coordinator!.open(child)
        try wait("cached navigation") { snapshots.last.map { !$0.2 && $0.0.root.path == child.path && $0.0.files == 2 } ?? false }
        if !activities.isEmpty { throw indexError("Cached child navigation started a scan") }
        print("PASS: opening an indexed child queries cached data without starting a scan")
        snapshots.removeAll()
        coordinator!.query(child, options: IndexQuery(search: "initial", recursive: true))
        coordinator!.query(child, options: IndexQuery(search: "offline", recursive: true))
        try wait("latest query wins") { snapshots.last?.0.entries.first?.name == "offline.bin" }
        if snapshots.contains(where: { $0.0.entries.contains(where: { $0.name == "initial.bin" }) }) {
            throw indexError("An obsolete query replaced the newest search")
        }
        print("PASS: obsolete search results cannot overwrite the newest query")
        stopped = false
        coordinator!.stop { stopped = true }
        try wait("final stop") { stopped }
        coordinator = nil

        // A child request must not resume an unfinished ancestor and traverse unrelated files.
        let pendingRoot = fixture.appendingPathComponent("unfinished")
        let requested = pendingRoot.appendingPathComponent("requested")
        try fm.createDirectory(at: requested, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4096).write(to: requested.appendingPathComponent("wanted.bin"))
        let parentIdentity = try IndexIdentity.read(pendingRoot)
        let paused = ScanCancellation()
        do {
            let seed = try DiskIndex(url: databaseURL)
            do {
                try seed.rebuild(parentIdentity, cursor: parentIdentity.startingCursor, cancellation: paused) { _ in paused.cancel() }
            } catch is CancellationError { }
        }
        snapshots.removeAll(); activities.removeAll()
        coordinator = IndexCoordinator(databaseURL: databaseURL, delivery: receive)
        coordinator!.open(requested)
        try wait("child of incomplete ancestor") { snapshots.last.map { !$0.2 && !$0.0.incomplete && $0.0.root.path == requested.path && $0.0.files == 1 } ?? false }
        let inspect = try DiskIndex(url: databaseURL, readOnly: true)
        guard try inspect.coveringRoot(requested.path)?.path == requested.path,
              try inspect.coveringRoot(pendingRoot.path)?.incomplete == true else {
            throw indexError("Child request resumed or replaced its unfinished ancestor")
        }
        print("PASS: child of unfinished ancestor builds only requested scope and preserves ancestor progress")
        stopped = false
        coordinator!.stop { stopped = true }
        try wait("scope test stop") { stopped }
        coordinator = nil
        let second = pendingRoot.appendingPathComponent("second")
        let unrelated = pendingRoot.appendingPathComponent("aaa-unrelated")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data([1]).write(to: second.appendingPathComponent("only.bin"))
        for number in 0..<1000 { fm.createFile(atPath: unrelated.appendingPathComponent("file-\(number)").path, contents: Data()) }
        snapshots.removeAll(); activities.removeAll()
        coordinator = IndexCoordinator(databaseURL: databaseURL, delivery: receive)
        onActivity = { coordinator!.open(second) }
        coordinator!.open(pendingRoot)
        try wait("switch away from running ancestor") { snapshots.last.map { !$0.2 && !$0.0.incomplete && $0.0.root.path == second.path && $0.0.files == 1 } ?? false }
        guard try inspect.coveringRoot(second.path)?.path == second.path else {
            throw indexError("Active ancestor fast path swallowed a child indexing request")
        }
        print("PASS: selecting a child interrupts the active ancestor instead of waiting for unrelated enumeration")
        stopped = false
        coordinator!.stop { stopped = true }
        try wait("final scope stop") { stopped }
        coordinator = nil


    }
}
