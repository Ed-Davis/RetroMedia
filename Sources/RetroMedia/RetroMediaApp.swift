import SwiftUI
import AppKit
import RetroMediaCore

@main
struct RetroMediaApp: App {
    @StateObject private var workspace = Workspace()
    @State private var showNewImage = false
    @State private var showAbout = false
    @State private var showHelp = false

    var body: some Scene {
        Window("RetroMedia", id: "main") {
            ContentView(showNewImage: $showNewImage)
                .environmentObject(workspace)
                .frame(minWidth: 960, minHeight: 580)
                .sheet(isPresented: $showNewImage) { NewImageSheet().environmentObject(workspace) }
                .sheet(isPresented: $showAbout) { AboutView() }
                .sheet(isPresented: $showHelp) { HelpView() }
                .onOpenURL { url in if url.isFileURL { workspace.open(url) } }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    workspace.closeAll()
                }
        }
        .defaultSize(width: 1120, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RetroMedia") { showAbout = true }
            }
            CommandGroup(replacing: .help) {
                Button("RetroMedia Help") { showHelp = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Image…") { showNewImage = true }.keyboardShortcut("n")
                Button("Open Image…") { openImages(workspace) }.keyboardShortcut("o")
                Divider()
                Button("Choose Gotek or SD Card Folder…") { workspace.chooseLibrary() }
                Divider()
                Button("Back Up Image…") { if let m = workspace.selectedMedium { workspace.backUp(m) } }
                    .disabled(workspace.selectedMedium == nil)
                Button("Close Image") { if let m = workspace.selectedMedium { workspace.close(m.url) } }
                    .keyboardShortcut("w")
                    .disabled(workspace.selectedMedium == nil)
            }
        }
    }
}

enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var full: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty { return "\(short) (\(build))" }
        return short
    }
}

enum AppArtwork {
    static var icon: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") { return NSImage(contentsOf: url) }
        return NSApp.applicationIconImage
    }
    static var banner: NSImage? {
        guard let url = Bundle.main.url(forResource: "Banner", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            if let banner = AppArtwork.banner {
                Image(nsImage: banner).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 6)
            } else if let icon = AppArtwork.icon {
                Image(nsImage: icon).resizable().frame(width: 128, height: 128)
            }
            Text("RetroMedia").font(.title2.bold())
            Text("Version \(AppVersion.full)").foregroundStyle(.secondary)
            Text("by Ed Davis").foregroundStyle(.secondary)
            Text("© \(String(Calendar.current.component(.year, from: Date()))) Ed Davis. All rights reserved.")
                .font(.caption).foregroundStyle(.tertiary)
            Text("Not affiliated with the makers of Gotek, FlashFloppy, ZuluSCSI, BlueSCSI, SCSI2SD or Akai Professional.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(28)
        .frame(width: 420)
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, [String])] = [
        ("What it does", [
            "RetroMedia opens the disk images that floppy and hard disk emulators use, so you can copy files on and off them on your Mac: floppy images for a Gotek (FlashFloppy or HxC), hard disk images for ZuluSCSI, BlueSCSI, SCSI2SD and similar adapters, and CD images (.iso).",
            "Nothing is mounted. RetroMedia reads and writes the disks itself, so there's nothing to eject and it works with images macOS won't mount.",
        ]),
        ("Opening images", [
            "Click Open Image… (⌘O), double-click an image in Finder, or drop one on the window. Several can be open at once; they're listed on the left.",
            "Choose Gotek or SD Card Folder… to list every image on your Gotek's USB stick or adapter's SD card (or any folder) in the sidebar. Click one to open it.",
            "A hard disk image with several partitions shows each partition separately.",
        ]),
        ("Copying files", [
            "Drop files and folders from Finder onto the file list, or click Add Files….",
            "Drag files between disks: from the file list onto another disk in the sidebar, or use Copy To in the right-click menu. Drag them to Finder, or click Export…, to copy them to your Mac.",
            "Files keep their names. On DOS/FAT disks long names are stored the way Windows and macOS store them, with an 8.3 name for older machines (shown in grey beside the long name). Characters FAT can't hold (\\ / : * ? \" < > |) aren't allowed: rename the file first.",
            "If something with the same name is already there, you can replace it, keep both (the new one is numbered) or skip it.",
            "Nothing is copied if there isn't room.",
        ]),
        ("Kinds of disk", [
            "DOS/FAT: FAT12 floppies (720 KB, 1.44 MB, 2.88 MB), and FAT16 and FAT32 hard disk images, whole or partitioned (up to four partitions).",
            "Akai S1000 and S3000 floppies (1.6 MB): files go on and off exactly as they are, named NAME.s3, NAME.p1 and so on, as akaiutil and Floppy Blaster use. Samples can move between S1000 and S3000 disks; anything that isn't an Akai file can't go on one.",
            "CD images (.iso): ISO 9660, with Joliet long names. CDs are read-only: drag files off them onto other disks or Finder.",
        ]),
        ("New images", [
            "New Image… (⌘N) makes a blank floppy (DOS 720 KB, 1.44 MB or 2.88 MB, or Akai S1000/S3000), or a hard disk image of any size from 16 MB, as FAT16 (for older machines; split into partitions of up to 2 GB) or FAT32.",
            "Name hard disk images the way your adapter expects. On ZuluSCSI and BlueSCSI, HD10_512.hda is SCSI ID 1, LUN 0, 512-byte sectors.",
        ]),
        ("Other things", [
            "Rename, delete and make folders from the right-click menu or the buttons below the list. Click the disk's name at the top to change its volume label.",
            "Remove Mac Files deletes the .DS_Store and ._ files macOS leaves on disks, which older machines list as junk.",
            "Play audio files (WAV, AIFF, MP3…) with the play button, a double-click or Space.",
            "Back Up Image… saves a copy of the whole image first, if you're about to make big changes.",
        ]),
        ("Saving", [
            "Every change is written straight to the image file, data first and the directory last, so an interruption can lose only free space, never existing files. Close an image (or quit) before ejecting the card.",
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RetroMedia Help").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.0) { title, paragraphs in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline)
                            ForEach(paragraphs, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 580, height: 640)
    }
}
