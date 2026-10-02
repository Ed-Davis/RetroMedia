import Foundation
import Darwin

/// Random access to a disk image file with pread/pwrite. Nothing is mounted:
/// RetroMedia reads and writes the filesystems inside images itself, which is
/// what lets it run in the App Store sandbox.
public final class ImageFile: @unchecked Sendable {
    public let url: URL
    public let size: UInt64
    public let isWritable: Bool
    private let fd: Int32

    /// Opens `url`. If it can't be opened for writing (locked file,
    /// write-protected card) it's opened read-only instead.
    public init(url: URL, writable: Bool = true) throws {
        self.url = url
        var fd = Darwin.open(url.path, writable ? O_RDWR : O_RDONLY)
        var writable = writable
        if fd < 0 && writable && (errno == EACCES || errno == EROFS || errno == EPERM) {
            fd = Darwin.open(url.path, O_RDONLY)
            writable = false
        }
        guard fd >= 0 else {
            throw MediaError.io("Couldn't open \(url.lastPathComponent): \(String(cString: strerror(errno))).")
        }
        var info = stat()
        fstat(fd, &info)
        self.fd = fd
        self.size = UInt64(info.st_size)
        self.isWritable = writable
    }

    deinit { Darwin.close(fd) }

    public func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        guard count > 0 else { return out }
        var done = 0
        try out.withUnsafeMutableBytes { raw in
            while done < count {
                let n = pread(fd, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0 { throw MediaError.io("Read failed: \(String(cString: strerror(errno))).") }
                if n == 0 { break }   // past the end: leave zeros
                done += n
            }
        }
        return out
    }

    public func write(_ bytes: [UInt8], at offset: UInt64) throws {
        guard isWritable else { throw MediaError.readOnly }
        var done = 0
        try bytes.withUnsafeBytes { raw in
            while done < bytes.count {
                let n = pwrite(fd, raw.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done))
                if n <= 0 { throw MediaError.io("Write failed: \(String(cString: strerror(errno))).") }
                done += n
            }
        }
    }

    /// Pushes everything written so far to the physical card, not just its cache.
    public func flush() {
        guard isWritable else { return }
        fsync(fd)
        _ = fcntl(fd, F_FULLFSYNC)
    }
}

/// Errors from any kind of medium.
public enum MediaError: LocalizedError, Equatable {
    case notRecognised(String)
    case unsupported(String)
    case diskFull(needed: Int64, free: Int64)
    case directoryFull(String)
    case nameTaken(String)
    case invalidName(String)
    case corrupt(String)
    case readOnly
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notRecognised(let what):
            return what
        case .unsupported(let why):
            return why
        case .diskFull(let needed, let free):
            let f = ByteCountFormatter()
            return "Not enough space: that needs \(f.string(fromByteCount: needed)) and \(f.string(fromByteCount: free)) is free."
        case .directoryFull(let name):
            return "\(name) is full. The top level of a FAT12/16 disk has a fixed number of entries; put files in a folder instead."
        case .nameTaken(let name):
            return "There's already something called \(name) here."
        case .invalidName(let why):
            return why
        case .corrupt(let what):
            return "The disk image looks damaged (\(what)). Nothing was changed."
        case .readOnly:
            return "This is read-only."
        case .io(let what):
            return what
        }
    }
}

@inline(__always) func le16(_ b: [UInt8], _ i: Int) -> Int {
    Int(b[i]) | (Int(b[i + 1]) << 8)
}

@inline(__always) func le32(_ b: [UInt8], _ i: Int) -> Int {
    let lo: Int = le16(b, i)
    let hi: Int = le16(b, i + 2)
    return lo | (hi << 16)
}

@inline(__always) func bytes16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
@inline(__always) func bytes32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * $0) & 0xFF) } }
