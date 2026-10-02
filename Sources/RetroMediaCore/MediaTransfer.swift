import Foundation

/// What to do when a file being copied has the same name as one already there.
public enum ConflictChoice: Sendable {
    case replace, keepBoth, skip
}

/// What a copy did.
public struct TransferReport: Sendable, Equatable {
    public var copied: [String] = []
    public var skipped: [String] = []
    public var failed: [String] = []
    /// Files written to the Mac (exports), for showing in Finder.
    public var written: [URL] = []
    public var cancelled = false
    public init() {}

    public var summary: String {
        var parts: [String] = []
        if !copied.isEmpty { parts.append("Copied \(copied.count) item\(copied.count == 1 ? "" : "s")") }
        if !skipped.isEmpty { parts.append("skipped \(skipped.count)") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if cancelled { parts.append("cancelled") }
        return parts.isEmpty ? "Nothing to copy." : parts.joined(separator: ", ") + "."
    }
}

/// Progress as bytes copied of the total, and the file being copied.
public typealias TransferProgress = @Sendable (_ done: Int64, _ total: Int64, _ current: String) -> Void

/// Copies files and folders between the Mac and media, and between media.
public enum MediaTransfer {

    /// Files macOS adds that aren't worth copying onto a disk.
    static func isMacJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == ".Trashes" || name == ".fseventsd"
            || name == ".Spotlight-V100" || name == ".TemporaryItems" || name == "Icon\r"
    }

    // MARK: Planning

    /// Names among `incoming` that are already in `folder`.
    public static func conflicts(_ incoming: [String], in medium: Medium, folder: FolderRef) -> [String] {
        let existing = (try? medium.list(folder)) ?? []
        return incoming.filter { name in existing.contains { same($0, name, on: medium) } }
    }

    /// Whether an item already there has the name a file would get. On an
    /// Akai disk only the 12-character name counts (.s1 and .s3 share names).
    static func same(_ item: MediaItem, _ name: String, on medium: Medium) -> Bool {
        if medium is AkaiMedium {
            return (item.name as NSString).deletingPathExtension == AkaiCharset.clean((name as NSString).deletingPathExtension)
        }
        let upper = name.uppercased()
        return item.name.uppercased() == upper || (item.shortName ?? "").uppercased() == upper
    }

    /// Bytes the Mac files and folders at `urls` will take on `medium`.
    public static func bytesNeeded(_ urls: [URL], on medium: Medium) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                total += medium.bytesNeeded(forFileOfSize: 0)
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                total += bytesNeeded(children.filter { !isMacJunk($0.lastPathComponent) }, on: medium)
            } else {
                total += medium.bytesNeeded(forFileOfSize: fileSize(url))
            }
        }
        return total
    }

    /// Bytes items on a medium hold (folders counted through).
    public static func size(of items: [MediaItem], on medium: Medium) -> Int64 {
        items.reduce(0) { total, item in
            if item.isDirectory, let f = medium.folder(of: item) {
                return total + size(of: ((try? medium.list(f)) ?? []).filter { !$0.isClutter }, on: medium)
            }
            return total + item.size
        }
    }

    // MARK: From the Mac

    /// Copies files and folders from the Mac onto a medium.
    public static func importURLs(_ urls: [URL], to medium: Medium, folder: FolderRef, conflict: ConflictChoice,
                                  progress: TransferProgress? = nil, isCancelled: () -> Bool = { false }) -> TransferReport {
        var report = TransferReport()
        var done: Int64 = 0
        let total = urls.reduce(Int64(0)) { $0 + macSize($1) }
        for url in urls {
            if isCancelled() { report.cancelled = true; break }
            importOne(url, to: medium, folder: folder, conflict: conflict, report: &report, done: &done, total: total,
                      progress: progress, isCancelled: isCancelled)
        }
        return report
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func macSize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(url) }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return children.reduce(0) { $0 + macSize($1) }
    }

    private static func importOne(_ url: URL, to medium: Medium, folder: FolderRef, conflict: ConflictChoice,
                                  report: inout TransferReport, done: inout Int64, total: Int64,
                                  progress: TransferProgress?, isCancelled: () -> Bool) {
        let name = url.lastPathComponent
        guard !isMacJunk(name) else { return }
        var url = url
        if (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            // Follow links to files; links to folders could loop forever.
            let resolved = url.resolvingSymlinksInPath()
            var linkDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &linkDir), linkDir.boolValue {
                report.skipped.append("\(name) (a link to a folder)")
                return
            }
            url = resolved
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            report.failed.append("\(name): it's no longer there")
            return
        }
        do {
            if isDir.boolValue {
                let target = try folderTarget(named: name, in: folder, on: medium, conflict: conflict, report: &report)
                guard let target else { return }
                let children = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for child in children {
                    if isCancelled() { report.cancelled = true; return }
                    importOne(child, to: medium, folder: target, conflict: conflict, report: &report, done: &done,
                              total: total, progress: progress, isCancelled: isCancelled)
                }
                return
            }
            // Straight from the file system: URL resource values are cached and
            // go stale if the file changes while the app is running.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attributes[.modificationDate] as? Date
            // Everything that could stop the copy is checked before anything
            // already on the disk is touched.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if medium is AkaiMedium, AkaiMedium.rawType(forExtension: (name as NSString).pathExtension) == nil {
                throw MediaError.unsupported("Only Akai files (.s1, .s3, .p1, .p3…) can go on an Akai disk.")
            }
            guard let plan = try resolveFileName(name, in: folder, on: medium, conflict: conflict, report: &report) else { return }
            let start = done
            progress?(done, total, name)
            let source: (Int64, Int) throws -> [UInt8] = { offset, count in
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: count) ?? Data()
                progress?(start + offset + Int64(count), total, name)
                return [UInt8](data)
            }
            let stored: String
            if let old = plan.replacing {
                stored = try replace(old, with: plan.name, size: size, modified: modified ?? Date(), in: folder, on: medium, source: source)
            } else {
                stored = try medium.addFile(named: plan.name, size: size, modified: modified ?? Date(), in: folder, source: source)
            }
            done = start + size
            report.copied.append(stored)
        } catch {
            report.failed.append("\(name): \(error.localizedDescription)")
        }
    }

    /// Replaces a file without risking it: when there's room, the new file is
    /// written under a temporary name first, then the old one is deleted and
    /// the new one renamed. Otherwise the old one is deleted first, but only
    /// once the new one is sure to fit.
    private static func replace(_ old: MediaItem, with name: String, size: Int64, modified: Date, in folder: FolderRef,
                                on medium: Medium, source: (Int64, Int) throws -> [UInt8]) throws -> String {
        let needed = medium.bytesNeeded(forFileOfSize: size)
        if medium.freeBytes >= needed + medium.bytesNeeded(forFileOfSize: 0) * 2 {
            let ext = (name as NSString).pathExtension
            let tempBase = medium is AkaiMedium ? "RMTEMP\(Int.random(in: 1000...9999))" : "RetroMedia temp \(UUID().uuidString.prefix(8))"
            let tempName = ext.isEmpty ? tempBase : tempBase + "." + ext
            let written = try medium.addFile(named: tempName, size: size, modified: modified, in: folder, source: source)
            guard let newItem = try medium.list(folder).first(where: { $0.name == written }) else {
                throw MediaError.io("The new copy of \(name) couldn't be found after writing it.")
            }
            try medium.delete([old])
            return try medium.rename(newItem, to: name)
        }
        guard medium.freeBytes + medium.bytesNeeded(forFileOfSize: old.size) >= needed else {
            throw MediaError.diskFull(needed: needed, free: medium.freeBytes + medium.bytesNeeded(forFileOfSize: old.size))
        }
        try medium.delete([old])
        return try medium.addFile(named: name, size: size, modified: modified, in: folder, source: source)
    }

    /// Where a folder's contents go: a new folder, an existing one of the same
    /// name (merged into), or nowhere (skipped). Akai disks have no folders,
    /// so their contents go at the top level.
    private static func folderTarget(named name: String, in folder: FolderRef, on medium: Medium,
                                     conflict: ConflictChoice, report: inout TransferReport) throws -> FolderRef? {
        guard medium.supportsFolders else { return folder }
        let existing = try medium.list(folder)
        if let same = existing.first(where: { $0.name.uppercased() == name.uppercased() }) {
            if same.isDirectory, conflict != .keepBoth, let f = medium.folder(of: same) {
                if conflict == .skip { report.skipped.append(name); return nil }
                return f   // replace: merge into the folder that's there
            }
            if conflict == .skip { report.skipped.append(name); return nil }
            // A file of the same name is never deleted to make way for a
            // folder: the folder gets a numbered name instead.
            return try medium.makeFolder(named: uniqueName(name, taken: Set(existing.map { $0.name.uppercased() })), in: folder)
        }
        return try medium.makeFolder(named: name, in: folder)
    }

    /// The name a file goes in under after any conflict, and the file it
    /// replaces (if any); nil to skip.
    private static func resolveFileName(_ name: String, in folder: FolderRef, on medium: Medium,
                                        conflict: ConflictChoice, report: inout TransferReport) throws -> (name: String, replacing: MediaItem?)? {
        let existing = try medium.list(folder)
        guard let same = existing.first(where: { Self.same($0, name, on: medium) }) else {
            return (name, nil)
        }
        // A folder is never replaced by a file: the file gets a numbered name.
        let choice: ConflictChoice = same.isDirectory && conflict == .replace ? .keepBoth : conflict
        switch choice {
        case .skip:
            report.skipped.append(name)
            return nil
        case .replace:
            return (name, same)
        case .keepBoth:
            if medium is AkaiMedium {
                let ext = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                let taken = Set(existing.map { ($0.name as NSString).deletingPathExtension.uppercased() })
                for n in 2...999 {
                    let candidate = AkaiCharset.clean(String(AkaiCharset.clean(base).prefix(12 - " \(n)".count)) + " \(n)")
                    if !taken.contains(candidate) { return (candidate + "." + ext, nil) }
                }
            }
            return (uniqueName(name, taken: Set(existing.flatMap { [$0.name.uppercased(), ($0.shortName ?? "").uppercased()] })), nil)
        }
    }

    /// "Name 2.ext", "Name 3.ext"… not in `taken` (uppercase).
    public static func uniqueName(_ name: String, taken: Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for n in 2...9999 {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !taken.contains(candidate.uppercased()) { return candidate }
        }
        return name
    }

    // MARK: To the Mac

    /// Copies items (folders included) from a medium into a Mac folder.
    public static func export(_ items: [MediaItem], from medium: Medium, to folder: URL, conflict: ConflictChoice,
                              progress: TransferProgress? = nil, isCancelled: () -> Bool = { false }) -> TransferReport {
        var report = TransferReport()
        var done: Int64 = 0
        let total = size(of: items, on: medium)
        for item in items where !item.isClutter {
            if isCancelled() { report.cancelled = true; break }
            exportOne(item, from: medium, to: folder, conflict: conflict, report: &report, done: &done, total: total,
                      progress: progress, isCancelled: isCancelled, topLevel: true)
        }
        return report
    }

    private static func exportOne(_ item: MediaItem, from medium: Medium, to folder: URL, conflict: ConflictChoice,
                                  report: inout TransferReport, done: inout Int64, total: Int64,
                                  progress: TransferProgress?, isCancelled: () -> Bool, topLevel: Bool) {
        let fm = FileManager.default
        var destination = folder.appendingPathComponent(item.name.replacingOccurrences(of: "/", with: ":"))
        if fm.fileExists(atPath: destination.path) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: destination.path, isDirectory: &isDir)
            if item.isDirectory && isDir.boolValue && conflict == .replace {
                // merge into it
            } else {
                // Never delete a folder to make way for a file, or the reverse.
                let choice: ConflictChoice = (item.isDirectory != isDir.boolValue && conflict == .replace) ? .keepBoth : conflict
                switch choice {
                case .skip:
                    report.skipped.append(item.name)
                    return
                case .replace:
                    try? fm.removeItem(at: destination)
                case .keepBoth:
                    let taken = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.uppercased() })
                    destination = folder.appendingPathComponent(uniqueName(item.name, taken: taken))
                }
            }
        }
        do {
            if item.isDirectory {
                if !fm.fileExists(atPath: destination.path) {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                }
                if let f = medium.folder(of: item) {
                    for child in try medium.list(f) where !child.isClutter {
                        if isCancelled() { report.cancelled = true; return }
                        exportOne(child, from: medium, to: destination, conflict: conflict, report: &report, done: &done,
                                  total: total, progress: progress, isCancelled: isCancelled, topLevel: false)
                    }
                }
            } else {
                guard fm.createFile(atPath: destination.path, contents: nil) else {
                    throw MediaError.io("Couldn't write \(destination.lastPathComponent) there.")
                }
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                progress?(done, total, item.name)
                try medium.read(item) { chunk in
                    try handle.write(contentsOf: Data(chunk))
                    done += Int64(chunk.count)
                    progress?(done, total, item.name)
                }
                if let date = item.modified {
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
                }
            }
            if topLevel { report.written.append(destination) }
            report.copied.append(item.name)
        } catch {
            report.failed.append("\(item.name): \(error.localizedDescription)")
        }
    }

    // MARK: Between media

    /// Copies items from one medium to another, through a temporary folder so
    /// big files never have to fit in memory.
    public static func copy(_ items: [MediaItem], from source: Medium, to target: Medium, folder: FolderRef,
                            conflict: ConflictChoice, progress: TransferProgress? = nil,
                            isCancelled: () -> Bool = { false }) -> TransferReport {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("RetroMedia-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            var r = TransferReport()
            r.failed.append("Couldn't make a temporary folder: \(error.localizedDescription)")
            return r
        }
        let half: TransferProgress? = progress.map { p in { done, total, name in p(done / 2, total, name) } }
        let out = export(items, from: source, to: temp, conflict: .keepBoth, progress: half, isCancelled: isCancelled)
        guard !out.cancelled else { return out }
        var report = importURLs(out.written, to: target, folder: folder, conflict: conflict,
                                progress: progress.map { p in { done, total, name in p(total / 2 + done / 2, total, name) } },
                                isCancelled: isCancelled)
        report.failed = out.failed + report.failed
        report.written = []
        return report
    }
}
