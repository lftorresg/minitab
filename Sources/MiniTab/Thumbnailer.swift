import ScreenCaptureKit

/// Window snapshots via ScreenCaptureKit (requires Screen Recording permission).
/// Includes windows on other Spaces. Images stay in memory only; nothing is written to disk.
/// DRM-protected video captures as black; that's macOS behaviour, not a bug.
enum Thumbnailer {
    /// Captures each window scaled to fit `pixelSize` (the on-screen slot size, so no wasted pixels).
    static func capture(ids: [CGWindowID], pixelSize: CGSize) async -> [CGWindowID: CGImage] {
        guard !ids.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return [:] }

        let wanted = Set(ids)
        let targets = content.windows.filter { wanted.contains($0.windowID) }

        return await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in targets {
                group.addTask {
                    let frame = window.frame
                    let scale = min(pixelSize.width / max(frame.width, 1),
                                    pixelSize.height / max(frame.height, 1), 2)
                    let config = SCStreamConfiguration()
                    config.width = max(Int(frame.width * scale), 1)
                    config.height = max(Int(frame.height * scale), 1)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                            configuration: config)
                    return (window.windowID, image)
                }
            }
            var images: [CGWindowID: CGImage] = [:]
            for await (id, image) in group {
                if let image { images[id] = image }
            }
            return images
        }
    }
}
