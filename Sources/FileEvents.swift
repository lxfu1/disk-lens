import Foundation
import CoreServices
import Darwin

func isWithin(_ path: String, _ root: String) -> Bool {
    path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
}

struct IndexIdentity {
    let root: String
    let device: dev_t
    let fileID: String
    let eventUUID: String
    let relativePath: String

    static func read(_ url: URL) throws -> IndexIdentity {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw indexError("目录不存在或无法访问：\(path)")
        }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw indexError("无法读取目录：\(path)") }
        defer { Darwin.close(fd) }
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { throw indexError("无法读取磁盘信息。") }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH_NOFIRMLINK, &buffer) == 0 else {
            throw indexError("无法确定目录所在磁盘的真实路径。")
        }
        let physical = String(cString: buffer)
        let mount = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard isWithin(physical, mount) else { throw indexError("目录与磁盘挂载位置不匹配。") }
        let relative = String(physical.dropFirst(mount == "/" ? 1 : mount.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let uuid = FSEventsCopyUUIDForDevice(info.st_dev).map { CFUUIDCreateString(nil, $0) as String } ?? ""
        return IndexIdentity(root: path, device: info.st_dev, fileID: "\(info.st_dev):\(info.st_ino)", eventUUID: uuid, relativePath: relative)
    }

    var startingCursor: UInt64 {
        // This API's timestamp is Unix time, despite the CFAbsoluteTime typedef.
        max(1, FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970))
    }
}

func indexError(_ message: String) -> NSError {
    NSError(domain: "DiskLens.Index", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct FileChange {
    let path: String
    let recursive: Bool
}

struct EventBatch {
    var changes: [FileChange] = []
    var cursor: UInt64 = 0
    var historyDone = false
    var invalidateRoot = false
}

// Owns one per-device stream. All callback payloads are copied before leaving the callback.
final class FileEventMonitor {
    private var stream: FSEventStreamRef?
    private let identity: IndexIdentity
    private let callback: (EventBatch) -> Void
    private let queue = DispatchQueue(label: "DiskLens.events", qos: .utility)

    init(identity: IndexIdentity, since: UInt64, callback: @escaping (EventBatch) -> Void) throws {
        self.identity = identity
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFullHistory)
        guard let created = FSEventStreamCreateRelativeToDevice(nil, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let monitor = Unmanaged<FileEventMonitor>.fromOpaque(info).takeUnretainedValue()
            let strings = unsafeBitCast(paths, to: NSArray.self) as! [String]
            var batch = EventBatch()
            for i in 0..<count {
                let flag = flags[i]
                if ids[i] != kFSEventStreamEventIdSinceNow { batch.cursor = max(batch.cursor, ids[i]) }
                if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    batch.historyDone = true
                    continue
                }
                if flag & UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagUnmount) != 0 {
                    batch.invalidateRoot = true
                    continue
                }
                if flag & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    batch.changes.append(FileChange(path: monitor.identity.root, recursive: true))
                    continue
                }
                let relative = strings[i].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let watched = monitor.identity.relativePath
                if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0,
                   relative.isEmpty || isWithin(watched, relative) {
                    batch.changes.append(FileChange(path: monitor.identity.root, recursive: true))
                    continue
                }
                guard watched.isEmpty || relative == watched || relative.hasPrefix(watched + "/") else { continue }
                let suffix = watched.isEmpty ? relative : String(relative.dropFirst(watched.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let path = suffix.isEmpty ? monitor.identity.root : URL(fileURLWithPath: monitor.identity.root).appendingPathComponent(suffix).path
                batch.changes.append(FileChange(path: path, recursive: flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0))
            }
            monitor.callback(batch)
        }, &context, identity.device, [identity.relativePath] as CFArray,
           identity.eventUUID.isEmpty ? UInt64(kFSEventStreamEventIdSinceNow) : since, 1.0, flags) else {
            throw indexError("无法创建文件变化监听。")
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            stop()
            throw indexError("无法启动文件变化监听，请检查磁盘与访问权限。")
        }
    }

    func flush() { if let stream { FSEventStreamFlushAsync(stream) } }
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        // The coordinator calls stop off the callback queue; drain callbacks before releasing self.
        queue.sync {}
    }
    deinit { stop() }
}
