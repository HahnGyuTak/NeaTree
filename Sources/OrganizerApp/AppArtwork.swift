import AppKit

/// The approved Liquid Glass app icon and mushroom-capped document menu symbol.
@MainActor
enum OrganizerArtwork {
    private static let menuBarSize = NSSize(width: 18, height: 18)

    private static var resourceBundle: Bundle? {
        // Packaged apps must resolve their own resources after relocation, without
        // depending on SwiftPM's absolute development-build fallback path.
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("NeaTree_OrganizerApp.bundle")) {
            return bundle
        }
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module
    }

    static func menuBarIcon() -> NSImage? {
        let image = NSImage(size: menuBarSize)
        for name in ["MenuBarTemplate", "MenuBarTemplate@2x"] {
            guard let url = resourceBundle?.url(forResource: name, withExtension: "png"),
                  let source = NSImage(contentsOf: url) else { continue }
            for representation in source.representations {
                representation.size = menuBarSize
                image.addRepresentation(representation)
            }
        }
        guard !image.representations.isEmpty else {
            // Keep the status controls reachable if an installation is damaged.
            NSLog("NeaTree: menu-bar artwork is missing; using the recovery symbol.")
            let fallback = NSImage(systemSymbolName: "doc", accessibilityDescription: "NeaTree")
            fallback?.size = menuBarSize
            fallback?.isTemplate = true
            return fallback
        }
        image.isTemplate = true
        return image
    }

    static func installDevelopmentAppIcon() {
        // Finder/Dock use the packaged Info.plist icon. A bare `swift run`
        // executable has no icon metadata, so give that process the same artwork.
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
              let url = resourceBundle?.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}
