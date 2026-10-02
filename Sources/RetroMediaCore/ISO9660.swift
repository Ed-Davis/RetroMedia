import Foundation

/// A CD image (.iso), read-only: ISO 9660, using the Joliet long names when
/// the disc has them (most PC CDs since Windows 95 do).
public final class ISO9660Image: @unchecked Sendable {
    public let file: ImageFile
    public let volumeName: String
    public let usesJoliet: Bool
    public let totalBytes: Int64
    let root: Extent

    static let sectorSize = 2048

    struct Extent: Hashable, Sendable {
        var parts: [(lba: UInt32, size: UInt32)]
        static func == (a: Extent, b: Extent) -> Bool { a.parts.map(\.lba) == b.parts.map(\.lba) && a.parts.map(\.size) == b.parts.map(\.size) }
        func hash(into h: inout Hasher) { for p in parts { h.combine(p.lba); h.combine(p.size) } }
        var size: Int64 { parts.reduce(0) { $0 + Int64($1.size) } }
    }

    /// A file or folder on the disc.
    public struct Entry: Hashable, Identifiable, Sendable {
        public let name: String
        public let isDirectory: Bool
        public let size: Int64
        public let modified: Date?
        public let isHidden: Bool
        let extent: Extent
        public var id: String { "\(extent.parts.first?.lba ?? 0):\(name)" }
    }

    public init(url: URL) throws {
        file = try ImageFile(url: url, writable: false)
        var primary: [UInt8]?
        var joliet: [UInt8]?
        var sector = 16
        while sector < 64 {
            let d = try file.read(at: UInt64(sector * Self.sectorSize), count: Self.sectorSize)
            guard String(decoding: d[1..<6], as: UTF8.self) == "CD001" else { break }
            if d[0] == 1 && primary == nil { primary = d }
            if d[0] == 2, d[88] == 0x25, d[89] == 0x2F, [0x40, 0x43, 0x45].contains(d[90]) { joliet = d }
            if d[0] == 255 { break }
            sector += 1
        }
        guard let descriptor = joliet ?? primary else {
            throw MediaError.notRecognised("This isn't an ISO 9660 CD image (it may be a UDF-only DVD, a raw .bin, or another kind of disk image).")
        }
        usesJoliet = joliet != nil
        let rec = Array(descriptor[156..<190])
        root = Extent(parts: [(UInt32(le32(rec, 2)), UInt32(le32(rec, 10)))])
        let rawName = Array(descriptor[40..<72])
        volumeName = (usesJoliet ? Self.ucs2(rawName) : String(decoding: rawName, as: UTF8.self))
            .trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        totalBytes = Int64(le32(Array(descriptor[80..<84]), 0)) * Int64(Self.sectorSize)
    }

    public var rootFolder: Entry {
        Entry(name: volumeName, isDirectory: true, size: root.size, modified: nil, isHidden: false, extent: root)
    }

    /// The contents of a folder (`nil` for the top level).
    public func list(_ folder: Entry?) throws -> [Entry] {
        let extent = folder?.extent ?? root
        let bytes = try read(extent)
        var out: [Entry] = []
        var pending: (name: String, parts: [(UInt32, UInt32)], first: [UInt8])?
        var o = 0
        var index = 0
        while o < bytes.count {
            let len = Int(bytes[o])
            if len == 0 {
                // Records never cross a sector boundary: skip to the next sector.
                o = (o / Self.sectorSize + 1) * Self.sectorSize
                continue
            }
            guard o + len <= bytes.count, len >= 34 else { break }
            let r = Array(bytes[o..<o + len])
            o += len
            index += 1
            let nameLength = Int(r[32])
            guard 33 + nameLength <= r.count else { continue }
            let rawName = Array(r[33..<33 + nameLength])
            if nameLength == 1 && (rawName[0] == 0 || rawName[0] == 1) { continue }   // "." and ".."
            let flags = r[25]
            let name = cleanName(rawName)
            let part = (UInt32(le32(r, 2)), UInt32(le32(r, 10)))
            if var p = pending, p.name == name {
                p.parts.append(part)
                pending = p
            } else {
                if let p = pending { out.append(makeEntry(p.name, parts: p.parts, record: p.first)) }
                pending = (name, [part], r)
            }
            // The last part of a multi-extent file has bit 7 clear.
            if flags & 0x80 == 0, let p = pending {
                out.append(makeEntry(p.name, parts: p.parts, record: p.first))
                pending = nil
            }
        }
        if let p = pending { out.append(makeEntry(p.name, parts: p.parts, record: p.first)) }
        return out
    }

    private func makeEntry(_ name: String, parts: [(UInt32, UInt32)], record r: [UInt8]) -> Entry {
        let extent = Extent(parts: parts.map { (lba: $0.0, size: $0.1) })
        return Entry(name: name, isDirectory: r[25] & 0x02 != 0, size: extent.size,
                     modified: Self.date(Array(r[18..<25])), isHidden: r[25] & 0x01 != 0, extent: extent)
    }

    private func cleanName(_ raw: [UInt8]) -> String {
        var name = usesJoliet ? Self.ucs2(raw) : String(decoding: raw, as: UTF8.self)
        if let semi = name.lastIndex(of: ";") { name = String(name[..<semi]) }   // ";1" version number
        if !usesJoliet && name.hasSuffix(".") { name.removeLast() }            // "README." → "README"
        return name
    }

    public func read(_ entry: Entry) throws -> Data {
        var out = Data()
        out.reserveCapacity(Int(entry.size))
        try read(entry) { out.append(contentsOf: $0) }
        return out
    }

    /// Reads a file in pieces (1 MB at a time), so large files don't have to fit in memory.
    public func read(_ entry: Entry, into sink: ([UInt8]) throws -> Void) throws {
        for part in entry.extent.parts {
            var done: Int64 = 0
            let size = Int64(part.size)
            while done < size {
                let n = Int(min(1_048_576, size - done))
                try sink(try file.read(at: UInt64(part.lba) * UInt64(Self.sectorSize) + UInt64(done), count: n))
                done += Int64(n)
            }
        }
    }

    private func read(_ extent: Extent) throws -> [UInt8] {
        var out: [UInt8] = []
        for part in extent.parts {
            out += try file.read(at: UInt64(part.lba) * UInt64(Self.sectorSize), count: Int(part.size))
        }
        return out
    }

    static func ucs2(_ raw: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < raw.count {
            units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func date(_ d: [UInt8]) -> Date? {
        guard d.count == 7, d[1] >= 1, d[1] <= 12, d[2] >= 1 else { return nil }
        var c = DateComponents()
        c.year = 1900 + Int(d[0])
        c.month = Int(d[1]); c.day = Int(d[2])
        c.hour = Int(d[3]); c.minute = Int(d[4]); c.second = Int(d[5])
        c.timeZone = TimeZone(secondsFromGMT: Int(Int8(bitPattern: d[6])) * 15 * 60)
        return Calendar(identifier: .gregorian).date(from: c)
    }
}
