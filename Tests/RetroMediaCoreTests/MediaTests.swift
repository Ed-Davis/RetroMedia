import XCTest
@testable import RetroMediaCore

final class MediaTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RetroMediaMedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func copyFixture(_ name: String) throws -> URL {
        let source = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "img", subdirectory: "Fixtures"))
        let destination = folder.appendingPathComponent("\(name).img")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func newFloppy(_ name: String = "floppy.img") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try DiskImageMaker.floppy(.hd144).write(to: url)
        return url
    }

    /// A folder on the Mac: "Song 1.wav", "notes.txt", "Sub folder/deep file.bin", plus a .DS_Store.
    private func macFolder() throws -> URL {
        let root = folder.appendingPathComponent("Source \(UUID().uuidString.prefix(4))")
        let sub = root.appendingPathComponent("Sub folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(count: 3000).write(to: root.appendingPathComponent("Song 1.wav"))
        try Data("hello".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data(repeating: 7, count: 70_000).write(to: sub.appendingPathComponent("deep file.bin"))
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        return root
    }

    // MARK: Opening

    func testOpenerRecognisesEachKind() throws {
        XCTAssertTrue(try MediaOpener.open(try newFloppy()).first is FATMedium)
        XCTAssertTrue(try MediaOpener.open(try copyFixture("s3000-fixture")).first is AkaiMedium)
        let hd = folder.appendingPathComponent("HD00_512.hda")
        try DiskImageMaker.createHardDisk(at: hd, totalMB: 4200, format: .fat16, label: "X")
        XCTAssertEqual(try MediaOpener.open(hd).count, 3, "one medium per partition")
        let junk = folder.appendingPathComponent("junk.img")
        try Data(count: AkaiDisk.imageSize).write(to: junk)
        XCTAssertThrowsError(try MediaOpener.open(junk))
    }

    // MARK: Akai

    func testAkaiFilesGoOnAndOffAsTheyAre() throws {
        let akai = try XCTUnwrap(try MediaOpener.open(try copyFixture("s3000-fixture")).first as? AkaiMedium)
        XCTAssertEqual(akai.formatName, "Akai S3000")
        let items = try akai.list(.root)
        XCTAssertEqual(items.map(\.name), ["SINE 440.s3", "TEST PROGRAM.p3", "LOW 220.s3"])
        XCTAssertEqual(items[0].kindLabel, "Akai sample")

        // Off to a DOS floppy and back onto an S1000 disk (the sample's header is converted).
        let dos = try XCTUnwrap(try MediaOpener.open(try newFloppy()).first)
        let out = MediaTransfer.copy([items[0]], from: akai, to: dos, folder: .root, conflict: .keepBoth)
        XCTAssertEqual(out.copied, ["SINE 440.s3"], "\(out)")
        let s1000 = try XCTUnwrap(try MediaOpener.open(try copyFixture("s1000-fixture")).first)
        let onDOS = try XCTUnwrap(try dos.list(.root).first)
        let back = MediaTransfer.copy([onDOS], from: dos, to: s1000, folder: .root, conflict: .keepBoth)
        XCTAssertEqual(back.copied, ["SINE 440 2.s1"], "\(back)")
        let reopened = try AkaiDisk(contentsOf: s1000.url)
        XCTAssertEqual(reopened.entries.last?.type, 0x73)
        XCTAssertEqual(reopened.entries.last?.size, Int(items[0].size) - 42)

        // Other files can't go on an Akai disk.
        let txt = folder.appendingPathComponent("readme.txt")
        try Data("x".utf8).write(to: txt)
        let refused = MediaTransfer.importURLs([txt], to: s1000, folder: .root, conflict: .keepBoth)
        XCTAssertEqual(refused.failed.count, 1)
    }

    // MARK: ISO

    func testISOImagesAreReadOnlyAndBrowsable() async throws {
        let source = try macFolder()
        let iso = folder.appendingPathComponent("disc.iso")
        let made = try await Shell.run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "MYDISC",
                                                            "-o", iso.path, source.path])
        XCTAssertEqual(made.status, 0, made.error)

        let medium = try XCTUnwrap(try MediaOpener.open(iso).first as? ISOMedium)
        XCTAssertTrue(medium.isReadOnly)
        XCTAssertEqual(medium.formatName, "ISO 9660 (Joliet)")
        XCTAssertEqual(medium.volumeName, "MYDISC")
        let top = try medium.list(.root)
        XCTAssertTrue(Set(top.map(\.name)).isSuperset(of: ["Song 1.wav", "notes.txt", "Sub folder"]), "\(top.map(\.name))")
        let notes = try XCTUnwrap(top.first { $0.name == "notes.txt" })
        XCTAssertEqual(try medium.read(notes), Data("hello".utf8))
        let sub = try XCTUnwrap(top.first { $0.name == "Sub folder" })
        let deep = try XCTUnwrap(try medium.list(XCTUnwrap(medium.folder(of: sub))).first)
        XCTAssertEqual(deep.name, "deep file.bin")
        XCTAssertEqual(try medium.read(deep), Data(repeating: 7, count: 70_000))
        XCTAssertThrowsError(try medium.addFile(named: "x", contents: Data(), in: .root))

        // Dragging a folder off the CD onto a floppy.
        let floppy = try XCTUnwrap(try MediaOpener.open(try newFloppy()).first)
        let report = MediaTransfer.copy([sub, notes], from: medium, to: floppy, folder: .root, conflict: .keepBoth)
        XCTAssertEqual(report.failed, [])
        let copiedSub = try XCTUnwrap(try floppy.list(.root).first { $0.name == "Sub folder" })
        let copiedDeep = try XCTUnwrap(try floppy.list(XCTUnwrap(floppy.folder(of: copiedSub))).first)
        XCTAssertEqual(try floppy.read(copiedDeep), Data(repeating: 7, count: 70_000))
    }

    // MARK: Transfers

    func testImportingFoldersAndConflicts() async throws {
        let source = try macFolder()
        let floppyURL = try newFloppy()
        let floppy = try XCTUnwrap(try MediaOpener.open(floppyURL).first)
        let contents = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(MediaTransfer.bytesNeeded(contents, on: floppy), 70_000)

        let first = MediaTransfer.importURLs([source], to: floppy, folder: .root, conflict: .keepBoth)
        XCTAssertEqual(first.failed, [])
        XCTAssertEqual(Set(first.copied), ["Song 1.wav", "notes.txt", "deep file.bin"])
        let dir = try XCTUnwrap(try floppy.list(.root).first)
        let inside = try floppy.list(XCTUnwrap(floppy.folder(of: dir)))
        XCTAssertEqual(Set(inside.map(\.name)), ["Song 1.wav", "notes.txt", "Sub folder"], ".DS_Store left behind")

        let into = try XCTUnwrap(floppy.folder(of: dir))
        let file = source.appendingPathComponent("notes.txt")
        XCTAssertEqual(MediaTransfer.conflicts(["notes.txt", "new.txt"], in: floppy, folder: into), ["notes.txt"])
        XCTAssertEqual(MediaTransfer.importURLs([file], to: floppy, folder: into, conflict: .skip).skipped, ["notes.txt"])
        XCTAssertEqual(MediaTransfer.importURLs([file], to: floppy, folder: into, conflict: .keepBoth).copied, ["notes 2.txt"])
        try Data("changed".utf8).write(to: file)
        XCTAssertEqual(MediaTransfer.importURLs([file], to: floppy, folder: into, conflict: .replace).copied, ["notes.txt"])
        let replaced = try XCTUnwrap(try floppy.list(into).first { $0.name == "notes.txt" })
        XCTAssertEqual(try floppy.read(replaced), Data("changed".utf8))

        // Out to the Mac again, folders and all.
        let out = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let exported = MediaTransfer.export([dir], from: floppy, to: out, conflict: .keepBoth)
        XCTAssertEqual(exported.failed, [])
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(dir.name).appendingPathComponent("Sub folder/deep file.bin")),
                       Data(repeating: 7, count: 70_000))

        let problems = try await Shell.fsck(floppyURL)
        XCTAssertEqual(problems, [])
    }

    func testCopyBetweenAFloppyAndAHardDisk() async throws {
        let hdURL = folder.appendingPathComponent("HD10_512.hda")
        try DiskImageMaker.createHardDisk(at: hdURL, totalMB: 64, format: .fat32, label: "SCSI")
        let hd = try XCTUnwrap(try MediaOpener.open(hdURL).first)
        let floppy = try XCTUnwrap(try MediaOpener.open(try newFloppy()).first)
        _ = MediaTransfer.importURLs([try macFolder()], to: hd, folder: .root, conflict: .keepBoth)
        let top = try hd.list(.root)
        let report = MediaTransfer.copy(top, from: hd, to: floppy, folder: .root, conflict: .keepBoth)
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(try floppy.list(.root).map(\.name), top.map(\.name))
        let problems = try await Shell.fsck(hdURL)
        XCTAssertEqual(problems, [])
    }
}
