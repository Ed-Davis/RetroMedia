import Foundation
import SwiftUI
import AppKit
import RetroMediaCore

/// One open medium: a floppy, one partition of a hard disk image, an Akai
/// floppy or a CD image. Keeps its own place (current folder) and listing.
@MainActor
final class OpenMedium: ObservableObject, Identifiable {
    let id = UUID()
    let medium: Medium
    /// Partition number when the image has more than one.
    let partition: Int?
    @Published private(set) var path: [(name: String, folder: FolderRef)] = []
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var clutter: [MediaItem] = []
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var listError: String?
    @Published var showHidden = false

    init(medium: Medium, partition: Int?) {
        self.medium = medium
        self.partition = partition
        refresh()
    }

    var url: URL { medium.url }
    var fileName: String { url.lastPathComponent }
    var title: String {
        guard let partition else { return fileName }
        return "\(fileName) — \(medium.volumeName.isEmpty ? "Partition \(partition + 1)" : medium.volumeName)"
    }
    var sidebarName: String {
        if let partition { return medium.volumeName.isEmpty ? "Partition \(partition + 1)" : medium.volumeName }
        return url.deletingPathExtension().lastPathComponent
    }
    var symbol: String {
        if medium is ISOMedium { return "opticaldisc" }
        if medium is AkaiMedium { return "pianokeys" }
        return medium.totalBytes <= 3 * 1_048_576 ? "externaldrive" : "internaldrive"
    }
    var currentFolder: FolderRef { path.last?.folder ?? .root }
    var displayPath: String { "/" + path.map { $0.name + "/" }.joined() }

    func refresh() {
        do {
            let all = try medium.list(currentFolder)
            clutter = all.filter(\.isClutter)
            items = all.filter { !$0.isClutter }.sorted {
                ($0.isDirectory ? 0 : 1, $0.name.localizedLowercase) < ($1.isDirectory ? 0 : 1, $1.name.localizedLowercase)
            }
            listError = nil
        } catch {
            items = []
            clutter = []
            listError = error.localizedDescription
        }
        freeBytes = medium.freeBytes
    }

    func open(_ item: MediaItem) {
        guard let folder = medium.folder(of: item) else { return }
        path.append((item.name, folder))
        refresh()
    }

    func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        refresh()
    }

    func goTo(depth: Int) {
        guard depth < path.count else { return }
        path = Array(path.prefix(depth))
        refresh()
    }
}

/// A folder or image in the library sidebar.
struct LibraryNode: Identifiable, Hashable {
    let url: URL
    let isImage: Bool
    var children: [LibraryNode]?
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum SidebarItem: Hashable {
    case medium(UUID)
    case library(URL)
}

/// Everything the window shows: the open media, the library folder (a Gotek
/// USB stick or a ZuluSCSI/BlueSCSI SD card, usually), and copy progress.
@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var media: [OpenMedium] = []
    @Published var selection: SidebarItem? { didSet { selectionChanged(from: oldValue) } }
    @Published private(set) var libraryRoot: URL?
    @Published private(set) var libraryNodes: [LibraryNode] = []
    @Published var status = "Open a disk image, or choose your Gotek or SD card folder."
    @Published var alert: String?
    @Published private(set) var busy: String?
    @Published private(set) var progress: Double?
    @Published var lastExported: [URL] = []

    private var accessed: [URL: Bool] = [:]
    private var cancelRequested = false
    private static let bookmarkKey = "libraryBookmark"

    init() {
        restoreLibrary()
    }

    var selectedMedium: OpenMedium? {
        guard case .medium(let id) = selection else { return nil }
        return media.first { $0.id == id }
    }

    func medium(_ id: UUID) -> OpenMedium? { media.first { $0.id == id } }

    // MARK: Opening and closing

    /// Opens an image (or selects it if it's already open).
    func open(_ url: URL) {
        if let already = media.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            selection = .medium(already.id)
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        do {
            let found = try MediaOpener.open(url)
            let opened = found.enumerated().map { i, m in OpenMedium(medium: m, partition: found.count > 1 ? i : nil) }
            accessed[url] = access
            media += opened
            selection = opened.first.map { .medium($0.id) }
            let readOnly = opened.first?.medium.isReadOnly == true && !(opened.first?.medium is ISOMedium)
            status = "Opened \(url.lastPathComponent)" + (opened.count > 1 ? " (\(opened.count) partitions)." : ".")
                + (readOnly ? " It's read-only (locked, or on a write-protected card)." : "")
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            alert = "Couldn't open \(url.lastPathComponent). \(error.localizedDescription)"
        }
    }

    /// Closes an image (all its partitions). Everything is already saved.
    func close(_ url: URL) {
        let closing = media.filter { $0.url == url }
        guard !closing.isEmpty else { return }
        for m in closing { (m.medium as? FATMedium)?.disk.file.flush() }
        media.removeAll { $0.url == url }
        if let access = accessed.removeValue(forKey: url), access { url.stopAccessingSecurityScopedResource() }
        if case .medium(let id) = selection, closing.contains(where: { $0.id == id }) {
            selection = media.first.map { .medium($0.id) }
        }
        status = "Closed \(url.lastPathComponent). It's safe to eject the card."
    }

    func closeAll() {
        for url in Set(media.map(\.url)) { close(url) }
    }

    private func selectionChanged(from old: SidebarItem?) {
        if case .library(let url) = selection {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                open(url)
            }
        }
    }

    // MARK: Library folder

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Gotek USB stick, your ZuluSCSI/BlueSCSI SD card, or any folder of disk images"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLibrary(url)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    private func restoreLibrary() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return }
        setLibrary(url)
    }

    private func setLibrary(_ url: URL) {
        libraryRoot?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        libraryRoot = url
        rescanLibrary()
    }

    func rescanLibrary() {
        guard let libraryRoot else { libraryNodes = []; return }
        libraryNodes = Self.scan(libraryRoot, depth: 0)
    }

    private static let skippedFolders: Set<String> = [".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems", "System Volume Information"]

    private static func scan(_ folder: URL, depth: Int) -> [LibraryNode] {
        guard depth < 8, let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var folders: [LibraryNode] = []
        var images: [LibraryNode] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                guard !skippedFolders.contains(url.lastPathComponent) else { continue }
                let children = scan(url, depth: depth + 1)
                if !children.isEmpty { folders.append(LibraryNode(url: url, isImage: false, children: children)) }
            } else if MediaOpener.extensions.contains(url.pathExtension.lowercased()) {
                images.append(LibraryNode(url: url, isImage: true, children: nil))
            }
        }
        let byName: (LibraryNode, LibraryNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders.sorted(by: byName) + images.sorted(by: byName)
    }

    // MARK: Long jobs

    var isBusy: Bool { busy != nil }

    func cancel() { cancelRequested = true }

    /// Runs a copy off the main thread with progress, then refreshes every
    /// open medium (a copy may change several).
    func run(_ what: String, _ job: @escaping @Sendable (_ progress: @escaping TransferProgress, _ isCancelled: @escaping @Sendable () -> Bool) -> TransferReport,
             done: @escaping (TransferReport) -> Void = { _ in }) {
        guard busy == nil else { return }
        busy = what
        progress = 0
        cancelRequested = false
        let throttle = Throttle(interval: 0.08)
        let progressBox: TransferProgress = { [weak self] d, t, name in
            guard throttle.ready() else { return }
            Task { @MainActor in
                guard let self, self.busy != nil else { return }
                self.progress = t > 0 ? Double(d) / Double(t) : nil
                self.busy = "\(what) \(name)…"
            }
        }
        let cancelFlag = CancelFlag()
        let watcher = Task { @MainActor [weak self] in
            while let self, self.busy != nil {
                if self.cancelRequested { cancelFlag.set() }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        Task.detached(priority: .userInitiated) {
            let report = job(progressBox, { cancelFlag.isSet })
            await MainActor.run { [weak self] in
                watcher.cancel()
                guard let self else { return }
                self.busy = nil
                self.progress = nil
                for m in self.media { m.refresh() }
                self.status = report.summary
                if !report.failed.isEmpty {
                    self.alert = "Some items couldn't be copied:\n\n" + report.failed.prefix(12).joined(separator: "\n")
                        + (report.failed.count > 12 ? "\n…and \(report.failed.count - 12) more." : "")
                }
                done(report)
            }
        }
    }
}

/// Lets progress through at most every `interval` seconds.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    let interval: TimeInterval
    init(interval: TimeInterval) { self.interval = interval }
    func ready() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

/// A flag a background job checks to stop early.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Lets a medium cross into a background job. Only one job runs at a time
/// (`Workspace.run` refuses a second), so it's never used from two threads at once.
struct MediumBox: @unchecked Sendable {
    let medium: Medium
}
