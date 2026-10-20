import Foundation
import Darwin

// getattrlistbulk uses a 4-byte-packed ABI, not Swift struct alignment. Decode only
// validated fields; non-regular files and missing attributes use the lstat path.
final class DirectoryReader {
    struct Entry {
        let name: String
        let info: stat?
    }
    private let directory: UnsafeMutablePointer<DIR>
    private var bulk: Bool
    private var delivered = false
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var remaining = 0
    private var offset = 0
    private(set) var bulkCalls = 0
    private(set) var bulkSeconds = 0.0

    init(path: String, useBulk: Bool = true) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Self.posixError() }
        guard let directory = fdopendir(fd) else {
            let error = Self.posixError(); close(fd); throw error
        }
        self.directory = directory
        bulk = useBulk
    }

    deinit { closedir(directory) }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    func next() throws -> Entry? {
        if !bulk { return try nextScalar() }
        if remaining == 0 {
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
            attributes.fileattr = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
            let start = ProcessInfo.processInfo.systemUptime
            let count = buffer.withUnsafeMutableBytes {
                getattrlistbulk(dirfd(directory), &attributes, $0.baseAddress!, $0.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
            }
            let code = errno
            bulkCalls += 1
            bulkSeconds += ProcessInfo.processInfo.systemUptime - start
            if count < 0 {
                // Only restart before any records were emitted. A later error keeps the
                // directory incomplete, so an interrupted listing never deletes children.
                if !delivered && [ENOTSUP, EINVAL, ENOSYS].contains(code) {
                    bulk = false
                    rewinddir(directory)
                    return try nextScalar()
                }
                throw Self.posixError(code)
            }
            if count == 0 { return nil }
            remaining = Int(count)
            offset = 0
        }
        let entry: Entry = try buffer.withUnsafeBytes { data in
            func u32(_ field: Int) -> UInt32 { data.loadUnaligned(fromByteOffset: offset + field, as: UInt32.self) }
            guard offset <= data.count - 36 else { throw Self.posixError(EIO) }
            let length = Int(u32(0))
            guard length >= 36, length <= data.count - offset else { throw Self.posixError(EIO) }
            let common = u32(4), file = u32(16)
            guard common & UInt32(ATTR_CMN_NAME) != 0 else { throw Self.posixError(EIO) }
            let nameOffset = 28 + Int(Int32(bitPattern: u32(28)))
            let nameLength = Int(u32(32))
            guard nameOffset >= 36, nameLength > 1, nameOffset <= length,
                  nameLength <= length - nameOffset,
                  data[offset + nameOffset + nameLength - 1] == 0 else { throw Self.posixError(EIO) }
            let nameBytes = data[(offset + nameOffset)..<(offset + nameOffset + nameLength - 1)]
            guard !nameBytes.contains(0), !nameBytes.contains(47) else { throw Self.posixError(EIO) }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let requiredCommon = UInt32(ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FILEID)
            let requiredFile = UInt32(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)
            var info: stat?
            // macOS omits the file attribute group for directories even with
            // PACK_INVAL_ATTRS. The name reference is authoritative for those rows.
            if length >= 64, nameOffset >= 64, u32(24) == 0, common & requiredCommon == requiredCommon,
               file & requiredFile == requiredFile, u32(40) == 1 { // VREG
                let allocated = data.loadUnaligned(fromByteOffset: offset + 56, as: Int64.self)
                let links = u32(52)
                if allocated >= 0, allocated % 512 == 0, links > 0, links <= UInt32(UInt16.max) {
                    var value = stat()
                    value.st_mode = mode_t(S_IFREG)
                    value.st_dev = Int32(bitPattern: u32(36))
                    value.st_ino = data.loadUnaligned(fromByteOffset: offset + 44, as: UInt64.self)
                    value.st_nlink = UInt16(links)
                    value.st_blocks = allocated / 512
                    info = value
                }
            }
            offset += length
            remaining -= 1
            return Entry(name: name, info: info)
        }
        delivered = true
        if entry.name == "." || entry.name == ".." { return try next() }
        return entry
    }

    private func nextScalar() throws -> Entry? {
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw Self.posixError() }
                return nil
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { return Entry(name: name, info: nil) }
        }
    }
}
