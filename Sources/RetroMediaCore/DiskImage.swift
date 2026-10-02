import Foundation

/// A FAT disk image: one volume filling the image (a floppy or "superfloppy"),
/// or up to four in an MBR partition table (hard disk images for ZuluSCSI,
/// BlueSCSI, SCSI2SD and the like).
public final class FATDiskImage: @unchecked Sendable {
    public let file: ImageFile
    public let volumes: [FATVolume]

    public init(url: URL, writable: Bool = true) throws {
        let file = try ImageFile(url: url, writable: writable)
        try self.init(file: file)
    }

    public init(file: ImageFile) throws {
        self.file = file
        guard file.size >= 512 * 16 else { throw MediaError.notRecognised("This file is too small to be a disk image.") }
        let first = try file.read(at: 0, count: 512)
        // A partition table, if the first sector has one with sensible entries…
        var found: [FATVolume] = []
        var sawOther = false
        if first[510] == 0x55, first[511] == 0xAA, Self.looksLikeMBR(first) {
            for i in 0..<4 {
                let p = 446 + i * 16
                let type = first[p + 4]
                let start = UInt64(le32(first, p + 8))
                guard start > 0, type != 0 else { continue }
                switch type {
                case 0x01, 0x04, 0x06, 0x0B, 0x0C, 0x0E:
                    if let v = try? FATVolume(image: file, offset: start * 512) { found.append(v) } else { sawOther = true }
                default:
                    sawOther = true
                }
            }
        }
        // …otherwise a volume starting at sector 0.
        if found.isEmpty, let whole = try? FATVolume(image: file, offset: 0) {
            found = [whole]
        }
        guard !found.isEmpty else {
            throw MediaError.notRecognised(sawOther
                ? "This disk image's partitions aren't FAT (they may be HFS, Linux or another system RetroMedia can't read)."
                : "This doesn't look like a FAT disk image.")
        }
        volumes = found
    }

    /// An MBR has a FAT boot sector's jump missing, or partition entries that
    /// look real. (A FAT boot sector also ends 55 AA, so this tells them apart.)
    static func looksLikeMBR(_ s: [UInt8]) -> Bool {
        var any = false
        for i in 0..<4 {
            let p = 446 + i * 16
            guard s[p] == 0x00 || s[p] == 0x80 else { return false }
            if s[p + 4] != 0 { any = true }
        }
        let bootJump = s[0] == 0xEB || s[0] == 0xE9
        let hasBPB = bootJump && le16(s, 11) == 512 && s[13] != 0
        return any && !hasBPB
    }

    public var isWritable: Bool { file.isWritable }
}

/// Makes blank disk images: DOS floppies for a Gotek, and FAT16 or FAT32
/// hard disk images for SCSI-to-SD adapters. Everything is written directly
/// (no hdiutil or newfs); on APFS the empty space costs nothing until used.
public enum DiskImageMaker {
    static let sectorSize = 512
    static let megabyte: Int64 = 1_048_576

    // MARK: Floppies

    public enum Floppy: String, CaseIterable, Identifiable, Sendable {
        case dd720 = "720 KB", hd144 = "1.44 MB", ed288 = "2.88 MB"
        public var id: String { rawValue }
        var sectors: Int { switch self { case .dd720: return 1440; case .hd144: return 2880; case .ed288: return 5760 } }
        var sectorsPerCluster: Int { switch self { case .dd720: return 2; case .hd144: return 1; case .ed288: return 2 } }
        var rootEntries: Int { switch self { case .dd720: return 112; case .hd144: return 224; case .ed288: return 240 } }
        var fatSectors: Int { switch self { case .dd720: return 3; case .hd144: return 9; case .ed288: return 9 } }
        var media: UInt8 { self == .dd720 ? 0xF9 : 0xF0 }
        var sectorsPerTrack: Int { switch self { case .dd720: return 9; case .hd144: return 18; case .ed288: return 36 } }
        public var bytes: Int { sectors * 512 }
    }

    /// A blank DOS floppy image, as DOS/Windows format them.
    public static func floppy(_ type: Floppy, label: String = "") -> Data {
        var b = [UInt8](repeating: 0, count: type.bytes)
        let name = volumeLabel(label)
        b.replaceSubrange(0..<3, with: [0xEB, 0x3C, 0x90])
        b.replaceSubrange(3..<11, with: Array("MSDOS5.0".utf8))
        b.replaceSubrange(11..<13, with: bytes16(512))
        b[13] = UInt8(type.sectorsPerCluster)
        b.replaceSubrange(14..<16, with: bytes16(1))
        b[16] = 2
        b.replaceSubrange(17..<19, with: bytes16(type.rootEntries))
        b.replaceSubrange(19..<21, with: bytes16(type.sectors))
        b[21] = type.media
        b.replaceSubrange(22..<24, with: bytes16(type.fatSectors))
        b.replaceSubrange(24..<26, with: bytes16(type.sectorsPerTrack))
        b.replaceSubrange(26..<28, with: bytes16(2))
        b[38] = 0x29
        b.replaceSubrange(39..<43, with: bytes32(Int(UInt32.random(in: 1...UInt32.max))))
        b.replaceSubrange(43..<54, with: padded(name.isEmpty ? "NO NAME" : name))
        b.replaceSubrange(54..<62, with: Array("FAT12   ".utf8))
        b[510] = 0x55
        b[511] = 0xAA
        for copy in 0..<2 {
            let o = (1 + copy * type.fatSectors) * 512
            b.replaceSubrange(o..<o + 3, with: [type.media, 0xFF, 0xFF])
        }
        if !name.isEmpty {
            let root = (1 + 2 * type.fatSectors) * 512
            b.replaceSubrange(root..<root + 11, with: padded(name))
            b[root + 11] = 0x08
        }
        return Data(b)
    }

    // MARK: Hard disks

    public enum Format: String, CaseIterable, Identifiable, Sendable {
        /// FAT16 partitions of up to 2 GB each (up to four): what older
        /// machines (samplers, Amigas with CrossDOS, DOS) read.
        case fat16 = "FAT16"
        /// One FAT32 partition: Windows 95 OSR2 and later, Macs, most modern kit.
        case fat32 = "FAT32"
        public var id: String { rawValue }
    }

    public static let maxFAT16PartitionMB: Int64 = 2040
    public static let minimumMB: Int64 = 16
    public static func maximumMB(_ format: Format) -> Int64 { format == .fat16 ? 4 * maxFAT16PartitionMB : 2_097_151 }
    /// FAT32 needs at least 65,525 clusters; at 512-byte clusters that's about 33 MB.
    public static let minimumFAT32MB: Int64 = 40

    /// Preset sizes offered, in MB.
    public static let presetSizesMB: [Int64] = [20, 40, 80, 100, 250, 500, 1024, 2048, 4096, 8192, 16384, 32768]

    public static func label(forMB mb: Int64) -> String {
        if mb < 1024 { return "\(mb) MB" }
        let gb = Double(mb) / 1024
        let text = gb == gb.rounded() ? String(Int(gb)) : String(format: "%g", (gb * 100).rounded() / 100)
        return "\(text) GB"
    }

    public enum MakeError: LocalizedError, Equatable {
        case sizeOutOfRange(Int64, Format)
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .sizeOutOfRange(let mb, let format):
                let lo = format == .fat32 ? DiskImageMaker.minimumFAT32MB : DiskImageMaker.minimumMB
                return "\(mb) MB is outside what \(format.rawValue) can do here (\(lo) MB to \(DiskImageMaker.label(forMB: DiskImageMaker.maximumMB(format))))."
            case .cannotWrite(let why):
                return why
            }
        }
    }

    struct Partition: Equatable {
        let startLBA: Int64
        let sectors: Int64
        let sectorsPerCluster: Int
        let fatSectors: Int
        let reserved: Int
        let rootEntries: Int
        let format: Format
    }

    static let firstPartitionLBA: Int64 = 63

    static func layout(totalMB: Int64, format: Format) throws -> [Partition] {
        let lo = format == .fat32 ? minimumFAT32MB : minimumMB
        guard (lo...maximumMB(format)).contains(totalMB) else { throw MakeError.sizeOutOfRange(totalMB, format) }
        let totalSectors = totalMB * megabyte / Int64(sectorSize)
        let usable = totalSectors - firstPartitionLBA
        switch format {
        case .fat32:
            let spc = fat32SectorsPerCluster(sectors: usable)
            return [Partition(startLBA: firstPartitionLBA, sectors: usable, sectorsPerCluster: spc,
                              fatSectors: fatSectors(usable, spc: spc, reserved: 32, rootEntries: 0, entryBytes: 4),
                              reserved: 32, rootEntries: 0, format: .fat32)]
        case .fat16:
            let maxSectors = maxFAT16PartitionMB * megabyte / Int64(sectorSize)
            let count = Int((usable + maxSectors - 1) / maxSectors)
            let each = usable / Int64(count)
            var out: [Partition] = []
            var lba = firstPartitionLBA
            for i in 0..<count {
                let sectors = i == count - 1 ? totalSectors - lba : each
                var spc = fat16SectorsPerCluster(sectors: sectors)
                func make(_ spc: Int) -> Partition {
                    Partition(startLBA: lba, sectors: sectors, sectorsPerCluster: spc,
                              fatSectors: fatSectors(sectors, spc: spc, reserved: 1, rootEntries: 512, entryBytes: 2),
                              reserved: 1, rootEntries: 512, format: .fat16)
                }
                var p = make(spc)
                while clusters(p) > 65524 && spc < 64 { spc *= 2; p = make(spc) }
                out.append(p)
                lba += sectors
            }
            return out
        }
    }

    static func clusters(_ p: Partition) -> Int {
        let rootSectors = p.rootEntries * 32 / sectorSize
        return (Int(p.sectors) - p.reserved - 2 * p.fatSectors - rootSectors) / p.sectorsPerCluster
    }

    static func fat16SectorsPerCluster(sectors: Int64) -> Int {
        switch sectors * Int64(sectorSize) / megabyte {
        case ..<128: return 4
        case ..<256: return 8
        case ..<512: return 16
        case ..<1024: return 32
        default: return 64
        }
    }

    /// Microsoft's default FAT32 cluster sizes.
    static func fat32SectorsPerCluster(sectors: Int64) -> Int {
        switch sectors * Int64(sectorSize) / megabyte {
        case ..<260: return 1
        case ..<8192: return 8
        case ..<16384: return 16
        case ..<32768: return 32
        default: return 64
        }
    }

    /// Sectors per FAT, by the formula in Microsoft's FAT specification.
    static func fatSectors(_ total: Int64, spc: Int, reserved: Int, rootEntries: Int, entryBytes: Int) -> Int {
        let rootSectors = Int64(rootEntries * 32 / sectorSize)
        let tmp1 = total - (Int64(reserved) + rootSectors)
        var tmp2 = Int64(256 * spc + 2)
        if entryBytes == 4 { tmp2 /= 2 }
        return Int((tmp1 + tmp2 - 1) / tmp2)
    }

    /// Writes a new hard disk image of `totalMB` to `url` (replacing any file there).
    /// Returns the number of partitions.
    @discardableResult
    public static func createHardDisk(at url: URL, totalMB: Int64, format: Format, label: String) throws -> Int {
        let parts = try layout(totalMB: totalMB, format: format)
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw MakeError.cannotWrite("Check you can save to that folder.")
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(totalMB * megabyte))
            func write(_ bytes: [UInt8], atSector sector: Int64) throws {
                try handle.seek(toOffset: UInt64(sector * Int64(sectorSize)))
                try handle.write(contentsOf: Data(bytes))
            }
            try write(masterBootRecord(parts), atSector: 0)
            let labels = partitionLabels(label, count: parts.count)
            for (i, p) in parts.enumerated() {
                let boot = bootSector(p, label: labels[i])
                try write(boot, atSector: p.startLBA)
                if p.format == .fat32 {
                    try write(fsInfo(p), atSector: p.startLBA + 1)
                    try write(boot, atSector: p.startLBA + 6)                 // backup boot sector
                    try write(fsInfo(p), atSector: p.startLBA + 7)
                    // FAT: media, end marker, and cluster 2 (the top level) ends its chain.
                    let start: [UInt8] = [0xF8, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0xFF, 0x0F]
                    for copy in 0..<2 { try write(start, atSector: p.startLBA + Int64(p.reserved + copy * p.fatSectors)) }
                    // The top-level directory's cluster: zeroed, then the label.
                    let dataStart = p.startLBA + Int64(p.reserved + 2 * p.fatSectors)
                    try write([UInt8](repeating: 0, count: p.sectorsPerCluster * sectorSize), atSector: dataStart)
                    if !labels[i].isEmpty { try write(labelEntry(labels[i]), atSector: dataStart) }
                } else {
                    let start: [UInt8] = [0xF8, 0xFF, 0xFF, 0xFF]
                    for copy in 0..<2 { try write(start, atSector: p.startLBA + Int64(p.reserved + copy * p.fatSectors)) }
                    if !labels[i].isEmpty { try write(labelEntry(labels[i]), atSector: p.startLBA + Int64(p.reserved + 2 * p.fatSectors)) }
                }
            }
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw (error as? MakeError) ?? MakeError.cannotWrite(error.localizedDescription)
        }
        return parts.count
    }

    static func partitionLabels(_ name: String, count: Int) -> [String] {
        let base = volumeLabel(name)
        guard count > 1, !base.isEmpty else { return Array(repeating: base, count: count) }
        let letters = Array("ABCD")
        return (0..<count).map { String(base.prefix(9)) + "_\(letters[$0])" }
    }

    /// A volume label: up to 11 characters of what DOS allows, uppercase.
    public static func volumeLabel(_ name: String) -> String {
        let bad = Set("*?/\\|,;:+=<>[]\".")
        return String(name.uppercased().filter { $0.isASCII && !bad.contains($0) && ($0.asciiValue ?? 0) >= 32 }.prefix(11))
            .trimmingCharacters(in: .whitespaces)
    }

    static func padded(_ s: String) -> [UInt8] { Array(s.padding(toLength: 11, withPad: " ", startingAt: 0).utf8) }

    static func masterBootRecord(_ parts: [Partition]) -> [UInt8] {
        var mbr = [UInt8](repeating: 0, count: sectorSize)
        for (i, p) in parts.prefix(4).enumerated() {
            let e = 446 + i * 16
            mbr.replaceSubrange((e + 1)..<(e + 4), with: chs(p.startLBA))
            mbr[e + 4] = p.format == .fat32 ? 0x0C : 0x06
            mbr.replaceSubrange((e + 5)..<(e + 8), with: chs(p.startLBA + p.sectors - 1))
            mbr.replaceSubrange((e + 8)..<(e + 12), with: bytes32(Int(p.startLBA)))
            mbr.replaceSubrange((e + 12)..<(e + 16), with: bytes32(Int(p.sectors)))
        }
        mbr[510] = 0x55
        mbr[511] = 0xAA
        return mbr
    }

    static func bootSector(_ p: Partition, label: String) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: sectorSize)
        s.replaceSubrange(0..<3, with: p.format == .fat32 ? [0xEB, 0x58, 0x90] : [0xEB, 0x3C, 0x90])
        s.replaceSubrange(3..<11, with: Array("MSWIN4.1".utf8))
        s.replaceSubrange(11..<13, with: bytes16(sectorSize))
        s[13] = UInt8(p.sectorsPerCluster)
        s.replaceSubrange(14..<16, with: bytes16(p.reserved))
        s[16] = 2
        s.replaceSubrange(17..<19, with: bytes16(p.rootEntries))
        if p.format == .fat16 && p.sectors < 65536 { s.replaceSubrange(19..<21, with: bytes16(Int(p.sectors))) }
        s[21] = 0xF8
        if p.format == .fat16 { s.replaceSubrange(22..<24, with: bytes16(p.fatSectors)) }
        s.replaceSubrange(24..<26, with: bytes16(63))
        s.replaceSubrange(26..<28, with: bytes16(255))
        s.replaceSubrange(28..<32, with: bytes32(Int(p.startLBA)))
        if p.format == .fat32 || p.sectors >= 65536 { s.replaceSubrange(32..<36, with: bytes32(Int(p.sectors))) }
        let serial = bytes32(Int(UInt32.random(in: 1...UInt32.max)))
        let name = padded(label.isEmpty ? "NO NAME" : label)
        if p.format == .fat32 {
            s.replaceSubrange(36..<40, with: bytes32(p.fatSectors))
            s.replaceSubrange(44..<48, with: bytes32(2))      // top level starts at cluster 2
            s.replaceSubrange(48..<50, with: bytes16(1))      // FSInfo sector
            s.replaceSubrange(50..<52, with: bytes16(6))      // backup boot sector
            s[64] = 0x80
            s[66] = 0x29
            s.replaceSubrange(67..<71, with: serial)
            s.replaceSubrange(71..<82, with: name)
            s.replaceSubrange(82..<90, with: Array("FAT32   ".utf8))
        } else {
            s[36] = 0x80
            s[38] = 0x29
            s.replaceSubrange(39..<43, with: serial)
            s.replaceSubrange(43..<54, with: name)
            s.replaceSubrange(54..<62, with: Array("FAT16   ".utf8))
        }
        s[510] = 0x55
        s[511] = 0xAA
        return s
    }

    static func fsInfo(_ p: Partition) -> [UInt8] {
        var s = [UInt8](repeating: 0, count: sectorSize)
        s.replaceSubrange(0..<4, with: bytes32(0x4161_5252))
        s.replaceSubrange(484..<488, with: bytes32(0x6141_7272))
        s.replaceSubrange(488..<492, with: bytes32(clusters(p) - 1))   // all free but the top level
        s.replaceSubrange(492..<496, with: bytes32(3))
        s[510] = 0x55
        s[511] = 0xAA
        return s
    }

    static func labelEntry(_ label: String) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 32)
        e.replaceSubrange(0..<11, with: padded(label))
        e[11] = 0x08
        return e
    }

    static func chs(_ lba: Int64) -> [UInt8] {
        let heads: Int64 = 255, spt: Int64 = 63
        var c = lba / (heads * spt)
        var h = (lba / spt) % heads
        var s = lba % spt + 1
        if c > 1023 { c = 1023; h = 254; s = 63 }
        return [UInt8(h), UInt8(s | ((c >> 2) & 0xC0)), UInt8(c & 0xFF)]
    }
}
