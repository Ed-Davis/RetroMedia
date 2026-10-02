import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RetroMediaCore

struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace
    @Binding var showNewImage: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar(showNewImage: $showNewImage)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let om = workspace.selectedMedium {
                        MediumView(om: om).id(om.id)
                    } else {
                        Placeholder(showNewImage: $showNewImage)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard workspace.selectedMedium == nil else { return false }
                return workspace.openDropped(providers)
            }
        }
        .alert("RetroMedia", isPresented: Binding(get: { workspace.alert != nil }, set: { if !$0 { workspace.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.alert ?? "")
        }
    }
}

struct Placeholder: View {
    @EnvironmentObject private var workspace: Workspace
    @Binding var showNewImage: Bool

    var body: some View {
        VStack(spacing: 14) {
            if let icon = AppArtwork.icon {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            Text("RetroMedia").font(.title2.bold())
            Text("Floppy images for a Gotek, hard disk images for ZuluSCSI and BlueSCSI, and CD images. Open one, or drop it here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack {
                Button("Open Image…") { openImages(workspace) }
                Button("New Image…") { showNewImage = true }
                Button("Choose Gotek or SD Card Folder…") { workspace.chooseLibrary() }
            }
        }
        .padding()
    }
}

@MainActor
func openImages(_ workspace: Workspace) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = MediaOpener.extensions.compactMap { UTType(filenameExtension: $0) }
    panel.message = "Choose disk images (.img, .hda, .iso…)"
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { workspace.open(url) }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var workspace: Workspace
    @Binding var showNewImage: Bool
    @State private var targeted: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $workspace.selection) {
                Section("Open") {
                    if workspace.media.isEmpty {
                        Text("Nothing open").foregroundStyle(.tertiary)
                    }
                    ForEach(workspace.media) { om in
                        MediumRow(om: om, targeted: targeted == om.id)
                            .tag(SidebarItem.medium(om.id))
                            .onDrop(of: [.retroMediaItems, .fileURL],
                                    isTargeted: Binding(get: { targeted == om.id }, set: { targeted = $0 ? om.id : (targeted == om.id ? nil : targeted) })) { providers in
                                workspace.handleDrop(providers, onto: om, folder: .root)
                            }
                            .contextMenu {
                                Button("Back Up Image…") { workspace.backUp(om) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([om.url]) }
                                Divider()
                                Button("Close \(om.fileName)") { workspace.close(om.url) }
                            }
                    }
                }
                if let root = workspace.libraryRoot {
                    Section(root.lastPathComponent) {
                        OutlineGroup(workspace.libraryNodes, children: \.children) { node in
                            Label(node.isImage ? node.url.deletingPathExtension().lastPathComponent : node.name,
                                  systemImage: node.isImage ? Self.symbol(for: node.url) : "folder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(node.url.lastPathComponent)
                                .tag(SidebarItem.library(node.url))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 8) {
                Button { openImages(workspace) } label: { Image(systemName: "folder") }
                    .help("Open disk images…")
                Button { showNewImage = true } label: { Image(systemName: "plus") }
                    .help("New floppy or hard disk image…")
                Spacer()
                Button(workspace.libraryRoot == nil ? "Choose Folder…" : "Change…") { workspace.chooseLibrary() }
                    .help("Choose your Gotek USB stick or ZuluSCSI/BlueSCSI SD card, to list its images here")
                Button { workspace.rescanLibrary() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Look for new disk images")
                    .disabled(workspace.libraryRoot == nil)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    static func symbol(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "iso" { return "opticaldisc" }
        if ["hda", "hds", "hdf"].contains(ext) { return "internaldrive" }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 3 * 1_048_576 ? "internaldrive" : "externaldrive"
    }
}

struct MediumRow: View {
    @ObservedObject var om: OpenMedium
    let targeted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: om.symbol)
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(om.sidebarName).lineLimit(1).truncationMode(.middle)
                Text(om.partition == nil ? "\(om.medium.formatName) · \(om.fileName)" : "\(om.medium.formatName) · \(om.fileName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if om.medium.isReadOnly {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Read-only")
            }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: targeted ? 2 : 0))
        .help(om.title)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            if let busy = workspace.busy {
                if let p = workspace.progress {
                    ProgressView(value: p).frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(busy).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { workspace.cancel() }
            } else {
                Text(workspace.status).lineLimit(1).truncationMode(.tail).help(workspace.status)
                Spacer()
                if !workspace.lastExported.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(workspace.lastExported) }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}
