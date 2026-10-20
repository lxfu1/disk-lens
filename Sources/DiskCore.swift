import Foundation
import Darwin

struct FileIdentity: Codable, Equatable {
    let device: Int64
    let inode: String

    init(_ info: stat) {
        device = Int64(info.st_dev)
        inode = String(info.st_ino)
    }

    init(device: Int64, inode: String) {
        self.device = device
        self.inode = inode
    }
}

struct DiskEntry: Identifiable, Codable, Equatable {
    var id: String { path }
    let path: String
    let isDirectory: Bool
    var bytes: Int64
    let name: String
    let identity: FileIdentity?
    init(path: String, isDirectory: Bool, bytes: Int64, identity: FileIdentity? = nil) {
        self.path = path; self.isDirectory = isDirectory; self.bytes = bytes
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.identity = identity
    }
}

struct ScanResult {
    let root: URL
    let entries: [DiskEntry]
    let files: Int
    let skipped: Int
    let issues: [String]
    let date: Date
    let total: Int64
    let incomplete: Bool
    let next: PageCursor?
    let pageReset: Bool
    var indexedScope: String = ""
}

struct ComparisonBaseline {
    let date: Date
    var sizes: [String: Int64]

    mutating func include(_ entries: [DiskEntry]) {
        for entry in entries where sizes[entry.path] == nil { sizes[entry.path] = entry.bytes }
    }
}

struct CapacityAlerts {
    private var volumeID: String?
    private var lastSuccess = Date.distantPast
    private var retryAfter = Date.distantPast
    private var inFlight: UUID?

    mutating func reset() { self = CapacityAlerts() }

    mutating func prepare(_ status: VolumeStatus, threshold: Double, enabled: Bool, now: Date = Date()) -> UUID? {
        if volumeID != status.id { reset(); volumeID = status.id }
        if status.fraction * 100 < threshold - 2 { lastSuccess = .distantPast }
        guard enabled, inFlight == nil, now >= retryAfter,
              status.fraction * 100 >= threshold, now.timeIntervalSince(lastSuccess) > 6 * 3600 else { return nil }
        let token = UUID()
        inFlight = token
        return token
    }

    @discardableResult mutating func complete(_ token: UUID, succeeded: Bool, now: Date = Date()) -> Bool {
        guard inFlight == token else { return false }
        inFlight = nil
        if succeeded { lastSuccess = now }
        else { retryAfter = now.addingTimeInterval(60) }
        return true
    }
}

@MainActor
final class VolumeReader {
    private let queue = DispatchQueue(label: "DiskLens.capacity", qos: .utility)
    private let read: (URL) throws -> VolumeStatus
    private var latest: (URL, (Result<VolumeStatus, Error>) -> Void)?
    private var generation = 0
    private(set) var isReading = false

    init(read: @escaping (URL) throws -> VolumeStatus = VolumeStatus.read) { self.read = read }

    func request(_ url: URL, completion: @escaping (Result<VolumeStatus, Error>) -> Void) {
        generation += 1
        latest = (url, completion)
        if !isReading { start() }
    }

    private func start() {
        guard let (url, _) = latest else { return }
        isReading = true
        let token = generation
        let read = self.read
        queue.async { [weak self] in
            let result = Result { try read(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReading = false
                if self.generation == token {
                    let completion = self.latest?.1
                    self.latest = nil
                    completion?(result)
                }
                if !self.isReading && self.latest != nil { self.start() }
            }
        }
    }
}

final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

struct VolumeStatus {
    let id: String
    let total: Int64
    let free: Int64
    var used: Int64 { max(0, total - free) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    static func read(at url: URL) throws -> VolumeStatus {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return VolumeStatus(id: "\(info.f_fsid.val.0):\(info.f_fsid.val.1)",
                            total: Int64(info.f_blocks) * Int64(info.f_bsize),
                            free: Int64(info.f_bavail) * Int64(info.f_bsize))
    }
}

enum TrashPolicy {
    static func validate(_ target: URL, root: URL, expected: FileIdentity? = nil) throws {
        let path = target.standardizedFileURL.path
        let scope = root.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/var", "/etc", "/tmp", "/usr", "/bin", "/sbin", "/dev", "/Volumes", home, home + "/Library", home + "/.Trash"]
        // Resolve parent directories but preserve a final symlink: trashing a link must not trash its target.
        let resolved = target.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(target.lastPathComponent).standardizedFileURL.path
        let prefix = scope == "/" ? "/" : scope + "/"
        guard path.hasPrefix(prefix), resolved.hasPrefix(prefix), path != scope,
              !protected.contains(path), !protected.contains(resolved),
              !resolved.hasPrefix("/System/"), !resolved.hasPrefix("/usr/"),
              !resolved.hasPrefix("/bin/"), !resolved.hasPrefix("/sbin/"),
              !resolved.hasPrefix("/dev/"), !resolved.hasPrefix("/private/"),
              !resolved.hasPrefix(home + "/.Trash/") else {
            throw NSError(domain: "DiskLens", code: 3, userInfo: [NSLocalizedDescriptionKey: "该位置受保护或已移出扫描范围，请在 Finder 中管理。"])
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw NSError(domain: "DiskLens", code: 4, userInfo: [NSLocalizedDescriptionKey: "文件已被移动或删除，请刷新索引。"])
        }
        if let expected, FileIdentity(info) != expected {
            throw indexError("该路径的文件已被替换，请刷新索引后重新选择。")
        }
    }
}

func formatBytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

struct NavigationHistory {
    private var back: [URL] = []
    private var forward: [URL] = []
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    mutating func visit(from current: URL, to next: URL) {
        guard current != next else { return }
        back.append(current)
        if back.count > 100 { back.removeFirst() }
        forward.removeAll()
    }
    mutating func goBack(from current: URL) -> URL? {
        guard let next = back.popLast() else { return nil }
        forward.append(current)
        return next
    }
    mutating func goForward(from current: URL) -> URL? {
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        return next
    }
}
