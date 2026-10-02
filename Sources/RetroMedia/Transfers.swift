import Foundation
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import RetroMediaCore

extension UTType {
    /// Items dragged within RetroMedia (one medium to another), copied directly.
    static let retroMediaItems = UTType(exportedAs: "com.ed1t.retromedia.items", conformingTo: .data)
}

/// What's dragged between media inside the app.
struct DraggedItems: Codable {
    let medium: UUID
    let items: [String]
}

extension Workspace {

    // MARK: Asking

    /// Asks what to do about names already there. nil = cancel.
    func askConflict(_ names: [String], in place: String) -> ConflictChoice? {
        guard !names.isEmpty else { return .keepBoth }
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? "“\(names[0])” is already in \(place)."
            : "\(names.count) items are already in \(place)."
        alert.informativeText = names.count == 1 ? "Replace it, keep both, or skip it?"
            : "Replace them, keep both (the new ones are numbered), or skip them? Folders with the same name are merged when replacing."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .skip
        default: return nil
        }
    }

    private func placeName(_ om: OpenMedium, _ folder: FolderRef) -> String {
        if folder == om.currentFolder, let last = om.path.last { return "“\(last.name)”" }
        return folder == .root ? "“\(om.sidebarName)”" : "that folder"
    }

    private func checkWritable(_ om: OpenMedium) -> Bool {
        guard !om.medium.isReadOnly else {
            alert = om.medium is ISOMedium
                ? "CD images are read-only. Drag files from it onto a floppy, a hard disk image or Finder instead."
                : "\(om.fileName) is read-only (it may be locked, or on a write-protected card)."
            return false
        }
        return true
    }

    private func checkSpace(_ needed: Int64, on om: OpenMedium) -> Bool {
        let free = om.medium.freeBytes
        guard needed <= free else {
            let f = ByteCountFormatter()
            alert = "Not enough room on \(om.sidebarName): that needs about \(f.string(fromByteCount: needed)) and \(f.string(fromByteCount: free)) is free. Nothing was copied."
            return false
        }
        return true
    }

    // MARK: Copying

    /// Copies Mac files and folders onto a medium.
    func importFiles(_ urls: [URL], into om: OpenMedium, folder: FolderRef? = nil) {
        guard !urls.isEmpty, checkWritable(om) else { return }
        let target = folder ?? om.currentFolder
        let names = urls.map(\.lastPathComponent)
        guard let choice = askConflict(MediaTransfer.conflicts(names, in: om.medium, folder: target), in: placeName(om, target)) else { return }
        for url in urls { _ = url.startAccessingSecurityScopedResource() }
        if choice != .replace, !checkSpace(MediaTransfer.bytesNeeded(urls, on: om.medium), on: om) { return }
        let box = MediumBox(medium: om.medium)
        run("Copying") { progress, cancelled in
            MediaTransfer.importURLs(urls, to: box.medium, folder: target, conflict: choice,
                                     progress: progress, isCancelled: cancelled)
        } done: { _ in
            for url in urls { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// Copies items from one medium to another (or another folder of the same one).
    func copy(_ items: [MediaItem], from source: OpenMedium, to target: OpenMedium, folder: FolderRef? = nil) {
        guard !items.isEmpty, checkWritable(target) else { return }
        let destination = folder ?? target.currentFolder
        if source.id == target.id && destination == source.currentFolder { return }   // dropped where it came from
        guard let choice = askConflict(MediaTransfer.conflicts(items.map(\.name), in: target.medium, folder: destination),
                                       in: placeName(target, destination)) else { return }
        let needed = MediaTransfer.size(of: items, on: source.medium)
        if choice != .replace, !checkSpace(needed, on: target) { return }
        let from = MediumBox(medium: source.medium), to = MediumBox(medium: target.medium)
        run("Copying") { progress, cancelled in
            MediaTransfer.copy(items, from: from.medium, to: to.medium, folder: destination, conflict: choice,
                               progress: progress, isCancelled: cancelled)
        }
    }

    /// Asks for a Mac folder and copies items there.
    func export(_ items: [MediaItem], from om: OpenMedium) {
        let chosen = items.isEmpty ? om.items : items
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to copy \(chosen.count == 1 ? "“\(chosen[0].name)”" : "\(chosen.count) items")"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let existing = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.uppercased() })
        let clashes = chosen.map(\.name).filter { existing.contains($0.uppercased()) }
        guard let choice = askConflict(clashes, in: "“\(folder.lastPathComponent)”") else { return }
        let box = MediumBox(medium: om.medium)
        run("Exporting") { progress, cancelled in
            MediaTransfer.export(chosen, from: box.medium, to: folder, conflict: choice, progress: progress, isCancelled: cancelled)
        } done: { [weak self] report in
            self?.lastExported = report.written
        }
    }

    // MARK: Changing

    func delete(_ items: [MediaItem], from om: OpenMedium) {
        guard !items.isEmpty, checkWritable(om) else { return }
        do {
            try om.medium.delete(items)
            status = items.count == 1 ? "Deleted \(items[0].name)." : "Deleted \(items.count) items."
        } catch {
            alert = "Delete failed: \(error.localizedDescription)"
        }
        om.refresh()
    }

    func rename(_ item: MediaItem, in om: OpenMedium, to name: String) {
        guard checkWritable(om), name != item.name, !name.isEmpty else { return }
        do {
            let stored = try om.medium.rename(item, to: name)
            status = "Renamed \(item.name) to \(stored)."
        } catch {
            alert = "Couldn't rename: \(error.localizedDescription)"
        }
        om.refresh()
    }

    func newFolder(in om: OpenMedium, named name: String) {
        guard checkWritable(om) else { return }
        do {
            _ = try om.medium.makeFolder(named: name, in: om.currentFolder)
            status = "Created folder \(name)."
        } catch {
            alert = "Couldn't create the folder: \(error.localizedDescription)"
        }
        om.refresh()
    }

    func removeClutter(in om: OpenMedium) {
        guard checkWritable(om), !om.clutter.isEmpty else { return }
        let n = om.clutter.count
        do {
            try om.medium.delete(om.clutter)
            status = "Removed \(n) Mac system file\(n == 1 ? "" : "s")."
        } catch {
            alert = "Couldn't remove them: \(error.localizedDescription)"
        }
        om.refresh()
    }

    func setVolumeName(_ name: String, of om: OpenMedium) {
        guard checkWritable(om) else { return }
        do { try om.medium.setVolumeName(name) } catch { alert = "Couldn't rename the disk: \(error.localizedDescription)" }
        objectWillChange.send()
        om.refresh()
    }

    /// Saves a copy of an image file somewhere else, before risky changes.
    func backUp(_ om: OpenMedium) {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let base = om.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base) backup \(stamp.string(from: Date())).\(om.url.pathExtension)"
        panel.message = "Save a copy of \(om.fileName)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        (om.medium as? FATMedium)?.disk.file.flush()
        let source = om.url
        run("Backing up") { _, _ in
            var r = TransferReport()
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
                r.copied = [destination.lastPathComponent]
            } catch {
                r.failed = [error.localizedDescription]
            }
            return r
        }
    }

    // MARK: Dragging

    /// A drag of one item: other media get the item directly; Finder and other
    /// apps get a copy written to a temporary folder when it's dropped.
    func itemProvider(for item: MediaItem, in om: OpenMedium, selected: [MediaItem]) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let group = selected.contains(where: { $0.id == item.id }) ? selected : [item]
        if let data = try? JSONEncoder().encode(DraggedItems(medium: om.id, items: group.map(\.id))) {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.retroMediaItems.identifier, visibility: .ownProcess) { done in
                done(data, nil)
                return nil
            }
        }
        let box = MediumBox(medium: om.medium)
        let type: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: item.pathExtension) ?? .data)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Drag-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let report = MediaTransfer.export([item], from: box.medium, to: temp, conflict: .keepBoth)
                if let url = report.written.first { done(url, false, nil) } else {
                    done(nil, false, MediaError.io(report.failed.first ?? "Couldn't copy \(item.name)."))
                }
            } catch {
                done(nil, false, error)
            }
            return nil
        }
        return provider
    }

    /// Handles a drop onto a medium: items from another medium are copied
    /// across; files from Finder are copied in.
    func handleDrop(_ providers: [NSItemProvider], onto om: OpenMedium, folder: FolderRef? = nil) -> Bool {
        if let own = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.retroMediaItems.identifier) }) {
            own.loadDataRepresentation(forTypeIdentifier: UTType.retroMediaItems.identifier) { data, _ in
                guard let data, let dragged = try? JSONDecoder().decode(DraggedItems.self, from: data) else { return }
                Task { @MainActor in
                    guard let source = self.medium(dragged.medium) else { return }
                    let all = (try? source.medium.list(source.currentFolder)) ?? []
                    let items = dragged.items.compactMap { id in all.first { $0.id == id } }
                    self.copy(items, from: source, to: om, folder: folder)
                }
            }
            return true
        }
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in fileProviders {
                let url: URL? = await withCheckedContinuation { c in
                    _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            // An image dropped on the sidebar's empty space opens; on a medium, it's copied in.
            self.importFiles(urls, into: om, folder: folder)
        }
        return true
    }

    /// Opens images dropped anywhere that isn't a medium.
    func openDropped(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        Task { @MainActor in
            for p in fileProviders {
                let url: URL? = await withCheckedContinuation { c in
                    _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
                }
                if let url, MediaOpener.extensions.contains(url.pathExtension.lowercased()) { self.open(url) }
            }
        }
        return true
    }
}

/// Plays audio files on a medium, for a quick listen.
@MainActor
final class AudioPreview: ObservableObject {
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?
    private var temp: URL?

    static let extensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "mp3", "m4a", "caf", "flac", "au", "snd"]

    static func canPlay(_ item: MediaItem) -> Bool {
        !item.isDirectory && extensions.contains(item.pathExtension.lowercased())
    }

    func toggle(_ item: MediaItem, in om: OpenMedium) -> String? {
        let key = "\(om.id)#\(item.id)"
        if playing == key { stop(); return nil }
        stop()
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(UUID().uuidString).\(item.pathExtension)")
            try om.medium.read(item).write(to: url)
            temp = url
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            player = p
            playing = key
            let length = p.duration
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((length + 0.2) * 1_000_000_000))
                if self?.playing == key { self?.stop() }
            }
            return nil
        } catch {
            return "Couldn't play \(item.name): it may not be a format macOS can play."
        }
    }

    func isPlaying(_ item: MediaItem, in om: OpenMedium) -> Bool { playing == "\(om.id)#\(item.id)" }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        if let temp { try? FileManager.default.removeItem(at: temp) }
        temp = nil
    }
}
