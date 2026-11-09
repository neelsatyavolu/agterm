import AppKit

/// Images pasted or dropped into the chat's box, as files the agent can read: image files as
/// they are, anything else (a screenshot on the clipboard, a HEIC or TIFF file) saved as a PNG
/// in a temporary folder. The agents take PNG, JPEG, GIF and WebP.
enum ChatImages {
    static let readable: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("agterm-chat-images", isDirectory: true) }

    /// The image paths for what's on the pasteboard, or nil when it holds no images (text, or
    /// files that aren't images), so it pastes as usual.
    static func paths(from pasteboard: NSPasteboard) -> [String]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            let images = urls.compactMap(path(forFile:))
            return images.count == urls.count ? images : nil
        }
        guard pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard), let path = save(image) else { return nil }
        return [path]
    }

    /// An image file the agent can read as it is, or a PNG copy of one it can't; nil for other files.
    private static func path(forFile url: URL) -> String? {
        if readable.contains(url.pathExtension.lowercased()), !url.path.contains(" ") { return url.path }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .image),
              let image = NSImage(contentsOf: url) else { return nil }
        return save(image)
    }

    private static func save(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let url = folder.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            NSLog("agterm: couldn't save a pasted image: \(error)")
            return nil
        }
        return url.path
    }
}
