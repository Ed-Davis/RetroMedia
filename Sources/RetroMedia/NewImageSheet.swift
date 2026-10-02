import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RetroMediaCore

/// New Image…: a blank floppy for a Gotek, or a hard disk image for a SCSI-to-SD adapter.
struct NewImageSheet: View {
    @EnvironmentObject private var workspace: Workspace
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case floppy = "Floppy (Gotek)", hardDisk = "Hard disk (ZuluSCSI, BlueSCSI…)"
        var id: String { rawValue }
    }

    enum FloppyType: String, CaseIterable, Identifiable {
        case dos144 = "DOS 1.44 MB (HD)", dos720 = "DOS 720 KB (DD)", dos288 = "DOS 2.88 MB (ED)"
        case akai3000 = "Akai S3000 format (1.6 MB)", akai1000 = "Akai S1000 format (1.6 MB)"
        var id: String { rawValue }
    }

    @AppStorage("newKind") private var kind = Kind.floppy.rawValue
    @AppStorage("newFloppy") private var floppy = FloppyType.dos144.rawValue
    @AppStorage("newSizeMB") private var sizeMB = 1024
    @AppStorage("newFormat") private var format = DiskImageMaker.Format.fat16.rawValue
    @State private var custom = false
    @State private var customMB = ""
    @State private var label = ""
    @State private var error: String?

    private var chosenKind: Kind { Kind(rawValue: kind) ?? .floppy }
    private var chosenFloppy: FloppyType { FloppyType(rawValue: floppy) ?? .dos144 }
    private var chosenFormat: DiskImageMaker.Format { DiskImageMaker.Format(rawValue: format) ?? .fat16 }
    private var megabytes: Int64 { custom ? (Int64(customMB.trimmingCharacters(in: .whitespaces)) ?? 0) : Int64(sizeMB) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Image").font(.title2.bold())
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                if chosenKind == .floppy {
                    Picker("Format", selection: $floppy) {
                        ForEach(FloppyType.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    TextField("Disk name (optional)", text: $label)
                } else {
                    Picker("Size", selection: Binding(get: { custom ? -1 : sizeMB }, set: { v in
                        if v == -1 { custom = true } else { custom = false; sizeMB = v }
                    })) {
                        ForEach(DiskImageMaker.presetSizesMB.map(Int.init), id: \.self) {
                            Text(DiskImageMaker.label(forMB: Int64($0))).tag($0)
                        }
                        Divider()
                        Text("Custom…").tag(-1)
                    }
                    if custom {
                        TextField("Size in MB", text: $customMB)
                    }
                    Picker("Format", selection: $format) {
                        Text("FAT16 (older machines; up to 2 GB per partition)").tag(DiskImageMaker.Format.fat16.rawValue)
                        Text("FAT32 (Windows 95 OSR2 and later, Macs, most modern kit)").tag(DiskImageMaker.Format.fat32.rawValue)
                    }
                    TextField("Disk name (optional)", text: $label)
                }
            }
            .formStyle(.grouped)

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create…") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenKind == .hardDisk && megabytes <= 0)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var note: String {
        switch chosenKind {
        case .floppy:
            switch chosenFloppy {
            case .akai3000, .akai1000:
                return "A blank Akai floppy, the format S-series samplers write. Files can be copied on and off it as they are (.s3, .p1…)."
            default:
                return "A blank DOS floppy for a Gotek running FlashFloppy or HxC. Most synths, samplers and PCs that use 3.5\" disks read DOS 720 KB or 1.44 MB."
            }
        case .hardDisk:
            let parts = chosenFormat == .fat16 && megabytes > DiskImageMaker.maxFAT16PartitionMB
                ? " Over 2 GB, FAT16 images are split into up to four partitions."
                : ""
            return "Name it the way your adapter expects: HD10_512.hda is SCSI ID 1, LUN 0, 512-byte sectors on ZuluSCSI and BlueSCSI. The image takes no space until it's filled (on an APFS disk), but an SD card needs its full size.\(parts)"
        }
    }

    private func create() {
        error = nil
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch chosenKind {
        case .floppy:
            panel.nameFieldStringValue = "Floppy.img"
            panel.message = "Save the new floppy image (on the Gotek's USB stick, for example)"
        case .hardDisk:
            panel.nameFieldStringValue = "HD10_512.hda"
            panel.message = "Save the new hard disk image (on the adapter's SD card, for example)"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch chosenKind {
            case .floppy:
                let data: Data
                switch chosenFloppy {
                case .dos144: data = DiskImageMaker.floppy(.hd144, label: label)
                case .dos720: data = DiskImageMaker.floppy(.dd720, label: label)
                case .dos288: data = DiskImageMaker.floppy(.ed288, label: label)
                case .akai3000, .akai1000:
                    var disk = AkaiDisk.blank(chosenFloppy == .akai3000 ? .s3000 : .s1000)
                    if !label.isEmpty { disk.setVolumeName(label) }
                    data = disk.data
                }
                try data.write(to: url)
            case .hardDisk:
                try DiskImageMaker.createHardDisk(at: url, totalMB: megabytes, format: chosenFormat, label: label)
            }
            dismiss()
            workspace.open(url)
            workspace.rescanLibrary()
        } catch {
            self.error = "Couldn't create the image. \(error.localizedDescription)"
        }
    }
}
