// swift-tools-version:5.9
import PackageDescription

// RetroMedia: browse and edit the disk images used by Gotek floppy emulators
// and SCSI-to-SD adapters (ZuluSCSI, BlueSCSI, SCSI2SD), and read CD .iso files.
let package = Package(
    name: "RetroMedia",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RetroMediaCore",
            path: "Sources/RetroMediaCore"
        ),
        .executableTarget(
            name: "RetroMedia",
            dependencies: ["RetroMediaCore"],
            path: "Sources/RetroMedia",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "RetroMediaCoreTests",
            dependencies: ["RetroMediaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
