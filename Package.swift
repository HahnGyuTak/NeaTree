// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeaTree",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrganizerCore", targets: ["OrganizerCore"]),
        .library(name: "OrganizerDesignSystem", targets: ["OrganizerDesignSystem"]),
        .library(name: "OrganizerAppSupport", targets: ["OrganizerAppSupport"]),
        .executable(name: "file-organizer", targets: ["OrganizerApp"]),
        .executable(name: "organizer", targets: ["OrganizerCLI"]),
        .executable(name: "organizer-design-preview", targets: ["OrganizerDesignPreview"])
    ],
    targets: [
        .target(name: "OrganizerCore"),
        .target(name: "OrganizerDesignSystem"),
        .target(name: "OrganizerAppSupport", dependencies: ["OrganizerCore"]),
        .executableTarget(name: "OrganizerApp", dependencies: ["OrganizerCore", "OrganizerDesignSystem", "OrganizerAppSupport"]),
        .executableTarget(name: "OrganizerCLI", dependencies: ["OrganizerCore"]),
        .executableTarget(name: "OrganizerDesignPreview", dependencies: ["OrganizerDesignSystem"]),
        .testTarget(name: "OrganizerCoreTests", dependencies: ["OrganizerCore"]),
        .testTarget(name: "OrganizerAppSupportTests", dependencies: ["OrganizerCore", "OrganizerAppSupport"])
    ]
)
