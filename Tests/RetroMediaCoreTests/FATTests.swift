import XCTest
@testable import RetroMediaCore

final class FATTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RetroMediaFAT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func floppy(_ type: DiskImageMaker.Floppy = .hd144, label: String = "") throws -> URL {
        let url = folder.appendingPathComponent("\(UUID().uuidString.prefix(6)).img")
        try DiskImageMaker.floppy(type, label: label).write(to: url)
        return url
    }

    private func hardDisk(_ mb: Int64, _ format: DiskImageMaker.Format, label: String = "RETRO") throws -> URL {
        let url = folder.appendingPathComponent("HD10_512-\(UUID().uuidString.prefix(6)).hda")
        try DiskImageMaker.createHardDisk(at: url, totalMB: mb, format: format, label: label)
        return url
    }

    private func checkWithMacOS(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let problems = try await Shell.fsck(url)
        XCTAssertEqual(problems, [], file: file, line: line)
    }

    // MARK: Making images

    func testBlankFloppiesAreStandardDOSDisks() async throws {
        for (type, clusters) in [(DiskImageMaker.Floppy.dd720, 713), (.hd144, 2847), (.ed288, 2863)] {
            let url = try floppy(type, label: "Disk 1")
            XCTAssertEqual(try Data(contentsOf: url).count, type.bytes)
            let disk = try FATDiskImage(url: url)
            XCTAssertEqual(disk.volumes.count, 1)
            XCTAssertEqual(disk.volumes[0].kind, .fat12)
            XCTAssertEqual(disk.volumes[0].label, "DISK 1")
            XCTAssertEqual(disk.volumes[0].clusterCount, clusters, "\(type)")
            try await checkWithMacOS(url)
        }
    }

    func testHardDiskImages() async throws {
        let fat16 = try hardDisk(100, .fat16)
        let d16 = try FATDiskImage(url: fat16)
        XCTAssertEqual(d16.volumes.map(\.kind), [.fat16])
        XCTAssertEqual(d16.volumes[0].label, "RETRO")
        try await checkWithMacOS(fat16)

        let fat32 = try hardDisk(300, .fat32)
        let d32 = try FATDiskImage(url: fat32)
        XCTAssertEqual(d32.volumes.map(\.kind), [.fat32])
        XCTAssertGreaterThan(d32.volumes[0].clusterCount, 65_525)
        XCTAssertEqual(d32.volumes[0].label, "RETRO")
        try await checkWithMacOS(fat32)

        let split = try hardDisk(4200, .fat16, label: "BIG")
        let parts = try FATDiskImage(url: split)
        XCTAssertEqual(parts.volumes.count, 3)
        XCTAssertEqual(parts.volumes.map(\.label), ["BIG_A", "BIG_B", "BIG_C"])
        try await checkWithMacOS(split)
    }

    // MARK: Names

    func testLongNamesKeepTheirNamesWithAnAlias() async throws {
        for url in [try floppy(), try hardDisk(64, .fat16), try hardDisk(64, .fat32)] {
            let volume = try FATDiskImage(url: url).volumes[0]
            try volume.createFile(in: .root, name: "Hello World.txt", contents: Data("hi".utf8))
            try volume.createFile(in: .root, name: "README.TXT", contents: Data("a".utf8))
            try volume.createFile(in: .root, name: "notes.txt", contents: Data("b".utf8))
            try volume.createFile(in: .root, name: "Über café – track 1 (final mix).wav", contents: Data(count: 5000))
            try volume.createFile(in: .root, name: String(repeating: "x", count: 120) + ".bin", contents: Data(count: 10))
            try volume.createFile(in: .root, name: ".hidden", contents: Data())
            let list = try volume.list(.root)
            XCTAssertEqual(Set(list.map(\.name)), ["Hello World.txt", "README.TXT", "notes.txt",
                                                   "Über café – track 1 (final mix).wav",
                                                   String(repeating: "x", count: 120) + ".bin", ".hidden"])
            let hello = try XCTUnwrap(list.first { $0.name == "Hello World.txt" })
            XCTAssertEqual(hello.shortName, "HELLOW~1.TXT")
            XCTAssertEqual(list.first { $0.name == "notes.txt" }?.shortName, "NOTES.TXT", "lower case kept with flags, no long name")
            XCTAssertEqual(list.first { $0.name == "notes.txt" }?.slots.count, 1)
            XCTAssertThrowsError(try volume.createFile(in: .root, name: "hello world.TXT", contents: Data()), "names are case-insensitive")
            XCTAssertThrowsError(try volume.createFile(in: .root, name: "a:b", contents: Data()))
            XCTAssertEqual(try volume.read(hello), Data("hi".utf8))
            try await checkWithMacOS(url)

            // macOS sees the same names.
            let (device, mounts) = try await Shell.mountReadOnly(url)
            let seen = Set(try FileManager.default.contentsOfDirectory(atPath: try XCTUnwrap(mounts.first).path))
            XCTAssertTrue(seen.isSuperset(of: ["Hello World.txt", "README.TXT", "notes.txt", "Über café – track 1 (final mix).wav"]), "\(seen)")
            await Shell.detach(device)
        }
    }

    func testRenameDeleteAndFoldersThatGrow() async throws {
        for url in [try floppy(), try hardDisk(64, .fat32)] {
            let volume = try FATDiskImage(url: url).volumes[0]
            let dir = try volume.createDirectory(in: .root, name: "My Samples")
            // Enough long names to need several clusters of directory.
            for i in 0..<120 {
                try volume.createFile(in: dir.asDirectory, name: "Sample number \(i) with a long name.wav", contents: Data(count: 100))
            }
            XCTAssertEqual(try volume.list(dir.asDirectory).count, 120)
            let first = try XCTUnwrap(try volume.list(dir.asDirectory).first)
            let renamed = try volume.rename(first, to: "Renamed sample.wav")
            XCTAssertEqual(renamed.name, "Renamed sample.wav")
            XCTAssertEqual(try volume.read(renamed), Data(count: 100))
            let renamedShort = try volume.rename(renamed, to: "KICK.WAV")
            XCTAssertEqual(renamedShort.slots.count, 1)
            try await checkWithMacOS(url)

            let free = volume.freeBytes
            try volume.delete(try XCTUnwrap(try volume.list(.root).first { $0.name == "My Samples" }))
            XCTAssertGreaterThan(volume.freeBytes, free)
            XCTAssertEqual(try volume.list(.root).count, 0)
            try await checkWithMacOS(url)
        }
    }

    func testFloppyTopLevelFillsUp() throws {
        let volume = try FATDiskImage(url: try floppy(.dd720)).volumes[0]
        XCTAssertThrowsError(try (0..<200).forEach { i in
            try volume.createFile(in: .root, name: "F\(i).TXT", contents: Data())
        }) { error in
            guard case MediaError.directoryFull = error else { return XCTFail("\(error)") }
        }
    }

    func testFullDiskWritesNothing() throws {
        let url = try floppy()
        let volume = try FATDiskImage(url: url).volumes[0]
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try volume.createFile(in: .root, name: "big.bin", contents: Data(count: 2_000_000)))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testVolumeLabel() async throws {
        let url = try hardDisk(64, .fat32, label: "")
        let volume = try FATDiskImage(url: url).volumes[0]
        XCTAssertEqual(volume.label, "")
        try volume.setLabel("Games")
        XCTAssertEqual(try FATDiskImage(url: url).volumes[0].label, "GAMES")
        try await checkWithMacOS(url)
    }

    func testFilesMacOSWroteReadBack() async throws {
        let url = try hardDisk(64, .fat16)
        // Mount writable with hdiutil and let macOS write some files.
        let attach = try await Shell.run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse",
                                                              "-imagekey", "diskimage-class=CRawDiskImage", url.path])
        XCTAssertEqual(attach.status, 0, attach.error)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any])
        let entities = (plist["system-entities"] as? [[String: Any]]) ?? []
        let mount = try XCTUnwrap(entities.compactMap { $0["mount-point"] as? String }.first)
        let whole = try XCTUnwrap(entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count })
        let dir = URL(fileURLWithPath: mount).appendingPathComponent("From the Mac")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("long name".utf8).write(to: dir.appendingPathComponent("A rather long file name.txt"))
        await Shell.detach(whole)

        let volume = try FATDiskImage(url: url).volumes[0]
        let folder = try XCTUnwrap(try volume.list(.root).first { $0.name == "From the Mac" })
        let file = try XCTUnwrap(try volume.list(folder.asDirectory).first { $0.name == "A rather long file name.txt" })
        XCTAssertEqual(try volume.read(file), Data("long name".utf8))
    }
}
