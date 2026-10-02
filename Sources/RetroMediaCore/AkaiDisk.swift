import Foundation

/// An Akai S1000/S3000-family high-density floppy image (1,638,400 bytes:
/// 1600 blocks of 1 KB), as used by Gotek/FlashFloppy floppy emulators.
///
/// Layout:
/// - `0x0000` 64 directory entries of 24 bytes. On S1000-layout disks this is
///   the directory; on S3000-layout disks it holds "MULTI FILE" placeholders.
/// - `0x0600` block table: 1600 × 2 bytes. 0 = free, 0x4000 = system,
///   0xC000 = last block of a file, otherwise the next block of the file.
/// - `0x1280` volume label (12 Akai characters) and volume parameters.
/// - `0x1400` 512 directory entries (S3000 layout only).
///
/// Directory entry: name[12], tags[4], type, size[3] LE, first block[2] LE,
/// OS version[2]. Entries are kept contiguous: the first entry with type 0
/// ends the directory.
///
/// The same code as Floppy Blaster, whose tests check it against disks made
/// by real S1000, S1100, S01, S2000, S2800 and S3000 samplers.
public struct AkaiDisk: Equatable {
    public static let blockSize = 1024
    public static let blockCount = 1600
    public static let imageSize = blockSize * blockCount

    static let tableOffset = 0x600
    static let labelOffset = 0x1280
    static let freeBlock: UInt16 = 0
    static let systemBlock: UInt16 = 0x4000
    static let lastBlock: UInt16 = 0xC000

    public enum Layout: String, Equatable {
        /// 64 files, files from block 5. S1000, S1100, S01.
        case s1000
        /// 512 files, files from block 17. S3000, S2800, S3200, S2000.
        case s3000

        public var displayName: String {
            switch self {
            case .s1000: return "S1000 format"
            case .s3000: return "S3000 format"
            }
        }
        var reservedBlocks: Int { self == .s3000 ? 17 : 5 }
        var directoryOffset: Int { self == .s3000 ? 0x1400 : 0 }
        public var maxFiles: Int { self == .s3000 ? 512 : 64 }
        var entryTags: [UInt8] { self == .s3000 ? [0, 0, 4, 0x0a] : [0x20, 0x20, 0x20, 0x20] }
    }

    public enum DiskError: LocalizedError, Equatable {
        case wrongSize(Int)
        case notAkai
        case directoryFull(Int)
        case diskFull(neededKB: Int, freeKB: Int)
        case nameTaken(String)
        case damagedFile(String)
        case noSuchFile

        public var errorDescription: String? {
            switch self {
            case .wrongSize(let size):
                return "This isn't an Akai high-density floppy image (it's \(size) bytes; they're 1,638,400)."
            case .notAkai:
                return "This doesn't look like an Akai S1000 or S3000 format floppy. It may be for another sampler (S900/S950 disks use a different format), or blank and unformatted."
            case .directoryFull(let max):
                return "The disk already holds the most files it can (\(max))."
            case .diskFull(let needed, let free):
                return "Not enough room on the disk: that needs \(needed) KB and \(free) KB is free."
            case .nameTaken(let name):
                return "There's already a file called \(name) on this disk."
            case .damagedFile(let name):
                return "\(name) is damaged on the disk (its block chain is broken)."
            case .noSuchFile:
                return "That file isn't on the disk any more."
            }
        }
    }

    public struct Entry: Equatable, Identifiable, Hashable, Sendable {
        /// Position in the directory.
        public let index: Int
        public let name: String
        public let type: UInt8
        public let size: Int
        public let startBlock: Int
        public var id: Int { index }

        public var kind: FileKind { FileKind(type: type) }
        public var blocks: Int { max(1, (size + AkaiDisk.blockSize - 1) / AkaiDisk.blockSize) }
    }

    public private(set) var bytes: [UInt8]
    public let layout: Layout

    // MARK: - Opening

    public init(data: Data) throws {
        guard data.count == Self.imageSize else { throw DiskError.wrongSize(data.count) }
        try self.init(bytes: [UInt8](data))
    }

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        var reserved = 0
        for i in 0..<Self.blockCount where Self.readTable(bytes, i) == Self.systemBlock { reserved += 1 }
        let leading = (0..<Self.blockCount).prefix { Self.readTable(bytes, $0) == Self.systemBlock }.count
        switch (reserved, leading) {
        case (17, 17): layout = .s3000
        case (5, 5): layout = .s1000
        default: throw DiskError.notAkai
        }
        // Every table value must be free, system, end, or a valid block.
        for i in 0..<Self.blockCount {
            let v = Self.readTable(bytes, i)
            guard v == Self.freeBlock || v == Self.systemBlock || v == Self.lastBlock || Int(v) < Self.blockCount else {
                throw DiskError.notAkai
            }
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// A newly formatted, empty disk. S3000 layout matches a disk formatted by
    /// an S3000-series sampler byte for byte.
    public static func blank(_ layout: Layout = .s3000) -> AkaiDisk {
        var b = [UInt8](repeating: 0, count: imageSize)
        switch layout {
        case .s3000:
            let multiFile = AkaiCharset.encode("MULTI FILE")
            for i in 0..<64 {
                b.replaceSubrange(i * 24..<i * 24 + 24,
                                  with: multiFile + [0, 0, 4, 0x0a, i == 0 ? 0xff : 0, 0, 0, 4, 0, 0, 0, 0x11])
            }
            b.replaceSubrange(labelOffset..<labelOffset + 26,
                              with: AkaiCharset.encode("NOT NAMED") + [0, 0, 0, 0x11, 0, 0, 1, 0, 0, 0, 0x32, 0x09, 0x0c, 0])
        case .s1000:
            for i in 0..<64 {
                b.replaceSubrange(i * 24..<i * 24 + 24, with: emptyEntry(.s1000, os: [0x1e, 0x09]))
            }
            b.replaceSubrange(labelOffset..<labelOffset + 16,
                              with: AkaiCharset.encode("NOT NAMED") + [0, 0, 0x1e, 0x09])
        }
        for i in 0..<layout.reservedBlocks {
            b[tableOffset + 2 * i] = 0x00
            b[tableOffset + 2 * i + 1] = 0x40
        }
        // swiftlint:disable:next force_try
        return try! AkaiDisk(bytes: b)
    }

    public var data: Data { Data(bytes) }

    // MARK: - Reading

    public var volumeName: String {
        get { AkaiCharset.decode(bytes[Self.labelOffset..<Self.labelOffset + 12]) }
    }

    public mutating func setVolumeName(_ name: String) {
        bytes.replaceSubrange(Self.labelOffset..<Self.labelOffset + 12, with: AkaiCharset.encode(name))
    }

    /// OS version stamp the disk was formatted with; copied into new entries.
    var osBytes: [UInt8] { [bytes[Self.labelOffset + 14], bytes[Self.labelOffset + 15]] }

    public var entries: [Entry] {
        var out: [Entry] = []
        let base = layout.directoryOffset
        for i in 0..<layout.maxFiles {
            let o = base + i * 24
            let type = bytes[o + 16]
            if type == 0 { break }
            out.append(Entry(index: i,
                             name: AkaiCharset.decode(bytes[o..<o + 12]),
                             type: type,
                             size: Int(bytes[o + 17]) | Int(bytes[o + 18]) << 8 | Int(bytes[o + 19]) << 16,
                             startBlock: Int(bytes[o + 20]) | Int(bytes[o + 21]) << 8))
        }
        return out
    }

    public var freeBlocks: Int {
        (0..<Self.blockCount).filter { table($0) == Self.freeBlock }.count
    }

    public var usableBlocks: Int { Self.blockCount - layout.reservedBlocks }

    public func contents(of entry: Entry) throws -> Data {
        var out = [UInt8]()
        out.reserveCapacity(entry.blocks * Self.blockSize)
        var block = entry.startBlock
        var visited = 0
        while out.count < entry.size {
            guard block >= layout.reservedBlocks, block < Self.blockCount, visited < Self.blockCount else {
                throw DiskError.damagedFile(entry.name)
            }
            out += bytes[block * Self.blockSize..<(block + 1) * Self.blockSize]
            visited += 1
            let next = table(block)
            if next == Self.lastBlock { break }
            guard next != Self.freeBlock, next != Self.systemBlock else { throw DiskError.damagedFile(entry.name) }
            block = Int(next)
        }
        guard out.count >= entry.size else { throw DiskError.damagedFile(entry.name) }
        return Data(out[0..<entry.size])
    }

    // MARK: - Writing

    /// True if a file of `size` bytes would fit (space and directory).
    public func canFit(sizes: [Int]) -> Bool {
        let needed = sizes.reduce(0) { $0 + max(1, ($1 + Self.blockSize - 1) / Self.blockSize) }
        return needed <= freeBlocks && entries.count + sizes.count <= layout.maxFiles
    }

    /// Adds a file as-is. `name` is converted to Akai characters; it must not
    /// already be in use.
    @discardableResult
    public mutating func addFile(name: String, type: UInt8, contents: Data) throws -> Entry {
        let akaiName = AkaiCharset.decode(AkaiCharset.encode(name))
        let existing = entries
        guard existing.count < layout.maxFiles else { throw DiskError.directoryFull(layout.maxFiles) }
        guard !existing.contains(where: { $0.name == akaiName }) else { throw DiskError.nameTaken(akaiName) }
        let needed = max(1, (contents.count + Self.blockSize - 1) / Self.blockSize)
        let free = (0..<Self.blockCount).filter { table($0) == Self.freeBlock }
        guard free.count >= needed else { throw DiskError.diskFull(neededKB: needed, freeKB: free.count) }
        guard contents.count < 1 << 24 else { throw DiskError.diskFull(neededKB: needed, freeKB: free.count) }

        let blocks = Array(free.prefix(needed))
        let source = [UInt8](contents)
        for (i, block) in blocks.enumerated() {
            let lo = i * Self.blockSize
            let hi = min(lo + Self.blockSize, source.count)
            var chunk = lo < hi ? Array(source[lo..<hi]) : []
            chunk += [UInt8](repeating: 0, count: Self.blockSize - chunk.count)
            bytes.replaceSubrange(block * Self.blockSize..<(block + 1) * Self.blockSize, with: chunk)
            setTable(block, i + 1 < needed ? UInt16(blocks[i + 1]) : Self.lastBlock)
        }

        let index = existing.count
        let size = contents.count
        let entry: [UInt8] = AkaiCharset.encode(name) + layout.entryTags
            + [type, UInt8(size & 0xff), UInt8(size >> 8 & 0xff), UInt8(size >> 16 & 0xff),
               UInt8(blocks[0] & 0xff), UInt8(blocks[0] >> 8)]
            + osBytes
        let o = layout.directoryOffset + index * 24
        bytes.replaceSubrange(o..<o + 24, with: entry)
        return entries[index]
    }

    /// Removes a file, frees its blocks and closes the gap in the directory.
    public mutating func delete(_ entry: Entry) throws {
        let current = entries
        guard current.indices.contains(entry.index), current[entry.index] == entry else { throw DiskError.noSuchFile }
        var block = entry.startBlock
        var visited = 0
        while block >= layout.reservedBlocks, block < Self.blockCount, visited < Self.blockCount {
            let next = table(block)
            setTable(block, Self.freeBlock)
            visited += 1
            if next == Self.lastBlock || next == Self.freeBlock || next == Self.systemBlock { break }
            block = Int(next)
        }
        let base = layout.directoryOffset
        let count = current.count
        let tail = Array(bytes[base + (entry.index + 1) * 24..<base + count * 24])
        bytes.replaceSubrange(base + entry.index * 24..<base + (count - 1) * 24, with: tail)
        bytes.replaceSubrange(base + (count - 1) * 24..<base + count * 24, with: Self.emptyEntry(layout, os: osBytes))
    }

    /// Renames a file. Samples and programs also carry their name inside the
    /// file, so that's updated too.
    public mutating func rename(_ entry: Entry, to newName: String) throws {
        let current = entries
        guard current.indices.contains(entry.index), current[entry.index] == entry else { throw DiskError.noSuchFile }
        let encoded = AkaiCharset.encode(newName)
        let decoded = AkaiCharset.decode(encoded)
        guard decoded == entry.name || !current.contains(where: { $0.name == decoded }) else {
            throw DiskError.nameTaken(decoded)
        }
        let o = layout.directoryOffset + entry.index * 24
        bytes.replaceSubrange(o..<o + 12, with: encoded)
        if entry.kind == .sample || entry.kind == .program, entry.size >= 15,
           entry.startBlock >= layout.reservedBlocks, entry.startBlock < Self.blockCount {
            let p = entry.startBlock * Self.blockSize + 3
            bytes.replaceSubrange(p..<p + 12, with: encoded)
        }
    }

    /// A name not yet on the disk, made from `name` by adding a number if needed.
    public func uniqueName(_ name: String, extraTaken: Set<String> = []) -> String {
        let base = AkaiCharset.decode(AkaiCharset.encode(name))
        let taken = Set(entries.map(\.name)).union(extraTaken)
        if !taken.contains(base) { return base }
        for n in 2...999 {
            let suffix = " \(n)"
            let candidate = AkaiCharset.decode(AkaiCharset.encode(String(base.prefix(12 - suffix.count)) + suffix))
            if !taken.contains(candidate) { return candidate }
        }
        return base
    }

    // MARK: - Internals

    static func emptyEntry(_ layout: Layout, os: [UInt8]) -> [UInt8] {
        switch layout {
        case .s3000: return [UInt8](repeating: 0, count: 24)
        case .s1000: return [UInt8](repeating: 10, count: 12) + [0x20, 0x20, 0x20, 0x20] + [0, 0, 0, 0, 0, 0] + os
        }
    }

    static func readTable(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[tableOffset + 2 * i]) | UInt16(b[tableOffset + 2 * i + 1]) << 8
    }

    func table(_ i: Int) -> UInt16 { Self.readTable(bytes, i) }

    mutating func setTable(_ i: Int, _ v: UInt16) {
        bytes[Self.tableOffset + 2 * i] = UInt8(v & 0xff)
        bytes[Self.tableOffset + 2 * i + 1] = UInt8(v >> 8)
    }
}

/// What a file on an Akai disk is, from its type byte. S3000-family files
/// have the top bit set (0xF3 sample, 0xF0 program); S1000-family ones don't.
public enum FileKind: Equatable {
    case sample, program, drumSettings, effects, cueList, multi, operatingSystem, s01Settings, other(UInt8)

    init(type: UInt8) {
        switch type & 0x7f {
        case 0x73: self = .sample
        case 0x70: self = .program
        case 0x64: self = .drumSettings
        case 0x78: self = .effects
        case 0x71: self = .cueList
        case 0x6d: self = .multi
        case 0x63: self = .operatingSystem
        case 0x61: self = .s01Settings
        default: self = .other(type)
        }
    }

    public var label: String {
        switch self {
        case .sample: return "Sample"
        case .program: return "Program"
        case .drumSettings: return "Drum settings"
        case .effects: return "Effects"
        case .cueList: return "Cue list"
        case .multi: return "Multi"
        case .operatingSystem: return "Operating system"
        case .s01Settings: return "S01 settings"
        case .other(let t): return String(format: "Type %02X", t)
        }
    }
}

/// Akai's 41-character set for names: digits, space, A–Z and # + - .
public enum AkaiCharset {
    static let characters = Array("0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ#+-.")

    /// Names are 12 characters. Lowercase becomes uppercase; anything Akai
    /// can't show becomes a space (or a dash, for _ and /).
    public static func encode(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for ch in name.uppercased() {
            guard out.count < 12 else { break }
            let c: Character = (ch == "_" || ch == "/") ? "-" : ch
            out.append(UInt8(characters.firstIndex(of: c) ?? 10))
        }
        return out + [UInt8](repeating: 10, count: 12 - out.count)
    }

    public static func decode<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(bytes.map { Int($0) < characters.count ? characters[Int($0)] : "?" })
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// The name as it will appear on the sampler.
    public static func clean(_ name: String) -> String { decode(encode(name)) }
}
