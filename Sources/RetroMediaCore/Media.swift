import Foundation

/// A place in a medium that holds items: the top level, or a folder.
public enum FolderRef: Hashable, Sendable {
    case root
    case fat(FATDirectory)
    case iso(ISO9660Image.Entry)
}

/// A file or folder on any medium.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Date?
    /// "Folder", "WAV file", "Akai sample"…
    public let kindLabel: String
    /// The name older machines see, if it's different (a FAT 8.3 alias).
    public let shortName: String?
    /// Files macOS leaves on disks (.DS_Store, ._ files). Hidden, and can be removed.
    public let isClutter: Bool
    let ref: Ref

    enum Ref: Hashable, Sendable {
        case fat(FATEntry)
        case akai(AkaiDisk.Entry)
        case iso(ISO9660Image.Entry)
    }

    public var pathExtension: String { (name as NSString).pathExtension }
}

/// Something RetroMedia can browse: a FAT volume (floppy, or one partition of
/// a hard disk image), an Akai S1000/S3000 floppy, or a CD image.
public protocol Medium: AnyObject {
    var url: URL { get }
    /// What the medium calls itself (volume label), if anything.
    var volumeName: String { get }
    /// "FAT16", "Akai S3000", "ISO 9660 (Joliet)"…
    var formatName: String { get }
    var isReadOnly: Bool { get }
    var supportsFolders: Bool { get }
    var totalBytes: Int64 { get }
    var freeBytes: Int64 { get }

    func list(_ folder: FolderRef) throws -> [MediaItem]
    func folder(of item: MediaItem) -> FolderRef?
    /// Reads a file in pieces.
    func read(_ item: MediaItem, into sink: ([UInt8]) throws -> Void) throws
    /// Adds a file; returns the name it was stored under.
    @discardableResult
    func addFile(named name: String, size: Int64, modified: Date, in folder: FolderRef,
                 source: (_ offset: Int64, _ count: Int) throws -> [UInt8]) throws -> String
    func makeFolder(named name: String, in folder: FolderRef) throws -> FolderRef
    func delete(_ items: [MediaItem]) throws
    @discardableResult
    func rename(_ item: MediaItem, to name: String) throws -> String
    /// Space a file of this size takes.
    func bytesNeeded(forFileOfSize size: Int64) -> Int64
    func setVolumeName(_ name: String) throws
}

public extension Medium {
    func read(_ item: MediaItem) throws -> Data {
        var out = Data()
        try read(item) { out.append(contentsOf: $0) }
        return out
    }

    @discardableResult
    func addFile(named name: String, contents: Data, modified: Date = Date(), in folder: FolderRef) throws -> String {
        try addFile(named: name, size: Int64(contents.count), modified: modified, in: folder) { offset, count in
            let lo = contents.startIndex + Int(offset)
            return [UInt8](contents[lo..<lo + count])
        }
    }
}

/// Describes a file by its extension, for the Kind column.
enum Kinds {
    static func label(forExtension ext: String, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        let e = ext.lowercased()
        let known: [String: String] = [
            "wav": "WAV audio", "aif": "AIFF audio", "aiff": "AIFF audio", "mp3": "MP3 audio", "snd": "Sound",
            "mid": "MIDI file", "txt": "Text", "pgm": "Program", "aps": "All programs", "all": "All sequences",
            "seq": "Sequence", "img": "Disk image", "iso": "CD image", "exe": "Program (DOS)", "com": "Program (DOS)",
            "bat": "Batch file", "zip": "ZIP archive", "lha": "LHA archive", "lzh": "LHA archive", "adf": "Amiga disk",
            "dsk": "Disk image", "hda": "Hard disk image", "bin": "Binary", "rom": "ROM image", "pdf": "PDF",
        ]
        if let k = known[e] { return k }
        return e.isEmpty ? "File" : e.uppercased() + " file"
    }
}

// MARK: - FAT

/// One FAT volume: a floppy, or a partition of a hard disk image.
public final class FATMedium: Medium, @unchecked Sendable {
    public let url: URL
    public let disk: FATDiskImage
    public let volume: FATVolume
    public let partition: Int

    public init(url: URL, disk: FATDiskImage, partition: Int) {
        self.url = url
        self.disk = disk
        self.partition = partition
        self.volume = disk.volumes[partition]
    }

    public var volumeName: String { volume.label }
    public var formatName: String { volume.kind.rawValue }
    public var isReadOnly: Bool { !volume.isWritable }
    public var supportsFolders: Bool { true }
    public var totalBytes: Int64 { volume.totalBytes }
    public var freeBytes: Int64 { volume.freeBytes }

    private func dir(_ folder: FolderRef) -> FATDirectory {
        if case .fat(let d) = folder { return d }
        return .root
    }

    public func list(_ folder: FolderRef) throws -> [MediaItem] {
        try volume.list(dir(folder)).map { e in
            MediaItem(id: e.id, name: e.name, isDirectory: e.isDirectory, size: Int64(e.size), modified: e.modified,
                      kindLabel: Kinds.label(forExtension: e.pathExtension, isDirectory: e.isDirectory),
                      shortName: e.shortName.uppercased() == e.name.uppercased() ? nil : e.shortName,
                      isClutter: e.isMacClutter, ref: .fat(e))
        }
    }

    public func folder(of item: MediaItem) -> FolderRef? {
        guard case .fat(let e) = item.ref, e.isDirectory else { return nil }
        return .fat(e.asDirectory)
    }

    public func read(_ item: MediaItem, into sink: ([UInt8]) throws -> Void) throws {
        guard case .fat(let e) = item.ref else { return }
        try volume.read(e, into: sink)
    }

    public func addFile(named name: String, size: Int64, modified: Date, in folder: FolderRef,
                        source: (Int64, Int) throws -> [UInt8]) throws -> String {
        try volume.createFile(in: dir(folder), name: name, size: size, modified: modified, source: source).name
    }

    public func makeFolder(named name: String, in folder: FolderRef) throws -> FolderRef {
        .fat(try volume.createDirectory(in: dir(folder), name: name).asDirectory)
    }

    public func delete(_ items: [MediaItem]) throws {
        let entries = items.compactMap { item -> FATEntry? in if case .fat(let e) = item.ref { return e }; return nil }
        // Last slot first, so earlier slots stay put while deleting.
        for e in entries.sorted(by: { ($0.slots.last ?? 0) > ($1.slots.last ?? 0) }) { try volume.delete(e) }
    }

    public func rename(_ item: MediaItem, to name: String) throws -> String {
        guard case .fat(let e) = item.ref else { return item.name }
        return try volume.rename(e, to: name).name
    }

    public func bytesNeeded(forFileOfSize size: Int64) -> Int64 { volume.bytesNeeded(forFileOfSize: size) }
    public func setVolumeName(_ name: String) throws { try volume.setLabel(name) }
}

// MARK: - Akai

/// An Akai S1000/S3000 floppy. Files go on and off exactly as they are, in
/// the raw form akaiutil and Floppy Blaster use (NAME.s3, NAME.p1…).
public final class AkaiMedium: Medium, @unchecked Sendable {
    public let url: URL
    public private(set) var disk: AkaiDisk
    public let isReadOnly: Bool

    public init(url: URL) throws {
        self.url = url
        disk = try AkaiDisk(contentsOf: url)
        isReadOnly = !FileManager.default.isWritableFile(atPath: url.path)
    }

    public var volumeName: String { disk.volumeName }
    public var formatName: String { disk.layout == .s3000 ? "Akai S3000" : "Akai S1000" }
    public var supportsFolders: Bool { false }
    public var totalBytes: Int64 { Int64(disk.usableBlocks) * 1024 }
    public var freeBytes: Int64 { Int64(disk.freeBlocks) * 1024 }

    /// The name a file has off the disk: NAME.s3, NAME.p1…
    static func exportName(_ e: AkaiDisk.Entry) -> String {
        let ext = rawExtension(e.type)
        return (e.name.isEmpty ? "UNNAMED" : e.name.replacingOccurrences(of: "/", with: "-")) + "." + ext
    }

    static func rawExtension(_ type: UInt8) -> String {
        let t = Int(type & 0x7F)
        guard (65...122).contains(t) else { return "bin" }
        return String(Character(UnicodeScalar(UInt8(t)))).lowercased() + (type & 0x80 != 0 ? "3" : "1")
    }

    static func rawType(forExtension ext: String) -> UInt8? {
        let e = ext.lowercased()
        guard e.count == 2, let letter = e.first?.asciiValue, (97...122).contains(letter),
              let family = e.last, family == "1" || family == "3" else { return nil }
        return family == "3" ? letter | 0x80 : letter
    }

    public func list(_ folder: FolderRef) throws -> [MediaItem] {
        disk.entries.map { e in
            MediaItem(id: "akai#\(e.index)", name: Self.exportName(e), isDirectory: false, size: Int64(e.size), modified: nil,
                      kindLabel: "Akai " + e.kind.label.lowercased(), shortName: nil, isClutter: false, ref: .akai(e))
        }
    }

    public func folder(of item: MediaItem) -> FolderRef? { nil }

    public func read(_ item: MediaItem, into sink: ([UInt8]) throws -> Void) throws {
        guard case .akai(let e) = item.ref else { return }
        try sink([UInt8](disk.contents(of: e)))
    }

    public func addFile(named name: String, size: Int64, modified: Date, in folder: FolderRef,
                        source: (Int64, Int) throws -> [UInt8]) throws -> String {
        guard !isReadOnly else { throw MediaError.readOnly }
        let ext = (name as NSString).pathExtension
        guard let type = Self.rawType(forExtension: ext) else {
            throw MediaError.unsupported("Only Akai files (.s1, .s3, .p1, .p3…) can go on an Akai disk; “\(name)” isn't one. Floppy Blaster or Sampler Food can convert audio to Akai samples.")
        }
        guard (type & 0x80 != 0) == (disk.layout == .s3000) || FileKind(type: type) == .sample else {
            throw MediaError.unsupported("“\(name)” is for the other Akai family (\(type & 0x80 != 0 ? "S3000" : "S1000")) and can't go on this \(formatName) disk.")
        }
        var data = Data(try source(0, Int(size)))
        var fileType = type
        if (type & 0x80 != 0) != (disk.layout == .s3000) {
            // Samples move between families by adding or removing the S3000 header extension.
            let b = [UInt8](data)
            if disk.layout == .s3000, b.count >= 150 {
                data = Data(b[0..<150] + [UInt8](repeating: 0, count: 42) + b[150...])
            } else if b.count >= 192 {
                data = Data(b[0..<150] + b[192...])
            }
            fileType = disk.layout == .s3000 ? (type | 0x80) : (type & 0x7F)
        }
        let base = (name as NSString).deletingPathExtension
        let akaiName = AkaiCharset.clean(base)
        guard !disk.entries.contains(where: { $0.name == akaiName }) else { throw MediaError.nameTaken(akaiName) }
        var updated = disk
        try updated.addFile(name: akaiName, type: fileType, contents: data)
        try save(updated)
        return Self.exportName(updated.entries.last!)
    }

    public func makeFolder(named name: String, in folder: FolderRef) throws -> FolderRef {
        throw MediaError.unsupported("Akai floppies don't have folders.")
    }

    public func delete(_ items: [MediaItem]) throws {
        guard !isReadOnly else { throw MediaError.readOnly }
        var updated = disk
        let entries = items.compactMap { item -> AkaiDisk.Entry? in if case .akai(let e) = item.ref { return e }; return nil }
        for e in entries.sorted(by: { $0.index > $1.index }) {
            if let current = updated.entries.first(where: { $0.index == e.index }) { try updated.delete(current) }
        }
        try save(updated)
    }

    public func rename(_ item: MediaItem, to name: String) throws -> String {
        guard !isReadOnly else { throw MediaError.readOnly }
        guard case .akai(let e) = item.ref else { return item.name }
        var updated = disk
        // "KICK.s3" → KICK: any Akai extension is the type, not part of the name.
        let base = Self.rawType(forExtension: (name as NSString).pathExtension) != nil ? (name as NSString).deletingPathExtension : name
        try updated.rename(e, to: base)
        try save(updated)
        return Self.exportName(updated.entries[e.index])
    }

    public func bytesNeeded(forFileOfSize size: Int64) -> Int64 { max(1024, (size + 1023) / 1024 * 1024) }

    public func setVolumeName(_ name: String) throws {
        guard !isReadOnly else { throw MediaError.readOnly }
        var updated = disk
        updated.setVolumeName(name)
        try save(updated)
    }

    /// Writes the whole image in place (it's only 1.6 MB) and flushes it to the card.
    private func save(_ updated: AkaiDisk) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: updated.data)
        try handle.synchronize()
        disk = updated
    }
}

// MARK: - ISO

/// A CD image, read-only.
public final class ISOMedium: Medium, @unchecked Sendable {
    public let url: URL
    public let iso: ISO9660Image

    public init(url: URL) throws {
        self.url = url
        iso = try ISO9660Image(url: url)
    }

    public var volumeName: String { iso.volumeName }
    public var formatName: String { iso.usesJoliet ? "ISO 9660 (Joliet)" : "ISO 9660" }
    public var isReadOnly: Bool { true }
    public var supportsFolders: Bool { true }
    public var totalBytes: Int64 { iso.totalBytes }
    public var freeBytes: Int64 { 0 }

    public func list(_ folder: FolderRef) throws -> [MediaItem] {
        let parent: ISO9660Image.Entry?
        if case .iso(let e) = folder { parent = e } else { parent = nil }
        return try iso.list(parent).map { e in
            MediaItem(id: "iso#\(e.id)", name: e.name, isDirectory: e.isDirectory, size: e.isDirectory ? 0 : e.size,
                      modified: e.modified, kindLabel: Kinds.label(forExtension: (e.name as NSString).pathExtension, isDirectory: e.isDirectory),
                      shortName: nil, isClutter: false, ref: .iso(e))
        }
    }

    public func folder(of item: MediaItem) -> FolderRef? {
        guard case .iso(let e) = item.ref, e.isDirectory else { return nil }
        return .iso(e)
    }

    public func read(_ item: MediaItem, into sink: ([UInt8]) throws -> Void) throws {
        guard case .iso(let e) = item.ref else { return }
        try iso.read(e, into: sink)
    }

    public func addFile(named name: String, size: Int64, modified: Date, in folder: FolderRef,
                        source: (Int64, Int) throws -> [UInt8]) throws -> String { throw MediaError.readOnly }
    public func makeFolder(named name: String, in folder: FolderRef) throws -> FolderRef { throw MediaError.readOnly }
    public func delete(_ items: [MediaItem]) throws { throw MediaError.readOnly }
    public func rename(_ item: MediaItem, to name: String) throws -> String { throw MediaError.readOnly }
    public func bytesNeeded(forFileOfSize size: Int64) -> Int64 { size }
    public func setVolumeName(_ name: String) throws { throw MediaError.readOnly }
}

// MARK: - Opening

public enum MediaOpener {
    /// Image file extensions RetroMedia lists and opens.
    public static let extensions: Set<String> = ["img", "ima", "hda", "hds", "hdf", "iso", "dsk", "vfd", "flp", "image"]

    /// Opens an image as whichever media it holds: one per FAT partition, an
    /// Akai floppy, or a CD image.
    public static func open(_ url: URL) throws -> [Medium] {
        let ext = url.pathExtension.lowercased()
        let size = Int(MediaTransfer.fileSize(url))
        if ext == "iso", let iso = try? ISOMedium(url: url) { return [iso] }
        if size == AkaiDisk.imageSize, let akai = try? AkaiMedium(url: url) { return [akai] }
        do {
            let disk = try FATDiskImage(url: url)
            return disk.volumes.indices.map { FATMedium(url: url, disk: disk, partition: $0) }
        } catch {
            if let iso = try? ISOMedium(url: url) { return [iso] }
            if size == AkaiDisk.imageSize {
                throw MediaError.notRecognised("This 1.6 MB image isn't an Akai S1000/S3000 floppy or a DOS disk. It may be for another sampler or computer (S900/S950, Amiga, Atari…), which RetroMedia can't read.")
            }
            throw error
        }
    }
}
