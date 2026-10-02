import Foundation

// FAT12, FAT16 and FAT32, read and written directly inside an image file.
// Started from MPC Blaster 3's FAT code and extended for general use:
// FAT32, and long (VFAT) file names with an automatic 8.3 alias, the way
// Windows and macOS write them, so files keep their names.
//
// Write order is chosen so an interruption can only ever lose space, never
// corrupt existing files: new data first, then the allocation table, then the
// directory entries that make a file visible. Deleting does the reverse.

/// Where a directory's entries live: the top level, or a cluster chain.
public enum FATDirectory: Hashable, Sendable {
    case root
    case cluster(UInt32)
}

/// A file or folder in a FAT directory.
public struct FATEntry: Hashable, Identifiable, Sendable {
    /// The long name if there is one, otherwise the 8.3 name.
    public let name: String
    /// "NAME.EXT" as stored, which is what older machines see.
    public let shortName: String
    public let isDirectory: Bool
    public let size: UInt32
    public let firstCluster: UInt32
    public let modified: Date?
    /// FAT attribute bits (0x01 read-only, 0x02 hidden, 0x04 system, 0x10 folder…).
    public let attributes: UInt8
    public let parent: FATDirectory
    /// Slot numbers in the parent: any long-name slots, then the 8.3 slot.
    public let slots: [Int]

    public var id: String { "\(parent)#\(slots.last ?? -1)" }
    public var pathExtension: String { (name as NSString).pathExtension }
    public var asDirectory: FATDirectory { firstCluster == 0 ? .root : .cluster(firstCluster) }
    /// Files macOS leaves behind (.DS_Store, ._ resource forks, .Trashes…).
    public var isMacClutter: Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".Trashes" || name == ".fseventsd"
            || name == ".Spotlight-V100" || name == ".TemporaryItems"
    }
    public var isHidden: Bool { attributes & 0x02 != 0 }
}

public final class FATVolume: @unchecked Sendable {
    public enum Kind: String, Sendable { case fat12 = "FAT12", fat16 = "FAT16", fat32 = "FAT32" }

    public let image: ImageFile
    /// Byte offset of the volume in the image.
    public let offset: UInt64
    public let kind: Kind
    public private(set) var label: String

    let bytesPerSector: Int
    let sectorsPerCluster: Int
    let reservedSectors: Int
    let fatCount: Int
    let rootEntryCount: Int
    let totalSectors: Int
    let fatSectors: Int
    let clusterCount: Int
    let rootCluster: UInt32
    let fsInfoSector: Int

    public var clusterBytes: Int { bytesPerSector * sectorsPerCluster }
    private var rootDirSectors: Int { (rootEntryCount * 32 + bytesPerSector - 1) / bytesPerSector }
    private var firstRootSector: Int { reservedSectors + fatCount * fatSectors }
    private var firstDataSector: Int { firstRootSector + rootDirSectors }
    private var endOfChain: UInt32 {
        switch kind { case .fat12: return 0xFFF; case .fat16: return 0xFFFF; case .fat32: return 0x0FFF_FFFF }
    }
    private var endMarkerFloor: UInt32 {
        switch kind { case .fat12: return 0xFF8; case .fat16: return 0xFFF8; case .fat32: return 0x0FFF_FFF8 }
    }
    private var badCluster: UInt32 { endMarkerFloor - 1 }

    /// The allocation table, one value per cluster (0 and 1 are reserved).
    private var fat: [UInt32]
    /// The table as stored, kept in step with `fat` for the entries written.
    private var fatBytes: [UInt8]
    private var dirtyClusters = Set<Int>()
    private var freeCount: Int
    private var nextFreeHint = 2

    public var isWritable: Bool { image.isWritable }

    /// Reads the boot sector at `offset`. Throws if there isn't a FAT volume there.
    public init(image: ImageFile, offset: UInt64) throws {
        self.image = image
        self.offset = offset
        let b = try image.read(at: offset, count: 512)
        let bps = le16(b, 11)
        let spc = Int(b[13])
        let reserved = le16(b, 14)
        let fats = Int(b[16])
        let rootEntries = le16(b, 17)
        let total16 = le16(b, 19)
        let fatSize16 = le16(b, 22)
        let total32 = le32(b, 32)
        guard [512, 1024, 2048, 4096].contains(bps), spc > 0, spc & (spc - 1) == 0,
              reserved >= 1, (1...2).contains(fats) else { throw MediaError.notRecognised("No FAT filesystem here.") }
        let isFAT32Layout = fatSize16 == 0
        let fatSize = isFAT32Layout ? le32(b, 36) : fatSize16
        let total = total16 != 0 ? total16 : total32
        guard fatSize > 0, total > 0 else { throw MediaError.notRecognised("No FAT filesystem here.") }
        bytesPerSector = bps
        sectorsPerCluster = spc
        reservedSectors = reserved
        fatCount = fats
        rootEntryCount = isFAT32Layout ? 0 : rootEntries
        totalSectors = total
        fatSectors = fatSize
        let rootSectors = (rootEntryCount * 32 + bps - 1) / bps
        let dataSectors = total - (reserved + fats * fatSize + rootSectors)
        guard dataSectors > 0,
              offset + UInt64(total) * UInt64(bps) <= image.size + UInt64(bps) * 64 else {
            throw MediaError.notRecognised("No FAT filesystem here.")
        }
        clusterCount = dataSectors / spc
        if isFAT32Layout {
            kind = .fat32
            rootCluster = UInt32(le32(b, 44))
            fsInfoSector = le16(b, 48)
        } else {
            guard rootEntries > 0 else { throw MediaError.notRecognised("No FAT filesystem here.") }
            kind = clusterCount < 4085 ? .fat12 : .fat16
            rootCluster = 0
            fsInfoSector = 0
        }

        let entries = clusterCount + 2
        let tableBytes = min(fatSize * bps, kind == .fat32 ? entries * 4 + bps : fatSize * bps)
        let raw = try image.read(at: offset + UInt64(reserved * bps), count: tableBytes)
        fatBytes = raw
        var table = [UInt32](repeating: 0, count: entries)
        var free = 0
        for n in 0..<entries {
            table[n] = Self.decode(raw, n, kind)
            if n >= 2 && table[n] == 0 { free += 1 }
        }
        fat = table
        freeCount = free

        // Volume label: from the top-level directory if there is one, else the boot sector.
        let labelOffset = isFAT32Layout ? 71 : 43
        let signature = isFAT32Layout ? b[66] : b[38]
        label = signature == 0x29 ? String(decoding: b[labelOffset..<labelOffset + 11], as: UTF8.self).trimmingCharacters(in: .whitespaces) : ""
        if let rootLabel = try? readRootLabel() { label = rootLabel }
        if label == "NO NAME" { label = "" }
    }

    private func readRootLabel() throws -> String? {
        let bytes = try directoryBytes(.root)
        for slot in 0..<(bytes.count / 32) {
            let e = Array(bytes[slot * 32..<slot * 32 + 32])
            if e[0] == 0 { break }
            if e[0] != 0xE5 && e[11] != 0x0F && e[11] & 0x08 != 0 {
                return String(decoding: e[0..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: Space

    public var totalBytes: Int64 { Int64(clusterCount) * Int64(clusterBytes) }
    public var freeBytes: Int64 { Int64(freeCount) * Int64(clusterBytes) }

    public func bytesNeeded(forFileOfSize size: Int64) -> Int64 {
        let c = Int64(clusterBytes)
        return max(c, (size + c - 1) / c * c)
    }

    // MARK: Reading

    public func list(_ dir: FATDirectory) throws -> [FATEntry] {
        let bytes = try directoryBytes(dir)
        var out: [FATEntry] = []
        var longParts: [Int: String] = [:]
        var longSlots: [Int] = []
        var longChecksum: UInt8?
        for slot in 0..<(bytes.count / 32) {
            let e = Array(bytes[slot * 32..<slot * 32 + 32])
            if e[0] == 0 { break }
            if e[0] == 0xE5 { longParts = [:]; longSlots = []; longChecksum = nil; continue }
            if e[11] == 0x0F {
                if e[0] & 0x40 != 0 { longParts = [:]; longSlots = [] }
                longParts[Int(e[0] & 0x1F)] = Self.longNamePart(e)
                longSlots.append(slot)
                longChecksum = e[13]
                continue
            }
            defer { longParts = [:]; longSlots = []; longChecksum = nil }
            if e[11] & 0x08 != 0 { continue }            // volume label
            if e[0] == 0x2E { continue }                 // "." and ".."
            let short = Self.shortName(e)
            var display = short.display
            var slots = [slot]
            if !longParts.isEmpty, longChecksum == Self.checksum(Array(e[0..<11])) {
                display = longParts.keys.sorted().compactMap { longParts[$0] }.joined()
                slots = longSlots + [slot]
            }
            out.append(FATEntry(name: display, shortName: short.plain,
                                isDirectory: e[11] & 0x10 != 0,
                                size: UInt32(le32(e, 28)),
                                firstCluster: entryCluster(e),
                                modified: Self.date(le16(e, 24), le16(e, 22)),
                                attributes: e[11],
                                parent: dir, slots: slots))
        }
        return out
    }

    private func entryCluster(_ e: [UInt8]) -> UInt32 {
        let lo = UInt32(le16(e, 26))
        return kind == .fat32 ? lo | UInt32(le16(e, 20)) << 16 : lo
    }

    public func read(_ entry: FATEntry) throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(entry.size))
        try read(entry) { out.append(contentsOf: $0) }
        return out
    }

    /// Reads a file cluster by cluster, handing each piece to `sink`, so large
    /// files don't have to fit in memory.
    public func read(_ entry: FATEntry, into sink: ([UInt8]) throws -> Void) throws {
        guard !entry.isDirectory else { throw MediaError.io("\(entry.name) is a folder.") }
        var remaining = Int(entry.size)
        guard remaining > 0 else { return }
        for cluster in try chain(from: entry.firstCluster) {
            let want = min(clusterBytes, remaining)
            try sink(try image.read(at: clusterOffset(cluster), count: want))
            remaining -= want
            if remaining == 0 { break }
        }
        guard remaining == 0 else { throw MediaError.corrupt("\(entry.name) is shorter than its directory entry says") }
    }

    // MARK: Writing

    /// Writes a new file from `data`. See `createFile(in:name:size:source:)`.
    @discardableResult
    public func createFile(in dir: FATDirectory, name: String, contents data: Data,
                           modified: Date = Date(), progress: ((Double) -> Void)? = nil) throws -> FATEntry {
        try createFile(in: dir, name: name, size: Int64(data.count), modified: modified, progress: progress) { offset, count in
            let lo = data.startIndex + Int(offset)
            return [UInt8](data[lo..<lo + count])
        }
    }

    /// Writes a new file, asking `source` for its bytes a cluster at a time.
    /// `name` is kept as it is (long names get an 8.3 alias); it must not be in use.
    @discardableResult
    public func createFile(in dir: FATDirectory, name: String, size: Int64, modified: Date = Date(),
                           progress: ((Double) -> Void)? = nil,
                           source: (_ offset: Int64, _ count: Int) throws -> [UInt8]) throws -> FATEntry {
        guard isWritable else { throw MediaError.readOnly }
        guard size < Int64(UInt32.max) else {
            throw MediaError.unsupported("\(name) is 4 GB or more, which FAT can't hold.")
        }
        let entries = try nameEntries(for: name, in: dir)
        let count = Int((size + Int64(clusterBytes) - 1) / Int64(clusterBytes))
        let clusters = count == 0 ? [] : try allocate(count: count)
        do {
            // 1. Data.
            for (i, cluster) in clusters.enumerated() {
                let lo = Int64(i) * Int64(clusterBytes)
                let n = Int(min(Int64(clusterBytes), size - lo))
                var chunk = try source(lo, n)
                if chunk.count < clusterBytes { chunk += [UInt8](repeating: 0, count: clusterBytes - chunk.count) }
                try image.write(chunk, at: clusterOffset(cluster))
                progress?(Double(i + 1) / Double(clusters.count))
            }
            // 2. Allocation table.
            try writeFAT()
            // 3. The directory entries that make it visible.
            let short = makeEntry(entries.short, flags: entries.flags, attributes: 0x20,
                                  cluster: clusters.first ?? 0, size: UInt32(size), date: modified)
            let slot = try addEntries(entries.long + [short], to: dir)
            image.flush()
            return try entryAt(slot: slot, in: dir)
        } catch {
            free(clusters)
            try? writeFAT()
            throw error
        }
    }

    @discardableResult
    public func createDirectory(in dir: FATDirectory, name: String, modified: Date = Date()) throws -> FATEntry {
        guard isWritable else { throw MediaError.readOnly }
        let entries = try nameEntries(for: name, in: dir)
        let cluster = try allocate(count: 1)[0]
        do {
            var block = [UInt8](repeating: 0, count: clusterBytes)
            var parentCluster: UInt32 = 0
            if case .cluster(let c) = dir, c != rootCluster { parentCluster = c }
            block.replaceSubrange(0..<32, with: makeEntry(Array(".          ".utf8), flags: 0, attributes: 0x10, cluster: cluster, size: 0, date: modified))
            block.replaceSubrange(32..<64, with: makeEntry(Array("..         ".utf8), flags: 0, attributes: 0x10, cluster: parentCluster, size: 0, date: modified))
            try image.write(block, at: clusterOffset(cluster))
            try writeFAT()
            let short = makeEntry(entries.short, flags: entries.flags, attributes: 0x10, cluster: cluster, size: 0, date: modified)
            let slot = try addEntries(entries.long + [short], to: dir)
            image.flush()
            return try entryAt(slot: slot, in: dir)
        } catch {
            free([cluster])
            try? writeFAT()
            throw error
        }
    }

    /// Deletes a file, or a folder and everything in it.
    public func delete(_ entry: FATEntry) throws {
        guard isWritable else { throw MediaError.readOnly }
        if entry.isDirectory && entry.firstCluster >= 2 {
            // Last slot first, so earlier slots stay where they are.
            for child in try list(entry.asDirectory).sorted(by: { ($0.slots.last ?? 0) > ($1.slots.last ?? 0) }) {
                try delete(child)
            }
        }
        // Directory entries first, so a crash leaves unused space rather than
        // a file pointing at freed clusters.
        for slot in entry.slots {
            try image.write([0xE5], at: try slotOffset(slot, in: entry.parent))
        }
        if entry.firstCluster >= 2 {
            free(try chain(from: entry.firstCluster))
            try writeFAT()
        }
        image.flush()
    }

    /// Renames, keeping the file's data, dates and attributes.
    @discardableResult
    public func rename(_ entry: FATEntry, to name: String) throws -> FATEntry {
        guard isWritable else { throw MediaError.readOnly }
        guard let shortSlot = entry.slots.last else { return entry }
        let shortOffset = try slotOffset(shortSlot, in: entry.parent)
        let old = try image.read(at: shortOffset, count: 32)
        let entries = try nameEntries(for: name, in: entry.parent, ignoring: entry)
        var short = old
        short.replaceSubrange(0..<11, with: entries.short)
        short[12] = entries.flags
        // Old name off first, then the new one on (it may need different slots).
        for slot in entry.slots { try image.write([0xE5], at: try slotOffset(slot, in: entry.parent)) }
        let slot = try addEntries(entries.long + [short], to: entry.parent)
        image.flush()
        return try entryAt(slot: slot, in: entry.parent)
    }

    /// Names in use in a directory, uppercase: both long and 8.3 names.
    public func names(in dir: FATDirectory) throws -> Set<String> {
        var out = Set<String>()
        for e in try list(dir) {
            out.insert(e.name.uppercased())
            out.insert(e.shortName.uppercased())
        }
        return out
    }

    /// Sets the volume label (up to 11 characters, as DOS shows it).
    public func setLabel(_ raw: String) throws {
        guard isWritable else { throw MediaError.readOnly }
        let text = String(raw.uppercased().unicodeScalars.filter { $0.isASCII && $0.value >= 32 && !"*?/\\|,;:+=<>[]\"".unicodeScalars.contains($0) }.map(Character.init))
        let label = String(text.prefix(11))
        let padded = Array(label.padding(toLength: 11, withPad: " ", startingAt: 0).utf8)
        // Boot sector copy.
        let at = UInt64(kind == .fat32 ? 71 : 43)
        let b = try image.read(at: offset, count: 512)
        if b[kind == .fat32 ? 66 : 38] == 0x29 { try image.write(padded, at: offset + at) }
        // Directory copy: replace an existing label entry, or add one.
        let bytes = try directoryBytes(.root)
        var done = false
        for slot in 0..<(bytes.count / 32) {
            let e = Array(bytes[slot * 32..<slot * 32 + 32])
            if e[0] == 0 { break }
            if e[0] != 0xE5 && e[11] != 0x0F && e[11] & 0x08 != 0 {
                if label.isEmpty {
                    try image.write([0xE5], at: try slotOffset(slot, in: .root))
                } else {
                    try image.write(padded, at: try slotOffset(slot, in: .root))
                }
                done = true
                break
            }
        }
        if !done && !label.isEmpty {
            var e = [UInt8](repeating: 0, count: 32)
            e.replaceSubrange(0..<11, with: padded)
            e[11] = 0x08
            _ = try addEntries([e], to: .root)
        }
        image.flush()
        self.label = label
    }

    // MARK: Internals: clusters

    private func clusterOffset(_ cluster: UInt32) -> UInt64 {
        let sector: Int = firstDataSector + (Int(cluster) - 2) * sectorsPerCluster
        return offset + UInt64(sector) * UInt64(bytesPerSector)
    }

    func chain(from start: UInt32) throws -> [UInt32] {
        var out: [UInt32] = []
        var c = start
        var seen = Set<UInt32>()
        while c >= 2 && c < endMarkerFloor {
            guard Int(c) < fat.count, c != badCluster, seen.insert(c).inserted else {
                throw MediaError.corrupt("a broken cluster chain")
            }
            out.append(c)
            c = fat[Int(c)]
        }
        return out
    }

    private func allocate(count: Int) throws -> [UInt32] {
        guard count <= freeCount else {
            throw MediaError.diskFull(needed: Int64(count) * Int64(clusterBytes), free: freeBytes)
        }
        var picked: [UInt32] = []
        picked.reserveCapacity(count)
        var n = nextFreeHint
        var scanned = 0
        while picked.count < count && scanned < fat.count {
            if n >= fat.count { n = 2 }
            if fat[n] == 0 { picked.append(UInt32(n)) }
            n += 1
            scanned += 1
        }
        guard picked.count == count else {
            throw MediaError.diskFull(needed: Int64(count) * Int64(clusterBytes), free: freeBytes)
        }
        for (i, c) in picked.enumerated() {
            setFAT(Int(c), i + 1 < picked.count ? picked[i + 1] : endOfChain)
        }
        freeCount -= count
        nextFreeHint = n
        return picked
    }

    private func free(_ clusters: [UInt32]) {
        for c in clusters where fat[Int(c)] != 0 {
            setFAT(Int(c), 0)
            freeCount += 1
        }
        if let first = clusters.min() { nextFreeHint = min(nextFreeHint, Int(first)) }
    }

    private func setFAT(_ n: Int, _ value: UInt32) {
        fat[n] = value
        dirtyClusters.insert(n)
    }

    private func writeFAT() throws {
        guard !dirtyClusters.isEmpty else { return }
        var sectors = Set<Int>()
        for n in dirtyClusters {
            Self.encode(&fatBytes, n, fat[n], kind)
            let byte = kind == .fat32 ? 4 * n : kind == .fat16 ? 2 * n : n + n / 2
            sectors.insert(byte / bytesPerSector)
            sectors.insert((byte + (kind == .fat32 ? 3 : 1)) / bytesPerSector)
        }
        dirtyClusters = []
        let base = offset + UInt64(reservedSectors * bytesPerSector)
        for sector in sectors.sorted() {
            let lo = sector * bytesPerSector
            guard lo < fatBytes.count else { continue }
            let chunk = Array(fatBytes[lo..<min(lo + bytesPerSector, fatBytes.count)])
            for copy in 0..<fatCount {
                try image.write(chunk, at: base + UInt64(copy * fatSectors * bytesPerSector + lo))
            }
        }
        if kind == .fat32 && fsInfoSector > 0 && fsInfoSector < reservedSectors {
            let at = offset + UInt64(fsInfoSector * bytesPerSector)
            let info = try image.read(at: at, count: 512)
            if le32(info, 0) == 0x4161_5252 && le32(info, 484) == 0x6141_7272 {
                try image.write(bytes32(freeCount) + bytes32(nextFreeHint), at: at + 488)
            }
        }
    }

    static func decode(_ raw: [UInt8], _ n: Int, _ kind: Kind) -> UInt32 {
        switch kind {
        case .fat32:
            guard 4 * n + 3 < raw.count else { return 0 }
            return UInt32(le32(raw, 4 * n)) & 0x0FFF_FFFF
        case .fat16:
            guard 2 * n + 1 < raw.count else { return 0 }
            return UInt32(le16(raw, 2 * n))
        case .fat12:
            let i = n + n / 2
            guard i + 1 < raw.count else { return 0 }
            let v = UInt32(le16(raw, i))
            return n & 1 == 0 ? v & 0xFFF : v >> 4
        }
    }

    static func encode(_ raw: inout [UInt8], _ n: Int, _ value: UInt32, _ kind: Kind) {
        switch kind {
        case .fat32:
            guard 4 * n + 3 < raw.count else { return }
            // The top four bits are reserved and kept as they were.
            let keep = UInt32(raw[4 * n + 3]) & 0xF0
            let v = (value & 0x0FFF_FFFF) | keep << 24
            for i in 0..<4 { raw[4 * n + i] = UInt8(v >> (8 * UInt32(i)) & 0xFF) }
        case .fat16:
            guard 2 * n + 1 < raw.count else { return }
            raw[2 * n] = UInt8(value & 0xFF)
            raw[2 * n + 1] = UInt8(value >> 8 & 0xFF)
        case .fat12:
            let i = n + n / 2
            guard i + 1 < raw.count else { return }
            if n & 1 == 0 {
                raw[i] = UInt8(value & 0xFF)
                raw[i + 1] = (raw[i + 1] & 0xF0) | UInt8(value >> 8 & 0x0F)
            } else {
                raw[i] = (raw[i] & 0x0F) | UInt8(value << 4 & 0xF0)
                raw[i + 1] = UInt8(value >> 4 & 0xFF)
            }
        }
    }

    // MARK: Internals: directories

    /// The cluster a directory starts at (FAT32's top level is a cluster chain too).
    private func startCluster(_ dir: FATDirectory) -> UInt32? {
        switch dir {
        case .root: return kind == .fat32 ? rootCluster : nil
        case .cluster(let c): return c
        }
    }

    private func directoryBytes(_ dir: FATDirectory) throws -> [UInt8] {
        if let start = startCluster(dir) {
            var out: [UInt8] = []
            for c in try chain(from: start) { out += try image.read(at: clusterOffset(c), count: clusterBytes) }
            return out
        }
        return try image.read(at: offset + UInt64(firstRootSector * bytesPerSector), count: rootEntryCount * 32)
    }

    private func slotOffset(_ slot: Int, in dir: FATDirectory) throws -> UInt64 {
        if let start = startCluster(dir) {
            let perCluster = clusterBytes / 32
            let clusters = try chain(from: start)
            guard slot / perCluster < clusters.count else { throw MediaError.corrupt("a directory slot out of range") }
            return clusterOffset(clusters[slot / perCluster]) + UInt64(slot % perCluster * 32)
        }
        guard slot < rootEntryCount else { throw MediaError.corrupt("a directory slot out of range") }
        return offset + UInt64(firstRootSector * bytesPerSector + slot * 32)
    }

    private func entryAt(slot: Int, in dir: FATDirectory) throws -> FATEntry {
        guard let entry = try list(dir).first(where: { $0.slots.last == slot }) else {
            throw MediaError.corrupt("a new entry couldn't be read back")
        }
        return entry
    }

    /// Writes `entries` into consecutive free slots (growing a folder if it
    /// must) and returns the slot of the last one.
    private func addEntries(_ entries: [[UInt8]], to dir: FATDirectory) throws -> Int {
        let needed = entries.count
        for _ in 0..<64 {
            let bytes = try directoryBytes(dir)
            let total = bytes.count / 32
            var run = 0
            var ended = false
            for slot in 0..<total {
                let first = bytes[slot * 32]
                if first == 0 { ended = true }
                if ended || first == 0xE5 {
                    run += 1
                    if run == needed {
                        let start = slot - needed + 1
                        for (i, e) in entries.enumerated() {
                            try image.write(e, at: try slotOffset(start + i, in: dir))
                        }
                        return slot
                    }
                } else {
                    run = 0
                }
            }
            guard let start = startCluster(dir) else {
                throw MediaError.directoryFull("The top level of this disk")
            }
            // Grow the folder by one zeroed cluster and try again.
            let last = try chain(from: start).last ?? start
            let added = try allocate(count: 1)[0]
            try image.write([UInt8](repeating: 0, count: clusterBytes), at: clusterOffset(added))
            setFAT(Int(last), added)
            try writeFAT()
        }
        throw MediaError.directoryFull("This folder")
    }

    // MARK: Names

    /// The directory entries for a name: long-name slots (if needed) and the
    /// 8.3 name with its lowercase flags.
    private func nameEntries(for rawName: String, in dir: FATDirectory, ignoring: FATEntry? = nil)
        throws -> (long: [[UInt8]], short: [UInt8], flags: UInt8) {
        let name = try FATNames.validated(rawName)
        let existing = try list(dir).filter { $0.slots.last != ignoring?.slots.last }
        let upper = name.uppercased()
        if existing.contains(where: { $0.name.uppercased() == upper || $0.shortName.uppercased() == upper }) {
            throw MediaError.nameTaken(name)
        }
        if let exact = FATNames.exactShortName(name) {
            return ([], exact.raw, exact.flags)
        }
        let taken = Set(existing.map { $0.shortName.uppercased() })
        let alias = FATNames.alias(for: name, taken: taken)
        return (FATNames.longEntries(name, checksum: Self.checksum(alias)), alias, 0)
    }

    static func shortName(_ e: [UInt8]) -> (plain: String, display: String) {
        var baseBytes = Array(e[0..<8])
        if baseBytes[0] == 0x05 { baseBytes[0] = 0xE5 }
        let base = String(decoding: baseBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let ext = String(decoding: e[8..<11], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let plain = ext.isEmpty ? base : base + "." + ext
        let flags = e.count > 12 ? e[12] : 0
        let dBase = flags & 0x08 != 0 ? base.lowercased() : base
        let dExt = flags & 0x10 != 0 ? ext.lowercased() : ext
        return (plain, dExt.isEmpty ? dBase : dBase + "." + dExt)
    }

    static func longNamePart(_ e: [UInt8]) -> String {
        var units: [UInt16] = []
        for range in [1..<11, 14..<26, 28..<32] {
            var i = range.lowerBound
            while i < range.upperBound {
                units.append(UInt16(le16(e, i)))
                i += 2
            }
        }
        if let end = units.firstIndex(where: { $0 == 0 || $0 == 0xFFFF }) { units = Array(units[..<end]) }
        return String(decoding: units, as: UTF16.self)
    }

    static func checksum(_ name: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for b in name { sum = (sum & 1 != 0 ? 0x80 : 0) &+ (sum >> 1) &+ b }
        return sum
    }

    private func makeEntry(_ name: [UInt8], flags: UInt8, attributes: UInt8, cluster: UInt32, size: UInt32, date: Date) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 32)
        e.replaceSubrange(0..<11, with: name)
        e[11] = attributes
        e[12] = flags
        let (d, t) = Self.dosDateTime(date)
        e.replaceSubrange(14..<16, with: bytes16(Int(t)))   // created
        e.replaceSubrange(16..<18, with: bytes16(Int(d)))
        e.replaceSubrange(18..<20, with: bytes16(Int(d)))   // accessed
        if kind == .fat32 { e.replaceSubrange(20..<22, with: bytes16(Int(cluster >> 16))) }
        e.replaceSubrange(22..<24, with: bytes16(Int(t)))   // modified
        e.replaceSubrange(24..<26, with: bytes16(Int(d)))
        e.replaceSubrange(26..<28, with: bytes16(Int(cluster & 0xFFFF)))
        e.replaceSubrange(28..<32, with: bytes32(Int(size)))
        return e
    }

    static func dosDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max(0, min(127, (c.year ?? 1980) - 1980))
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let d: Int = (year << 9) | (month << 5) | day
        let t: Int = (hour << 11) | (minute << 5) | (second / 2)
        return (UInt16(d), UInt16(t))
    }

    static func date(_ d: Int, _ t: Int) -> Date? {
        guard d != 0 else { return nil }
        var c = DateComponents()
        c.year = 1980 + (d >> 9)
        c.month = d >> 5 & 0x0F
        c.day = d & 0x1F
        c.hour = t >> 11
        c.minute = t >> 5 & 0x3F
        c.second = (t & 0x1F) * 2
        return Calendar.current.date(from: c)
    }
}

/// FAT file names: long (VFAT) names stored as given, with the 8.3 alias
/// older machines see, made the way Windows makes them (LONGNA~1.TXT).
public enum FATNames {
    static let shortNameCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-!#$%&'()@^`{}~")
    /// Characters no FAT name can contain.
    public static let forbidden = Set("\\/:*?\"<>|")

    /// Checks a name can be stored. Names aren't changed: one FAT can't hold
    /// is refused with the reason.
    public static func validated(_ raw: String) throws -> String {
        let name = raw.precomposedStringWithCanonicalMapping
        if name.isEmpty || name == "." || name == ".." {
            throw MediaError.invalidName("A name can't be empty.")
        }
        if let bad = name.first(where: { forbidden.contains($0) || ($0.asciiValue ?? 32) < 32 }) {
            throw MediaError.invalidName("“\(name)” contains \(bad == "/" || bad == ":" ? "“\(bad)”" : "a character") that FAT disks can't store (\\ / : * ? \" < > |). Rename it first.")
        }
        if name.hasSuffix(".") || name.hasSuffix(" ") {
            throw MediaError.invalidName("“\(name)” ends with a dot or space, which FAT disks can't store. Rename it first.")
        }
        if name.utf16.count > 255 {
            throw MediaError.invalidName("“\(name.prefix(40))…” is longer than the 255 characters FAT allows.")
        }
        return name
    }

    /// The 8.3 entry for a name that needs no long name: valid 8.3, each part
    /// all upper or all lower case (lower case is kept with the flags Windows
    /// and macOS use).
    static func exactShortName(_ name: String) -> (raw: [UInt8], flags: UInt8)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              (1...8).contains(parts[0].count),
              parts.count == 1 || (1...3).contains(parts[1].count) else { return nil }
        var flags: UInt8 = 0
        for (i, part) in parts.enumerated() {
            let s = String(part)
            guard s.uppercased().allSatisfy({ shortNameCharacters.contains($0) }) else { return nil }
            let hasLower = s != s.uppercased(), hasUpper = s != s.lowercased()
            if hasLower && hasUpper { return nil }
            if hasLower { flags |= i == 0 ? 0x08 : 0x10 }
        }
        let upper = name.uppercased()
        let base = Array(String(parts[0]).uppercased().utf8)
        let ext = parts.count > 1 ? Array(String(parts[1]).uppercased().utf8) : []
        var raw = base + [UInt8](repeating: 0x20, count: 8 - base.count) + ext + [UInt8](repeating: 0x20, count: 3 - ext.count)
        if raw[0] == 0xE5 { raw[0] = 0x05 }
        _ = upper
        return (raw, flags)
    }

    /// A Windows-style 8.3 alias (LONGNA~1.TXT) not in `taken`.
    static func alias(for name: String, taken: Set<String>) -> [UInt8] {
        func clean(_ s: Substring) -> String {
            String(s.uppercased().compactMap { ch -> Character? in
                if ch == " " || ch == "." { return nil }
                return shortNameCharacters.contains(ch) ? ch : "_"
            })
        }
        let trimmed = name.drop { $0 == "." }
        let dot = trimmed.lastIndex(of: ".")
        var base = clean(dot.map { trimmed[..<$0] } ?? trimmed[...])
        let ext = String(clean(dot.map { trimmed[trimmed.index(after: $0)...] } ?? "").prefix(3))
        if base.isEmpty { base = "_" }
        for n in 1...999_999 {
            let tail = "~\(n)"
            let stem = String(base.prefix(8 - tail.count)) + tail
            let candidate = ext.isEmpty ? stem : stem + "." + ext
            if !taken.contains(candidate) {
                let b = Array(stem.utf8), e = Array(ext.utf8)
                return b + [UInt8](repeating: 0x20, count: 8 - b.count) + e + [UInt8](repeating: 0x20, count: 3 - e.count)
            }
        }
        return Array("_~999999   ".utf8)
    }

    /// Long-name directory entries, in the order they're stored (last part first).
    static func longEntries(_ name: String, checksum: UInt8) -> [[UInt8]] {
        var units = Array(name.utf16)
        let count = (units.count + 12) / 13
        if units.count % 13 != 0 {
            units.append(0)
            while units.count % 13 != 0 { units.append(0xFFFF) }
        }
        var out: [[UInt8]] = []
        for i in 0..<count {
            var e = [UInt8](repeating: 0, count: 32)
            e[0] = UInt8(i + 1) | (i == count - 1 ? 0x40 : 0)
            e[11] = 0x0F
            e[13] = checksum
            let part = Array(units[i * 13..<(i + 1) * 13])
            var positions: [Int] = []
            positions += stride(from: 1, to: 11, by: 2)
            positions += stride(from: 14, to: 26, by: 2)
            positions += stride(from: 28, to: 32, by: 2)
            for (u, p) in zip(part, positions) {
                e[p] = UInt8(u & 0xFF)
                e[p + 1] = UInt8(u >> 8)
            }
            out.append(e)
        }
        return out.reversed()
    }
}
