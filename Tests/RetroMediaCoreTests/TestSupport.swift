import Foundation
import XCTest

/// Runs command-line tools. RetroMedia never uses hdiutil or fsck;
/// the tests use them to check that macOS's own FAT code agrees with what
/// RetroMedia's FAT code wrote.
enum Shell {
    static func run(_ tool: String, _ args: [String]) async throws -> (status: Int32, output: Data, error: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, outData, String(decoding: errData, as: UTF8.self))
        }.value
    }

    /// Attaches a raw image without mounting it; returns the whole-disk
    /// device and its partition devices.
    static func attachRaw(_ url: URL) async throws -> (whole: String, slices: [String]) {
        let attach = try await run("/usr/bin/hdiutil", ["attach", "-nomount", "-plist",
                                                       "-imagekey", "diskimage-class=CRawDiskImage", url.path])
        XCTAssertEqual(attach.status, 0, attach.error)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any])
        let devices = ((plist["system-entities"] as? [[String: Any]]) ?? []).compactMap { $0["dev-entry"] as? String }
        let whole = try XCTUnwrap(devices.min { $0.count < $1.count })
        let slices = devices.filter { $0 != whole }
        return (whole, slices.isEmpty ? [whole] : slices)
    }

    /// fsck_msdos -n on every partition of the image. Returns problems found.
    static func fsck(_ url: URL) async throws -> [String] {
        let (whole, slices) = try await attachRaw(url)
        defer { Task { _ = try? await run("/usr/bin/hdiutil", ["detach", "-force", whole]) } }
        var problems: [String] = []
        for slice in slices {
            let result = try await run("/sbin/fsck_msdos", ["-n", slice])
            if result.status != 0 {
                problems.append("\(slice): \(String(decoding: result.output, as: UTF8.self)) \(result.error)")
            }
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", "-force", whole])
        return problems
    }

    /// Mounts the image read-only and returns the mount points.
    static func mountReadOnly(_ url: URL) async throws -> (whole: String, mounts: [URL]) {
        let attach = try await run("/usr/bin/hdiutil", ["attach", "-readonly", "-plist", "-nobrowse",
                                                       "-imagekey", "diskimage-class=CRawDiskImage", url.path])
        XCTAssertEqual(attach.status, 0, attach.error)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: attach.output, format: nil) as? [String: Any])
        let entities = (plist["system-entities"] as? [[String: Any]]) ?? []
        let whole = try XCTUnwrap(entities.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count })
        let mounts = entities
            .compactMap { e -> (String, String)? in
                guard let m = e["mount-point"] as? String else { return nil }
                return (e["dev-entry"] as? String ?? "", m)
            }
            .sorted { $0.0.compare($1.0, options: .numeric) == .orderedAscending }
            .map { URL(fileURLWithPath: $0.1) }
        return (whole, mounts)
    }

    static func detach(_ device: String) async {
        _ = try? await run("/usr/bin/hdiutil", ["detach", "-force", device])
    }
}
