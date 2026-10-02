import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RetroMediaCore

/// The files on one medium.
struct MediumView: View {
    @ObservedObject var om: OpenMedium
    @EnvironmentObject private var workspace: Workspace
    @StateObject private var preview = AudioPreview()

    @State private var selection = Set<String>()
    @State private var dropTargeted = false
    @State private var confirmDelete = false
    @State private var renameTarget: MediaItem?
    @State private var renameText = ""
    @State private var newFolderShown = false
    @State private var newFolderText = "New Folder"
    @State private var labelShown = false
    @State private var labelText = ""

    private var selectedItems: [MediaItem] { om.items.filter { selection.contains($0.id) } }
    private var otherMedia: [OpenMedium] { workspace.media.filter { $0.id != om.id && !$0.medium.isReadOnly } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pathBar
            Divider()
            table
            Divider()
            footer
        }
        .onChange(of: om.items) { _, items in
            selection = selection.filter { id in items.contains { $0.id == id } }
        }
        .onDisappear { preview.stop() }
        .confirmationDialog("Delete \(selectedItems.count == 1 ? "“\(selectedItems.first?.name ?? "")”" : "\(selectedItems.count) items")?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                preview.stop()
                workspace.delete(selectedItems, from: om)
                selection = []
            }
        } message: {
            Text("This can't be undone. Folders are deleted with everything in them.")
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let t = renameTarget { workspace.rename(t, in: om, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(om.medium is AkaiMedium ? "Akai names are up to 12 characters: A–Z, 0–9, space and # + - ." : "")
        }
        .alert("New Folder", isPresented: $newFolderShown) {
            TextField("Name", text: $newFolderText)
            Button("Create") { workspace.newFolder(in: om, named: newFolderText) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Disk Name", isPresented: $labelShown) {
            TextField("Name", text: $labelText)
            Button("Rename") { workspace.setVolumeName(labelText, of: om) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(om.medium is AkaiMedium ? "Up to 12 characters." : "The volume label: up to 11 characters, shown in capitals.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: om.symbol)
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(om.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    if !om.medium.isReadOnly {
                        Button {
                            labelText = om.medium.volumeName
                            labelShown = true
                        } label: {
                            Text(om.medium.volumeName.isEmpty ? "No name" : "“\(om.medium.volumeName)”")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("The disk's own name. Click to change it.")
                    } else if !om.medium.volumeName.isEmpty {
                        Text("“\(om.medium.volumeName)”").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(om.medium.formatName)
                    if om.medium.isReadOnly {
                        Label("Read-only", systemImage: "lock.fill").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !(om.medium is ISOMedium) {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: Double(om.medium.totalBytes - om.freeBytes), total: Double(max(om.medium.totalBytes, 1)))
                        .frame(width: 180)
                    Text("\(bytes(om.freeBytes)) free of \(bytes(om.medium.totalBytes))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(bytes(om.medium.totalBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: Path

    private var pathBar: some View {
        HStack(spacing: 4) {
            Button { om.goUp() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(om.path.isEmpty)
                .help("Up one folder")
            Button(om.sidebarName) { om.goTo(depth: 0) }.buttonStyle(.borderless)
            ForEach(Array(om.path.enumerated()), id: \.offset) { i, part in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(part.name) { om.goTo(depth: i + 1) }.buttonStyle(.borderless)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: Files

    private var table: some View {
        Table(of: MediaItem.self, selection: $selection) {
            TableColumn("") { item in
                if AudioPreview.canPlay(item) {
                    let playing = preview.isPlaying(item, in: om)
                    Button { play(item) } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .foregroundStyle(playing ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Stop" : "Play")
                } else {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(item.isDirectory ? Color.accentColor.opacity(0.8) : .secondary)
                }
            }
            .width(22)
            TableColumn("Name") { item in
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let short = item.shortName {
                        Text(short).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            .help("The 8.3 name older machines see")
                    }
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Kind") { item in Text(item.kindLabel).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 120)
            TableColumn("Size") { item in
                Text(item.isDirectory ? "—" : bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified") { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150)
        } rows: {
            ForEach(om.items) { item in
                TableRow(item)
                    .itemProvider { workspace.itemProvider(for: item, in: om, selected: selectedItems) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: om.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            guard let item = om.items.first(where: { ids.contains($0.id) }) else { return }
            if item.isDirectory {
                preview.stop()
                om.open(item)
            } else if AudioPreview.canPlay(item) {
                play(item)
            }
        }
        .onKeyPress(.space) {
            guard let item = selectedItems.first(where: AudioPreview.canPlay) else {
                if preview.playing != nil { preview.stop(); return .handled }
                return .ignored
            }
            play(item)
            return .handled
        }
        .onDeleteCommand { if !selection.isEmpty && !om.medium.isReadOnly { confirmDelete = true } }
        .overlay {
            if let error = om.listError {
                Text(error).foregroundStyle(.red).padding()
            } else if om.items.isEmpty {
                Text(om.medium.isReadOnly ? "Empty." : "Empty. Drop files here, or drag them from another disk in the sidebar.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).padding(3)
            }
        }
        .onDrop(of: [.retroMediaItems, .fileURL], isTargeted: $dropTargeted) { providers in
            guard !om.medium.isReadOnly else { return false }
            return workspace.handleDrop(providers, onto: om)
        }
    }

    @ViewBuilder
    private func menu(for chosen: [MediaItem]) -> some View {
        if chosen.count == 1, let item = chosen.first, item.isDirectory {
            Button("Open") { om.open(item) }
        }
        if chosen.count == 1, let item = chosen.first, AudioPreview.canPlay(item) {
            Button(preview.isPlaying(item, in: om) ? "Stop" : "Play") { play(item) }
        }
        Button("Export…") { workspace.export(chosen, from: om) }
        if !otherMedia.isEmpty {
            Menu("Copy To") {
                ForEach(otherMedia) { other in
                    Button(other.title) { workspace.copy(chosen, from: om, to: other) }
                }
            }
        }
        if !om.medium.isReadOnly {
            if chosen.count == 1, let item = chosen.first {
                Button("Rename…") { renameText = item.name; renameTarget = item }
            }
            Divider()
            Button("Delete…", role: .destructive) { selection = Set(chosen.map(\.id)); confirmDelete = true }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !om.medium.isReadOnly {
                Button { addFiles() } label: { Label("Add Files…", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                if om.medium.supportsFolders {
                    Button { newFolderText = "New Folder"; newFolderShown = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                }
            }
            Button("Export…") { workspace.export(selectedItems, from: om) }
                .help("Copy the selected items (or everything here) to a folder on your Mac")
                .disabled(om.items.isEmpty)
            if !om.medium.isReadOnly {
                Button("Delete…") { confirmDelete = true }
                    .disabled(selection.isEmpty)
            }
            if !om.clutter.isEmpty && !om.medium.isReadOnly {
                Button("Remove \(om.clutter.count) Mac File\(om.clutter.count == 1 ? "" : "s")") { workspace.removeClutter(in: om) }
                    .help("Delete .DS_Store, ._ files and other files macOS leaves on disks. Older machines show them as junk.")
            }
            Spacer()
            Text("\(om.items.count) item\(om.items.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            Button { workspace.close(om.url) } label: { Label("Close", systemImage: "eject") }
                .help("Close \(om.fileName). Changes are already saved; then it's safe to eject the card.")
        }
        .padding(10)
        .disabled(workspace.isBusy)
    }

    // MARK: Actions

    private func play(_ item: MediaItem) {
        if let error = preview.toggle(item, in: om) { workspace.status = error }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = om.medium.supportsFolders
        panel.message = om.medium is AkaiMedium
            ? "Choose Akai files (.s1, .s3, .p1, .p3…) to add to \(om.fileName)"
            : "Choose files and folders to copy onto \(om.sidebarName)"
        guard panel.runModal() == .OK else { return }
        workspace.importFiles(panel.urls, into: om)
    }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
