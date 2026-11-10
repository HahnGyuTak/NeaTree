// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileOrganizer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrganizerCore", targets: ["OrganizerCore"]),
        .library(name: "OrganizerDesignSystem", targets: ["OrganizerDesignSystem"]),
        .executable(name: "organizer", targets: ["OrganizerCLI"]),
        .executable(name: "organizer-design-preview", targets: ["OrganizerDesignPreview"])
    ],
    targets: [
        .target(name: "OrganizerCore"),
        .target(name: "OrganizerDesignSystem"),
        .executableTarget(name: "OrganizerCLI", dependencies: ["OrganizerCore"]),
        .executableTarget(name: "OrganizerDesignPreview", dependencies: ["OrganizerDesignSystem"]),
        .testTarget(name: "OrganizerCoreTests", dependencies: ["OrganizerCore"])
    ]
)
